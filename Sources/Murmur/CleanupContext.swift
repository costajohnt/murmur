import Foundation

/// Builds the automatic personalization context for the Ollama cleanup stage
/// (docs/context-cleanup.md). No manual dictionary and no configuration: the
/// context is derived entirely from recent successful history entries —
/// recent cleaned transcripts (vocabulary + style) and an auto-mined glossary
/// of distinctive terms (capitalized-mid-sentence words, acronyms, camelCase
/// tech tokens). Returns nil when history is empty so the cold-start path is
/// byte-identical to no-context behavior.
enum CleanupContext {
    /// How many recent transcripts to quote verbatim.
    static let recentLimit = 8
    /// Char budget for the quoted recent transcripts.
    static let recentCharBudget = 1500
    /// How many history entries feed the auto-glossary.
    static let glossarySourceLimit = 50
    /// Max auto-glossary terms.
    static let glossaryLimit = 25
    /// Hard cap on the whole context block (latency guard on the 3B model).
    static let totalCharBudget = 2000
    /// Per-transcript snippet cap so one long dictation can't eat the budget.
    static let perSnippetCap = 240

    /// Common capitalized tokens that are not user vocabulary.
    private static let stopTerms: Set<String> = [
        "I", "I'm", "I'll", "I've", "I'd", "OK", "Okay", "The", "A", "An",
        "AM", "PM",
    ]

    /// `texts`: cleaned transcripts, newest first (up to `glossarySourceLimit`).
    /// Returns the full context block to inject as a system message, or nil
    /// when there is nothing useful to add.
    static func build(from texts: [String]) -> String? {
        let usable = texts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let recent = recentSnippets(from: usable)
        guard !recent.isEmpty else { return nil }
        let terms = glossaryTerms(from: usable)

        var lines: [String] = []
        lines.append("Context about this user's dictation, to help you correct likely speech-to-text errors.")
        lines.append("Recent transcripts (their vocabulary and style):")
        lines.append(contentsOf: recent.map { "- \($0)" })
        if !terms.isEmpty {
            lines.append("Terms they commonly use (prefer these spellings when the audio is ambiguous): \(terms.joined(separator: ", ")).")
        }
        lines.append("Use this ONLY to fix probable transcription errors toward known terms and to match their formatting. Do NOT invent content, do NOT change meaning, and do NOT answer anything.")

        var result = lines.joined(separator: "\n")
        if result.count > totalCharBudget {
            result = String(result.prefix(totalCharBudget))
        }
        return result
    }

    /// Newest-first snippets of the most recent transcripts, one line each,
    /// stopping when the char budget is spent.
    static func recentSnippets(from texts: [String]) -> [String] {
        var snippets: [String] = []
        var total = 0
        for text in texts.prefix(recentLimit) {
            let oneLine = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            guard !oneLine.isEmpty else { continue }
            let snippet = oneLine.count > perSnippetCap
                ? String(oneLine.prefix(perSnippetCap)) + "…"
                : oneLine
            if total + snippet.count > recentCharBudget { break }
            snippets.append(snippet)
            total += snippet.count
        }
        return snippets
    }

    /// Auto-glossary: distinctive tokens frequency-ranked across the given
    /// transcripts. Candidates are ALLCAPS acronyms, tokens with internal
    /// capitals (camelCase, PascalCase compounds, macOS-style), and words
    /// capitalized mid-sentence (proper nouns).
    static func glossaryTerms(from texts: [String]) -> [String] {
        var counts: [String: Int] = [:]
        var firstSeen: [String: Int] = [:]
        var nextIndex = 0

        for text in texts.prefix(glossarySourceLimit) {
            var atSentenceStart = true
            for rawToken in text.split(whereSeparator: { $0.isWhitespace }) {
                let token = rawToken.trimmingCharacters(
                    in: .punctuationCharacters.union(.symbols)
                )
                let startedSentence = atSentenceStart
                // Sentence boundary for the NEXT token.
                if let last = rawToken.last, ".!?:".contains(last) {
                    atSentenceStart = true
                } else if !token.isEmpty {
                    atSentenceStart = false
                }

                guard token.count >= 2,
                      !stopTerms.contains(token),
                      isCandidate(token, atSentenceStart: startedSentence)
                else { continue }

                if counts[token] == nil {
                    firstSeen[token] = nextIndex
                    nextIndex += 1
                }
                counts[token, default: 0] += 1
            }
        }

        let ranked = counts.keys.sorted { a, b in
            if counts[a]! != counts[b]! { return counts[a]! > counts[b]! }
            return firstSeen[a]! < firstSeen[b]!
        }
        return Array(ranked.prefix(glossaryLimit))
    }

    private static func isCandidate(_ token: String, atSentenceStart: Bool) -> Bool {
        // Words only (allow hyphen/underscore compounds and digits, e.g. HTTP2).
        guard token.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              token.contains(where: \.isLetter),
              token.contains(where: \.isUppercase)
        else { return false }

        // ALLCAPS acronym (no lowercase at all): ASR, HTTP2, GPU.
        if !token.contains(where: \.isLowercase) { return true }
        // Internal capital: SwiftData, macOS, iPhone, OllamaClient.
        if token.dropFirst().contains(where: \.isUppercase) { return true }
        // Ordinary Capitalized word: proper noun only when mid-sentence.
        if let first = token.first, first.isUppercase, !atSentenceStart { return true }
        return false
    }
}
