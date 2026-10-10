import AppKit
import FluidAudio
import Foundation

/// The v1 pipeline behind the pill:
/// click (idle→listening): snapshot target app + start recording;
/// click (listening→processing): stop, ASR → Ollama cleanup → paste-inject →
/// persist; then back to idle.
@MainActor
final class DictationCoordinator {
    static let shared = DictationCoordinator()

    let pillState = PillState()

    private let recorder = AudioRecorder()
    private let ollama = OllamaClient()
    /// In-flight or finished Parakeet load. Caching the Task (not just the
    /// manager) stops the launch preload and an early first dictation from
    /// both running `downloadAndLoad`, since main-actor reentrancy lets both
    /// pass a nil check across the await.
    private var asrLoad: Task<AsrManager, Error>?
    /// True from a tap on an idle pill until `recorder.start()` returns. The
    /// phase stays `.idle` for that whole window (mic prompt, Bluetooth
    /// format settle), so without this a second tap ran a second concurrent
    /// `start()` on the same engine and could leave the mic live behind an
    /// idle pill.
    private var isStarting = false
    private var targetApp: NSRunningApplication?
    private var recordStart: Date?
    /// N2: auto-opening Setup on an Accessibility-missing paste failure should
    /// fire at most once per app session — otherwise the window re-pops on
    /// every dictation attempt while permission stays ungranted. The menubar
    /// "Setup…" item and first-run onboarding are unaffected.
    private var didAutoOpenOnboarding = false

    private init() {}

    // MARK: - Pill entry point

    func pillTapped() {
        switch pillState.phase {
        case .idle:
            startListening()
        case .listening:
            stopAndProcess()
        case .processing, .captured:
            // Ignore clicks while the pipeline runs or the capture
            // confirmation is showing; both return to idle on their own.
            Log.log("pipeline: click ignored (\(pillState.phase))")
        }
    }

    /// ✕ on the active pill: stop and DISCARD the in-progress recording — no
    /// ASR, no cleanup, no injection, no history entry — straight back to
    /// idle.
    func cancel() {
        guard pillState.phase == .listening else {
            Log.log("pipeline: cancel ignored (phase \(pillState.phase))")
            return
        }
        let samples = recorder.stop()
        recorder.onLevel = nil
        recorder.onAutoStop = nil
        pillState.resetLevels()
        recordStart = nil
        targetApp = nil
        pillState.phase = .idle
        Log.log("record cancel: discarded \(samples.count) samples, nothing processed or persisted")
    }

    // MARK: - Phases

    private func startListening() {
        guard !isStarting else {
            Log.log("pipeline: click ignored (recording already starting)")
            return
        }
        isStarting = true

        // Snapshot the injection target NOW (didActivate-tracked, never a
        // stale frontmost read at paste time — v0 lesson).
        targetApp = TargetAppTracker.shared.lastActiveApp
        Log.log("record start: target = \(targetApp?.bundleIdentifier ?? "none") (\(targetApp?.localizedName ?? "-"))")

        // Live level → meter bars. Callback arrives on the audio thread;
        // hop to main for the @Published updates.
        recorder.onLevel = { [weak self] level in
            DispatchQueue.main.async {
                self?.pillState.pushLevel(level)
            }
        }
        // Sustained near-silence (AppSettings.silenceAutoStopSeconds, 0 =
        // off) and the recording length cap both auto-stop through the exact
        // same path as a manual pill tap.
        recorder.onAutoStop = { [weak self] reason in
            DispatchQueue.main.async {
                self?.autoStop(reason)
            }
        }

        Task { @MainActor in
            defer { isStarting = false }
            do {
                try await recorder.start()
                recordStart = Date()
                pillState.phase = .listening
                Log.log("record start: engine running")
            } catch {
                Log.log("record start FAILED: \(error.localizedDescription)")
                // Surface mic-denied / engine failures — the pill just returns
                // to idle otherwise.
                AppStatus.shared.report(error.localizedDescription)
                pillState.phase = .idle
            }
        }
    }

    /// Auto-stop entry point: AudioRecorder fires this at most once per
    /// recording, for sustained near-silence or for hitting the length cap.
    /// Guarded to `.listening` so it can't fire twice or race a manual
    /// stop/cancel, which already move the phase away from `.listening`
    /// before this could run. Either way the audio recorded so far is
    /// transcribed, exactly as a manual stop would.
    private func autoStop(_ reason: AudioRecorder.AutoStopReason) {
        guard pillState.phase == .listening else { return }
        switch reason {
        case .silence:
            Log.log("record auto-stop: sustained silence, stopping")
        case .maxDuration:
            Log.log("record auto-stop: hit the \(Int(AudioRecorder.maxRecordingSeconds / 60))-minute length cap, stopping")
        case .deviceChanged:
            Log.log("record auto-stop: audio route changed mid-recording, stopping")
        }
        stopAndProcess()
    }

