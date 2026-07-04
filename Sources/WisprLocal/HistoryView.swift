import AppKit
import SwiftData
import SwiftUI

/// History window: dictations newest-first with Copy / Insert at cursor /
/// Re-clean per row.
struct HistoryView: View {
    @Query(sort: \Dictation.createdAt, order: .reverse) private var entries: [Dictation]

    var body: some View {
        Group {
            if entries.isEmpty {
                Text("No dictations yet. Click the pill, speak, click again.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(entries) { entry in
                    DictationRow(entry: entry)
                        .padding(.vertical, 4)
                }
            }
        }
        .frame(minWidth: 520, minHeight: 360)
    }
}

private struct DictationRow: View {
    let entry: Dictation
    @State private var showRaw = false
    @State private var recleaning = false
    @State private var actionNote: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.createdAt, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                statusBadge
                if let ms = entry.durationMs {
                    Text(String(format: "%.1fs", Double(ms) / 1000))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                if !entry.modelName.isEmpty {
                    Text(entry.modelName)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if let note = actionNote {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
            }

            Text(primaryText)
                .font(.body)
                .textSelection(.enabled)

            DisclosureGroup("Raw transcript", isExpanded: $showRaw) {
                Text(entry.rawTranscript.isEmpty ? "(empty)" : entry.rawTranscript)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            .font(.caption)

            HStack(spacing: 12) {
                Button("Copy") { copy() }
                Button("Insert at cursor") { insert() }
                Button(recleaning ? "Re-cleaning…" : "Re-clean") { reclean() }
                    .disabled(recleaning || entry.rawTranscript.isEmpty)
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }

    private var primaryText: String {
        if !entry.cleanedText.isEmpty { return entry.cleanedText }
        if !entry.rawTranscript.isEmpty { return entry.rawTranscript }
        return "(no transcript)"
    }

    private var statusBadge: some View {
        Text(entry.status.label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(badgeColor.opacity(0.2)))
            .foregroundStyle(badgeColor)
    }

    private var badgeColor: Color {
        switch entry.status {
        case .done: return .green
        case .cleanupFailed: return .orange
        case .asrFailed: return .red
        }
    }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(primaryText, forType: .string)
        flash("copied")
    }

    private func insert() {
        let target = TargetAppTracker.shared.lastActiveApp
        Log.log("history insert: target = \(target?.bundleIdentifier ?? "none")")
        TextInjector.inject(primaryText, into: target) { ok, error in
            flash(ok ? "inserted" : (error ?? "failed"))
        }
    }

    private func reclean() {
        recleaning = true
        let raw = entry.rawTranscript
        Task {
            let client = OllamaClient()
            let model = await client.resolveModel()
            do {
                let cleaned = try await client.clean(raw, model: model)
                entry.cleanedText = cleaned
                entry.modelName = model
                entry.status = .done
                Log.log("history re-clean OK (\(model)): \"\(cleaned)\"")
                flash("re-cleaned")
            } catch {
                entry.status = .cleanupFailed
                Log.log("history re-clean FAILED: \(error.localizedDescription)")
                flash("re-clean failed")
            }
            HistoryStore.shared?.save()
            recleaning = false
        }
    }

    private func flash(_ note: String) {
        withAnimation { actionNote = note }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { actionNote = nil }
        }
    }
}
