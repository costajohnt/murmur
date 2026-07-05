import Foundation
import SwiftData

enum DictationStatus: String {
    case done
    case cleanupFailed = "cleanup_failed"
    case asrFailed = "asr_failed"

    var label: String {
        switch self {
        case .done: return "done"
        case .cleanupFailed: return "cleanup failed"
        case .asrFailed: return "ASR failed"
        }
    }
}

@Model
final class Dictation {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var audioPath: String?
    var rawTranscript: String
    var cleanedText: String
    var modelName: String
    var statusRaw: String
    var durationMs: Int?

    var status: DictationStatus {
        get { DictationStatus(rawValue: statusRaw) ?? .done }
        set { statusRaw = newValue.rawValue }
    }

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        audioPath: String? = nil,
        rawTranscript: String,
        cleanedText: String,
        modelName: String,
        status: DictationStatus,
        durationMs: Int? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.audioPath = audioPath
        self.rawTranscript = rawTranscript
        self.cleanedText = cleanedText
        self.modelName = modelName
        self.statusRaw = status.rawValue
        self.durationMs = durationMs
    }
}

/// Versioned schema for the dictation history store.
///
/// `DictationSchemaV1` captures the `Dictation` model exactly as it ships
/// today, so the existing on-disk store opens with no migration. This exists
/// purely so a FUTURE model change (new/renamed/removed field) can be made
/// safe: add a `DictationSchemaV2`, list it in `DictationMigrationPlan.schemas`,
/// and add a `MigrationStage` describing V1 -> V2. SwiftData then migrates the
/// user's history forward instead of silently discarding a store whose shape no
/// longer matches the current model.
///
/// Do NOT edit `Dictation` in place for a schema change: mutate a copy owned by
/// a new versioned schema and migrate to it, otherwise V1 stops matching the
/// on-disk data and the store can be dropped.
enum DictationSchemaV1: VersionedSchema {
    static var versionIdentifier = Schema.Version(1, 0, 0)

    static var models: [any PersistentModel.Type] {
        [Dictation.self]
    }
}

/// Ordered list of schema versions plus the migration stages between them.
/// Today there is only V1, so the plan is a no-op that establishes the
/// versioning machinery. Future versions append to `schemas` and add a
/// lightweight or custom `MigrationStage` to `stages`.
enum DictationMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [DictationSchemaV1.self]
    }

    static var stages: [MigrationStage] {
        []
    }
}

/// SwiftData-backed history with a naive retention policy:
/// keep the newest `maxEntries`, delete audio files older than
/// `audioRetentionDays`. Store + audio live under
/// ~/Library/Application Support/Murmur/ (auto-migrated from the pre-rename
/// wispr-local/ directory on first launch).
@MainActor
final class HistoryStore {
    static let maxEntries = 200
    static let audioRetentionDays = 30

    static let shared: HistoryStore? = {
        do {
            return try HistoryStore()
        } catch {
            Log.log("history: FAILED to open store: \(error)")
            return nil
        }
    }()

