#if DEBUG
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

    @MainActor
    private static func transcribeFixture() async throws {
        guard let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "wav") else {
            Log.log("SPIKE A FAILED: fixture.wav not found in app bundle")
            return
        }
        Log.log("SPIKE A: fixture = \(fixtureURL.path)")

        // Reuses the coordinator's resident Parakeet instance instead of
        // loading a second full model — this used to load its own copy.
        let loadStart = Date()
        let asrManager = try await DictationCoordinator.shared.ensureAsr()
        let loadElapsed = Date().timeIntervalSince(loadStart)
        Log.log(String(format: "SPIKE A: models ready in %.2fs (instant if already warmed)", loadElapsed))

        let asrStart = Date()
        var decoderState = try TdtDecoderState()
        let result = try await asrManager.transcribe(fixtureURL, decoderState: &decoderState)
        let asrElapsed = Date().timeIntervalSince(asrStart)

        Log.log(String(format: "SPIKE A TRANSCRIPT (%.3fs): \"%@\"", asrElapsed, result.text))
        Log.log(String(format: "SPIKE A: confidence = %.3f", result.confidence))
    }
}
#endif
