#if DEBUG
import AppKit
import FluidAudio
import Foundation
import ServiceManagement

extension AppDelegate {
    /// Headless test hooks (dev only): trigger flows from the command line via
    /// distributed notifications so evidence can be captured without GUI
    /// scripting. DEBUG-only — these are system-wide observers any local
    /// process could post to (mic capture, injection, history mutation), so
    /// they must never exist in a release build. Example:
    ///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.costajohnt.murmur.spikeA"), object: nil, userInfo: nil, deliverImmediately: true)'
    func registerTestHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.costajohnt.murmur.spikeA"), object: nil, queue: .main) { _ in
            Log.log("test hook: spikeA triggered")
            SpikeA.run()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.spikeC"), object: nil, queue: .main) { _ in
            Log.log("test hook: spikeC triggered")
            SpikeC.run()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.pillFrame"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let panel = self.pillPanel, let screen = NSScreen.main else { return }
            Log.log("test hook: pillFrame = \(NSStringFromRect(panel.frame)), window id = \(panel.windowNumber), screenFrame = \(NSStringFromRect(screen.frame))")
        }
        // Pill-redesign hooks:
        center.addObserver(forName: .init("com.costajohnt.murmur.cancelTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: cancelTest triggered")
            V1TestHooks.runCancelTest()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.guardTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: guardTest triggered")
            V1TestHooks.runGuardTest()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.mainMenu"), object: nil, queue: .main) { _ in
            let titles = NSApp.mainMenu?.items.map(\.title) ?? []
            Log.log("MAIN MENU: policy = \(NSApp.activationPolicy().rawValue) (0 = regular), items = \(titles)")
        }
        // v1 hooks:
        center.addObserver(forName: .init("com.costajohnt.murmur.historyTest"), object: nil, queue: .main) { note in
            Log.log("test hook: historyTest triggered")
            V1TestHooks.runHistoryCheck(customText: note.object as? String)
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.historyCount"), object: nil, queue: .main) { _ in
            V1TestHooks.logHistoryState()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.pipelineFixture"), object: nil, queue: .main) { _ in
            Log.log("test hook: pipelineFixture triggered")
            V1TestHooks.runPipelineOnFixture()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.meterTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: meterTest triggered")
            V1TestHooks.runMeterTest()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.historyDeleteNewest"), object: nil, queue: .main) { _ in
            guard let store = HistoryStore.shared, let newest = store.newest() else {
                Log.log("DELETE CHECK: no entry to delete")
                return
            }
            let audioPath = newest.audioPath
            let before = store.count()
            store.delete(newest)
            let audioGone = audioPath.map { !FileManager.default.fileExists(atPath: $0) } ?? true
            Log.log("DELETE CHECK: count \(before) -> \(store.count()), audio file removed = \(audioGone) (path: \(audioPath ?? "none"))")
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.openHistory"), object: nil, queue: .main) { [weak self] note in
            let appearance = note.object as? String
            Log.log("test hook: openHistory (\(appearance ?? "system"))")
            self?.openHistory(appearance: appearance)
        }
        // Settings hooks:
        center.addObserver(forName: .init("com.costajohnt.murmur.openSettings"), object: nil, queue: .main) { [weak self] note in
            let appearance = note.object as? String
            Log.log("test hook: openSettings (\(appearance ?? "system"))")
            self?.openSettings(appearance: appearance)
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.settingsStatus"), object: nil, queue: .main) { _ in
            Log.log("test hook: settingsStatus triggered")
            V1TestHooks.logSettingsStatus()
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.hotkeyApply"), object: nil, queue: .main) { _ in
            Log.log("test hook: hotkeyApply triggered")
            HotkeyManager.shared.apply()
            Log.log("HOTKEY STATE: registered = \(HotkeyManager.shared.registeredBinding?.rawValue ?? "none")")
        }
        center.addObserver(forName: .init("com.costajohnt.murmur.loginToggleTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: loginToggleTest triggered")
            V1TestHooks.runLoginToggleTest()
        }
    }
}

