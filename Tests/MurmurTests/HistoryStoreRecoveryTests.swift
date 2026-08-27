import XCTest

/// Recovery only helps if it actually moves the unopenable store out of the
/// way (so a fresh one can be created) and refuses when there is nothing to
/// move (so a disk-full failure isn't retried forever against the same state).
/// Every case runs against a temp directory, never the real support dir.
@MainActor
final class HistoryStoreRecoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("murmur-history-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String) throws {
        try Data("x".utf8).write(to: dir.appendingPathComponent(name))
    }

    func testMovesStoreAndItsSqliteSiblingsAside() throws {
        for name in ["history.store", "history.store-wal", "history.store-shm"] {
            try write(name)
        }

        let archive = try HistoryStore.archiveUnopenableStore(in: dir)

        let fm = FileManager.default
        for name in ["history.store", "history.store-wal", "history.store-shm"] {
            XCTAssertFalse(fm.fileExists(atPath: dir.appendingPathComponent(name).path),
                           "\(name) should have been moved out of the store dir")
            XCTAssertTrue(fm.fileExists(atPath: archive.appendingPathComponent(name).path),
                          "\(name) should have been preserved in the archive")
        }
    }

    func testArchivesTheStoreEvenWithNoWalOrShm() throws {
        try write("history.store")

        let archive = try HistoryStore.archiveUnopenableStore(in: dir)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: archive.appendingPathComponent("history.store").path))
    }

    func testThrowsAndLeavesNoEmptyArchiveWhenThereIsNoStore() throws {
        XCTAssertThrowsError(try HistoryStore.archiveUnopenableStore(in: dir)) { error in
            XCTAssertEqual(error as? HistoryStore.StoreRecoveryError, .nothingToArchive)
        }
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(leftovers, [], "a failed archive attempt should not leave an empty dir behind")
    }
}
