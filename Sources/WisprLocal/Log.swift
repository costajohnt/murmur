import Foundation

/// Spike logging: prints to stdout AND appends to /tmp/wisprlocal.log so
/// evidence can be captured from a detached `.app` launch (stdout is lost
/// when launched via `open`).
enum Log {
    static let path = "/tmp/wisprlocal.log"

    static func log(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)"
        print(line)
        appendToFile(line + "\n")
    }

    private static func appendToFile(_ text: String) {
        let url = URL(fileURLWithPath: path)
        guard let data = text.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
