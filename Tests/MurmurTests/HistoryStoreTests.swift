import XCTest
import SwiftData

/// Covers HistoryStore against an in-memory ModelContainer (no on-disk
/// store, no app hosting): the context fetch, retention (cap + audio age),
/// delete, the legacy audio-path relink, and the private dir permissions.
final class HistoryStoreTests: XCTestCase {
    @MainActor
    private func makeInMemoryContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Dictation.self, configurations: config)
        return ModelContext(container)
    }

    @MainActor
    func testRecentRawTranscriptsReturnsOnlyDoneRawNewestFirst() throws {
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
                rawTranscript: text,
                cleanedText: status == .done ? text.uppercased() : "",
                modelName: "test",
                status: status
            )
            ctx.insert(entry)
        }
        try ctx.save()

        let fetched = HistoryStore.recentRawTranscripts(in: ctx, limit: 50)
        XCTAssertEqual(fetched, [
            "Ping the Proxmox box before the backup runs.",
            "The SwiftData store keeps the ASR history on macOS.",
            "Let's deploy to Proxmox over Tailscale.",
        ])
    }

    @MainActor
    func testRecentRawTranscriptsRespectsLimit() throws {
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

        let fetched = HistoryStore.recentRawTranscripts(in: ctx, limit: 2)
        XCTAssertEqual(fetched, ["raw 0", "raw 1"])
    }

    /// Pins the empty-raw exclusion that the `!= ""` predicate provides. On
    /// Xcode 26.4, `.isEmpty` inside a SwiftData #Predicate did not filter
    /// (seen on cleanedText); on Xcode 26.6, `!$0.rawTranscript.isEmpty` was
    /// checked and does filter, so this guards the behaviour whichever form
    /// the predicate uses.
    @MainActor
    func testRecentRawTranscriptsSkipsEmptyRaw() throws {
        let ctx = try makeInMemoryContext()
        ctx.insert(Dictation(createdAt: Date(), rawTranscript: "", cleanedText: "Hallucinated.", modelName: "test", status: .done))
        try ctx.save()
        XCTAssertTrue(HistoryStore.recentRawTranscripts(in: ctx, limit: 50).isEmpty)
    }

    @MainActor
    func testRecentRawTranscriptsOnEmptyStoreReturnsEmpty() throws {
        let ctx = try makeInMemoryContext()
        XCTAssertTrue(HistoryStore.recentRawTranscripts(in: ctx, limit: 50).isEmpty)
    }

    // MARK: - Store instance: retention, delete, relink

    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    @MainActor
    private func makeStore(legacyDir: URL? = nil, supportDir: URL? = nil, seed: (ModelContext) -> Void = { _ in }) throws -> HistoryStore {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Dictation.self, configurations: config)
        seed(container.mainContext)
        try container.mainContext.save()
        return HistoryStore(
            container: container,
            legacyDir: legacyDir ?? tmp.appendingPathComponent("legacy"),
            supportDir: supportDir ?? tmp.appendingPathComponent("support")
        )
    }

    private func makeWAV(_ name: String) throws -> String {
        let url = tmp.appendingPathComponent("\(name).wav")
        try Data("RIFF".utf8).write(to: url)
        return url.path
    }

    /// `count` entries one second apart, newest first; only the oldest gets
    /// an audio file. Returns that file's path.
    @MainActor
    private func seed(_ store: HistoryStore, count: Int, now: Date) throws -> String {
        let oldestAudio = try makeWAV("oldest")
        for i in 0..<count {
            store.context.insert(Dictation(
                createdAt: now.addingTimeInterval(Double(-i)),
                audioPath: i == count - 1 ? oldestAudio : nil,
                rawTranscript: "raw \(i)", cleanedText: "c", modelName: "t", status: .done))
        }
        store.save()
        return oldestAudio
    }

    @MainActor
    func testPruneKeepsExactlyMaxEntries() throws {
        let store = try makeStore()
        let now = Date()
        let audio = try seed(store, count: HistoryStore.maxEntries, now: now)
        store.prune(now: now)
        XCTAssertEqual(store.count(), 200)
        XCTAssertTrue(FileManager.default.fileExists(atPath: audio))
    }

    @MainActor
    func testPruneDropsOldestBeyondCapWithItsAudio() throws {
        let store = try makeStore()
        let now = Date()
        let audio = try seed(store, count: HistoryStore.maxEntries + 1, now: now)
        store.prune(now: now)
        XCTAssertEqual(store.count(), 200)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio), "the pruned entry's WAV goes with it")
        let remaining = try store.context.fetch(FetchDescriptor<Dictation>()).map(\.rawTranscript)
        XCTAssertFalse(remaining.contains("raw 200"), "the oldest entry is the one dropped")
    }

    @MainActor
    func testAddPrunesAtTheCap() throws {
        let store = try makeStore()
        _ = try seed(store, count: HistoryStore.maxEntries, now: Date().addingTimeInterval(-60))
        store.add(rawTranscript: "new", cleanedText: "New.", modelName: "t", status: .done)
        XCTAssertEqual(store.count(), 200)
        XCTAssertEqual(store.newest()?.rawTranscript, "new")
    }

    @MainActor
    func testPruneDeletesOnlyAudioOlderThanRetention() throws {
        let store = try makeStore()
        let now = Date()
        let day = 86_400.0
        let oldAudio = try makeWAV("old")
        let freshAudio = try makeWAV("fresh")
        let old = Dictation(createdAt: now.addingTimeInterval(-31 * day), audioPath: oldAudio,
                            rawTranscript: "old", cleanedText: "c", modelName: "t", status: .done)
        let fresh = Dictation(createdAt: now.addingTimeInterval(-29 * day), audioPath: freshAudio,
                              rawTranscript: "fresh", cleanedText: "c", modelName: "t", status: .done)
        store.context.insert(old)
        store.context.insert(fresh)
        store.save()

        store.prune(now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldAudio))
        XCTAssertNil(old.audioPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: freshAudio))
        XCTAssertEqual(fresh.audioPath, freshAudio)
        XCTAssertEqual(store.count(), 2, "age-based pruning drops audio, never the entry")
    }

    @MainActor
    func testDeleteRemovesEntryAndAudio() throws {
        let store = try makeStore()
        let audio = try makeWAV("del")
        let entry = store.add(rawTranscript: "x", cleanedText: "X.", modelName: "t", status: .done, audioPath: audio)
        store.delete(entry)
        XCTAssertEqual(store.count(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: audio))
    }

    @MainActor
    func testInitRelinksLegacyAudioPaths() throws {
        let legacy = tmp.appendingPathComponent("wispr-local")
        let support = tmp.appendingPathComponent("Murmur")
        let store = try makeStore(legacyDir: legacy, supportDir: support) { ctx in
            ctx.insert(Dictation(audioPath: legacy.path + "/audio/a.wav", rawTranscript: "a", cleanedText: "", modelName: "t", status: .done))
            ctx.insert(Dictation(audioPath: "/elsewhere/b.wav", rawTranscript: "b", cleanedText: "", modelName: "t", status: .done))
        }
        let paths = Set(try store.context.fetch(FetchDescriptor<Dictation>()).compactMap(\.audioPath))
        XCTAssertEqual(paths, [support.path + "/audio/a.wav", "/elsewhere/b.wav"])
    }

    func testCreatePrivateDirectoryIsOwnerOnlyAndTightensExisting() throws {
        let fresh = tmp.appendingPathComponent("a/b")
        try HistoryStore.createPrivateDirectory(fresh)
        let existing = tmp.appendingPathComponent("loose")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
        try HistoryStore.createPrivateDirectory(existing)
        for dir in [fresh, existing] {
            let mode = try FileManager.default.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int
            XCTAssertEqual(mode, 0o700, dir.lastPathComponent)
        }
    }
}
