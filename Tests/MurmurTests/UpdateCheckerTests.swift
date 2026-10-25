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

final class UpdateCheckerURLTests: XCTestCase {
    func testOnlyGitHubHttpsReleasePagesAreTrusted() {
        XCTAssertTrue(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com/costajohnt/murmur/releases/tag/v1.4.0")!))
        XCTAssertFalse(UpdateChecker.isTrustedReleaseURL(URL(string: "http://github.com/costajohnt/murmur/releases/tag/v1.4.0")!))
        XCTAssertFalse(UpdateChecker.isTrustedReleaseURL(URL(string: "file:///Applications/Calculator.app")!))
        XCTAssertFalse(UpdateChecker.isTrustedReleaseURL(URL(string: "x-apple.systempreferences:com.apple.preference.security")!))
        XCTAssertFalse(UpdateChecker.isTrustedReleaseURL(URL(string: "https://github.com.example.net/x")!))
        XCTAssertFalse(UpdateChecker.isTrustedReleaseURL(URL(string: "https://example.net/github.com")!))
    }
}

/// The once-a-day stamp, against a stubbed network and a throwaway defaults
/// suite.
final class UpdateCheckerStampTests: StubbedNetworkTestCase {
    private var suiteName: String!
    private var original: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = UUID().uuidString
        original = AppSettings.defaults
        AppSettings.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        AppSettings.defaults.removePersistentDomain(forName: suiteName)
        AppSettings.defaults = original
        super.tearDown()
    }

    private var stamp: Date? {
        AppSettings.defaults.object(forKey: AppSettings.lastUpdateCheckKey) as? Date
    }

    @MainActor
    func testFailedCheckLeavesItDue() async {
        StubURLProtocol.handler = { _ in throw URLError(.notConnectedToInternet) }
        await UpdateChecker.shared.check(session: stubbedURLSession())
        XCTAssertNil(stamp, "an offline launch must not suppress checks for a day")
    }

    @MainActor
    func testRateLimitedCheckLeavesItDue() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!
            return (response, Data(#"{"message":"API rate limit exceeded"}"#.utf8))
        }
        await UpdateChecker.shared.check(session: stubbedURLSession())
        XCTAssertNil(stamp)
    }

    @MainActor
    func testSuccessfulCheckIsStamped() async {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = #"{"tag_name":"v0.0.1","html_url":"https://github.com/costajohnt/murmur/releases/tag/v0.0.1"}"#
            return (response, Data(body.utf8))
        }
        await UpdateChecker.shared.check(session: stubbedURLSession())
        XCTAssertNotNil(stamp)
    }
}
