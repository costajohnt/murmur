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

/// SwiftData-backed history with a naive retention policy:
/// keep the newest `maxEntries`, delete audio files older than
/// `audioRetentionDays`. Store + audio live under
/// ~/Library/Application Support/wispr-local/.
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
            .appendingPathComponent("wispr-local", isDirectory: true)
    }

    static var audioDir: URL {
        supportDir.appendingPathComponent("audio", isDirectory: true)
    }

    private init() throws {
        try FileManager.default.createDirectory(at: Self.audioDir, withIntermediateDirectories: true)
        let storeURL = Self.supportDir.appendingPathComponent("history.store")
        let config = ModelConfiguration(url: storeURL)
        container = try ModelContainer(for: Dictation.self, configurations: config)
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
