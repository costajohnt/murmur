import AppKit
import SwiftData
import SwiftUI

/// History window, Wispr Flow transcript style: one flat, editorial column of
/// date-grouped transcripts. No sidebar, no stats — transcripts only.
struct HistoryView: View {
    @Query(sort: \Dictation.createdAt, order: .reverse) private var entries: [Dictation]
    @State private var searchText = ""
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                    .padding(.bottom, 20)

                if entries.isEmpty {
                    emptyState("No transcripts yet — click the pill and start talking.")
                } else if filtered.isEmpty {
                    emptyState("No matches.")
                } else {
                    ForEach(groups, id: \.header) { group in
                        Text(group.header)
                            .font(.system(size: 11, weight: .semibold))
                            .tracking(1.4)
                            .foregroundStyle(.secondary)
                            .padding(.top, 28)
                            .padding(.bottom, 6)

                        ForEach(group.items) { entry in
                            TranscriptRow(entry: entry)
                            HistoryTheme.divider
                        }
                    }
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .padding(.horizontal, 40)
            .padding(.vertical, 28)
            .frame(maxWidth: .infinity)
        }
        .background(HistoryTheme.background(colorScheme))
        .frame(minWidth: 640, minHeight: 480)
    }

    // MARK: - Header (title + search)

    private var headerRow: some View {
        HStack(alignment: .center) {
            Text("History")
                .font(.system(size: 20, weight: .semibold, design: .serif))
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                TextField("Search transcripts", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(HistoryTheme.searchFill(colorScheme))
            )
            .frame(width: 240)
        }
    }

    private func emptyState(_ message: String) -> some View {
        Text(message)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 120)
    }

    // MARK: - Filtering + grouping

    private var filtered: [Dictation] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return entries }
        return entries.filter {
            $0.cleanedText.localizedCaseInsensitiveContains(query)
                || $0.rawTranscript.localizedCaseInsensitiveContains(query)
        }
    }

    private var groups: [(header: String, items: [Dictation])] {
        let calendar = Calendar.current
        var order: [Date] = []
        var byDay: [Date: [Dictation]] = [:]
        for entry in filtered {
            let day = calendar.startOfDay(for: entry.createdAt)
            if byDay[day] == nil { order.append(day) }
            byDay[day, default: []].append(entry)
        }
        return order.map { day in
            (header: Self.dayHeader(for: day, calendar: calendar), items: byDay[day] ?? [])
        }
    }

    private static func dayHeader(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "TODAY" }
        if calendar.isDateInYesterday(day) { return "YESTERDAY" }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMMM d, yyyy"
        return formatter.string(from: day).uppercased()
    }
}

// MARK: - Row

private struct TranscriptRow: View {
    let entry: Dictation
    @State private var hovering = false
    @State private var recleaning = false
    @State private var copied = false

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Left: timestamp (+ subtle failure dot).
            HStack(spacing: 5) {
                if entry.status != .done {
                    Circle()
                        .fill(entry.status == .cleanupFailed ? Color.orange.opacity(0.7) : Color.red.opacity(0.7))
                        .frame(width: 6, height: 6)
                        .help(entry.status.label)
                }
                Text(Self.timeFormatter.string(from: entry.createdAt).lowercased())
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(width: 72, alignment: .leading)
            .padding(.top, 2)

            // Body: cleaned transcript with light bullet rendering.
            TranscriptBody(text: primaryText)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Trailing hover actions.
            HStack(spacing: 8) {
                if copied {
                    Text("copied")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .transition(.opacity)
                }
                if recleaning {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(action: copy) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Copy")

                    Menu {
                        Button("Insert at cursor") { insert() }
                        Button("Re-clean") { reclean() }
                            .disabled(entry.rawTranscript.isEmpty)
                        Divider()
                        Button("Delete", role: .destructive) { delete() }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 12))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .foregroundStyle(.secondary)
                }
            }
            .opacity(hovering || recleaning || copied ? 1 : 0)
            .animation(.easeInOut(duration: 0.15), value: hovering)
            .padding(.top, 2)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var primaryText: String {
        if !entry.cleanedText.isEmpty { return entry.cleanedText }
        if !entry.rawTranscript.isEmpty { return entry.rawTranscript }
        return "(no transcript)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    // MARK: - Actions

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(primaryText, forType: .string)
        withAnimation { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation { copied = false }
        }
    }

    private func insert() {
        let target = TargetAppTracker.shared.lastActiveApp
        Log.log("history insert: target = \(target?.bundleIdentifier ?? "none")")
        TextInjector.inject(primaryText, into: target)
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
            } catch {
                entry.status = .cleanupFailed
                Log.log("history re-clean FAILED: \(error.localizedDescription)")
            }
            HistoryStore.shared?.save()
            recleaning = false
        }
    }

    private func delete() {
        Log.log("history delete: \(entry.id)")
        withAnimation(.easeOut(duration: 0.2)) {
            HistoryStore.shared?.delete(entry)
        }
    }
}

// MARK: - Transcript body (light markdown: paragraphs + bullets)

private struct TranscriptBody: View {
    let text: String

    private enum Block: Hashable {
        case paragraph(String)
        case bullets([String])
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(text)
                case .bullets(let items):
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                Text(item)
                            }
                        }
                    }
                }
            }
        }
        .font(.system(size: 15))
        .lineSpacing(3)
        .textSelection(.enabled)
    }

    /// Line-by-line: consecutive `-` / `*` / `•` lines fold into one bullet
    /// list; other non-empty lines are paragraphs.
    private var blocks: [Block] {
        var result: [Block] = []
        var bullets: [String] = []
        func flushBullets() {
            if !bullets.isEmpty {
                result.append(.bullets(bullets))
                bullets = []
            }
        }
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                flushBullets()
                continue
            }
            if let marker = ["- ", "* ", "• "].first(where: { line.hasPrefix($0) }) {
                bullets.append(String(line.dropFirst(marker.count)))
            } else if line == "-" || line == "*" || line == "•" {
                bullets.append("")
            } else {
                flushBullets()
                result.append(.paragraph(line))
            }
        }
        flushBullets()
        return result
    }
}

// MARK: - Theme

private enum HistoryTheme {
    static func background(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)   // deep neutral
            : Color(red: 0.968, green: 0.965, blue: 0.953) // warm off-white #F7F6F3
    }

    static func searchFill(_ scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.07)
            : Color.black.opacity(0.05)
    }

    static var divider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(height: 0.5)
    }
}
