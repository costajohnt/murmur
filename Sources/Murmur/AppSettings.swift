import Foundation

/// Cleanup tone presets. Faithful/polished/casual keep the
/// FULL faithful "reformat, don't answer" core — they only append a style
/// layer on top (see `OllamaClient.systemPrompt(for:)`), so none of them can
/// weaken the don't-answer / don't-invent guard. Caveman is the deliberate
/// exception: compression requires rewording, which the core forbids, so it
/// uses a standalone prompt that re-states the don't-answer / don't-invent /
/// keep-code-verbatim guards on its own.
enum TonePreset: String, CaseIterable, Identifiable {
    case faithful
    case polished
    case casual
    case caveman

    var id: String { rawValue }

    var label: String {
        switch self {
        case .faithful: return "Faithful"
        case .polished: return "Polished"
        case .casual: return "Casual"
        case .caveman: return "Caveman"
        }
    }

    var summary: String {
        switch self {
        case .faithful: return "Fix punctuation and fillers, leave your wording alone."
        case .polished: return "Also tighten grammar so it reads cleanly, without changing meaning."
        case .casual: return "Keep the relaxed spoken tone, just clean it up."
        case .caveman: return "Compress into terse caveman speak. Every point kept, fluff dies."
        }
    }
}

/// How much post-ASR cleanup to run. Trades latency for polish:
/// `.off` skips the LLM entirely (instant, raw transcript); `.light` runs the
/// LLM with the tightened formatter prompt but NO dictation-history context
/// (punctuation/capitalization only, no cold-context feedback loop); `.full`
/// is the history-aware path. The unwritten-key default is RAM-gated (see
/// `AppSettings.cleanupMode`) so low-memory Macs default Off.
enum CleanupMode: String, CaseIterable, Identifiable {
    case off
    case light
    case full

    var id: String { rawValue }

    var label: String {
        switch self {
        case .off: return "Off"
        case .light: return "Light"
        case .full: return "Full"
        }
    }

    var summary: String {
        switch self {
        case .off: return "Off — instant, raw transcript"
        case .light: return "Light — punctuation only, no history"
        case .full: return "Full — uses your dictation history"
        }
    }
}

/// The fixed global-hotkey choices (a small fixed set instead of a full
/// shortcut recorder).
/// Carbon virtual key codes + modifier masks, registered via
/// `RegisterEventHotKey`, which needs NO Input Monitoring or Accessibility
/// permission (unlike an NSEvent global monitor).
enum HotkeyBinding: String, CaseIterable, Identifiable {
    case optionSpace
    case controlOptionSpace
    case commandShiftSpace
    case optionD
    /// Bare F13/F14, no modifier: for a mapped external device (e.g. a
    /// Bluetooth remote remapped via Karabiner-Elements) rather than typing.
    /// F13/F14 have no physical key on virtually any keyboard, so there's
    /// zero collision risk with normal typing even with no modifier.
    case f13
    case f14

    var id: String { rawValue }

    var label: String {
        switch self {
        case .optionSpace: return "⌥ Space"
        case .controlOptionSpace: return "⌃⌥ Space"
        case .commandShiftSpace: return "⌘⇧ Space"
        case .optionD: return "⌥ D"
        case .f13: return "F13"
        case .f14: return "F14"
        }
    }

    /// Carbon virtual key code (kVK_Space = 49, kVK_ANSI_D = 2, kVK_F13 =
    /// 105, kVK_F14 = 107 — verified against the real HIToolbox constants,
    /// not hardcoded from memory).
    var keyCode: UInt32 {
        switch self {
        case .optionSpace, .controlOptionSpace, .commandShiftSpace: return 49
        case .optionD: return 2
        case .f13: return 105
        case .f14: return 107
        }
    }

    /// Carbon modifier mask (cmdKey 0x100, shiftKey 0x200, optionKey 0x800,
    /// controlKey 0x1000). Raw values so this file stays Foundation-only.
    /// F13/F14 use 0 (no modifier) — they're bare-key bindings by design.
    var carbonModifiers: UInt32 {
        switch self {
        case .optionSpace: return 0x800
        case .controlOptionSpace: return 0x1000 | 0x800
        case .commandShiftSpace: return 0x100 | 0x200
        case .optionD: return 0x800
        case .f13, .f14: return 0
        }
    }
}