/// Dev-only automated checks for the v1 acceptance criteria that don't need
/// mic/Accessibility: SwiftData persistence and the ASR→cleanup→persist
/// integration on the bundled fixture. (The Ollama tone/guard checks this
/// used to duplicate now live in OllamaClientTests + scripts/test-settings,
/// which exercise the same prompts against live Ollama.)
@MainActor
enum V1TestHooks {
    /// Inserts a marker entry; relaunch + historyCount proves persistence.
    /// Pass a custom string via the notification object to control content
    /// (used to eyeball the bullet-list renderer).
    static func runHistoryCheck(customText: String? = nil) {
        guard let store = HistoryStore.shared else {
            Log.log("HISTORY CHECK FAILED: store unavailable")
            return
        }
        var text = customText ?? "persistence-check \(ISO8601DateFormatter().string(from: Date()))"
        // "withaudio:" prefix → also create a dummy WAV so delete-with-audio
        // can be verified without touching real dictations.
        var audioPath: String?
        if text.hasPrefix("withaudio:") {
            text = String(text.dropFirst("withaudio:".count))
            let url = HistoryStore.audioURL(for: UUID())
            FileManager.default.createFile(atPath: url.path, contents: Data("dummy".utf8))
            audioPath = url.path
        }
        store.add(
            rawTranscript: "raw: \(text.prefix(60))",
            cleanedText: text,
            modelName: "test",
            status: .done,
            audioPath: audioPath
        )
        Log.log("HISTORY CHECK: inserted entry (\(text.count) chars, audio: \(audioPath != nil)), count now \(store.count())")
    }

    /// Cancel-path check: start a real recording,
    /// cancel it, and prove no history entry was created and the phase is
    /// back to idle. Mic is captured for ~1.5 s; nothing is transcribed,
    /// injected, or persisted.
    static func runCancelTest() {
        Task { @MainActor in
            let store = HistoryStore.shared
            let before = store?.count() ?? -1
            let coordinator = DictationCoordinator.shared
            coordinator.pillTapped() // start recording
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            Log.log("CANCEL TEST: phase after start = \(coordinator.pillState.phase)")
            coordinator.cancel()
            try? await Task.sleep(nanoseconds: 500_000_000)
            let after = store?.count() ?? -1
            Log.log("CANCEL TEST: history count \(before) -> \(after) (no new entry = \(before == after)), phase = \(coordinator.pillState.phase)")
        }
    }

    /// Near-silence guard check: drive the REAL post-ASR pipeline tail with a
    /// 1-char transcript ("S" — the observed hallucination trigger) and prove
    /// it is discarded: no cleanup, no inject, no history entry, and the
    /// orphaned WAV is deleted.
    static func runGuardTest() {
        Task { @MainActor in
            let store = HistoryStore.shared
            let before = store?.count() ?? -1
            // Dummy WAV standing in for the already-persisted recording.
            let wavURL = HistoryStore.audioURL(for: UUID())
            FileManager.default.createFile(atPath: wavURL.path, contents: Data("dummy".utf8))

            await DictationCoordinator.shared.finish(
                raw: "S", audioPath: wavURL.path, durationMs: 1500, target: nil)

            let after = store?.count() ?? -1
            let wavGone = !FileManager.default.fileExists(atPath: wavURL.path)
            Log.log("GUARD TEST: raw \"S\" → history count \(before) -> \(after) (no new entry = \(before == after)), orphan wav deleted = \(wavGone)")
        }
    }

    /// Logs the live resolved settings + model so overrides can be verified
    /// against the real app defaults (`defaults write com.costajohnt.murmur …`).
    static func logSettingsStatus() {
        Task {
            let model = await OllamaClient().resolveModel()
            Log.log("SETTINGS STATUS: override = \(AppSettings.cleanupModelOverride ?? "nil (Auto)"), resolved model = \(model)")
            Log.log("SETTINGS STATUS: tone = \(AppSettings.tonePreset.rawValue)")
            Log.log("SETTINGS STATUS: hotkey enabled = \(AppSettings.hotkeyEnabled), binding = \(AppSettings.hotkeyBinding.rawValue), registered = \(HotkeyManager.shared.registeredBinding?.rawValue ?? "none")")
        }
    }

