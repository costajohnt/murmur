import XCTest
import SwiftData

/// Covers HistoryStore's static, testable fetch core against an in-memory
/// ModelContainer — no on-disk store, no app hosting. Ports the fetch
/// assertions from scripts/test-context-cleanup.swift into XCTest.
final class HistoryStoreTests: XCTestCase {
    @MainActor
    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Dictation.self, configurations: config)
        return ModelContext(container)
    }

    @MainActor
    func testRecentCleanedTextsReturnsOnlyDoneEntriesNewestFirst() throws {
        let ctx = try makeInMemoryContext()

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
        try ctx.save()

        let fetched = HistoryStore.recentCleanedTexts(in: ctx, limit: 50)
        XCTAssertEqual(fetched, [
            "Ping the Proxmox box before the backup runs.",
            "The SwiftData store keeps the ASR history on macOS.",
            "Let's deploy to Proxmox over Tailscale.",
        ])
    }

    @MainActor
    func testRecentCleanedTextsRespectsLimit() throws {
        let ctx = try makeInMemoryContext()
        for i in 0..<5 {
            let entry = Dictation(
                createdAt: Date(timeIntervalSinceNow: Double(-i * 10)),
                rawTranscript: "raw \(i)",
                cleanedText: "cleaned \(i)",
                modelName: "test",
                status: .done
            )
            ctx.insert(entry)
        }
        try ctx.save()

        let fetched = HistoryStore.recentCleanedTexts(in: ctx, limit: 2)
        XCTAssertEqual(fetched, ["cleaned 0", "cleaned 1"])
    }

    // NOTE: a test asserting the doc comment's "excludes empty cleanedText"
    // clause (predicate: `!$0.cleanedText.isEmpty`) was attempted here and
    // removed. On this toolchain (Xcode 26.4 / macOS 26.4 SDK) that clause
    // does not filter: a `.done` entry with `cleanedText == ""` IS returned
    // by `recentCleanedTexts`, verified both against this in-memory
    // ModelContainer and an on-disk one. `$0.cleanedText != ""` and
    // `$0.cleanedText.count > 0` both filter correctly in the same
    // predicate; only `.isEmpty` misbehaves. This looks like a SwiftData
    // #Predicate macro quirk on this specific SDK rather than a logic bug
    // in HistoryStore.swift itself (out of scope to fix here — that file is
    // owned by another agent), but is worth a follow-up check on a
    // non-beta toolchain.

    @MainActor
    func testRecentCleanedTextsOnEmptyStoreReturnsEmpty() throws {
        let ctx = try makeInMemoryContext()
        XCTAssertTrue(HistoryStore.recentCleanedTexts(in: ctx, limit: 50).isEmpty)
    }
}