/// UserDefaults-backed settings. SettingsView binds
/// via @AppStorage with these keys; the pipeline reads through these statics
/// so changes apply live, no restart. The zero-config defaults (no keys
/// written) are exactly today's behavior: Auto model, Faithful tone, hotkey
/// off. Launch-at-login is not stored here — it's derived from
/// SMAppService.mainApp.status, the source of truth.
enum AppSettings {
    static let cleanupModeKey = "cleanupMode"
    static let cleanupModelOverrideKey = "cleanupModelOverride"
    static let tonePresetKey = "tonePreset"
    static let hotkeyEnabledKey = "hotkeyEnabled"
    static let hotkeyBindingKey = "hotkeyBinding"
    static let hasCompletedOnboardingKey = "hasCompletedOnboarding"
    static let silenceAutoStopSecondsKey = "silenceAutoStopSeconds"
    static let brainstemURLKey = "brainstemURL"
    static let preferredInputDeviceUIDKey = "preferredInputDeviceUID"

    private static var defaults: UserDefaults { .standard }

    /// First-run gate for the permissions guide.
    /// Defaults to false (unwritten key) so a fresh install shows onboarding
    /// exactly once; set true when the user dismisses it.
    static var hasCompletedOnboarding: Bool {
        get { defaults.bool(forKey: hasCompletedOnboardingKey) }
        set { defaults.set(newValue, forKey: hasCompletedOnboardingKey) }
    }

    /// Shared RAM gate for both the cleanup-mode default (below) and
    /// OllamaClient's model choice — keeping one threshold means tuning it
    /// only requires touching one site.
    static var isHighMemoryMachine: Bool {
        ProcessInfo.processInfo.physicalMemory > 32 * 1024 * 1024 * 1024
    }

    /// How much cleanup to run on the next dictation. The unwritten-key
    /// default is RAM-gated: Macs with more than 32 GB default to `.full`
    /// (an M5 Max / 64 GB runs the 7B history-aware path comfortably), while
    /// smaller Macs (M4 / 24 GB) default to `.off` so the first dictation is
    /// instant rather than paying a cold model load. Once the user picks a
    /// mode in Settings the stored value wins.
    static var cleanupMode: CleanupMode {
        if let raw = defaults.string(forKey: cleanupModeKey),
           let mode = CleanupMode(rawValue: raw) {
            return mode
        }
        return isHighMemoryMachine ? .full : .off
    }

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

    /// SettingsView's @AppStorage default must match this exactly — it reads
    /// the same key as its own storage, independent of this getter.
    static let defaultSilenceAutoStopSeconds = 2.0

    /// Seconds of sustained near-silence before a listening recording
    /// auto-stops via the same path as a manual pill tap. 0 disables
    /// auto-stop. Read via `object(forKey:)` rather than `double(forKey:)` so
    /// an explicit user-chosen 0 (off) is distinguishable from an unwritten
    /// key — `double(forKey:)` returns 0.0 for both.
    static var silenceAutoStopSeconds: Double {
        (defaults.object(forKey: silenceAutoStopSecondsKey) as? Double) ?? defaultSilenceAutoStopSeconds
    }

    /// Base URL of the brainstem vault-capture endpoint (e.g.
    /// "http://brainstem.tail194f9d.ts.net"), no trailing "/capture". Empty
    /// (the unwritten-key default) means the "note to self" routing feature
    /// is entirely off: dictations paste like normal, prefix included.
    static var brainstemURL: String {
        defaults.string(forKey: brainstemURLKey) ?? ""
    }

    /// Persistent UID of the CoreAudio input device Murmur should record from.
    /// Empty (the unwritten-key default) means "System Default" — today's
    /// behavior, where AVAudioEngine binds to whatever macOS marks as the
    /// default input. A stored UID (e.g. the RØDE NT-USB Mini) is re-bound in
    /// `AudioRecorder.start()` whenever that device is connected; if it's
    /// unplugged the recorder silently falls back to the system default.
    static var preferredInputDeviceUID: String {
        get { defaults.string(forKey: preferredInputDeviceUIDKey) ?? "" }
        set { defaults.set(newValue, forKey: preferredInputDeviceUIDKey) }
    }
}
