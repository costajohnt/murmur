import Foundation

/// Near-silence guard, applied right after ASR. Ambient noise produces tiny
/// transcripts (a real capture yielded just "S"), and the cleanup model
/// reliably hallucinates content for them ("Sorry, I didn't catch that.
/// Could you please repeat...?") — which then got injected into the user's
/// document and persisted. Transcripts that fail this check are DISCARDED:
/// no cleanup, no injection, no history entry — same outcome as a cancel.
enum TranscriptGuard {
    /// Minimum trimmed length that counts as meaningful speech. 2 keeps real
    /// short dictations ("no", "ok", "hi") while dropping single stray
    /// characters. Deliberately conservative — false discards would eat real
    /// speech, which is far worse than an occasional noise entry.
    static let minMeaningfulLength = 2

    /// True when the transcript is worth cleaning + injecting.
    static func isMeaningful(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minMeaningfulLength else { return false }
        // Punctuation/symbol-only output ("...", "- -") is noise too.
        return trimmed.contains { $0.isLetter || $0.isNumber }
    }

    /// Post-cleanup check: does `cleaned` still look like `raw` reformatted,
    /// rather than an answer to it or a rewrite? Word-level, case- and
    /// punctuation-insensitive. A formatter keeps most of the speaker's words
    /// and adds few of its own; "what is the capital of france" → "Paris."
    /// fails both.
    ///
    /// ponytail: crude bag-of-words heuristic. An answer that echoes the
    /// question ("The capital of France is Paris") still passes; a real
    /// semantic check needs a second model call. Dictations under
    /// `minWordsToCheck` words skip the check, since number formatting
    /// ("twenty five" → "25") legitimately replaces every word.
    static func isReformat(of raw: String, _ cleaned: String) -> Bool {
        let rawWords = words(raw)
        let cleanedWords = words(cleaned)
        guard rawWords.count >= minWordsToCheck else { return true }
        guard !cleanedWords.isEmpty else { return false }
        let rawSet = Set(rawWords)
        let cleanedSet = Set(cleanedWords)
        let kept = Double(rawWords.filter { cleanedSet.contains($0) || fillers.contains($0) }.count) / Double(rawWords.count)
        let ownWords = Double(cleanedWords.filter { rawSet.contains($0) }.count) / Double(cleanedWords.count)
        let growth = Double(cleanedWords.count) / Double(rawWords.count)
        return kept >= minFraction && ownWords >= minFraction && growth <= maxGrowth
    }

    static let minWordsToCheck = 3
    /// Share of the speaker's words the output must keep, and share of the
    /// output's words that must come from the speaker.
    static let minFraction = 0.5
    /// Output may not be more than this many times longer than the input.
    static let maxGrowth = 2.0
    private static let fillers: Set<String> = ["um", "uh", "er", "ah", "hmm", "mm", "like"]

    private static func words(_ text: String) -> [String] {
        text.lowercased()
            .split { !($0.isLetter || $0.isNumber || $0 == "'") }
            .map(String.init)
    }
}
