import AVFoundation
import AppKit
import ApplicationServices
import SwiftUI

/// First-run permissions guide. Murmur needs two
/// system grants and today gives no guidance for either:
///
/// - **Microphone** — prompts automatically the first time we record, but the
///   user can deny it, and there's no in-app way to see or recover that.
/// - **Accessibility** — CANNOT be prompted into existence; the user must add
///   Murmur under System Settings > Privacy & Security > Accessibility by hand,
///   or the ⌘V paste-inject silently no-ops.
///
/// This view shows both with live status and a per-row action, polling so the
/// checkmarks flip the moment a grant lands (mic via the async callback,
/// Accessibility while the user is over in System Settings). Presented once on
/// first launch and re-openable from the menubar "Setup…" item.
struct OnboardingView: View {
    /// Called when the user dismisses the guide ("Get Started" / "Done").
    var onComplete: () -> Void

    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    /// Installed model count; nil = Ollama not reachable.
    @State private var ollamaModelCount: Int?
    @ObservedObject private var pillState = DictationCoordinator.shared.pillState

    /// Poll every second so grants made outside the app (Accessibility toggled
    /// in System Settings, mic granted from the OS prompt) reflect live.
    private let pollTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var micGranted: Bool { micStatus == .authorized }
    private var allGranted: Bool { micGranted && accessibilityTrusted }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Murmur")
                    .font(.title2.bold())
                Text("Murmur turns your speech into text, entirely on this Mac. Two one-time permissions and you're set.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 12) {
                PermissionRow(
                    title: "Microphone",
                    detail: "Lets Murmur hear you so it can transcribe. macOS asks the first time you record.",
                    granted: micGranted,
                    actionTitle: micActionTitle,
                    actionEnabled: micStatus != .authorized,
                    action: requestMic
                )
                PermissionRow(
                    title: "Accessibility",
                    detail: "Lets Murmur paste the transcript into whatever app you're typing in. Add Murmur under Privacy & Security > Accessibility.",
                    granted: accessibilityTrusted,
                    actionTitle: "Open System Settings",
                    actionEnabled: !accessibilityTrusted,
                    action: openAccessibilitySettings
                )
                PermissionRow(
                    title: "Speech model",
                    detail: speechModelDetail,
                    granted: pillState.asrModel == .ready,
                    grantedLabel: "Ready",
                    neededLabel: speechModelBadge,
                    actionTitle: "Retry",
                    actionEnabled: speechModelRetryable,
                    action: { DictationCoordinator.shared.preloadAsr() }
                )
                // Informational only: cleanup is optional and off by default.
                PermissionRow(
                    title: "Text cleanup (optional): Ollama",
                    detail: ollamaDetail,
                    granted: ollamaModelCount != nil,
                    grantedLabel: "Running",
                    neededLabel: "Optional",
                    actionTitle: "Refresh",
                    actionEnabled: true,
                    action: { Task { await refreshOllama() } }
                )
            }

            Divider()

            HStack {
                if allGranted {
                    Label("All set — you're ready to dictate.", systemImage: "checkmark.seal.fill")
                        .font(.callout)
                        .foregroundStyle(.green)
                } else {
                    Text("You can grant these now or later from the menubar's Setup item.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(allGranted ? "Get Started" : "Done") {
                    onComplete()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onReceive(pollTimer) { _ in refreshStatuses() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatuses()
        }
        .onAppear(perform: refreshStatuses)
        .task { await refreshOllama() }
    }

    private var speechModelBadge: String {
        switch pillState.asrModel {
        case .downloading(let fraction?): return "Downloading \(Int(fraction * 100))%"
        case .downloading(nil): return "Downloading"
        case .loading: return "Loading"
        case .failed: return "Failed"
        case .notLoaded, .ready: return "Not loaded"
        }
    }

    private var speechModelDetail: String {
        switch pillState.asrModel {
        case .ready: return "Parakeet is loaded and runs entirely on this Mac."
        case .failed(let message): return "Couldn't load the speech model: \(message)"
        default: return "The first run downloads the speech model (a few hundred MB). You can record meanwhile; transcription waits for it."
        }
    }

    private var speechModelRetryable: Bool {
        switch pillState.asrModel {
        case .failed, .notLoaded: return true
        default: return false
        }
    }

    private var ollamaDetail: String {
        switch ollamaModelCount {
        case nil: return "Not running. Cleanup stays off; install from ollama.com"
        case 0: return "Running, no models installed. Run: ollama pull \(OllamaClient.fallbackModel)"
        case let count?: return "Running with \(count) model\(count == 1 ? "" : "s") installed. Turn cleanup on in Settings."
        }
    }

    @MainActor
    private func refreshOllama() async {
        ollamaModelCount = (try? await OllamaClient().installedModels())?.count
    }

    private var micActionTitle: String {
        switch micStatus {
        case .authorized: return "Granted"
        case .denied, .restricted: return "Open System Settings"
        default: return "Allow Microphone"
        }
    }

    private func refreshStatuses() {
        micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibilityTrusted = AXIsProcessTrusted()
    }

    private func requestMic() {
        switch micStatus {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { _ in
                DispatchQueue.main.async { refreshStatuses() }
            }
        default:
            // Already decided — the OS won't re-prompt, so send them to the pane.
            openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        }
    }

    private func openAccessibilitySettings() {
        // Prompt option surfaces Murmur in the list and pops the system dialog;
        // it does NOT grant anything, so we also deep-link to the pane.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openURL("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private func openURL(_ string: String) {
        guard let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

/// One permission line: what it's for, a live granted/needed badge, and an
/// action button that disables itself once the grant is in place.
private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    var grantedLabel = "Granted"
    var neededLabel = "Needed"
    let actionTitle: String
    let actionEnabled: Bool
    let action: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.title3)
                .foregroundStyle(granted ? .green : .orange)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(title).font(.headline)
                    Text(granted ? grantedLabel : neededLabel)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(granted ? .green : .orange)
                }
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(actionTitle, action: action)
                .disabled(!actionEnabled)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: .controlBackgroundColor))
        )
    }
}
