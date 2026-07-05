import XCTest

/// Mirrors scripts/test-guard.swift's discard/keep boundary, wired into
/// XCTest so it runs via `xcodebuild test` instead of a standalone harness.
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
