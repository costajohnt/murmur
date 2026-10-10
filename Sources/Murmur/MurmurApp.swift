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

    /// A condition that outlives any one dictation: the history store failed
    /// to open, so nothing is being saved until the next launch. Reported at
    /// launch and re-armed by every `clearError()`, so a clean dictation (or
    /// "Dismiss Warning") cannot hide it while it still holds (#49).
    static var persistentWarning: String? {
        HistoryStore.shared == nil ? HistoryStore.openFailure : nil
    }

    func clearError() {
        let persistent = Self.persistentWarning
        guard lastError != persistent else { return }
        lastError = persistent
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
                // No dismiss for the persistent warning: clearError() would
                // re-arm it on the spot, so the button would look broken.
                if error != AppStatus.persistentWarning {
                    Button("Dismiss Warning") {
                        status.clearError()
                    }
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
            // Dev-only trigger, compiled out of release builds.
            Divider()
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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    // Not private: the DEBUG-only test hooks in DevTestHooks.swift read this
    // directly (e.g. to log the pill's current frame).
    var pillPanel: PillPanel?
    private var historyWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("Murmur launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        // Before any UI binds to the settings keys: drop stored values that
        // no longer parse (e.g. a removed tone preset).
        AppSettings.migrateStaleValues()
        // Open the store now rather than at first save, so a store that cannot
        // be opened becomes a menubar warning instead of dictations silently
        // never being persisted (#38).
        _ = HistoryStore.shared
        if let failure = HistoryStore.openFailure {
            AppStatus.shared.report(failure)
        }
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

    /// Shared shape of the History/Settings/Setup windows: centered, titled
    /// "Murmur — <title>", kept alive after close so reopening reuses it.
    private func makeWindow<Content: View>(
        _ title: String, width: CGFloat, height: CGFloat, resizable: Bool = false, _ content: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: resizable ? [.titled, .closable, .resizable] : [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Murmur — \(title)"
        window.contentView = NSHostingView(rootView: content)
        window.center()
        window.isReleasedWhenClosed = false
        return window
    }

    func openHistory() {
        guard let store = HistoryStore.shared else {
            Log.log("history: store unavailable, cannot open window")
            return
        }
        if historyWindow == nil {
            historyWindow = makeWindow(
                "History", width: 820, height: 720, resizable: true,
                HistoryView().modelContainer(store.container))
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
            settingsWindow = makeWindow("Settings", width: 460, height: 700, SettingsView())
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
            onboardingWindow = makeWindow("Setup", width: 460, height: 480, OnboardingView(onComplete: { [weak self] in
                AppSettings.hasCompletedOnboarding = true
                self?.onboardingWindow?.close()
            }))
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
}
