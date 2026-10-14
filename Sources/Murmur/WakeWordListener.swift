import Foundation

/// Hands-free start: while the pill is idle, keeps a mic open, cuts the audio
/// into short utterances, runs each through the already-loaded Parakeet model
/// and starts a dictation when one contains the wake phrase. Fully local, no
/// extra model or permission. Off unless `AppSettings.wakeWordEnabled`.
///
/// ponytail: wake detection is "ASR every short utterance", not a trained
/// keyword spotter. Parakeet on the ANE makes that cheap, but a busy room
/// costs one transcription per short phrase; a dedicated KWS model is the
/// upgrade if that ever shows up in battery use.
@MainActor
final class WakeWordListener {
    static let shared = WakeWordListener()

    private let recorder = AudioRecorder(accumulates: false)
    private var running = false
    /// A `recorder.start()` is in flight. Starts are never overlapped on the
    /// one recorder; a stale start re-syncs via `apply()` when it lands.
    private var starting = false
    /// Paused by the coordinator while a dictation owns the mic.
    private var paused = false
    /// Bumped on every stop, so a start still awaiting the engine can tell it
    /// was cancelled meanwhile.
    private var generation = 0
    private var transcribing = false

    private init() {}

    /// Re-sync with settings (launch and Settings changes).
    func apply() {
        if AppSettings.wakeWordEnabled, !paused {
            start()
        } else {
            stop()
        }
    }

    func pause() {
        paused = true
        stop()
    }

    func resume() {
        paused = false
        apply()
    }

    private func start() {
        guard !running, !starting else { return }
        starting = true
        let myGeneration = generation
        recorder.onChunk = Self.chunkHandler { [weak self] utterance in
            Task { @MainActor in self?.heard(utterance) }
        }
        // A route change stops the tap; come back up on the new device.
        recorder.onAutoStop = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.running else { return }
                self.stop()
                self.apply()
            }
        }
        Task { @MainActor in
            do {
                try await recorder.start(silenceAutoStop: 0)
                starting = false
                if generation != myGeneration {
                    // pause()/stop() ran while the engine was starting: shut
                    // it, then follow whatever is wanted now.
                    _ = recorder.stop()
                    apply()
                    return
                }
                running = true
                Log.log("wake: listening for \"\(AppSettings.wakePhrase)\"")
            } catch {
                starting = false
                guard generation == myGeneration else {
                    apply()
                    return
                }
                Log.log("wake: could not open the mic: \(error.localizedDescription)")
                AppStatus.shared.report("Wake word is off: \(error.localizedDescription)")
            }
        }
    }

    private func stop() {
        generation += 1
        recorder.onChunk = nil
        recorder.onAutoStop = nil
        // A start in flight sees the bumped generation and stops itself.
        guard running else { return }
        running = false
        _ = recorder.stop()
        Log.log("wake: stopped listening")
    }

    /// Built outside the main actor for the same reason as
    /// `AudioRecorder.tapBlock`: it runs on the audio thread. Each start gets
    /// a fresh segmenter owned by the closure, so a stop never races a
    /// callback still in flight over shared state.
    private nonisolated static func chunkHandler(
        onUtterance: @escaping ([Float]) -> Void
    ) -> ([Float]) -> Void {
        var segmenter = UtteranceSegmenter()
        return { chunk in
            if let utterance = segmenter.feed(chunk) { onUtterance(utterance) }
        }
    }

    private func heard(_ utterance: [Float]) {
        // One transcription at a time; anything said meanwhile is dropped.
        guard running, !transcribing else { return }
        // Never trigger a model download or retry from room noise; wait for
        // the launch preload (or a dictation) to have the model ready.
        guard DictationCoordinator.shared.pillState.asrModel == .ready else { return }
        transcribing = true
        let phrase = AppSettings.wakePhrase
        Task { @MainActor in
            defer { transcribing = false }
            do {
                let asr = try await DictationCoordinator.shared.ensureAsr()
                let text = try await DictationCoordinator.transcribe(utterance, with: asr)
                guard running, VoiceCommands.containsWakePhrase(text, phrase: phrase) else { return }
                DictationCoordinator.shared.wakeWordHeard()
            } catch {
                Log.log("wake: transcription failed: \(error)")
            }
        }
    }
}
