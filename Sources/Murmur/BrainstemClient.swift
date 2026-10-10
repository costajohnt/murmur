import Foundation

/// Client for brainstem's `/capture` endpoint — the vault-capture half of the
/// two-way voice loop. Entirely off unless `AppSettings.brainstemURL` is
/// configured; callers gate on that before ever constructing this.
struct BrainstemClient {
    let baseURL: String
    private let session: URLSession

    init(baseURL: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    enum CaptureError: LocalizedError {
        case invalidURL(String)
        case insecureURL(String)
        case invalidResponse
        case badStatus(Int, body: String)

        var errorDescription: String? {
            switch self {
            case .invalidURL(let base): return "Invalid brainstem URL: \(base)"
            case .insecureURL(let base):
                return "Brainstem URL must be https (plain http only for a Tailscale *.ts.net or 100.64.0.0/10 host, or localhost): \(base)"
            case .invalidResponse: return "Brainstem returned a non-HTTP response"
            // The body is kept on the case for callers that want it, but left
            // out of the description: this string is logged, and a server that
            // echoes the request would otherwise put transcript text in the log.
            case .badStatus(let code, _): return "Brainstem HTTP \(code)"
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
        guard let url = URL(string: trimmedBase + "/capture"), let host = url.host?.lowercased() else {
            throw CaptureError.invalidURL(baseURL)
        }
        guard Self.isAllowed(scheme: url.scheme?.lowercased(), host: host) else {
            throw CaptureError.insecureURL(baseURL)
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

    /// The transcript leaves the machine here, so plain http is only allowed
    /// where the transport is already private: Tailscale (WireGuard-encrypted
    /// MagicDNS names and CGNAT 100.64.0.0/10 addresses) or this machine.
    static func isAllowed(scheme: String?, host: String) -> Bool {
        switch scheme {
        case "https": return true
        case "http":
            if host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".ts.net") {
                return true
            }
            // Exactly four canonical decimal octets. A lenient parse would let
            // a public name like "100.64.1.2.example.com" through, and a
            // leading zero ("100.064.0.1") is octal to some resolvers.
            let parts = host.split(separator: ".", omittingEmptySubsequences: false)
            let octets = parts.compactMap { part in UInt8(part).flatMap { String($0) == part ? $0 : nil } }
            return parts.count == 4 && octets.count == 4
                && octets[0] == 100 && (64...127).contains(octets[1])
        default: return false
        }
    }

    // MARK: - "note to self" prefix routing

    /// The spoken prefix that routes a dictation to the vault instead of
    /// pasting it. Matched case-insensitively at the start of the raw ASR
    /// transcript (before cleanup, so the LLM cannot reword the prefix away).
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
