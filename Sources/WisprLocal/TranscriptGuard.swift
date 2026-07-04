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
}
