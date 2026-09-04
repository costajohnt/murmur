import XCTest

/// When recovery moved the old store aside and the retry still failed, the
/// user's files are already in the archive directory; the warning must say
/// where, or the move looks like data loss.
@MainActor
final class HistoryStoreUnavailableMessageTests: XCTestCase {
    func testNamesTheArchiveWhenTheStoreWasMovedAside() {
        let archive = URL(fileURLWithPath: "/tmp/Murmur/history-unopenable-2026-09-04T10-00-00Z", isDirectory: true)

        let message = HistoryStore.unavailableMessage(reason: "disk I/O error", archivedAt: archive)

        XCTAssertTrue(message.hasPrefix("History is unavailable, so dictations are not being saved (disk I/O error)."), message)
        XCTAssertTrue(message.hasSuffix("Your previous history was moved to \(archive.path)."), message)
    }

    func testOmitsTheArchiveWhenNothingWasMoved() {
        let message = HistoryStore.unavailableMessage(reason: "disk full", archivedAt: nil)

        XCTAssertEqual(message, "History is unavailable, so dictations are not being saved (disk full).")
    }
}
