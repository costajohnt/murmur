import XCTest

/// Drives the real post-ASR decision logic with stubbed cleaner/capturer, so
/// the order (route on raw → clean remainder → capture → fallback paste) and
/// the reported warnings are pinned against the code that actually runs.
@MainActor
final class DictationPipelineTests: XCTestCase {
    private struct Boom: Error {}

    private var cleanedInputs: [String] = []
    private var captured: [String] = []
    private var reports: [String] = []

    private func pipeline(
        mode: CleanupMode = .light,
        clean: @escaping (String) throws -> String = { "CLEAN(\($0))" },
        capture: ((String) throws -> Void)? = nil
    ) -> DictationPipeline {
        DictationPipeline(
            mode: mode,
            resolveModel: { "m1" },
            clean: { [unowned self] text, _ in
                self.cleanedInputs.append(text)
                return try clean(text)
            },
            capture: capture.map { capture in
                { [unowned self] text in
                    self.captured.append(text)
                    try capture(text)
                }
            },
            report: { [unowned self] in self.reports.append($0) }
        )
    }

    private func run(_ p: DictationPipeline, _ raw: String, targetGone: Bool = false) async -> DictationPipeline.Outcome? {
        await p.run(raw: raw, targetGone: { targetGone })
    }

    func testNoiseIsDiscardedWithoutCleanup() async {
        let outcome = await run(pipeline(), "S")
        XCTAssertNil(outcome)
        XCTAssertTrue(cleanedInputs.isEmpty)
    }

    func testModeOffReturnsRawVerbatimWithRawModel() async {
        let outcome = await run(pipeline(mode: .off), "  hello there world  ")
        XCTAssertEqual(outcome?.text, "hello there world")
        XCTAssertEqual(outcome?.model, "raw")
        XCTAssertEqual(outcome?.status, .done)
        XCTAssertEqual(outcome?.delivery, .paste)
        XCTAssertEqual(outcome?.clearsWarning, true)
        XCTAssertTrue(cleanedInputs.isEmpty, "mode off must never call the cleaner")
    }

    func testLightAndFullSuccess() async {
        for mode in [CleanupMode.light, .full] {
            let outcome = await run(pipeline(mode: mode), "hello there world")
            XCTAssertEqual(outcome?.text, "CLEAN(hello there world)")
            XCTAssertEqual(outcome?.model, "m1")
            XCTAssertEqual(outcome?.status, .done)
            XCTAssertEqual(outcome?.clearsWarning, true)
        }
        XCTAssertTrue(reports.isEmpty)
    }

    func testGenericFailureFallsBackToRawWithBanner() async {
        let outcome = await run(pipeline(clean: { _ in throw Boom() }), "hello there world")
        XCTAssertEqual(outcome?.text, "hello there world")
        XCTAssertEqual(outcome?.status, .cleanupFailed)
        XCTAssertEqual(outcome?.model, "")
        XCTAssertEqual(outcome?.clearsWarning, false)
        XCTAssertEqual(reports, ["Text cleanup unavailable (Ollama). Inserted the raw transcript."])
    }

    func testNoModelInstalledBannerSaysHowToFixIt() async {
        let outcome = await run(pipeline(clean: { _ in throw OllamaClient.OllamaError.noModelInstalled }), "hello there world")
        XCTAssertEqual(outcome?.text, "hello there world")
        XCTAssertEqual(outcome?.clearsWarning, false)
        XCTAssertEqual(reports, ["Ollama has no models installed. Run: ollama pull \(OllamaClient.fallbackModel)"])
    }

    func testNotAReformatFallsBackQuietly() async {
        let outcome = await run(pipeline(clean: { _ in throw OllamaClient.OllamaError.notAReformat }), "hello there world")
        XCTAssertEqual(outcome?.text, "hello there world")
        XCTAssertEqual(outcome?.status, .cleanupFailed)
        XCTAssertEqual(outcome?.model, "m1")
        XCTAssertEqual(outcome?.clearsWarning, false)
        XCTAssertTrue(reports.isEmpty, "notAReformat must not raise a banner")
    }

    func testNoteToSelfRoutesOnRawAndCapturesCleanedRemainder() async {
        // An aggressive cleaner that would eat the trigger phrase if it ever saw it.
        let p = pipeline(clean: { $0.replacingOccurrences(of: "note to self", with: "reminder").uppercased() }, capture: { _ in })
        let outcome = await run(p, "note to self, buy milk and eggs")
        XCTAssertEqual(cleanedInputs, ["buy milk and eggs"], "cleaner must only see the remainder")
        XCTAssertEqual(captured, ["BUY MILK AND EGGS"])
        XCTAssertEqual(outcome?.delivery, .captured)
        XCTAssertEqual(outcome?.status, .done)
        XCTAssertEqual(outcome?.clearsWarning, true)
    }

    func testNoteToSelfIsPlainTextWhenCaptureIsOff() async {
        let outcome = await run(pipeline(capture: nil), "note to self, buy milk")
        XCTAssertEqual(cleanedInputs, ["note to self, buy milk"])
        XCTAssertEqual(outcome?.delivery, .paste)
    }

    func testCaptureFailureFallsBackToPrefixedPasteAndKeepsWarning() async {
        let outcome = await run(pipeline(capture: { _ in throw Boom() }), "note to self, buy milk")
        XCTAssertEqual(outcome?.text, "note to self: CLEAN(buy milk)")
        XCTAssertEqual(outcome?.delivery, .paste)
        XCTAssertEqual(outcome?.status, .done)
        XCTAssertEqual(reports, ["Vault capture failed. Pasted the transcript instead."])
        // M18: the fallback paste succeeding must not wipe the capture warning.
        XCTAssertEqual(outcome?.clearsWarning, false)
    }

    func testTerminatedTargetSkipsInjectButStillReturnsOutcomeToPersist() async {
        let outcome = await run(pipeline(), "hello there world", targetGone: true)
        XCTAssertEqual(outcome?.delivery, .targetGone)
        XCTAssertEqual(outcome?.text, "CLEAN(hello there world)")
        XCTAssertEqual(outcome?.status, .done)
    }

    func testCleanupAloneMatchesRunCleanup() async {
        let result = await pipeline(clean: { _ in throw Boom() }).cleanup("hi there")
        XCTAssertEqual(result, .init(text: "hi there", status: .cleanupFailed, model: "", warning: "Text cleanup unavailable (Ollama). Inserted the raw transcript."))
    }
}