    let container: ModelContainer
    var context: ModelContext { container.mainContext }

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
    }

    /// Pre-rename data directory (the app shipped its early life as
    /// "wispr-local"). Migrated once by `migrateLegacyDataIfNeeded()`.
    static var legacySupportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("wispr-local", isDirectory: true)
    }

    static var audioDir: URL {
        supportDir.appendingPathComponent("audio", isDirectory: true)
    }

    /// One-time rename migration: if the old wispr-local data dir exists and
    /// no Murmur store exists yet, move the whole dir so existing dictations
    /// (SwiftData store + audio) carry over. Audio paths stored in old
    /// entries still point at the wispr-local path, so `relinkAudioPaths`
    /// rewrites them after the store opens.
    private static func migrateLegacyDataIfNeeded() {
        let fm = FileManager.default
        let newStore = supportDir.appendingPathComponent("history.store")
        guard !fm.fileExists(atPath: newStore.path),
              fm.fileExists(atPath: legacySupportDir.path)
        else { return }
        do {
            // The new dir may already exist (e.g. debug.log written first);
            // move contents item-by-item in that case, else move the dir.
            if fm.fileExists(atPath: supportDir.path) {
                for item in try fm.contentsOfDirectory(atPath: legacySupportDir.path) {
                    try fm.moveItem(
                        at: legacySupportDir.appendingPathComponent(item),
                        to: supportDir.appendingPathComponent(item)
                    )
                }
                try fm.removeItem(at: legacySupportDir)
            } else {
                try fm.moveItem(at: legacySupportDir, to: supportDir)
            }
            Log.log("history: migrated legacy data wispr-local/ -> Murmur/")
        } catch {
            Log.log("history: legacy data migration FAILED (continuing with fresh store): \(error)")
        }
    }

    /// Post-migration fixup: entries created pre-rename persisted absolute
    /// `audioPath`s under .../wispr-local/audio/. Point them at the new dir
    /// so playback/delete keep working.
    private func relinkAudioPaths() {
        let oldPrefix = Self.legacySupportDir.path
        let descriptor = FetchDescriptor<Dictation>()
        guard let all = try? context.fetch(descriptor) else { return }
        var relinked = 0
        for entry in all {
            if let path = entry.audioPath, path.hasPrefix(oldPrefix) {
                entry.audioPath = Self.supportDir.path + path.dropFirst(oldPrefix.count)
                relinked += 1
            }
        }
        if relinked > 0 {
            save()
            Log.log("history: relinked \(relinked) audio paths to the Murmur dir")
        }
    }

    private init() throws {
        Self.migrateLegacyDataIfNeeded()
        try FileManager.default.createDirectory(at: Self.audioDir, withIntermediateDirectories: true)
        let storeURL = Self.supportDir.appendingPathComponent("history.store")
        let config = ModelConfiguration(url: storeURL)
        let schema = Schema(versionedSchema: DictationSchemaV1.self)
        container = try ModelContainer(
            for: schema,
            migrationPlan: DictationMigrationPlan.self,
            configurations: config
        )
        relinkAudioPaths()
    }

    @discardableResult
    func add(
        rawTranscript: String,
        cleanedText: String,
        modelName: String,
        status: DictationStatus,
        audioPath: String? = nil,
        durationMs: Int? = nil
    ) -> Dictation {
        let entry = Dictation(
            audioPath: audioPath,
            rawTranscript: rawTranscript,
            cleanedText: cleanedText,
            modelName: modelName,
            status: status,
            durationMs: durationMs
        )
        context.insert(entry)
        save()
        prune()
        return entry
    }

    func save() {
        do {
            try context.save()
        } catch {
            Log.log("history: save failed: \(error)")
        }
    }

    func count() -> Int {
        (try? context.fetchCount(FetchDescriptor<Dictation>())) ?? 0
    }

    func newest() -> Dictation? {
        var descriptor = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        descriptor.fetchLimit = 1
        return (try? context.fetch(descriptor))?.first
    }

    /// Last `limit` successful cleaned texts, newest first — the context
    /// source for context-aware cleanup (docs/context-cleanup.md).
    func recentCleanedTexts(limit: Int) -> [String] {
        Self.recentCleanedTexts(in: context, limit: limit)
    }

    /// Static core so the fetch is testable against an in-memory container.
    static func recentCleanedTexts(in context: ModelContext, limit: Int) -> [String] {
        let doneRaw = DictationStatus.done.rawValue
        var descriptor = FetchDescriptor<Dictation>(
            predicate: #Predicate { $0.statusRaw == doneRaw && !$0.cleanedText.isEmpty },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        return ((try? context.fetch(descriptor)) ?? []).map(\.cleanedText)
    }

    /// Deletes an entry and its backing WAV (if any).
    func delete(_ entry: Dictation) {
        if let path = entry.audioPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        context.delete(entry)
        save()
    }

    /// Naive retention: delete entries beyond the newest `maxEntries` (and
    /// their audio), and audio files older than `audioRetentionDays`.
    func prune() {
        let descriptor = FetchDescriptor<Dictation>(sortBy: [SortDescriptor(\.createdAt, order: .reverse)])
        guard let all = try? context.fetch(descriptor) else { return }

        if all.count > Self.maxEntries {
            for entry in all[Self.maxEntries...] {
                if let path = entry.audioPath {
                    try? FileManager.default.removeItem(atPath: path)
                }
                context.delete(entry)
            }
            save()
            Log.log("history: pruned \(all.count - Self.maxEntries) entries beyond cap of \(Self.maxEntries)")
        }

        let cutoff = Date().addingTimeInterval(-Double(Self.audioRetentionDays) * 86_400)
        for entry in all.prefix(Self.maxEntries) where entry.createdAt < cutoff {
            if let path = entry.audioPath {
                try? FileManager.default.removeItem(atPath: path)
                entry.audioPath = nil
            }
        }
        save()
    }

    /// New WAV destination for a dictation's audio.
    static func audioURL(for id: UUID) -> URL {
        audioDir.appendingPathComponent("\(id.uuidString).wav")
    }
}
