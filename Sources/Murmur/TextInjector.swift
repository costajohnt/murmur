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
    /// The dictation is promised through an NSPasteboardItem data provider,
    /// so a read of it is the "paste happened" signal (audit M1); a fixed
    /// timer restored the old clipboard under a slow target (a terminal's
    /// multi-line paste sheet, a busy Electron app) and the queued ⌘V then
    /// pasted the old clipboard. How long after the read to restore; see
    /// `restoreDeadline` for why it equals the old timer.
    nonisolated static let restoreGrace: TimeInterval = 1.5
    /// A read this soon after ⌘V is more likely a clipboard manager polling
    /// on change than the target processing the key event.
    nonisolated static let bystanderWindow: TimeInterval = 0.1
    /// If nobody reads the paste within this, give up: restore the clipboard
    /// (changeCount guard still applies) and tell the user.
    private static let maxPasteWait: TimeInterval = 10

    /// The paste window closes early when a new dictation arrives while an
    /// unread paste still holds the clipboard, instead of dropping the new
    /// one for up to `maxPasteWait`.
    private static var pendingFinish: (() -> Void)?
    /// Delay between ⌘V and the send word's Return, so an app that handles
    /// paste asynchronously (Electron, some terminals) inserts the text first.
    private static let returnDelay: TimeInterval = 0.15

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
    /// activates it first. `pressReturn` (the send word) presses Return after
    /// the paste; with empty `text` it presses only Return. Returns via
    /// `completion` on the main queue.
    static func inject(
        _ text: String,
        into target: NSRunningApplication? = nil,
        pressReturn: Bool = false,
        completion: ((_ ok: Bool, _ error: String?) -> Void)? = nil
    ) {
        guard AXIsProcessTrusted() else {
            Log.log("inject FAILED: Accessibility permission not granted (System Settings > Privacy & Security > Accessibility)")
            completion?(false, "Accessibility permission not granted")
            return
        }

        if isInjecting, let pendingFinish {
            Log.log("inject: closing out the previous paste window early")
            pendingFinish()
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
                pasteWhenActive(text, target: target, pressReturn: pressReturn, attemptsLeft: activationPollAttempts, completion: completion)
            }
        } else {
            performPaste(text, pressReturn: pressReturn, completion: completion)
        }
    }

    /// M19: only post ⌘V once the target is actually frontmost. Activation can
    /// be refused or slow, and ⌘V would then land in whatever app is in front.
    private static func pasteWhenActive(
        _ text: String,
        target: NSRunningApplication,
        pressReturn: Bool,
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
            performPaste(text, pressReturn: pressReturn, completion: completion)
            return
        }
        guard attemptsLeft > 0 else {
            Log.log("inject SKIPPED: target app never became active")
            isInjecting = false
            completion?(false, "the target app didn't come to the front. The text is saved in History")
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + activationPollInterval) {
            pasteWhenActive(text, target: target, pressReturn: pressReturn, attemptsLeft: attemptsLeft - 1, completion: completion)
        }
    }

    private static func performPaste(_ text: String, pressReturn: Bool, completion: ((Bool, String?) -> Void)?) {
        // Send word said on its own: nothing to paste, leave the clipboard alone.
        if text.isEmpty {
            let ok = pressReturn && postKey(returnKey)
            isInjecting = false
            completion?(ok, ok ? nil : "could not create CGEvents")
            return
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        var ourChangeCount = 0
        var postedAt: Date?
        var readSeen = false
        var finished = false

        // Runs once: from the provider read (plus grace), the timeout, or a
        // new inject closing this window, whichever comes first.
        func finish(consumed: Bool) {
            guard !finished else { return }
            finished = true
            pendingFinish = nil
            if !consumed {
                Log.log("inject: nothing read the paste within \(Int(maxPasteWait))s")
            }
            if !restoreIfUnchanged(pasteboard, items: saved, ourChangeCount: ourChangeCount) {
                Log.log("inject: pasteboard changed during paste window, skipping restore to avoid clobbering a user copy")
            }
            isInjecting = false
            completion?(consumed, consumed ? nil : "the app didn't pick up the paste. The text is saved in History")
        }

        writeDictation(text, to: pasteboard) {
            readSeen = true
            let now = Date()
            let deadline = restoreDeadline(readAt: now, postedAt: postedAt)
            if deadline.timeIntervalSince(now) < restoreGrace {
                Log.log("inject: pasteboard read within \(Int(bystanderWindow * 1000)) ms of ⌘V, likely a clipboard manager; restoring on the fixed timer")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(deadline.timeIntervalSince(now), 0)) { finish(consumed: true) }
        }
        // changeCount right after WE wrote it. ⌘V only reads the pasteboard, so
        // this value should still hold at restore time — unless something else
        // (a user copy, another app) wrote in the meantime (A2).
        ourChangeCount = pasteboard.changeCount

        guard postKey(vKey, flags: .maskCommand) else {
            finished = true
            restore(pasteboard, items: saved)
            isInjecting = false
            completion?(false, "could not create CGEvents")
            return
        }
        postedAt = Date()
        pendingFinish = { finish(consumed: readSeen) }
        if pressReturn {
            DispatchQueue.main.asyncAfter(deadline: .now() + returnDelay) {
                if !postKey(returnKey) { Log.log("inject: could not post Return after paste") }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + maxPasteWait) { finish(consumed: false) }
    }

    /// When to restore after the one provider read. An NSPasteboard promise
    /// resolves once: the first reader triggers the provider, the item then
    /// holds the data and later readers never call back, and the pasteboard
    /// does not say who read. So this is the only signal, and honestly a
    /// weak one: a clipboard manager that ignores the transient marker polls
    /// on change and reads within `bystanderWindow` of ⌘V, in which case the
    /// restore falls back to the old fixed timer from ⌘V. A later read is
    /// taken as the target's and the restore runs `restoreGrace` after it.
    /// Either way the restore is never earlier than the old 1.5 s timer,
    /// only later under a slow target. No read at all: `maxPasteWait`.
    nonisolated static func restoreDeadline(readAt: Date, postedAt: Date?) -> Date {
        if let postedAt, readAt.timeIntervalSince(postedAt) > bystanderWindow {
            return readAt.addingTimeInterval(restoreGrace)
        }
        return (postedAt ?? readAt).addingTimeInterval(restoreGrace)
    }

    // MARK: - Clipboard snapshot/restore

    /// Writes dictated text marked private (M2): `.currentHostOnly` keeps it
    /// off Universal Clipboard, the markers keep it out of clipboard managers.
    /// With `onConsumed`, the string is promised rather than written and the
    /// closure fires (on main) each time a reader resolves it.
    nonisolated static func writeDictation(_ text: String, to pasteboard: NSPasteboard, onConsumed: (() -> Void)? = nil) {
        pasteboard.prepareForNewContents(with: .currentHostOnly)
        let item = NSPasteboardItem()
        if let onConsumed {
            item.setDataProvider(DictationProvider(text: text, onConsumed: onConsumed), forTypes: [.string])
        } else {
            item.setString(text, forType: .string)
        }
        item.setData(Data(), forType: transientType)
        item.setData(Data(), forType: concealedType)
        pasteboard.writeObjects([item])
    }

    /// History's Copy button. A transcript copied from history is the same
    /// dictated text, so it gets the same private write: never relayed to
    /// other devices or recorded by a clipboard manager.
    nonisolated static func copyTranscript(_ text: String, to pasteboard: NSPasteboard) {
        writeDictation(text, to: pasteboard)
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

    /// Resolves the promised `.string` when a reader asks for it. The item
    /// retains its provider, and the signal hops to main so the caller's
    /// state stays main-actor.
    private final class DictationProvider: NSObject, NSPasteboardItemDataProvider {
        private let text: String
        private let onConsumed: () -> Void

        init(text: String, onConsumed: @escaping () -> Void) {
            self.text = text
            self.onConsumed = onConsumed
        }

        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            item.setString(text, forType: type)
            DispatchQueue.main.async(execute: onConsumed)
        }
    }

    // MARK: - Key synthesis

    private static let vKey: CGKeyCode = 9 // kVK_ANSI_V
    private static let returnKey: CGKeyCode = 36 // kVK_Return

    private static func postKey(_ key: CGKeyCode, flags: CGEventFlags = []) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else {
            return false
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
