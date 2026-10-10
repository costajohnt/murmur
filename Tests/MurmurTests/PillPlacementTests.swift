import XCTest

final class PillPlacementTests: XCTestCase {
    private let size = CGSize(width: 170, height: 44)
    private let left = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    // Visible frames inset by a dock on the left screen only.
    private var screens: [(frame: CGRect, visibleFrame: CGRect)] {
        [(left, CGRect(x: 0, y: 70, width: 1440, height: 805)), (right, right)]
    }

    func testMouseOnSecondScreenPlacesPillThere() {
        let origin = PillPlacement.origin(size: size, mouse: CGPoint(x: 2000, y: 500), screens: screens, main: screens[0].visibleFrame, bottomMargin: 18)
        XCTAssertEqual(origin, CGPoint(x: 1440 + 960 - 85, y: 18))
    }

    func testMouseOnFirstScreenUsesItsVisibleFrame() {
        let origin = PillPlacement.origin(size: size, mouse: CGPoint(x: 100, y: 100), screens: screens, main: right, bottomMargin: 18)
        XCTAssertEqual(origin, CGPoint(x: 720 - 85, y: 70 + 18))
    }

    func testTopEdgeOfScreenCountsAsOnIt() {
        let origin = PillPlacement.origin(size: size, mouse: CGPoint(x: 2000, y: 1080), screens: screens, main: screens[0].visibleFrame, bottomMargin: 18)
        XCTAssertEqual(origin?.x, 1440 + 960 - 85)
    }

    func testMouseOffAllScreensFallsBackToMain() {
        let origin = PillPlacement.origin(size: size, mouse: CGPoint(x: -500, y: -500), screens: screens, main: right, bottomMargin: 18)
        XCTAssertEqual(origin, CGPoint(x: 1440 + 960 - 85, y: 18))
    }

    func testNoScreensReturnsNil() {
        XCTAssertNil(PillPlacement.origin(size: size, mouse: .zero, screens: [], main: nil, bottomMargin: 18))
    }
}
