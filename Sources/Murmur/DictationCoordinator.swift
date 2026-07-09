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
    private var asrManager: AsrManager?
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
        recorder.onSilenceTimeout = nil
        pillState.resetLevels()
        recordStart = nil
        targetApp = nil
        pillState.phase = .idle
        Log.log("record cancel: discarded \(samples.count) samples, nothing processed or persisted")
    }

    // MARK: - Phases

    private func startListening() {
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
        // off) auto-stops through the exact same path as a manual pill tap.
        recorder.onSilenceTimeout = { [weak self] in
            DispatchQueue.main.async {
                self?.autoStopOnSilence()
            }
        }

        Task { @MainActor in
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
    /// recording after `AppSettings.silenceAutoStopSeconds` of sustained
    /// near-silence. Guarded to `.listening` so it can't fire twice or race a
    /// manual stop/cancel, which already move the phase away from
    /// `.listening` before this could run.
    private func autoStopOnSilence() {
        guard pillState.phase == .listening else { return }
        Log.log("record auto-stop: sustained silence, stopping")
        stopAndProcess()
    }

    private func stopAndProcess() {
        pillState.phase = .processing
        let samples = recorder.stop()
        recorder.onLevel = nil
        recorder.onSilenceTimeout = nil
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
            let asr = try await ensureAsr()
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
        } catch {
            Log.log("pipeline ASR FAILED: \(error)")
            AppStatus.shared.report("Transcription failed. See history for the recording.")
            HistoryStore.shared?.add(
                rawTranscript: "",
                cleanedText: "",
                modelName: "",
                status: .asrFailed,
                audioPath: audioPath,
                durationMs: durationMs
            )
            return
        }

        guard !raw.isEmpty else {
            Log.log("pipeline: empty transcript, nothing to inject")
            HistoryStore.shared?.add(
                rawTranscript: "",
                cleanedText: "",
                modelName: "",
                status: .asrFailed,
                audioPath: audioPath,
                durationMs: durationMs
            )
            return
        }

        await finish(raw: raw, audioPath: audioPath, durationMs: durationMs, target: target)
    }

    /// Post-ASR pipeline tail: near-silence guard → cleanup → inject →
    /// persist. Split from `process()` so the dev guard-test hook can drive
    /// it with a known transcript (ASR output on ambient noise is
    /// nondeterministic, so the guard can't be exercised reliably end-to-end
    /// from real audio).
    func finish(raw: String, audioPath: String?, durationMs: Int?, target: NSRunningApplication?) async {
        // 1.5 Near-silence guard: a trivially short transcript is mic noise,
        // not speech — and the cleanup model invents content for it (observed:
        // ASR "S" → "Sorry, I didn't catch that..."). Discard outright: no
        // cleanup, no inject, no history entry, and drop the orphaned WAV.
        guard TranscriptGuard.isMeaningful(raw) else {
            #if DEBUG
            Log.log("pipeline: no meaningful speech (raw=\"\(raw)\"), discarded")
            #else
            Log.log("pipeline: no meaningful speech (\(raw.count) chars), discarded")
            #endif
            if let audioPath {
                try? FileManager.default.removeItem(atPath: audioPath)
            }
            return
        }

        // 2. Vault-capture routing decision — made on the RAW transcript,
        // BEFORE cleanup runs. Cleanup (especially the Caveman tone) can
        // rewrite or drop the "note to self" trigger phrase entirely, which
        // silently broke routing when this check ran post-cleanup (observed
        // live: a caveman-compressed transcript never matched). Empty
        // brainstemURL still means the feature is off, so the prefix is left
        // in place and cleaned/pasted like any other text below.
        let brainstemURL = AppSettings.brainstemURL
        let rawRemainder = brainstemURL.isEmpty ? nil : BrainstemClient.noteToSelfRemainder(in: raw)

        // 3. Cleanup — how much runs depends on AppSettings.cleanupMode:
        //   .off   → no LLM at all: inject the raw transcript verbatim. Instant,
        //            and persisted with the "raw" model sentinel (NOT "", which
        //            HistoryView treats as a cleanup-failed marker).
        //   .light → LLM with the tightened formatter prompt but NO history
        //            context, so there's no cold-context feedback loop.
        //   .full  → history-aware path: feed recent transcripts so the model
        //            corrects ASR errors toward the user's real vocabulary.
        //
        // When vault-capture routing matched above, only the REMAINDER (the
        // trigger phrase already stripped) is cleaned — the cleanup model
        // never sees "note to self" at all, so it can't rewrite or drop it.
        let textToClean = rawRemainder ?? raw
        let mode = AppSettings.cleanupMode
        var cleaned = textToClean
        var status = DictationStatus.done
        var persistedModelName = "raw"

        if mode == .off {
            cleaned = textToClean.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.log("pipeline cleanup: mode=off, injecting \(rawRemainder != nil ? "note-to-self remainder" : "raw transcript") verbatim")
        } else {
            // .light feeds no context (nil); .full builds it from history.
            var context: String?
            if mode == .full {
                let recentTexts = HistoryStore.shared?.recentCleanedTexts(limit: CleanupContext.glossarySourceLimit) ?? []
                context = CleanupContext.build(from: recentTexts)
                if let context {
                    Log.log("pipeline cleanup context: \(context.count) chars from \(recentTexts.count) history entries")
                }
            }
            let model = await ollama.resolveModel()
            do {
                let cleanStart = Date()
                cleaned = try await ollama.clean(textToClean, model: model, context: context, tone: AppSettings.tonePreset)
                persistedModelName = model
                #if DEBUG
                Log.log(String(format: "pipeline cleanup (%@, mode=%@, %.2fs): \"%@\"", model, mode.rawValue, Date().timeIntervalSince(cleanStart), cleaned))
                #else
                Log.log(String(format: "pipeline cleanup (%@, mode=%@, %.2fs): %d chars", model, mode.rawValue, Date().timeIntervalSince(cleanStart), cleaned.count))
                #endif
            } catch {
                status = .cleanupFailed
                persistedModelName = ""
                // Raw transcript still gets injected (existing fallback); ALSO
                // tell the user cleanup didn't run.
                AppStatus.shared.report("Text cleanup unavailable (Ollama). Inserted the raw transcript.")
                Log.log("pipeline cleanup FAILED (injecting raw transcript): \(error.localizedDescription)")
            }
        }

        // 4. Vault-capture: send the cleaned remainder to brainstem's
        // /capture endpoint instead of pasting it.
        if let rawRemainder {
            do {
                try await BrainstemClient(baseURL: brainstemURL).capture(cleaned)
                Log.log("pipeline vault-capture OK: \(cleaned.count) chars")
                pillState.phase = .captured
                // Mirrors the inject-success rule below: don't clear a
                // cleanup-failed warning just because capture succeeded.
                if status == .done {
                    AppStatus.shared.clearError()
                }
                // Give the checkmark a moment on screen — mirrors how a
                // paste is visible the instant it lands; a vault capture
                // needs this instead since there's nothing else to see.
                try? await Task.sleep(nanoseconds: 900_000_000)
                HistoryStore.shared?.add(
                    rawTranscript: raw,
                    cleanedText: cleaned,
                    modelName: persistedModelName,
                    status: status,
                    audioPath: audioPath,
                    durationMs: durationMs
                )
                Log.log("pipeline done: status = \(status.rawValue) (captured to vault), history count = \(HistoryStore.shared?.count() ?? -1)")
                return
            } catch {
                // Never lose the words: fall back to pasting. Restore the
                // literal "note to self: " prefix onto the already-cleaned
                // remainder rather than paying for a second cleanup pass
                // over the full raw transcript — same words, less work.
                Log.log("pipeline vault-capture FAILED (falling back to paste): \(error.localizedDescription)")
                AppStatus.shared.report("Vault capture failed. Pasted the transcript instead.")
                cleaned = "note to self: " + cleaned
            }
        }

        // 5. Inject into the snapshotted target.
        if let target, target.isTerminated {
            // A3: the target was snapshotted at record-start; after ASR +
            // cleanup it may have quit. Pasting now would land ⌘V in whatever
            // is frontmost, so skip injection entirely. The transcript is still
            // saved to history below.
            Log.log("pipeline inject SKIPPED: target \(target.bundleIdentifier ?? "?") has quit before paste")
            AppStatus.shared.report("The app you were dictating into has closed, so the text wasn't inserted. It's saved in History.")
        } else {
            Log.log("pipeline inject: target = \(target?.bundleIdentifier ?? "none")")
            let injectStatus = status
            TextInjector.inject(cleaned, into: target) { [weak self] ok, error in
                Task { @MainActor in
                    if ok {
                        // A fully clean run clears any prior warning. Don't clear on
                        // a cleanup-failed run — that warning must stay visible even
                        // though the raw text pasted fine.
                        if injectStatus == .done {
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

        // 6. Persist.
        HistoryStore.shared?.add(
            rawTranscript: raw,
            cleanedText: cleaned,
            modelName: persistedModelName,
            status: status,
            audioPath: audioPath,
            durationMs: durationMs
        )
        Log.log("pipeline done: status = \(status.rawValue), history count = \(HistoryStore.shared?.count() ?? -1)")
    }

    // MARK: - ASR

    /// Lazy-loads Parakeet once and keeps it resident (ANE, ~66 MB).
    func ensureAsr() async throws -> AsrManager {
        if let asrManager { return asrManager }
        Log.log("asr: loading Parakeet TDT v2 (first ever run downloads the model)")
        let start = Date()
        let models = try await AsrModels.downloadAndLoad(version: .v2)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager
        Log.log(String(format: "asr: models ready in %.2fs", Date().timeIntervalSince(start)))
        return manager
    }

    /// Warm the ASR models at launch so the first dictation isn't slow.
    func preloadAsr() {
        Task {
            _ = try? await ensureAsr()
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
