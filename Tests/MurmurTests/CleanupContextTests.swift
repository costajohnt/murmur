import XCTest

/// Covers docs/context-cleanup.md's automatic personalization context:
/// cold-start nil, the recent-snippet budget/cap, the auto-glossary
/// candidate rules, and the overall context char budget. Ports the
/// assertions from scripts/test-context-cleanup.swift's non-network checks
/// into XCTest.
final class CleanupContextTests: XCTestCase {

    // MARK: - build(from:)

    func testEmptyHistoryReturnsNil() {
        XCTAssertNil(CleanupContext.build(from: []))
    }

    func testAllBlankHistoryReturnsNil() {
        XCTAssertNil(CleanupContext.build(from: ["", "   ", "\n\n"]))
    }

    func testRealHistoryBuildsNonNilContextWithinBudget() {
        let texts = [
            "Ping the Proxmox box before the backup runs.",
            "The SwiftData store keeps the ASR history on macOS.",
            "Let's deploy to Proxmox over Tailscale.",
        ]
        guard let context = CleanupContext.build(from: texts) else {
            return XCTFail("expected a non-nil context")
        }
        XCTAssertLessThanOrEqual(context.count, CleanupContext.totalCharBudget)
        XCTAssertTrue(context.contains("Proxmox"))
        XCTAssertTrue(context.contains("Tailscale"))
    }

    /// Raw, pre-cap content (max recent budget + a full 25-term glossary
    /// line) comfortably exceeds totalCharBudget, so build(from:) must
    /// truncate the joined result down to exactly the budget.
    func testTotalCharBudgetTruncatesOutput() {
        var texts: [String] = []
        for i in 0..<10 {
            let filler = String(repeating: "x", count: 300)
            let terms = (0..<3).map { "TERM\(i)\($0)" }.joined(separator: " ")
            texts.append("\(filler) \(terms).")
        }
        guard let result = CleanupContext.build(from: texts) else {
            return XCTFail("expected a non-nil context")
        }
        XCTAssertEqual(result.count, CleanupContext.totalCharBudget)
    }

    // MARK: - recentSnippets: char budget + per-snippet cap

    func testPerSnippetCapTruncatesLongSnippetWithEllipsis() {
        let long = String(repeating: "a", count: CleanupContext.perSnippetCap + 100)
        let snippets = CleanupContext.recentSnippets(from: [long])
        XCTAssertEqual(snippets.count, 1)
        XCTAssertEqual(snippets[0].count, CleanupContext.perSnippetCap + 1) // +1 for the ellipsis
        XCTAssertTrue(snippets[0].hasSuffix("…"))
    }

    func testShortSnippetIsNotTruncated() {
        let short = "a short transcript"
        let snippets = CleanupContext.recentSnippets(from: [short])
        XCTAssertEqual(snippets, [short])
    }

    func testRecentCharBudgetStopsAccumulating() {
        // Each already-capped snippet is perSnippetCap+1 chars; once the
        // running total would exceed recentCharBudget, later snippets are
        // dropped even though recentLimit hasn't been reached.
        let snippetLen = CleanupContext.perSnippetCap + 1
        let maxFit = CleanupContext.recentCharBudget / snippetLen
        XCTAssertLessThan(maxFit, CleanupContext.recentLimit, "test assumes budget binds before recentLimit does")

        let texts = (0..<CleanupContext.recentLimit).map { i in
            String(repeating: "a", count: CleanupContext.perSnippetCap + 50) + "\(i)"
        }
        let snippets = CleanupContext.recentSnippets(from: texts)
        XCTAssertEqual(snippets.count, maxFit)
        XCTAssertLessThanOrEqual(snippets.reduce(0) { $0 + $1.count }, CleanupContext.recentCharBudget)
    }

    func testRecentLimitCapsSourceTextsConsidered() {
        // Short snippets that fit the char budget comfortably; only the
        // first recentLimit texts should ever be considered.
        let texts = (0..<(CleanupContext.recentLimit + 5)).map { "line \($0)" }
        let snippets = CleanupContext.recentSnippets(from: texts)
        XCTAssertEqual(snippets.count, CleanupContext.recentLimit)
        XCTAssertEqual(snippets.last, "line \(CleanupContext.recentLimit - 1)")
    }

