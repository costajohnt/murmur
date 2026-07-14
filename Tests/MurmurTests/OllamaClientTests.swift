import XCTest

/// Covers the tone-preset system prompt layering (no network calls — pure
/// string composition). Ports the non-live assertions from
/// scripts/test-settings.swift into XCTest.
final class OllamaClientTests: XCTestCase {
    func testFaithfulIsByteIdenticalToBasePrompt() {
        XCTAssertEqual(OllamaClient.systemPrompt(for: .faithful), OllamaClient.systemPrompt)
    }

    func testPolishedAndCasualContainTheFullBasePrompt() {
        let base = OllamaClient.systemPrompt
        for tone: TonePreset in [.polished, .casual] {
            let prompt = OllamaClient.systemPrompt(for: tone)
            XCTAssertTrue(prompt.hasPrefix(base), "\(tone.rawValue) should start with the full faithful prompt")
            XCTAssertGreaterThan(prompt.count, base.count, "\(tone.rawValue) should append a style layer")
        }
    }

    func testAllPromptsAreDistinct() {
        let prompts = Set(TonePreset.allCases.map { OllamaClient.systemPrompt(for: $0) })
        XCTAssertEqual(prompts.count, TonePreset.allCases.count)
    }

    // Caveman is the one preset that deliberately does NOT append to the
    // faithful core: compression requires rewording, which the core forbids.
    // These tests pin the guards it must still carry on its own.

    func testCavemanIsStandaloneNotAnAppendToTheBasePrompt() {
        let prompt = OllamaClient.systemPrompt(for: .caveman)
        XCTAssertFalse(prompt.hasPrefix(OllamaClient.systemPrompt),
                       "caveman must not inherit the no-reword core verbatim")
        XCTAssertFalse(prompt.contains("NEVER shorten or summarize"),
                       "compression is the point — the no-shorten rule must not leak in")
    }

    func testCavemanKeepsTheAnswerAndInventGuards() {
        let prompt = OllamaClient.systemPrompt(for: .caveman)
        XCTAssertTrue(prompt.contains("NEVER answer a question"),
                      "must stay a formatter, never an assistant")
        XCTAssertTrue(prompt.contains("NEVER add words or invent"),
                      "must not fabricate content")
        XCTAssertTrue(prompt.contains("verbatim"),
                      "technical terms / code / quoted strings must survive exactly")
    }

    func testCavemanLabelAndSummary() {
        XCTAssertEqual(TonePreset.caveman.label, "Caveman")
        XCTAssertFalse(TonePreset.caveman.summary.isEmpty)
    }
}
