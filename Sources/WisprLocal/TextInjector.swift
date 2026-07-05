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

    /// Serializes injections (A2): only one paste may be mid-flight — snapshot →
    /// set → ⌘V → restore. A second `inject` arriving inside that window is
    /// dropped rather than racing on the shared pasteboard (e.g. rapid history
    /// "Insert"). Accessed on the main thread only; `inject` hops to main first.
    private static var isInjecting = false

    /// Injects `text` at the cursor. If `target` is provided and not active,
    /// activates it first. Returns via `completion` on the main queue.
    static func inject(
        _ text: String,
        into target: NSRunningApplication? = nil,
        completion: ((_ ok: Bool, _ error: String?) -> Void)? = nil
    ) {
        // Serialization state + the pasteboard dance run on main. Hop there if
        // called off-main so `isInjecting` is never read/written concurrently.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { inject(text, into: target, completion: completion) }
            return
        }

        guard AXIsProcessTrusted() else {
            Log.log("inject FAILED: Accessibility permission not granted (System Settings > Privacy & Security > Accessibility)")
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            completion?(false, "Accessibility permission not granted")
            return
        }

        guard !isInjecting else {
            Log.log("inject IGNORED: another injection is already in flight")
            completion?(false, "another injection is in progress")
            return
        }

        // A3: the target was snapshotted earlier; if it has since quit, do NOT
        // fall through to ⌘V — that would paste into whatever is now frontmost.
        if let target, target.isTerminated {
            Log.log("inject SKIPPED: target app is no longer running")
            completion?(false, "target app is no longer running")
            return
        }

        isInjecting = true

        if let target, !target.isActive {
            target.activate(options: [])
            DispatchQueue.main.asyncAfter(deadline: .now() + activationDelay) {
                // A3 re-check: the app may have quit during the activation wait.
                if target.isTerminated {
                    Log.log("inject SKIPPED: target app quit during activation delay")
                    isInjecting = false
                    completion?(false, "target app is no longer running")
                    return
                }
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
        // changeCount right after WE wrote it. ⌘V only reads the pasteboard, so
        // this value should still hold at restore time — unless something else
        // (a user copy, another app) wrote in the meantime (A2).
        let ourChangeCount = pasteboard.changeCount

        guard synthesizeCmdV() else {
            restore(pasteboard, items: saved)
            isInjecting = false
            completion?(false, "could not create CGEvents")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // Only restore if nothing else touched the pasteboard during the
            // paste window. If the user copied something, changeCount advanced
            // past ours — leave their clipboard alone instead of clobbering it
            // with the stale snapshot (A2).
            if pasteboard.changeCount == ourChangeCount {
                restore(pasteboard, items: saved)
            } else {
                Log.log("inject: pasteboard changed during paste window, skipping restore to avoid clobbering a user copy")
            }
            isInjecting = false
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
