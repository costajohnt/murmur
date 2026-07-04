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

    private init() {}

    // MARK: - Pill entry point

    func pillTapped() {
        switch pillState.phase {
        case .idle:
            startListening()
        case .listening:
            stopAndProcess()
        case .processing:
            // Ignore clicks while the pipeline runs; it returns to idle itself.
            Log.log("pipeline: click ignored (processing)")
        }
    }

    /// ✕ on the active pill: stop and DISCARD the in-progress recording — no
    /// ASR, no cleanup, no injection, no history entry — straight back to
    /// idle (docs/pill-app-redesign.md §B).
    func cancel() {
        guard pillState.phase == .listening else {
            Log.log("pipeline: cancel ignored (phase \(pillState.phase))")
            return
        }
        let samples = recorder.stop()
        recorder.onLevel = nil
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

        Task {
            do {
                try await recorder.start()
                recordStart = Date()
                pillState.phase = .listening
                Log.log("record start: engine running")
            } catch {
                Log.log("record start FAILED: \(error.localizedDescription)")
                pillState.phase = .idle
            }
        }
    }

    private func stopAndProcess() {
        pillState.phase = .processing
        let samples = recorder.stop()
        recorder.onLevel = nil
        pillState.resetLevels()
        let durationMs = recordStart.map { Int(Date().timeIntervalSince($0) * 1000) }
        recordStart = nil
        Log.log("record stop: \(samples.count) samples (\(String(format: "%.2f", Double(samples.count) / AudioRecorder.sampleRate))s)")

        let target = targetApp
        Task {
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
            Log.log(String(format: "pipeline ASR (%.3fs): \"%@\"", Date().timeIntervalSince(asrStart), raw))
        } catch {
            Log.log("pipeline ASR FAILED: \(error)")
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

        // 2. Cleanup (Ollama) — on any failure fall back to the raw transcript.
        // Context-aware: feed recent history so the model corrects ASR errors
        // toward the user's real vocabulary (docs/context-cleanup.md). Empty
        // history → nil context → identical to the old cold-start behavior.
        let recentTexts = HistoryStore.shared?.recentCleanedTexts(limit: CleanupContext.glossarySourceLimit) ?? []
        let context = CleanupContext.build(from: recentTexts)
        if let context {
            Log.log("pipeline cleanup context: \(context.count) chars from \(recentTexts.count) history entries")
        }
        let model = await ollama.resolveModel()
        var cleaned = raw
        var status = DictationStatus.done
        do {
            let cleanStart = Date()
            cleaned = try await ollama.clean(raw, model: model, context: context, tone: AppSettings.tonePreset)
            Log.log(String(format: "pipeline cleanup (%@, %.2fs): \"%@\"", model, Date().timeIntervalSince(cleanStart), cleaned))
        } catch {
            status = .cleanupFailed
            Log.log("pipeline cleanup FAILED (injecting raw transcript): \(error.localizedDescription)")
        }

        // 3. Inject into the snapshotted target.
        Log.log("pipeline inject: target = \(target?.bundleIdentifier ?? "none")")
        TextInjector.inject(cleaned, into: target)

        // 4. Persist.
        HistoryStore.shared?.add(
            rawTranscript: raw,
            cleanedText: cleaned,
            modelName: status == .cleanupFailed ? "" : model,
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
}
