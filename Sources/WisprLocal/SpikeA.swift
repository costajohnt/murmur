import Foundation
import FluidAudio

/// Spike A: FluidAudio (Parakeet TDT v2, CoreML/ANE) transcribes the bundled
/// WAV fixture. Logs model-load time and transcription wall-clock separately.
/// First run downloads the CoreML model bundle from HuggingFace — expected,
/// logged. Subsequent runs are fully offline.
enum SpikeA {
    private static var running = false

    static func run() {
        guard !running else {
            Log.log("SPIKE A: already running, ignoring")
            return
        }
        running = true
        Task {
            defer { running = false }
            do {
                try await transcribeFixture()
            } catch {
                Log.log("SPIKE A FAILED: \(error)")
            }
        }
    }

    private static func transcribeFixture() async throws {
        guard let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "wav") else {
            Log.log("SPIKE A FAILED: fixture.wav not found in app bundle")
            return
        }
        Log.log("SPIKE A: fixture = \(fixtureURL.path)")
        Log.log("SPIKE A: loading Parakeet TDT v2 (English) — first run downloads the CoreML model from HuggingFace")

        let loadStart = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let asrManager = AsrManager(config: .default)
        try await asrManager.loadModels(models)
        let loadElapsed = Date().timeIntervalSince(loadStart)
        Log.log(String(format: "SPIKE A: models loaded in %.2fs", loadElapsed))

        let asrStart = Date()
        var decoderState = try TdtDecoderState()
        let result = try await asrManager.transcribe(fixtureURL, decoderState: &decoderState)
        let asrElapsed = Date().timeIntervalSince(asrStart)

        Log.log(String(format: "SPIKE A TRANSCRIPT (%.3fs): \"%@\"", asrElapsed, result.text))
        Log.log(String(format: "SPIKE A: confidence = %.3f", result.confidence))
    }
}
