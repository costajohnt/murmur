import Foundation
import SwiftData

/// Verification harness for context-aware cleanup (docs/context-cleanup.md).
/// Compiles the REAL production sources (OllamaClient, CleanupContext,
/// HistoryStore, Log) and exercises them against live Ollama:
///   1. history fetch (in-memory SwiftData container, real fetch code)
///   2. correction test: "prox mocks"/"tail scale" → Proxmox/Tailscale
///   3. no-answer regression (question formatted, not answered)
///   4. generic messy transcript regression
///   5. cold-start: empty history → nil context, clean() still works
///
/// Run: scripts/test-context-cleanup.sh
@main
struct ContextCleanupTest {
    static var failures = 0

    static func check(_ name: String, _ condition: Bool, detail: String = "") {
        if condition {
            print("  PASS: \(name)")
        } else {
            failures += 1
            print("  FAIL: \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    @MainActor
    static func main() async {
        // ---- 1. HistoryStore fetch against an in-memory container ----
        print("\n=== 1. HistoryStore.recentCleanedTexts (in-memory SwiftData) ===")
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: Dictation.self, configurations: config)
        let ctx = ModelContext(container)

        let seeds: [(String, DictationStatus, Date)] = [
            ("Let's deploy to Proxmox over Tailscale.", .done, Date(timeIntervalSinceNow: -300)),
            ("The SwiftData store keeps the ASR history on macOS.", .done, Date(timeIntervalSinceNow: -200)),
            ("raw only, cleanup failed", .cleanupFailed, Date(timeIntervalSinceNow: -100)),
            ("Ping the Proxmox box before the backup runs.", .done, Date(timeIntervalSinceNow: -50)),
        ]
        for (text, status, date) in seeds {
            let entry = Dictation(
                createdAt: date,
                rawTranscript: text.lowercased(),
                cleanedText: status == .done ? text : "",
                modelName: "test",
                status: status
            )
            ctx.insert(entry)
        }
        try! ctx.save()

        let fetched = HistoryStore.recentCleanedTexts(in: ctx, limit: 50)
        print("  fetched (newest first): \(fetched)")
        check("only done entries, newest first", fetched == [
            "Ping the Proxmox box before the backup runs.",
            "The SwiftData store keeps the ASR history on macOS.",
            "Let's deploy to Proxmox over Tailscale.",
        ])

        // ---- 2. Context build ----
        print("\n=== 2. CleanupContext.build ===")
        let context = CleanupContext.build(from: fetched)
        print("  context (\(context?.count ?? 0) chars):\n---\n\(context ?? "<nil>")\n---")
        check("context built", context != nil)
        check("within budget", (context?.count ?? 0) <= CleanupContext.totalCharBudget)
        check("glossary has Proxmox", context?.contains("Proxmox") == true)
        check("glossary has Tailscale", context?.contains("Tailscale") == true)
        check("cold-start returns nil", CleanupContext.build(from: []) == nil)

        // ---- Live Ollama tests ----
        let ollama = OllamaClient()
        let model = await ollama.resolveModel()
        print("\n(model: \(model))")

        func run(_ name: String, raw: String, context: String?) async -> String? {
            do {
                let start = Date()
                let out = try await ollama.clean(raw, model: model, context: context)
                print("  raw:     \"\(raw)\"")
                print("  cleaned: \"\(out)\"  (%.2fs)".replacingOccurrences(
                    of: "%.2fs", with: String(format: "%.2fs", Date().timeIntervalSince(start))))
                return out
            } catch {
                failures += 1
                print("  FAIL: \(name) — clean() threw: \(error.localizedDescription)")
                return nil
            }
        }

        print("\n=== 3. Correction test (with context) ===")
        if let out = await run("correction", raw: "lets deploy to prox mocks over tail scale", context: context) {
            check("recovers Proxmox", out.contains("Proxmox"), detail: out)
            check("recovers Tailscale", out.contains("Tailscale"), detail: out)
        }

        print("\n=== 4. No-answer regression (with context) ===")
        if let out = await run("no-answer", raw: "um so whats the capital of france", context: context) {
            let lower = out.lowercased()
            check("still a question, not an answer",
                  lower.contains("capital of france") && !lower.contains("paris"),
                  detail: out)
        }

        print("\n=== 5. Generic messy transcript (with context) ===")
        if let out = await run("generic", raw: "so um i think we should uh push the meeting to like three pm tomorrow", context: context) {
            let lower = out.lowercased()
            check("fillers removed", !lower.contains("um") && !lower.contains(" uh "), detail: out)
            check("meaning kept", lower.contains("meeting") && lower.contains("3") || lower.contains("three"), detail: out)
            check("no invented Proxmox/Tailscale", !out.contains("Proxmox") && !out.contains("Tailscale"), detail: out)
        }

        print("\n=== 6. Cold-start (no context) ===")
        if let out = await run("cold-start", raw: "can you uh send me the report by friday", context: nil) {
            check("cleans without context", out.lowercased().contains("report"), detail: out)
        }

        print("\n==== \(failures == 0 ? "ALL PASS" : "\(failures) FAILURE(S)") ====")
        exit(failures == 0 ? 0 : 1)
    }
}
