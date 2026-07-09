import ServiceManagement
import SwiftUI

/// Native Settings window. Zero-config: every
/// control's default reproduces today's behavior (Auto model, Faithful tone,
/// hotkey off, launch-at-login off), so the panel is purely for overrides.
///
/// Bindings go through @AppStorage with the AppSettings keys; the pipeline
/// reads AppSettings live, so model/tone changes apply to the next dictation
/// without restart. Hotkey and login-item changes are applied immediately in
/// onChange handlers.
struct SettingsView: View {
    @AppStorage(AppSettings.cleanupModeKey) private var cleanupModeRaw = AppSettings.cleanupMode.rawValue
    @AppStorage(AppSettings.cleanupModelOverrideKey) private var modelOverride = ""
    @AppStorage(AppSettings.tonePresetKey) private var toneRaw = TonePreset.faithful.rawValue
    @AppStorage(AppSettings.hotkeyEnabledKey) private var hotkeyEnabled = false
    @AppStorage(AppSettings.hotkeyBindingKey) private var hotkeyBindingRaw = HotkeyBinding.optionSpace.rawValue
    @AppStorage(AppSettings.silenceAutoStopSecondsKey) private var silenceAutoStopSeconds = 2.0

    /// nil = tags not fetched yet or Ollama unreachable.
    @State private var installedModels: [String]?
    @State private var ollamaReachable = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        Form {
            cleanupSection
            // Model and Tone only apply when the LLM actually runs. Off mode
            // injects the raw transcript, so hide both.
            if !cleanupOff {
                modelSection
                toneSection
            }
            hotkeySection
            silenceSection
            loginSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .task {
            await refreshModels()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: hotkeyEnabled) { HotkeyManager.shared.apply() }
        .onChange(of: hotkeyBindingRaw) { HotkeyManager.shared.apply() }
        .onChange(of: launchAtLogin) { syncLoginItem() }
    }

    // MARK: - Cleanup mode

    private var cleanupOff: Bool {
        (CleanupMode(rawValue: cleanupModeRaw) ?? .off) == .off
    }

    private var cleanupSection: some View {
        Section("Cleanup") {
            Picker("Cleanup", selection: $cleanupModeRaw) {
                ForEach(CleanupMode.allCases) { mode in
                    Text(mode.label).tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text((CleanupMode(rawValue: cleanupModeRaw) ?? .off).summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Cleanup model

    private var staleOverride: Bool {
        guard let models = installedModels, !modelOverride.isEmpty else { return false }
        return !models.contains(modelOverride)
    }

    private var modelSection: some View {
        Section("Cleanup Model") {
            Picker("Model", selection: $modelOverride) {
                Text("Auto (recommended)").tag("")
                if let models = installedModels {
                    ForEach(models, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                // Keep a stored-but-unavailable override selectable so the
                // picker shows the truth instead of silently jumping.
                if !modelOverride.isEmpty && !(installedModels ?? []).contains(modelOverride) {
                    Text("\(modelOverride) (not installed)").tag(modelOverride)
                }
            }
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Auto picks \(OllamaClient.preferredModel) based on this Mac's memory.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !ollamaReachable {
                        Text("Ollama not running. Showing your saved choice.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if staleOverride {
                        Label("\(modelOverride) is no longer installed; Auto is used until it's back.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button("Refresh") {
                    Task { await refreshModels() }
                }
                .controlSize(.small)
            }
        }
    }

    @MainActor
    private func refreshModels() async {
        do {
            installedModels = try await OllamaClient().installedModels()
            ollamaReachable = true
        } catch {
            // Keep whatever list we had; just flag the reachability.
            ollamaReachable = false
            Log.log("settings: model refresh failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Tone

    private var toneSection: some View {
        Section("Cleanup Tone") {
            Picker("Tone", selection: $toneRaw) {
                ForEach(TonePreset.allCases) { preset in
                    Text(preset.label).tag(preset.rawValue)
                }
            }
            .pickerStyle(.segmented)
            Text((TonePreset(rawValue: toneRaw) ?? .faithful).summary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Hotkey

    private var hotkeySection: some View {
        Section("Global Hotkey") {
            Toggle("Enable global hotkey", isOn: $hotkeyEnabled)
            Picker("Shortcut", selection: $hotkeyBindingRaw) {
                ForEach(HotkeyBinding.allCases) { binding in
                    Text(binding.label).tag(binding.rawValue)
                }
            }
            .disabled(!hotkeyEnabled)
            Text("Toggles dictation exactly like clicking the pill. Registered as a system hotkey, so no Input Monitoring permission is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Silence auto-stop

    private var silenceSection: some View {
        Section("Silence Auto-Stop") {
            Slider(value: $silenceAutoStopSeconds, in: 0...5, step: 0.5) {
                Text("Silence Auto-Stop")
            }
            Text(silenceAutoStopSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var silenceAutoStopSummary: String {
        silenceAutoStopSeconds <= 0
            ? "Off — recordings only stop when you tap the pill."
            : String(format: "Stops automatically after %.1fs of silence.", silenceAutoStopSeconds)
    }

    // MARK: - Launch at login

    private var loginSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: $launchAtLogin)
            if let loginError {
                Label(loginError, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// Register/unregister with SMAppService, then reflect the ACTUAL state
    /// back into the toggle (the service is the source of truth; a failed
    /// register snaps the toggle back).
    private func syncLoginItem() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                if service.status != .enabled { try service.register() }
            } else {
                if service.status == .enabled { try service.unregister() }
            }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
            Log.log("settings: launch-at-login change failed: \(error.localizedDescription)")
        }
        let actual = service.status == .enabled
        if launchAtLogin != actual { launchAtLogin = actual }
        Log.log("settings: launch-at-login now \(actual ? "enabled" : "disabled") (status \(service.status.rawValue))")
    }
}
