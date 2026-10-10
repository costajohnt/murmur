import XCTest

final class UpdateCheckerTests: XCTestCase {
    func testNumericComponentsNotStrings() {
        XCTAssertTrue(UpdateChecker.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertFalse(UpdateChecker.isNewer("1.9.9", than: "1.10.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.3.2", than: "1.3.1"))
        XCTAssertTrue(UpdateChecker.isNewer("2", than: "1.9"))
    }

    func testEqualIsNotNewer() {
        XCTAssertFalse(UpdateChecker.isNewer("1.3.1", than: "1.3.1"))
        XCTAssertFalse(UpdateChecker.isNewer("v1.3", than: "1.3.0"))
    }

    func testMalformedIsNeverAnUpdate() {
        XCTAssertFalse(UpdateChecker.isNewer("", than: "1.3.1"))
        XCTAssertFalse(UpdateChecker.isNewer("latest", than: "1.3.1"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0-beta", than: "1.3.1"))
        XCTAssertFalse(UpdateChecker.isNewer("2..0", than: "1.3.1"))
        XCTAssertFalse(UpdateChecker.isNewer("2.0.0", than: ""))
    }
}
