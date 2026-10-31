import XCTest

/// `HistoryStore.sweepAudio` against a temp dir (audit M2): orphans past the
/// age guard go, fresh orphans and referenced files stay, kept files end up
/// owner-only.
final class HistoryStoreSweepTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func wav(_ name: String, age: TimeInterval, mode: Int = 0o644) throws -> URL {
        let url = tmp.appendingPathComponent("\(name).wav")
        try Data("RIFF".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age), .posixPermissions: mode],
            ofItemAtPath: url.path)
        return url
    }

    func testSweepDeletesOldOrphansOnly() throws {
        let fm = FileManager.default
        let kept = try wav("kept", age: 7200)
        let oldOrphan = try wav("old-orphan", age: 7200)
        let freshOrphan = try wav("fresh-orphan", age: 60)
        let notWav = tmp.appendingPathComponent("notes.txt")
        try Data("x".utf8).write(to: notWav)

        let deleted = HistoryStore.sweepAudio(in: tmp, keeping: ["kept.wav"], minAge: 3600)

        XCTAssertEqual(deleted, 1)
        XCTAssertFalse(fm.fileExists(atPath: oldOrphan.path))
        XCTAssertTrue(fm.fileExists(atPath: freshOrphan.path))
        XCTAssertTrue(fm.fileExists(atPath: kept.path))
        XCTAssertTrue(fm.fileExists(atPath: notWav.path))
        let mode = try XCTUnwrap(fm.attributesOfItem(atPath: kept.path)[.posixPermissions] as? Int)
        XCTAssertEqual(mode, 0o600)
    }

    func testSweepOfMissingDirIsANoOp() {
        XCTAssertEqual(HistoryStore.sweepAudio(in: tmp.appendingPathComponent("missing"), keeping: []), 0)
    }
}