    private func stopAndProcess() {
        pillState.phase = .processing
        let samples = recorder.stop()
        recorder.onLevel = nil
        recorder.onAutoStop = nil
        pillState.resetLevels()
        let durationMs = recordStart.map { Int(Date().timeIntervalSince($0) * 1000) }
        recordStart = nil
        Log.log("record stop: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / AudioRecorder.sampleRate))s)")

        let target = targetApp
        Task { @MainActor in
            await process(samples: samples, durationMs: durationMs, target: target)
            pillState.phase = .idle
        }
    }

    private func process(samples: [Float], durationMs: Int?, target: NSRunningApplication?) async {
        // Under ~0.3 s of audio is a stray double-click, not speech.
        guard samples.count > Int(AudioRecorder.sampleRate * 0.3) else {
            Log.log("pipeline: recording too short (\(samples.count) samples), discarded")
            return
        }

        // Persist audio first (usable even if ASR fails).
        let entryId = UUID()
        var audioPath: String?
        do {
            let url = HistoryStore.audioURL(for: entryId)
            try AudioRecorder.writeWav(samples, to: url)
            audioPath = url.path
        } catch {
            Log.log("pipeline: audio save failed (continuing): \(error)")
        }

        // 1. ASR
        let raw: String
        do {
            let asrStart = Date()
            let asr = try await ensureAsr(timeout: 120)
            var decoderState = try TdtDecoderState()
            let result = try await asr.transcribe(samples, decoderState: &decoderState)
            raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Transcript content is DEBUG-only: release builds must never
            // write the user's words to any log.
            #if DEBUG
            Log.log(String(format: "pipeline ASR (%.3fs): \"%@\"", Date().timeIntervalSince(asrStart), raw))
            #else
            Log.log(String(format: "pipeline ASR (%.3fs): %d chars", Date().timeIntervalSince(asrStart), raw.count))
            #endif
        } catch is AsrLoadTimeout {
            Log.log("pipeline ASR: model still loading after timeout, giving up on this dictation")
            AppStatus.shared.report("Speech model still downloading, try again shortly. The recording is in History.")
            persist(status: .asrFailed, audioPath: audioPath, durationMs: durationMs)
            return
        } catch {
            Log.log("pipeline ASR FAILED: \(error)")
            AppStatus.shared.report("Transcription failed. See history for the recording.")
            persist(status: .asrFailed, audioPath: audioPath, durationMs: durationMs)
            return
        }

        guard !raw.isEmpty else {
            Log.log("pipeline: empty transcript, nothing to inject")
            persist(status: .asrFailed, audioPath: audioPath, durationMs: durationMs)
            return
        }

        await finish(raw: raw, audioPath: audioPath, durationMs: durationMs, target: target)
    }

    /// Post-ASR pipeline tail: `DictationPipeline` decides (near-silence
    /// discard, note-to-self routing, cleanup, vault capture); this adapter
    /// acts on its outcome (pill, paste, persist). Split from `process()` so
    /// the dev guard-test and fixture-pipeline hooks can drive it with a
    /// known transcript. `inject` defaults to true for the real pipeline; dev
    /// hooks pass false to exercise cleanup without pasting into whatever app
    /// happens to be frontmost.
    func finish(raw: String, audioPath: String?, durationMs: Int?, target: NSRunningApplication?, inject: Bool = true) async {
        let pipeline = DictationPipeline.live(ollama: ollama)
        guard let outcome = await pipeline.run(raw: raw, targetGone: { target?.isTerminated ?? false }) else {
            // Discarded as noise: no history entry, so drop the orphaned WAV.
            if let audioPath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            return
        }

        if outcome.delivery == .captured {
            pillState.phase = .captured
            if outcome.clearsWarning {
                AppStatus.shared.clearError()
            }
            // Give the checkmark a moment on screen; a vault capture has
            // nothing else to see.
            try? await Task.sleep(nanoseconds: 900_000_000)
            persist(raw: raw, cleaned: outcome.text, model: outcome.model, status: outcome.status, audioPath: audioPath, durationMs: durationMs)
            Log.log("pipeline done: status = \(outcome.status.rawValue) (captured to vault), history count = \(HistoryStore.shared?.count() ?? -1)")
            return
        }

        if !inject {
            Log.log("pipeline inject SKIPPED: inject=false (dev/test call site)")
        } else if outcome.delivery == .targetGone {
            // A3: the target was snapshotted at record-start; after ASR +
            // cleanup it may have quit. Pasting now would land ⌘V in whatever
            // is frontmost, so skip injection. Still saved to history below.
            Log.log("pipeline inject SKIPPED: target \(target?.bundleIdentifier ?? "?") has quit before paste")
            AppStatus.shared.report("The app you were dictating into has closed, so the text wasn't inserted. It's saved in History.")
        } else {
            Log.log("pipeline inject: target = \(target?.bundleIdentifier ?? "none")")
            let clearsWarning = outcome.clearsWarning
            TextInjector.inject(outcome.text, into: target) { [weak self] ok, error in
                Task { @MainActor in
                    if ok {
                        // Only a fully clean run clears a prior warning: a
                        // cleanup-failed or vault-capture-failed warning must
                        // stay visible even though the fallback pasted fine.
                        if clearsWarning {
                            AppStatus.shared.clearError()
                        }
                        return
                    }
                    if AXIsProcessTrusted() {
                        AppStatus.shared.report("Couldn't paste the transcript: \(error ?? "unknown error").")
                    } else {
                        // The dominant paste failure: Accessibility never granted.
                        // Surface it AND pop the setup guide so the user can fix it —
                        // but only once per session (N2), not on every attempt.
                        AppStatus.shared.report("Accessibility permission needed to paste. Open Setup to grant it.")
                        if self?.didAutoOpenOnboarding != true {
                            self?.didAutoOpenOnboarding = true
                            (NSApp.delegate as? AppDelegate)?.openOnboarding()
                        }
                    }
                }
            }
        }

        // ponytail: a failed vault capture still persists as .done (the
        // warning carries the signal); a capture_failed status would also
        // need HistoryStore's context predicate updated.
        persist(raw: raw, cleaned: outcome.text, model: outcome.model, status: outcome.status, audioPath: audioPath, durationMs: durationMs)
        Log.log("pipeline done: status = \(outcome.status.rawValue), history count = \(HistoryStore.shared?.count() ?? -1)")
    }

