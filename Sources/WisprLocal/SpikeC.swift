import AppKit
import CoreGraphics

/// Spike C: paste-inject text at the cursor of the frontmost app.
/// Pipeline: snapshot clipboard -> set string -> synthesize ⌘V via CGEvent
/// -> restore previous clipboard after a short delay.
enum SpikeC {
    static let payload = "hello from wispr-local"

    /// Menu-triggered entry point. Waits 3 seconds so the user (or the test
    /// harness) can put TextEdit frontmost before the paste fires — selecting
    /// the menubar item itself interacts with our own UI.
    static func run() {
        Log.log("SPIKE C: armed — injecting in 3s; focus the target app now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            injectText(payload)
        }
    }

    static func injectText(_ text: String) {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
        Log.log("SPIKE C: injecting into frontmost = \(front)")

        guard AXIsProcessTrusted() else {
            Log.log("SPIKE C FAILED: Accessibility permission not granted. " +
                    "Grant in System Settings > Privacy & Security > Accessibility, then retry.")
            // Trigger the system prompt/registration so the app appears in the list.
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        synthesizeCmdV()

        // Restore the previous clipboard after the paste has been consumed.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            restore(pasteboard, items: saved)
            Log.log("SPIKE C: clipboard restored (\(saved.count) item(s))")
        }
    }

    // MARK: - Clipboard snapshot/restore

    private static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pasteboard.pasteboardItems ?? []).map { item in
            var entry: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) {
                    entry[type] = data
                }
            }
            return entry
        }
    }

    private static func restore(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            return item
        }
        pasteboard.writeObjects(restored)
    }

    // MARK: - ⌘V synthesis

    private static func synthesizeCmdV() {
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            Log.log("SPIKE C FAILED: could not create CGEvents")
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        Log.log("SPIKE C: ⌘V posted")
    }
}
