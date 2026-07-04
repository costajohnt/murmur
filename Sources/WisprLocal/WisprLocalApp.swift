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
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
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
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.historyTest"), object: nil, queue: .main) { note in
            Log.log("test hook: historyTest triggered")
            V1TestHooks.runHistoryCheck(customText: note.object as? String)
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.historyCount"), object: nil, queue: .main) { _ in
            V1TestHooks.logHistoryState()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.pipelineFixture"), object: nil, queue: .main) { _ in
            Log.log("test hook: pipelineFixture triggered")
            V1TestHooks.runPipelineOnFixture()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.meterTest"), object: nil, queue: .main) { _ in
            Log.log("test hook: meterTest triggered")
            V1TestHooks.runMeterTest()
        }
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.historyDeleteNewest"), object: nil, queue: .main) { _ in
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
        center.addObserver(forName: .init("com.costajohnt.wisprlocal.openHistory"), object: nil, queue: .main) { [weak self] note in
            let appearance = note.object as? String
            Log.log("test hook: openHistory (\(appearance ?? "system"))")
            self?.openHistory(appearance: appearance)
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