    func testMultilineTranscriptCollapsedToOneLine() {
        let text = "first line\nsecond line\n\nthird line"
        let snippets = CleanupContext.recentSnippets(from: [text])
        XCTAssertEqual(snippets, ["first line second line third line"])
    }

    // MARK: - glossaryTerms: candidate rules

    func testAllCapsAcronymIsIncluded() {
        let terms = CleanupContext.glossaryTerms(from: ["The ASR pipeline uses a GPU and HTTP2."])
        XCTAssertTrue(terms.contains("ASR"))
        XCTAssertTrue(terms.contains("GPU"))
        XCTAssertTrue(terms.contains("HTTP2"))
    }

    func testInternalCapitalCompoundIsIncluded() {
        let terms = CleanupContext.glossaryTerms(from: ["I use SwiftData and macOS on my iPhone."])
        XCTAssertTrue(terms.contains("SwiftData"))
        XCTAssertTrue(terms.contains("macOS"))
        XCTAssertTrue(terms.contains("iPhone"))
    }

    func testMidSentenceProperNounIsIncluded() {
        let terms = CleanupContext.glossaryTerms(from: ["I use Proxmox and Tailscale daily."])
        XCTAssertTrue(terms.contains("Proxmox"))
        XCTAssertTrue(terms.contains("Tailscale"))
    }

    func testSentenceStartCapitalIsExcluded() {
        // "Mondays" is capitalized only because it starts the sentence, not
        // because it's a proper noun mid-sentence — must be excluded.
        let terms = CleanupContext.glossaryTerms(from: ["Mondays are busy. Deploy the fix."])
        XCTAssertFalse(terms.contains("Mondays"))
    }

    func testNewlineIsTreatedAsSentenceBoundary() {
        // List-item leading words are capitalized only because they start a
        // line, not because they're proper nouns. A newline must reset the
        // sentence-start state so "Add", "Redesign", and "Then" are excluded,
        // while a genuine mid-line proper noun ("Proxmox") still qualifies.
        let text = "Add the pill fix.\nRedesign the panel using Proxmox.\nThen deploy."
        let terms = CleanupContext.glossaryTerms(from: [text])
        XCTAssertFalse(terms.contains("Add"))
        XCTAssertFalse(terms.contains("Redesign"))
        XCTAssertFalse(terms.contains("Then"))
        XCTAssertTrue(terms.contains("Proxmox"))
    }

    func testStopTermsAreExcluded() {
        let terms = CleanupContext.glossaryTerms(from: ["I'm OK with The plan, I've said An hour is fine."])
        XCTAssertFalse(terms.contains("I'm"))
        XCTAssertFalse(terms.contains("OK"))
        XCTAssertFalse(terms.contains("The"))
        XCTAssertFalse(terms.contains("I've"))
        XCTAssertFalse(terms.contains("An"))
    }

    func testLowercaseWordsAreNeverCandidates() {
        let terms = CleanupContext.glossaryTerms(from: ["just an ordinary lowercase sentence about nothing"])
        XCTAssertTrue(terms.isEmpty)
    }

    func testGlossaryRankedByFrequencyThenFirstSeen() {
        // Both target words placed mid-sentence (not the first token after a
        // sentence boundary), since a sentence-initial capitalized word is
        // never a candidate regardless of how often it recurs.
        let terms = CleanupContext.glossaryTerms(from: [
            "Remember to check Proxmox and Tailscale before the trip.",
            "I checked Proxmox again this morning.",
        ])
        // "Proxmox" appears twice, "Tailscale" once — frequency wins.
        XCTAssertEqual(terms.first, "Proxmox")
        XCTAssertTrue(terms.contains("Tailscale"))
    }

    func testGlossaryLimitCapsResultCount() {
        let words = (0..<40).map { "TERM\($0)" }
        let text = words.joined(separator: " ") + "."
        let terms = CleanupContext.glossaryTerms(from: [text])
        XCTAssertEqual(terms.count, CleanupContext.glossaryLimit)
    }
}
