import Foundation

/// Client for brainstem's `/capture` endpoint — the vault-capture half of the
/// two-way voice loop (docs/superpowers/plans/2026-07-08-voice-loop.md, Task
/// C). Entirely off unless `AppSettings.brainstemURL` is configured; callers
/// gate on that before ever constructing this.
struct BrainstemClient {
    let baseURL: String
    private let session: URLSession

    init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    enum CaptureError: LocalizedError {
        case invalidURL(String)
        case invalidResponse
        case badStatus(Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let base): return "Invalid brainstem URL: \(base)"
            case .invalidResponse: return "Brainstem returned a non-HTTP response"
            case .badStatus(let code, let body): return "Brainstem HTTP \(code): \(body.prefix(200))"
            }
        }
    }

    private struct CaptureRequest: Encodable {
        let text: String
    }

    /// POSTs `text` to `{baseURL}/capture` as `{"text": ...}`. Success is any
    /// 2xx status; anything else (including a network failure) throws so the
    /// caller can fall back to pasting instead — vault-capture must never
    /// silently drop the transcript.
    func capture(_ text: String) async throws {
        let trimmedBase = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        guard let url = URL(string: trimmedBase + "/capture") else {
            throw CaptureError.invalidURL(baseURL)
        }

        var request = URLRequest(url: url, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(CaptureRequest(text: text))

        let data: Data
        let response: URLResponse
        (data, response) = try await session.data(for: request)

        guard let http = response as? HTTPURLResponse else {
            throw CaptureError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            throw CaptureError.badStatus(http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
    }

    // MARK: - "note to self" prefix routing

    /// The spoken prefix that routes a dictation to the vault instead of
    /// pasting it. Matched case-insensitively at the start of the (already
    /// cleaned-up) transcript.
    private static let prefix = "note to self"
    private static let separators: Set<Character> = [",", ":", "."]

    /// Returns the remainder of `transcript` with the "note to self" prefix
    /// (and an optional trailing comma/colon/period) stripped and trimmed, or
    /// nil when the transcript doesn't match the routing rule:
    /// - must start with "note to self", case-insensitive
    /// - must be followed by whitespace, one of `,:.`, or end of string (a
    ///   word boundary — "note to selfish..." is NOT a match)
    /// - the remainder after stripping must be non-empty (bare "note to
    ///   self" with nothing said after it is not worth capturing)
    static func noteToSelfRemainder(in transcript: String) -> String? {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= prefix.count else { return nil }

        let prefixEnd = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
        guard trimmed[trimmed.startIndex..<prefixEnd].caseInsensitiveCompare(prefix) == .orderedSame else {
            return nil
        }

        var rest = trimmed[prefixEnd...]
        if let first = rest.first {
            if separators.contains(first) {
                rest = rest.dropFirst()
            } else if !first.isWhitespace {
                // No word boundary right after the prefix (e.g. "selfish").
                return nil
            }
        }

        let remainder = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        return remainder.isEmpty ? nil : remainder
    }
}
