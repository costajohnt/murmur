import XCTest

final class TranscriptGuardReformatTests: XCTestCase {
    func testAcceptsFormattingFixes() {
        XCTAssertTrue(TranscriptGuard.isReformat(
            of: "uh so I think we should ship the release tomorrow morning",
            "So I think we should ship the release tomorrow morning."))
        XCTAssertTrue(TranscriptGuard.isReformat(
            of: "um what is the capital of france",
            "What is the capital of France?"))
    }

    func testRejectsAnAnswer() {
        XCTAssertFalse(TranscriptGuard.isReformat(of: "um what is the capital of france", "Paris."))
    }

    func testRejectsALongAnswerOrRewrite() {
        XCTAssertFalse(TranscriptGuard.isReformat(
            of: "write me a haiku about autumn",
            "Crimson leaves drifting, cool wind whispers through bare trees, autumn settles in."))
    }

    func testRejectsAnOutputThatBalloons() {
        XCTAssertFalse(TranscriptGuard.isReformat(
            of: "list the steps",
            "List the steps. Step one list the steps. Step two list the steps again."))
    }

    func testSkipsVeryShortDictations() {
        // Number formatting legitimately replaces every word.
        XCTAssertTrue(TranscriptGuard.isReformat(of: "twenty five", "25"))
    }
}

/// Pins the discard/keep boundary for ASR output.
final class TranscriptGuardTests: XCTestCase {
    private let discard = ["S", "s", ".", "", " ", "…", "- -", "??", "\n.\n", "7"]
    private let keep = [
        "no", "ok", "yes", "hi", "OK.", "42", "I do",
        "What is the capital of France?",
        "lets deploy to prox mocks over tail scale",
    ]

    func testDiscardsNoiseAndSingleCharacters() {
        for raw in discard {
            XCTAssertFalse(
                TranscriptGuard.isMeaningful(raw),
                "expected DISCARD for \"\(raw)\""
            )
        }
    }

    func testKeepsShortWordsAndSentences() {
        for raw in keep {
            XCTAssertTrue(
                TranscriptGuard.isMeaningful(raw),
                "expected KEEP for \"\(raw)\""
            )
        }
    }

    func testEmptyStringIsDiscarded() {
        XCTAssertFalse(TranscriptGuard.isMeaningful(""))
    }

    func testWhitespaceOnlyIsDiscarded() {
        XCTAssertFalse(TranscriptGuard.isMeaningful("   \n  "))
    }

    func testPunctuationOnlyRunIsDiscarded() {
        XCTAssertFalse(TranscriptGuard.isMeaningful("...")) // 3-char punctuation run
        XCTAssertFalse(TranscriptGuard.isMeaningful("- -"))
    }

    func testDigitsCountAsMeaningful() {
        XCTAssertTrue(TranscriptGuard.isMeaningful("42"))
    }
}
