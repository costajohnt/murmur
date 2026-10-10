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
    @AppStorage(AppSettings.silenceAutoStopSecondsKey) private var silenceAutoStopSeconds = AppSettings.defaultSilenceAutoStopSeconds
    @AppStorage(AppSettings.brainstemURLKey) private var brainstemURL = ""
    @AppStorage(AppSettings.preferredInputDeviceUIDKey) private var inputDeviceUID = ""
    @AppStorage(AppSettings.pushToTalkKey) private var pushToTalk = false
    @AppStorage(AppSettings.checkForUpdatesKey) private var checkForUpdates = false

    /// nil = tags not fetched yet or Ollama unreachable.
    @State private var installedModels: [String]?
    @State private var ollamaReachable = true
    /// The model cleanup would use right now (pickModel over the last tags fetch).
    @State private var resolvedModel: String?
    @State private var pullTask: Task<Void, Never>?
    @State private var pullStatus = ""
    @State private var pullFraction: Double?
    @State private var pullError: String?
    @State private var inputDevices: [AudioInputDevice] = []
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
            microphoneSection
            hotkeySection
            silenceSection
            vaultCaptureSection
            loginSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 700)
        .task {
            await refreshModels()
            inputDevices = AudioInputDevice.available()
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
        .onChange(of: hotkeyEnabled) { HotkeyManager.shared.apply() }
        .onChange(of: hotkeyBindingRaw) { HotkeyManager.shared.apply() }
        .onChange(of: launchAtLogin) { syncLoginItem() }
        .onChange(of: checkForUpdates) { UpdateChecker.shared.checkIfDue() }
        .onChange(of: modelOverride) { updateResolvedModel() }
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
            if !cleanupOff {
                modelStatus
            }
        }
    }

    /// Which model cleanup will use, whether it's installed, and a one-click
    /// pull when it isn't.
    @ViewBuilder
    private var modelStatus: some View {
        if !ollamaReachable {
            HStack(spacing: 4) {
                Text("Ollama isn't running")
                Link("(ollama.com)", destination: URL(string: "https://ollama.com")!)
            }
            .font(.callout)
            .foregroundStyle(.orange)
        } else if let model = resolvedModel, let installed = installedModels {
            if installed.contains(model) {
                Label("Uses \(model) (installed)", systemImage: "checkmark.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if pullTask != nil {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: pullFraction)
                    HStack {
                        Text(pullStatus)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Cancel") { pullTask?.cancel() }
                            .controlSize(.small)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Label("\(model) isn't installed, so cleanup can't run.", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                    Button("Download \(model)\(Self.downloadSizes[model].map { " (\($0))" } ?? "")") {
                        startPull(model)
                    }
                    if let pullError {
                        Text(pullError)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// Approximate sizes for the two Auto models; others show no size.
    private static let downloadSizes = ["llama3.2:3b": "~2 GB", "qwen2.5:7b": "~4.7 GB"]

    @MainActor
    private func startPull(_ model: String) {
        pullError = nil
        pullStatus = "Starting…"
        pullFraction = nil
        pullTask = Task { @MainActor in
            do {
                try await OllamaClient().pull(model: model) { update in
                    pullStatus = update.status
                    pullFraction = update.fraction
                }
                await refreshModels()
            } catch is CancellationError {
                // User cancelled; back to the Download button.
            } catch {
                pullError = error.localizedDescription
                Log.log("settings: pull \(model) failed: \(error.localizedDescription)")
            }
            pullTask = nil
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
        updateResolvedModel()
    }

    /// Same decision `resolveModel` makes at dictation time, over the last
    /// tags fetch. Kept in state (not computed in body) because pickModel logs.
    private func updateResolvedModel() {
        resolvedModel = OllamaClient.pickModel(
            installed: installedModels ?? [],
            override: modelOverride.isEmpty ? nil : modelOverride,
            preferred: OllamaClient.preferredModel,
            fallback: OllamaClient.fallbackModel
        )
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

    // MARK: - Microphone

    private var microphoneSection: some View {
        Section("Microphone") {
            HStack(alignment: .firstTextBaseline) {
                Picker("Input", selection: $inputDeviceUID) {
                    Text("System Default").tag("")
                    ForEach(inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // Keep a stored-but-disconnected mic selectable so the
                    // picker shows the truth instead of silently snapping back
                    // to System Default.
                    if !inputDeviceUID.isEmpty && !inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
                        Text("\(inputDeviceUID) (disconnected)").tag(inputDeviceUID)
                    }
                }
                Button("Refresh") {
                    inputDevices = AudioInputDevice.available()
                }
                .controlSize(.small)
            }
            Text(microphoneSummary)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var microphoneSummary: String {
        if inputDeviceUID.isEmpty {
            return "System Default — follows your macOS Sound input setting."
        }
        if inputDevices.contains(where: { $0.uid == inputDeviceUID }) {
            return "Murmur records from this mic regardless of the macOS default."
        }
        return "This mic isn't connected right now; Murmur falls back to the system default until it's back."
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
            Toggle("Push-to-talk (hold to record)", isOn: $pushToTalk)
                .disabled(!hotkeyEnabled)
            Text("\(pushToTalk ? "Records while held and stops on release." : "Toggles dictation exactly like clicking the pill.") Registered as a system hotkey, so no Input Monitoring permission is needed.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Silence auto-stop

    private var silenceSection: some View {
        Section("Silence Auto-Stop") {
            Slider(value: $silenceAutoStopSeconds, in: 0...15, step: 1.0) {
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

    // MARK: - Vault capture

    private var vaultCaptureSection: some View {
        Section("Vault Capture") {
            TextField("Brainstem URL", text: $brainstemURL, prompt: Text("https://brainstem.example.ts.net"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
            Text(brainstemURL.isEmpty
                ? "Off — dictations starting with \"note to self\" paste normally, like any other transcript."
                : "On — dictations starting with \"note to self\" are sent to the vault instead of pasted.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Launch at login

    private var loginSection: some View {
        Section("Startup") {
            Toggle("Launch at login", isOn: $launchAtLogin)
            Toggle("Check for updates", isOn: $checkForUpdates)
            Text("Checks GitHub once a day for a newer release. Sends no dictation data.")
                .font(.callout)
                .foregroundStyle(.secondary)
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
