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
    // Not private: the DEBUG-only test hooks in DevTestHooks.swift read this
    // directly (e.g. to log the pill's current frame).
    var pillPanel: PillPanel?
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
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 700),
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
}
