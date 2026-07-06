import FluidAudio
import ServiceManagement
import SwiftUI

/// App-wide, user-visible status surface. Dictation
/// failures used to only hit the log; this drives the menubar indicator so the
/// user can tell something went wrong and why. Cleared on the next clean
/// dictation. MainActor because the pipeline and MenuBarExtra both touch it.
@MainActor
final class AppStatus: ObservableObject {
    static let shared = AppStatus()

    /// Most recent failure message, or nil when the last dictation was clean.
    @Published var lastError: String?

    private init() {}

    func report(_ message: String) {
        lastError = message
        Log.log("status surfaced to user: \(message)")
    }

    func clearError() {
        guard lastError != nil else { return }
        lastError = nil
    }
}

@main
struct MurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @ObservedObject private var status = AppStatus.shared

    var body: some Scene {
        MenuBarExtra("Murmur", systemImage: status.lastError == nil ? "waveform.circle" : "exclamationmark.triangle.fill") {
            if let error = status.lastError {
                Text("⚠︎ \(error)")
                Button("Dismiss Warning") {
                    status.clearError()
                }
                Divider()
            }
            Button("Open History…") {
                appDelegate.openHistory()
            }
            Button("Settings…") {
                appDelegate.openSettings()
            }
            .keyboardShortcut(",")
            Button("Setup…") {
                appDelegate.openOnboarding()
            }
            #if DEBUG
            // Dev-only spike triggers — compiled out of release builds
            //.
            Divider()
            Button("Spike A: transcribe fixture") {
                SpikeA.run()
            }
            Button("Spike B: show floating pill") {
                appDelegate.showPill()
            }
            Button("Spike C: inject test string (3s delay)") {
                SpikeC.run()
            }
            #endif
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
        // Regular-app main menu (post-LSUIElement): bind ⌘, app-wide so the
        // standard Settings shortcut works while any window is focused.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    appDelegate.openSettings()
                }
                .keyboardShortcut(",")
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pillPanel: PillPanel?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("Murmur launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        _ = TargetAppTracker.shared // start tracking activations immediately
        showPill()
        #if DEBUG
        // Dev-only: system-wide DistributedNotificationCenter hooks that can
        // trigger recording/injection/history mutation. NEVER registered in
        // release builds — any local process could
        // post these notifications.
        registerTestHooks()
        #endif
        DictationCoordinator.shared.preloadAsr()
        // Warm the Ollama cleanup model too — but only when cleanup will run.
        // Off mode skips the LLM entirely, so there's nothing to preload.
        if AppSettings.cleanupMode != .off {
            DictationCoordinator.shared.preloadOllama()
        }
        // No-op unless the user enabled the hotkey in Settings (default off).
        HotkeyManager.shared.apply()
        // Regular app now: opening the app shows the History window as the
        // main window.
        openHistory()
        // First launch: guide the user through the two permission grants
        //. Shown once; re-openable via "Setup…".
        if !AppSettings.hasCompletedOnboarding {
            openOnboarding()
        }
    }

    /// Dock-icon click (or app reopen) with no visible windows → re-show the
    /// History window. The pill/menubar keep running either way.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Log.log("app reopen (visible windows = \(flag))")
        if !flag {
            openHistory()
        }
        return true
    }

    /// Closing the last window must NOT quit — the pill and menubar stay
    /// until ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showPill() {
        if pillPanel == nil {
            pillPanel = PillPanel()
        }
        pillPanel?.orderFrontRegardless()
        Log.log("pill panel shown (bottom-center)")
    }

    func openHistory() {
        guard let store = HistoryStore.shared else {
            Log.log("history: store unavailable, cannot open window")
            return
        }
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmur — History"
            window.contentView = NSHostingView(
                rootView: HistoryView().modelContainer(store.container)
            )
            window.center()
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    #if DEBUG
    /// Test-only: force the history window's appearance ("light"/"dark"/nil
    /// = follow system) so both modes can be screenshot-verified.
    func openHistory(appearance: String?) {
        openHistory()
        switch appearance {
        case "light": historyWindow?.appearance = NSAppearance(named: .aqua)
        case "dark": historyWindow?.appearance = NSAppearance(named: .darkAqua)
        default: historyWindow?.appearance = nil
        }
    }
    #endif

    func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 560),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmur — Settings"
            window.contentView = NSHostingView(rootView: SettingsView())
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.log("settings window shown")
    }

    /// First-run permissions guide. Own window,
    /// same NSWindow pattern as Settings/History; re-openable from the menubar
    /// "Setup…" item and auto-presented when a paste fails for lack of
    /// Accessibility. Dismissing marks onboarding complete.
    func openOnboarding() {
        if onboardingWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 480),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "Murmur — Setup"
            window.contentView = NSHostingView(rootView: OnboardingView(onComplete: { [weak self] in
                AppSettings.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            }))
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        Log.log("onboarding window shown")
    }

    #if DEBUG
    /// Test-only: force the settings window's appearance for screenshots.
    func openSettings(appearance: String?) {
        openSettings()
        switch appearance {
        case "light": settingsWindow?.appearance = NSAppearance(named: .aqua)
        case "dark": settingsWindow?.appearance = NSAppearance(named: .darkAqua)
        default: settingsWindow?.appearance = nil
        }
        if let window = settingsWindow {
            Log.log("settings window id = \(window.windowNumber), frame = \(NSStringFromRect(window.frame))")
        }
    }
    #endif

    #if DEBUG
    /// Headless test hooks (dev only): trigger flows from the command line via
    /// distributed notifications so evidence can be captured without GUI
    /// scripting. DEBUG-only — these are system-wide observers any local
    /// process could post to (mic capture, injection, history mutation), so
    /// they must never exist in a release build. Example:
    ///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.costajohnt.murmur.spikeA"), object: nil, userInfo: nil, deliverImmediately: true)'
    private func registerTestHooks() {
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
        center.addObserver(forName: .init("com.costajohnt.murmur.ollamaTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: ollamaTest triggered")
            V1TestHooks.runOllamaChecks()
        }
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
    #endif
}

