import Foundation

/// Cleanup tone presets (docs/settings-panel.md §2). Every preset keeps the
/// FULL faithful "reformat, don't answer" core — presets only append a style
/// layer on top (see `OllamaClient.systemPrompt(for:)`), so no preset can
/// weaken the don't-answer / don't-invent guard.
enum TonePreset: String, CaseIterable, Identifiable {
    case faithful
    case polished
    case casual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .faithful: return "Faithful"
        case .polished: return "Polished"
        case .casual: return "Casual"
        }
    }

    var summary: String {
        switch self {
        case .faithful: return "Fix punctuation and fillers, leave your wording alone."
        case .polished: return "Also tighten grammar so it reads cleanly, without changing meaning."
        case .casual: return "Keep the relaxed spoken tone, just clean it up."
        }
    }
}

/// The fixed global-hotkey choices (docs/settings-panel.md §3 allows a small
/// fixed set instead of a full shortcut recorder — that's what this is).
/// Carbon virtual key codes + modifier masks, registered via
/// `RegisterEventHotKey`, which needs NO Input Monitoring or Accessibility
/// permission (unlike an NSEvent global monitor).
enum HotkeyBinding: String, CaseIterable, Identifiable {
    case optionSpace
    case controlOptionSpace
    case commandShiftSpace
    case optionD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .commandShiftSpace: return "⌘⇧ Space"
        case .optionD: return "⌥ D"
        }
    }

    /// Carbon virtual key code (kVK_Space = 49, kVK_ANSI_D = 2).
    var keyCode: UInt32 {
        switch self {
        case .optionSpace, .controlOptionSpace, .commandShiftSpace: return 49
        case .optionD: return 2
        }
    }

    /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800,
    /// controlKey 0x1000). Raw values so this file stays Foundation-only.
    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return 0x800
        case .controlOptionSpace: return 0x1000 | 0x800
        case .commandShiftSpace: return 0x100 | 0x200
        case .optionD: return 0x800
        }
    }
}

/// UserDefaults-backed settings (docs/settings-panel.md). SettingsView binds
/// via @AppStorage with these keys; the pipeline reads through these statics
/// so changes apply live, no restart. The zero-config defaults (no keys
/// written) are exactly today's behavior: Auto model, Faithful tone, hotkey
/// off. Launch-at-login is not stored here — it's derived from
/// SMAppService.mainApp.status, the source of truth.
enum AppSettings {
    static let cleanupModelOverrideKey = "cleanupModelOverride"
    static let tonePresetKey = "tonePreset"
    static let hotkeyEnabledKey = "hotkeyEnabled"
    static let hotkeyBindingKey = "hotkeyBinding"

    private static var defaults: UserDefaults { .standard }

    /// nil = Auto (the RAM-based resolve). Stored as "" for @AppStorage.
    static var cleanupModelOverride: String? {
        let value = defaults.string(forKey: cleanupModelOverrideKey) ?? ""
        return value.isEmpty ? nil : value
    }

    static var tonePreset: TonePreset {
        defaults.string(forKey: tonePresetKey).flatMap(TonePreset.init(rawValue:)) ?? .faithful
    }

    static var hotkeyEnabled: Bool {
        defaults.bool(forKey: hotkeyEnabledKey)
    }

    static var hotkeyBinding: HotkeyBinding {
        defaults.string(forKey: hotkeyBindingKey).flatMap(HotkeyBinding.init(rawValue:)) ?? .optionSpace
    }
}