    /// SMAppService round-trip: register → log status → unregister → log
    /// status. Leaves launch-at-login OFF (the default) when done.
    static func runLoginToggleTest() {
        let service = SMAppService.mainApp
        Log.log("LOGIN TEST: initial status = \(service.status.rawValue) (\(service.status == .enabled ? "enabled" : "not enabled"))")
        do {
            try service.register()
            Log.log("LOGIN TEST: after register, status = \(service.status.rawValue) (enabled = \(service.status == .enabled))")
        } catch {
            Log.log("LOGIN TEST: register FAILED: \(error.localizedDescription)")
        }
        do {
            try service.unregister()
            Log.log("LOGIN TEST: after unregister, status = \(service.status.rawValue) (enabled = \(service.status == .enabled))")
        } catch {
            Log.log("LOGIN TEST: unregister FAILED: \(error.localizedDescription)")
        }
    }

    static func logHistoryState() {
        guard let store = HistoryStore.shared else {
            Log.log("HISTORY STATE: store unavailable")
            return
        }
        let newest = store.newest()
        Log.log("HISTORY STATE: count = \(store.count()), newest = \"\(newest?.cleanedText ?? "-")\" (\(newest?.statusRaw ?? "-"))")
    }

    /// Meter check without the pipeline: records for ~6 s on a standalone
    /// recorder, drives the pill's listening meter, and logs the smoothed
    /// level once per 500 ms. Nothing is transcribed, injected, or persisted.
    static func runMeterTest() {
        Task { @MainActor in
            let recorder = AudioRecorder()
            let state = DictationCoordinator.shared.pillState
            recorder.onLevel = { level in
                DispatchQueue.main.async { state.pushLevel(level) }
            }
            do {
                try await recorder.start()
            } catch {
                Log.log("METER TEST FAILED: \(error.localizedDescription)")
                return
            }
            state.phase = .listening
            for tick in 0..<12 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                Log.log(String(format: "METER TEST level[%02d] = %.3f (bars: %@)",
                               tick, state.audioLevel,
                               state.levelHistory.map { String(format: "%.2f", $0) }.joined(separator: " ")))
            }
            _ = recorder.stop()
            state.resetLevels()
            state.phase = .idle
            Log.log("METER TEST done (recording discarded)")
        }
    }

    /// Full pipeline minus mic: fixture WAV → ASR → the REAL post-ASR pipeline
    /// tail (`DictationCoordinator.finish`), so this can never drift from
    /// production cleanup-mode/tone/context behavior the way a reimplemented
    /// copy did twice before. Injection is suppressed (`inject: false`) so
    /// triggering this doesn't paste into whatever app happens to be
    /// frontmost; the cleaned result still lands in History either way.
    static func runPipelineOnFixture() {
        Task {
            guard let fixtureURL = Bundle.main.url(forResource: "fixture", withExtension: "wav") else {
                Log.log("PIPELINE FIXTURE FAILED: fixture missing")
                return
            }
            do {
                let asr = try await DictationCoordinator.shared.ensureAsr()
                var decoderState = try TdtDecoderState()
                let asrStart = Date()
                let result = try await asr.transcribe(fixtureURL, decoderState: &decoderState)
                let raw = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
                Log.log(String(format: "PIPELINE FIXTURE ASR (%.3fs): \"%@\"", Date().timeIntervalSince(asrStart), raw))

                await DictationCoordinator.shared.finish(raw: raw, audioPath: nil, durationMs: nil, target: nil, inject: false)
                Log.log("PIPELINE FIXTURE persisted: history count = \(HistoryStore.shared?.count() ?? -1)")
            } catch {
                Log.log("PIPELINE FIXTURE FAILED: \(error)")
            }
        }
    }
}
#endif
