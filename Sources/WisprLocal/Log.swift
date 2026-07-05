import Foundation
import os

/// App logging with a hard privacy boundary (docs/release-prep.md C2):
///
/// - **DEBUG builds:** print to stdout AND append to a log file under
///   `~/Library/Application Support/Murmur/debug.log` (NOT /tmp — /tmp is
///   world-readable). Dev evidence flows (test hooks, harnesses) read this.
/// - **RELEASE builds:** no file is ever written. Messages go to os_log with
///   `.private` interpolation, so they are redacted in Console for other
///   users/processes. Transcript-CONTENT log lines are additionally
///   `#if DEBUG`-gated at their call sites (DictationCoordinator,
///   HistoryView), so release builds never emit the user's words anywhere.
enum Log {
    #if DEBUG
    static var path: String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
            .appendingPathComponent("debug.log")
            .path
    }
    #else
    private static let logger = Logger(subsystem: "com.costajohnt.murmur", category: "app")
    #endif

    static func log(_ message: String) {
        #if DEBUG
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)"
        print(line)
        appendToFile(line + "\n")
        #else
        logger.log("\(message, privacy: .private)")
        #endif
    }

    #if DEBUG
    private static func appendToFile(_ text: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            // First write: the support dir may not exist yet (Log can run
            // before HistoryStore creates it).
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }
    #endif
}
