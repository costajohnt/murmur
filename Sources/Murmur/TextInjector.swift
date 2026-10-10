import AppKit
import CoreGraphics

/// Paste-injection (v0 Spike C logic, made reusable):
/// snapshot clipboard → set string → CGEvent ⌘V → restore clipboard.
/// Optionally activates an explicit target app first (used by history
/// "Insert at cursor", where our own window is frontmost).
/// Main actor: the injection state and the pasteboard dance live there. The
/// pure pasteboard helpers are `nonisolated` so tests can call them directly.
@MainActor
enum TextInjector {
    /// Delay between activating the target app and posting ⌘V.
    private static let activationDelay: TimeInterval = 0.35
    /// After the activation delay, keep polling `isActive` this often, up to
    /// this many times (~0.5 s), before giving up on the paste (M19).
    private static let activationPollInterval: TimeInterval = 0.05
    private static let activationPollAttempts = 10
    /// Delay before restoring the previous clipboard (paste must be consumed
    /// first). 1.5 s rather than 1.0 s: an app that was just activated can be
    /// slow to process ⌘V, and restoring early would paste the old clipboard.
    private static let restoreDelay: TimeInterval = 1.5

    /// nspasteboard.org markers. Transient: clipboard managers should not
    /// record this content. Concealed: it is sensitive, don't display it.
    nonisolated static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    nonisolated static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Serializes injections (A2): only one paste may be mid-flight — snapshot →
    /// set → ⌘V → restore. A second `inject` arriving inside that window is
    /// dropped rather than racing on the shared pasteboard (e.g. rapid history
    /// "Insert"). Main-actor isolated with the rest of the enum.
    private static var isInjecting = false

    /// Injects `text` at the cursor. If `target` is provided and not active,
    /// activates it first. Returns via `completion` on the main queue.
    static func inject(
        _ text: String,
        into target: NSRunningApplication? = nil,
        completion: ((_ ok: Bool, _ error: String?) -> Void)? = nil
    ) {
        guard AXIsProcessTrusted() else {
            Log.log("inject FAILED: Accessibility permission not granted (System Settings > Privacy & Security > Accessibility)")
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
                pasteWhenActive(text, target: target, attemptsLeft: activationPollAttempts, completion: completion)
            }
        } else {
            performPaste(text, completion: completion)
        }
    }

    /// M19: only post ⌘V once the target is actually frontmost. Activation can
    /// be refused or slow, and ⌘V would then land in whatever app is in front.
    private static func pasteWhenActive(
        _ text: String,
        target: NSRunningApplication,
        attemptsLeft: Int,
        completion: ((Bool, String?) -> Void)?
    ) {
        // A3 re-check: the app may have quit during the activation wait.
        if target.isTerminated {
            Log.log("inject SKIPPED: target app quit during activation delay")
            isInjecting = false
            completion?(false, "target app is no longer running")
            return
        }
        if target.isActive {
            performPaste(text, completion: completion)
            return
        }
        guard attemptsLeft > 0 else {
            Log.log("inject SKIPPED: target app never became active")
            isInjecting = false
            completion?(false, "the target app didn't come to the front. The text is saved in History")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + activationPollInterval) {
            pasteWhenActive(text, target: target, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    private static func performPaste(_ text: String, completion: ((Bool, String?) -> Void)?) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)

        writeDictation(text, to: pasteboard)
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
            if !restoreIfUnchanged(pasteboard, items: saved, ourChangeCount: ourChangeCount) {
                Log.log("inject: pasteboard changed during paste window, skipping restore to avoid clobbering a user copy")
            }
            isInjecting = false
            completion?(true, nil)
        }
    }

    // MARK: - Clipboard snapshot/restore

    /// Writes dictated text marked private (M2): `.currentHostOnly` keeps it
    /// off Universal Clipboard, the markers keep it out of clipboard managers.
    nonisolated static func writeDictation(_ text: String, to pasteboard: NSPasteboard) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        pasteboard.setString(text, forType: .string)
        pasteboard.setData(Data(), forType: transientType)
        pasteboard.setData(Data(), forType: concealedType)
    }

    /// Only restore if nothing else touched the pasteboard during the paste
    /// window. If the user copied something, changeCount advanced past ours —
    /// leave their clipboard alone instead of clobbering it with the stale
    /// snapshot (A2). Returns whether it restored.
    @discardableResult
    nonisolated static func restoreIfUnchanged(
        _ pasteboard: NSPasteboard,
        items: [[NSPasteboard.PasteboardType: Data]],
        ourChangeCount: Int
    ) -> Bool {
        guard pasteboard.changeCount == ourChangeCount else { return false }
        restore(pasteboard, items: items)
        return true
    }

    nonisolated static func snapshot(_ pasteboard: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
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

    /// Puts the user's snapshot back, also `.currentHostOnly` + transient: it is
    /// their data, already synced/recorded when they first copied it, so the
    /// restore must not re-broadcast it as a fresh copy.
    nonisolated static func restore(_ pasteboard: NSPasteboard, items: [[NSPasteboard.PasteboardType: Data]]) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        guard !items.isEmpty else { return }
        let restored = items.map { entry -> NSPasteboardItem in
            let item = NSPasteboardItem()
            for (type, data) in entry {
                item.setData(data, forType: type)
            }
            item.setData(Data(), forType: transientType)
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
