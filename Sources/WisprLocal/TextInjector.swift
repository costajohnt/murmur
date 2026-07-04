import AppKit
import CoreGraphics

/// Paste-injection (v0 Spike C logic, made reusable):
/// snapshot clipboard → set string → CGEvent ⌘V → restore clipboard.
/// Optionally activates an explicit target app first (used by history
/// "Insert at cursor", where our own window is frontmost).
enum TextInjector {
    /// Delay between activating the target app and posting ⌘V.
    private static let activationDelay: TimeInterval = 0.35
    /// Delay before restoring the previous clipboard (paste must be consumed first).
    private static let restoreDelay: TimeInterval = 1.0

    /// Injects `text` at the cursor. If `target` is provided and not active,
    /// activates it first. Returns via `completion` on the main queue.
    static func inject(
        _ text: String,
        into target: NSRunningApplication? = nil,
        completion: ((_ ok: Bool, _ error: String?) -> Void)? = nil
    ) {
        guard AXIsProcessTrusted() else {
            Log.log("inject FAILED: Accessibility permission not granted (System Settings > Privacy & Security > Accessibility)")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            completion?(false, "Accessibility permission not granted")
            return
        }

        if let target, !target.isActive {
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
                performPaste(text, completion: completion)
            }
        } else {
            performPaste(text, completion: completion)
        }
    }

    private static func performPaste(_ text: String, completion: ((Bool, String?) -> Void)?) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        guard synthesizeCmdV() else {
            restore(pasteboard, items: saved)
            completion?(false, "could not create CGEvents")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            restore(pasteboard, items: saved)
            completion?(true, nil)
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

    private static func synthesizeCmdV() -> Bool {
        let vKey: CGKeyCode = 9 // kVK_ANSI_V
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        else {
            return false
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
