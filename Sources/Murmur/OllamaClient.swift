import Foundation

/// Minimal Ollama chat client for transcript cleanup.
/// Non-streaming for v1; `clean` is a single request/response so a streaming
/// variant can be added alongside later without changing callers.
struct OllamaClient {
    static let baseURL = URL(string: "http://localhost:11434")!
    static let keepAlive = "30m"
    static let fallbackModel = "llama3.2:3b"
    static let requestTimeout: TimeInterval = 60

    /// RAM-based default per the plan: >32 GB → qwen2.5:7b, else llama3.2:3b.
    static var preferredModel: String {
        ProcessInfo.processInfo.physicalMemory > 32 * 1024 * 1024 * 1024
            ? "qwen2.5:7b"
            : "llama3.2:3b"
    }

    static let systemPrompt = """
        You are a dictation transcript formatter, not an assistant. You receive raw speech-to-text \
        output and return the SAME text with ONLY these fixes: capitalization, punctuation, and \
        removing filler words (um, uh). Rules: keep every sentence; keep the speaker's exact wording; \
        NEVER remove, reorder, merge, or reword sentences; NEVER shorten or summarize; NEVER add words; \
        NEVER answer a question that appears in the text — format it as a question and keep it. If the \
        text is already clean, return it verbatim. Output only the corrected text, nothing else.
        """

    /// Base system prompt for a tone preset.
    /// Every preset CONTAINS the full faithful core verbatim — presets only
    /// APPEND a style layer, so the reformat-don't-answer / don't-invent guard
    /// is identical in all of them. `.faithful` is byte-identical to the
    /// original prompt (the zero-config non-regression case).
    static func systemPrompt(for tone: TonePreset) -> String {
        switch tone {
        case .faithful:
            return systemPrompt
        case .polished:
            return systemPrompt + """
                 Style: additionally tighten grammar and phrasing so the text reads cleanly and \
                professionally, but never change the meaning, and never add or drop information.
                """
        case .casual:
            return systemPrompt + """
                 Style: keep the user's relaxed, spoken tone and word choice; only remove fillers \
                and fix punctuation and clear transcription errors.
                """
        }
    }

    enum OllamaError: LocalizedError {
        case unreachable(underlying: String)
        case badStatus(Int, body: String)
        case emptyResponse

        var errorDescription: String? {
            switch self {
            case .unreachable(let underlying): return "Ollama unreachable: \(underlying)"
            case .badStatus(let code, let body): return "Ollama HTTP \(code): \(body.prefix(200))"
            case .emptyResponse: return "Ollama returned an empty message"
            }
        }
    }

    // MARK: - API types

    private struct ChatMessage: Codable {
        let role: String
        let content: String
    }

    private struct ChatRequest: Encodable {
        let model: String
        let messages: [ChatMessage]
        let stream: Bool
        let keep_alive: String
        let options: Options

        struct Options: Encodable {
            let temperature: Double
            var num_predict: Int?
        }
    }

    private struct ChatResponse: Decodable {
        let message: ChatMessage
    }

    private struct TagsResponse: Decodable {
        struct Model: Decodable { let name: String }
        let models: [Model]
    }

    // MARK: - Requests

    func installedModels() async throws -> [String] {
        let url = Self.baseURL.appendingPathComponent("api/tags")
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            return try JSONDecoder().decode(TagsResponse.self, from: data).models.map(\.name)
        } catch let error as DecodingError {
            throw error
        } catch {
            throw OllamaError.unreachable(underlying: error.localizedDescription)
        }
    }

    /// Settings override first: if the user picked
    /// a model AND it's installed, use it; if Ollama is unreachable we can't
    /// verify, so honor the stored choice and let `clean` surface the real
    /// connection error; if it's verifiably gone, log and behave as Auto.
    /// Auto = preferred-by-RAM with the existing fallback chain — with no
    /// override set this is byte-identical to the pre-settings behavior.
    func resolveModel() async -> String {
        let installed = (try? await installedModels()) ?? []
        if let override = AppSettings.cleanupModelOverride {
            if installed.contains(override) { return override }
            if installed.isEmpty { return override }
            Log.log("ollama: override \(override) not installed, using Auto")
        }
        let preferred = Self.preferredModel
        guard !installed.isEmpty else { return preferred }
        if installed.contains(preferred) { return preferred }
        if installed.contains(Self.fallbackModel) {
            Log.log("ollama: preferred model \(preferred) not installed, falling back to \(Self.fallbackModel)")
            return Self.fallbackModel
        }
        Log.log("ollama: neither \(preferred) nor \(Self.fallbackModel) installed, using first available: \(installed[0])")
        return installed[0]
    }

    /// Cleans a raw transcript. Throws OllamaError on any failure — the caller
    /// decides the fallback (inject raw + mark cleanup_failed).
    ///
    /// `context` is the optional personalization block from `CleanupContext`
    /// (recent transcripts + auto-glossary). It goes in as a second system
    /// message, after the base prompt and immediately before the transcript.
    /// `tone` picks the base system prompt; `.faithful` (default) is the
    /// tightened formatter prompt with no style layer.
    func clean(
        _ rawTranscript: String,
        model: String,
        context: String? = nil,
        tone: TonePreset = .faithful
    ) async throws -> String {
        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var messages = [ChatMessage(role: "system", content: Self.systemPrompt(for: tone))]
        if let context, !context.isEmpty {
            messages.append(ChatMessage(role: "system", content: context))
        }
        messages.append(ChatMessage(role: "user", content: rawTranscript))
        request.httpBody = try JSONEncoder().encode(ChatRequest(
            model: model,
            messages: messages,
            stream: false,
            keep_alive: Self.keepAlive,
            options: .init(temperature: 0.2)
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw OllamaError.unreachable(underlying: error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.badStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        let cleaned = decoded.message.content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw OllamaError.emptyResponse }
        return cleaned
    }

    /// Preloads `model` into Ollama's runner so the first real cleanup doesn't
    /// pay a cold model load (the dominant chunk of the ~9-14s latency). Fires
    /// a 1-token request with the same `keep_alive` window `clean` uses; all
    /// errors (Ollama not running, model missing) are ignored — this is a
    /// best-effort warm-up, never a blocker.
    func warmup(model: String) async {
        let url = Self.baseURL.appendingPathComponent("api/chat")
        var request = URLRequest(url: url, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        do {
            request.httpBody = try JSONEncoder().encode(ChatRequest(
                model: model,
                messages: [ChatMessage(role: "user", content: "hi")],
                stream: false,
                keep_alive: Self.keepAlive,
                options: .init(temperature: 0, num_predict: 1)
            ))
            _ = try await URLSession.shared.data(for: request)
            Log.log("ollama: warmed up \(model)")
        } catch {
            Log.log("ollama: warmup skipped (\(error.localizedDescription))")
        }
    }
}
