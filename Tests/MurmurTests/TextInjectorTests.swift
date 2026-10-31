import AppKit
import XCTest

/// Pasteboard half of TextInjector, run against a private named pasteboard so
/// the user's real clipboard is never touched. ⌘V/AX paths are not exercised.
final class TextInjectorTests: XCTestCase {
    private var pasteboard: NSPasteboard!
    private let custom = NSPasteboard.PasteboardType("com.costajohnt.murmur.test")

    override func setUp() {
        pasteboard = NSPasteboard(name: .init(UUID().uuidString))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        pasteboard = nil
    }

    func testMultiItemMultiTypeRoundTrip() {
        let first = NSPasteboardItem()
        first.setString("hello", forType: .string)
        first.setData(Data([1, 2, 3]), forType: custom)
        let second = NSPasteboardItem()
        second.setString("https://example.com", forType: .URL)
        pasteboard.clearContents()
        pasteboard.writeObjects([first, second])

        let saved = TextInjector.snapshot(pasteboard)
        TextInjector.writeDictation("dictated", to: pasteboard)
        TextInjector.restore(pasteboard, items: saved)

        let items = pasteboard.pasteboardItems ?? []
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items[0].string(forType: .string), "hello")
        XCTAssertEqual(items[0].data(forType: custom), Data([1, 2, 3]))
        XCTAssertEqual(items[1].string(forType: .URL), "https://example.com")
        // Restore is marked transient (not re-recorded) but not concealed.
        XCTAssertTrue(items[0].types.contains(TextInjector.transientType))
        XCTAssertFalse(items[0].types.contains(TextInjector.concealedType))
    }

    func testEmptyClipboardRestoresToEmpty() {
        pasteboard.clearContents()
        let saved = TextInjector.snapshot(pasteboard)
        XCTAssertTrue(saved.isEmpty)

        TextInjector.writeDictation("dictated", to: pasteboard)
        TextInjector.restore(pasteboard, items: saved)

        XCTAssertTrue((pasteboard.pasteboardItems ?? []).isEmpty)
        XCTAssertNil(pasteboard.string(forType: .string))
    }

    func testDictationWriteCarriesPrivacyMarkers() {
        TextInjector.writeDictation("secret", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "secret")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(TextInjector.transientType))
        XCTAssertTrue(types.contains(TextInjector.concealedType))
    }

    func testHistoryCopyCarriesPrivacyMarkers() {
        TextInjector.copyTranscript("from history", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "from history")
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(TextInjector.transientType))
        XCTAssertTrue(types.contains(TextInjector.concealedType))
    }

    /// Audit M1: the paste path promises the string, so a reader's request
    /// for it is the consumption signal that gates the clipboard restore.
    func testPromisedDictationResolvesOnReadAndSignals() {
        var consumed = 0
        TextInjector.writeDictation("dictated", to: pasteboard) { consumed += 1 }
        let types = pasteboard.types ?? []
        XCTAssertTrue(types.contains(.string))
        XCTAssertTrue(types.contains(TextInjector.transientType))
        XCTAssertTrue(types.contains(TextInjector.concealedType))
        XCTAssertEqual(consumed, 0, "not read yet")

        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")

        let hop = expectation(description: "signal hops to main")
        DispatchQueue.main.async { hop.fulfill() }
        wait(for: [hop], timeout: 1)
        XCTAssertEqual(consumed, 1)
    }

    /// A clipboard manager reads the pasteboard the moment it changes, before
    /// ⌘V is posted; that read must not count, or the restore fires early and
    /// the target pastes the user's old clipboard.
    func testReadBeforePasteIsPostedDoesNotCount() {
        var window = TextInjector.PasteWindow()
        let t0 = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(window.read(at: t0))
        XCTAssertNil(window.lastReadAt)

        window.posted(at: t0.addingTimeInterval(0.01))
        XCTAssertFalse(window.read(at: t0), "a read stamped before the post still does not count")
        XCTAssertTrue(window.read(at: t0.addingTimeInterval(0.5)))
        XCTAssertEqual(window.lastReadAt, t0.addingTimeInterval(0.5))
        // A later read moves the restore out again (debounce).
        XCTAssertTrue(window.read(at: t0.addingTimeInterval(3)))
        XCTAssertEqual(window.lastReadAt, t0.addingTimeInterval(3))
    }

    /// The promised write path keeps the changeCount guard: a user copy after
    /// the target read the paste must not be clobbered by the restore.
    func testPromisedWriteStillSkipsRestoreAfterUserCopy() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let saved = TextInjector.snapshot(pasteboard)
        TextInjector.writeDictation("dictated", to: pasteboard) {}
        let ours = pasteboard.changeCount
        XCTAssertEqual(pasteboard.string(forType: .string), "dictated")

        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)

        XCTAssertFalse(TextInjector.restoreIfUnchanged(pasteboard, items: saved, ourChangeCount: ours))
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    func testRestoreSkippedWhenUserCopiedMidPaste() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let saved = TextInjector.snapshot(pasteboard)
        TextInjector.writeDictation("dictated", to: pasteboard)
        let ours = pasteboard.changeCount

        // User copies during the paste window.
        pasteboard.clearContents()
        pasteboard.setString("user copy", forType: .string)

        XCTAssertFalse(TextInjector.restoreIfUnchanged(pasteboard, items: saved, ourChangeCount: ours))
        XCTAssertEqual(pasteboard.string(forType: .string), "user copy")
    }

    func testRestoreHappensWhenUntouched() {
        pasteboard.clearContents()
        pasteboard.setString("original", forType: .string)
        let saved = TextInjector.snapshot(pasteboard)
        TextInjector.writeDictation("dictated", to: pasteboard)
        let ours = pasteboard.changeCount

        XCTAssertTrue(TextInjector.restoreIfUnchanged(pasteboard, items: saved, ourChangeCount: ours))
        XCTAssertEqual(pasteboard.string(forType: .string), "original")
    }
}