    private func persist(raw: String = "", cleaned: String = "", model: String = "", status: DictationStatus, audioPath: String?, durationMs: Int?) {
        HistoryStore.shared?.add(
            rawTranscript: raw,
            cleanedText: cleaned,
            modelName: model,
            status: status,
            audioPath: audioPath,
            durationMs: durationMs
        )
    }

    // MARK: - ASR

    /// Lazy-loads Parakeet once and keeps it resident (ANE, ~66 MB).
    func ensureAsr() async throws -> AsrManager {
        if let asrLoad { return try await asrLoad.value }
        let load = Task { @MainActor in
            Log.log("asr: loading Parakeet TDT v2 (first ever run downloads the model)")
            let start = Date()
            let models = try await AsrModels.downloadAndLoad(version: .v2)
            let manager = AsrManager(config: .default)
            try await manager.loadModels(models)
            Log.log(String(format: "asr: models ready in %.2fs", Date().timeIntervalSince(start)))
            return manager
        }
        asrLoad = load
        do {
            return try await load.value
        } catch {
            // Forget the failed load so the next dictation retries.
            asrLoad = nil
            throw error
        }
    }

    private struct AsrLoadTimeout: Error {}

    /// `ensureAsr()` bounded for the processing path: a first-run model
    /// download can take minutes, and the pill would sit in `.processing` the
    /// whole time. Gives up after `seconds` but leaves the shared load running
    /// (awaiting `asrLoad.value` can't be cancelled anyway), so the next
    /// dictation picks it up.
    private func ensureAsr(timeout seconds: Double) async throws -> AsrManager {
        @MainActor final class Once { var resumed = false }
        let once = Once()
        return try await withCheckedThrowingContinuation { continuation in
            let timer = Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                guard !once.resumed else { return }
                once.resumed = true
                continuation.resume(throwing: AsrLoadTimeout())
            }
            Task { @MainActor in
                let result: Result<AsrManager, Error>
                do { result = .success(try await self.ensureAsr()) } catch { result = .failure(error) }
                timer.cancel()
                guard !once.resumed else { return }
                once.resumed = true
                continuation.resume(with: result)
            }
        }
    }

    /// Warm the ASR models at launch so the first dictation isn't slow.
    func preloadAsr() {
        Task {
            do {
                _ = try await ensureAsr()
            } catch {
                // Not fatal — ensureAsr() retries on the first real dictation.
                // But a silent launch-time failure (offline first run, full
                // disk) previously surfaced only when that first dictation
                // failed too, with nothing in between to explain why.
                Log.log("asr preload FAILED (will retry on first dictation): \(error)")
            }
        }
    }

    // MARK: - Ollama warm-up

    /// Preload the cleanup model into Ollama at launch so the first cleanup
    /// doesn't pay a cold model load. Callers should only invoke this when
    /// cleanup will actually run (`AppSettings.cleanupMode != .off`).
    func preloadOllama() {
        Task {
            let model = await ollama.resolveModel()
            await ollama.warmup(model: model)
        }
    }
}

extension DictationPipeline {
    /// The real wiring: Ollama cleanup with the current tone and (Full-mode)
    /// history context, brainstem capture when a URL is configured, and
    /// warnings to the menubar status.
    static func live(
        ollama: OllamaClient = OllamaClient(),
        mode: CleanupMode = AppSettings.cleanupMode,
        brainstemURL: String = AppSettings.brainstemURL
    ) -> DictationPipeline {
        DictationPipeline(
            mode: mode,
            resolveModel: { await ollama.resolveModel() },
            clean: { text, model in
                let context = CleanupContext.currentContext()
                if let context {
                    Log.log("pipeline cleanup context: \(context.count) chars")
                }
                return try await ollama.clean(text, model: model, context: context, tone: AppSettings.tonePreset)
            },
            capture: brainstemURL.isEmpty ? nil : { try await BrainstemClient(baseURL: brainstemURL).capture($0) },
            report: { AppStatus.shared.report($0) }
        )
    }
}
