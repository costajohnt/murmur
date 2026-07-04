import SwiftUI

@main
struct WisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("WisprLocal", systemImage: "waveform.circle") {
            Button("Spike A: transcribe fixture") {
                SpikeA.run()
            }
            Button("Spike B: show floating pill") {
                appDelegate.showPill()
            }
            Button("Spike C: inject 'hello from wispr-local' (3s delay)") {
                SpikeC.run()
            }
            Divider()
            Button("Open History") {
                appDelegate.openHistoryStub()
            }
            Divider()
            Button("Quit") {
                NSApp.terminate(nil)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pillPanel: PillPanel?
    private var historyWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.log("WisprLocal launched (pid \(ProcessInfo.processInfo.processIdentifier))")
        // Show the pill immediately so Spike B is testable without touching the menubar.
        showPill()
        registerTestHooks()
    }

    /// Headless test hooks: spikes can be triggered from the command line via
    /// distributed notifications, e.g.
    ///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.costajohnt.wisprlocal.spikeA"), object: nil, userInfo: nil, deliverImmediately: true)'
    /// This lets the build agent capture real log evidence without GUI scripting.
    private func registerTestHooks() {
        let center = DistributedNotificationCenter.default()
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.spikeA"), object: nil, queue: .main) { _ in
            Log.log("test hook: spikeA triggered")
            SpikeA.run()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.spikeC"), object: nil, queue: .main) { _ in
            Log.log("test hook: spikeC triggered")
            SpikeC.run()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.pillFrame"), object: nil, queue: .main) { [weak self] _ in
            guard let self, let panel = self.pillPanel, let screen = NSScreen.main else { return }
            // Log the pill frame (Cocoa coords) + screen height so a test
            // driver can compute CGEvent (top-left origin) click coordinates.
            Log.log("test hook: pillFrame = \(NSStringFromRect(panel.frame)), screenFrame = \(NSStringFromRect(screen.frame))")
        }
    }

    func showPill() {
        if pillPanel == nil {
            pillPanel = PillPanel()
        }
        pillPanel?.orderFrontRegardless()
        Log.log("SPIKE B: pill panel shown (bottom-center)")
    }

    func openHistoryStub() {
        if historyWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "History (stub)"
            window.contentView = NSHostingView(
                rootView: Text("History window stub — v1 will list dictations here.")
                    .padding()
            )
            window.center()
            window.isReleasedWhenClosed = false
            historyWindow = window
        }
        historyWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
