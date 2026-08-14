import XCTest

/// The bridge only earns its place if it actually converts a raised
/// NSException into a Swift-visible failure instead of aborting — if it
/// didn't, this test would crash the whole test runner rather than fail.
final class ObjCExceptionBridgeTests: XCTestCase {
    func testReturnsTrueWhenBlockDoesNotRaise() {
        var ran = false
        var error: NSError?
        XCTAssertTrue(MurmurCatchNSException({ ran = true }, &error))
        XCTAssertTrue(ran)
        XCTAssertNil(error)
    }

    func testCatchesRaisedExceptionAndReportsReason() {
        var error: NSError?
        let ok = MurmurCatchNSException({
            NSException(name: .invalidArgumentException, reason: "boom", userInfo: nil).raise()
        }, &error)
        XCTAssertFalse(ok)
        XCTAssertTrue(error?.localizedDescription.contains("boom") ?? false)
    }
}
