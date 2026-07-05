import Carbon.HIToolbox
import Foundation

/// Global hotkey via Carbon `RegisterEventHotKey` (docs/settings-panel.md §3).
/// Chosen over an NSEvent global monitor deliberately: RegisterEventHotKey
/// requires NO Input Monitoring / Accessibility permission and fires even
/// when the app is in the background, so the off-by-default toggle never
/// triggers a permission prompt — and neither does turning it on.
///
/// When the hotkey fires it toggles dictation exactly like a pill click
/// (`DictationCoordinator.pillTapped()`). When disabled, nothing is
/// registered and no monitor of any kind is installed.
@MainActor
final class HotkeyManager {
    static let shared = HotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// What is actually registered right now (nil = nothing) — lets tests and
    /// logs verify the real state rather than the stored preference.
    private(set) var registeredBinding: HotkeyBinding?

    private init() {}

    /// Re-sync Carbon registration with AppSettings. Safe to call repeatedly
    /// (launch, toggle change, binding change).
    func apply() {
        unregister()
        guard AppSettings.hotkeyEnabled else {
            Log.log("hotkey: disabled (nothing registered)")
            return
        }
        let binding = AppSettings.hotkeyBinding
        installHandlerIfNeeded()
        let hotKeyID = EventHotKeyID(signature: OSType(0x5753_504C) /* 'WSPL' */, id: 1)
        let status = RegisterEventHotKey(
            binding.keyCode,
            binding.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        if status == noErr {
            registeredBinding = binding
            Log.log("hotkey: registered \(binding.label) (\(binding.rawValue))")
        } else {
            hotKeyRef = nil
            Log.log("hotkey: RegisterEventHotKey FAILED (status \(status)) for \(binding.label)")
        }
    }

    private func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            if let binding = registeredBinding {
                Log.log("hotkey: unregistered \(binding.label)")
            }
        }
        registeredBinding = nil
    }

    /// One Carbon event handler for the app; the hotkey itself is registered
    /// and torn down per `apply()`.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, _ -> OSStatus in
                Task { @MainActor in
                    Log.log("hotkey: pressed → pillTapped")
                    DictationCoordinator.shared.pillTapped()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            &handlerRef
        )
    }
}