#if DEBUG
/// Dev-only automated checks for the v1 acceptance criteria that don't need
/// mic/Accessibility: Ollama cleanup behavior, SwiftData persistence, and the
/// ASR→cleanup→persist integration on the bundled fixture.
@MainActor
enum V1TestHooks {
    /// Messy transcript must come back cleaned; a dictated question must be
    /// formatted, NOT answered.
    static func runOllamaChecks() {
        Task {
            let client = OllamaClient()
            let model = await client.resolveModel()
            Log.log("OLLAMA CHECK: model = \(model)")

            let messy = "um so like the meeting is at uh three pm and we should you know prep the uh slides before"
            do {
                let cleaned = try await client.clean(messy, model: model)
                Log.log("OLLAMA CHECK messy in : \"\(messy)\"")
                Log.log("OLLAMA CHECK messy out: \"\(cleaned)\"")
            } catch {
                Log.log("OLLAMA CHECK messy FAILED: \(error.localizedDescription)")
            }

            let question = "what time is it"
            do {
                let cleaned = try await client.clean(question, model: model)
                Log.log("OLLAMA CHECK question in : \"\(question)\"")
                Log.log("OLLAMA CHECK question out: \"\(cleaned)\"")
            } catch {
                Log.log("OLLAMA CHECK question FAILED: \(error.localizedDescription)")
            }
        }
    }

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

    /// Full pipeline minus mic + injection: fixture WAV → ASR → Ollama →
    /// persist. Injection is skipped (Accessibility-gated; covered manually).
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

                let client = OllamaClient()
                let model = await client.resolveModel()
                var cleaned = raw
                var status = DictationStatus.done
                do {
                    cleaned = try await client.clean(raw, model: model)
                    Log.log("PIPELINE FIXTURE cleanup (\(model)): \"\(cleaned)\"")
                } catch {
                    status = .cleanupFailed
                    Log.log("PIPELINE FIXTURE cleanup FAILED (raw kept): \(error.localizedDescription)")
                }

                HistoryStore.shared?.add(
                    rawTranscript: raw,
                    cleanedText: cleaned,
                    modelName: model,
                    status: status
                )
                Log.log("PIPELINE FIXTURE persisted: history count = \(HistoryStore.shared?.count() ?? -1)")
            } catch {
                Log.log("PIPELINE FIXTURE FAILED: \(error)")
            }
        }
    }
}
#endif
