import FluidAudio
import SwiftUI

@main
struct WisprLocalApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("WisprLocal", systemImage: "waveform.circle") {
            Button("Open History…") {
                appDelegate.openHistory()
            }
            Divider()
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
        _ = TargetAppTracker.shared // start tracking activations immediately
        showPill()
        registerTestHooks()
        DictationCoordinator.shared.preloadAsr()
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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 420),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.title = "wispr-local History"
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

    /// Headless test hooks (dev only): trigger flows from the command line via
    /// distributed notifications so evidence can be captured without GUI
    /// scripting. Example:
    ///   swift -e 'import Foundation; DistributedNotificationCenter.default().postNotificationName(.init("com.costajohnt.wisprlocal.spikeA"), object: nil, userInfo: nil, deliverImmediately: true)'
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
            Log.log("test hook: pillFrame = \(NSStringFromRect(panel.frame)), screenFrame = \(NSStringFromRect(screen.frame))")
        }
        // v1 hooks:
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.ollamaTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: ollamaTest triggered")
            V1TestHooks.runOllamaChecks()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.historyTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: historyTest triggered")
            V1TestHooks.runHistoryCheck()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.historyCount"), object: nil, queue: .main) { _ in
            V1TestHooks.logHistoryState()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.pipelineFixture"), object: nil, queue: .main) { _ in
            Log.log("test hook: pipelineFixture triggered")
            V1TestHooks.runPipelineOnFixture()
        }
    }
}

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
    static func runHistoryCheck() {
        guard let store = HistoryStore.shared else {
            Log.log("HISTORY CHECK FAILED: store unavailable")
            return
        }
        let marker = "persistence-check \(ISO8601DateFormatter().string(from: Date()))"
        store.add(
            rawTranscript: "raw \(marker)",
            cleanedText: marker,
            modelName: "test",
            status: .done
        )
        Log.log("HISTORY CHECK: inserted entry \"\(marker)\", count now \(store.count())")
    }

    static func logHistoryState() {
        guard let store = HistoryStore.shared else {
            Log.log("HISTORY STATE: store unavailable")
            return
        }
        let newest = store.newest()
        Log.log("HISTORY STATE: count = \(store.count()), newest = \"\(newest?.cleanedText ?? "-")\" (\(newest?.statusRaw ?? "-"))")
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
