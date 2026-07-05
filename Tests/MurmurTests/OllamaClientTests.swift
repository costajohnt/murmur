import XCTest

/// Covers docs/settings-panel.md's tone-preset system prompt layering
/// (no network calls — pure string composition). Ports the non-live
/// assertions from scripts/test-settings.swift into XCTest.
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

    func testAllThreePromptsAreDistinct() {
        let prompts = Set(TonePreset.allCases.map { OllamaClient.systemPrompt(for: $0) })
        XCTAssertEqual(prompts.count, TonePreset.allCases.count)
    }
}
