import Foundation

/// Spoken commands matched on the raw ASR transcript: the send word at the
/// end of a dictation (press Return after pasting) and the wake phrase that
/// starts a hands-free dictation. Pure, so the matching is tested without
/// audio. Case- and punctuation-insensitive, like `TranscriptGuard`.
enum VoiceCommands {
    /// If `transcript` ends with `sendWord` (one or more words), returns the
    /// text before it with trailing separators trimmed (possibly empty: the
    /// user said only the send word). nil when it doesn't end with it, or
    /// `sendWord` is blank.
    static func stripSendWord(from transcript: String, sendWord: String) -> String? {
        let target = words(in: sendWord).map(\.text)
        let found = words(in: transcript)
        guard !target.isEmpty, found.count >= target.count else { return nil }
        let tail = found.suffix(target.count)
        guard tail.map(\.text) == target, let first = tail.first else { return nil }
        // Only punctuation may follow the send word ("…, send."), and that
        // holds by construction: it is the last word.
        let before = transcript[..<first.range.lowerBound]
        return before.trimmingCharacters(in: trailingSeparators)
    }

    /// True when `transcript` contains `phrase` as a run of whole words,
    /// allowing a small spelling slip: ASR renders a made-up word like
    /// "murmur" inconsistently ("murmer", "mur mur").
    static func containsWakePhrase(_ transcript: String, phrase: String) -> Bool {
        let target = words(in: phrase).map(\.text).joined(separator: " ")
        guard !target.isEmpty else { return false }
        let heard = words(in: transcript).map(\.text)
        let tolerance = max(1, target.count / 6)
        // Window sizes around the phrase's word count absorb a split or
        // merged word ("mur mur" / "heymurmur").
        let n = words(in: phrase).count
        for size in max(1, n - 1)...(n + 1) where size <= heard.count {
            for start in 0...(heard.count - size) {
                let window = heard[start..<(start + size)].joined(separator: " ")
                if editDistance(window, target) <= tolerance { return true }
            }
        }
        return false
    }

    private static let trailingSeparators = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: ",;:-–—"))

    private struct Word {
        let text: String
        let range: Range<String.Index>
    }

    private static func words(in text: String) -> [Word] {
        var result: [Word] = []
        var start: String.Index?
        for index in text.indices {
            let ch = text[index]
            let isWordChar = ch.isLetter || ch.isNumber || ch == "'"
            if isWordChar, start == nil {
                start = index
            } else if !isWordChar, let s = start {
                result.append(Word(text: text[s..<index].lowercased(), range: s..<index))
                start = nil
            }
        }
        if let s = start {
            result.append(Word(text: text[s...].lowercased(), range: s..<text.endIndex))
        }
        return result
    }

    /// Levenshtein distance over characters.
    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(
                    previous[j] + 1,
                    current[j - 1] + 1,
                    previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                )
            }
            previous = current
        }
        return previous[b.count]
    }
}
