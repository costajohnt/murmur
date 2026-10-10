import XCTest

/// Covers the "note to self" prefix-routing rule (pure string logic, no
/// network) and BrainstemClient.capture's request shape / success-failure
/// mapping (stubbed via URLProtocol — never hits the live brainstem endpoint
/// from tests).
final class BrainstemClientTests: StubbedNetworkTestCase {

    // MARK: - noteToSelfRemainder (pure routing logic)

    func testStripsCommaSeparator() {
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "note to self, buy milk"),
            "buy milk"
        )
    }

    func testStripsColonSeparator() {
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "note to self: call mom"),
            "call mom"
        )
    }

    func testStripsPeriodSeparator() {
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "note to self. pick up dry cleaning"),
            "pick up dry cleaning"
        )
    }

    func testStripsWithNoSeparatorJustWhitespace() {
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "note to self buy milk"),
            "buy milk"
        )
    }

    func testCaseInsensitivePrefix() {
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "Note To Self: call mom"),
            "call mom"
        )
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "NOTE TO SELF, pick up dry cleaning"),
            "pick up dry cleaning"
        )
    }

    func testTrimsLeadingAndTrailingWhitespaceAroundTranscriptAndRemainder() {
        XCTAssertEqual(
            BrainstemClient.noteToSelfRemainder(in: "  note to self,   buy milk  "),
            "buy milk"
        )
    }

    func testNoMatchWhenTranscriptDoesNotStartWithPrefix() {
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: "remember to buy milk"))
    }

    func testNoMatchWithoutWordBoundaryAfterPrefix() {
        // "selfish" must NOT be treated as "self" + separator.
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: "note to selfish behavior is bad"))
    }

    func testNoMatchWhenNothingFollowsThePrefix() {
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: "note to self"))
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: "note to self,"))
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: "note to self   "))
    }

    func testNoMatchWithoutSpacesBetweenWords() {
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: "notetoself buy milk"))
    }

    // MARK: - capture (network, stubbed)

    func testCaptureSendsPostWithJSONBodyToCaptureEndpoint() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = BrainstemClient(baseURL: "https://brainstem.example/", session: stubbedURLSession())
        try await client.capture("buy milk")

        let request = try XCTUnwrap(StubURLProtocol.requests.last)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://brainstem.example/capture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)

        let body = try XCTUnwrap(request.httpBodyData)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded["text"], "buy milk")
    }

    func testCaptureAppendsEndpointToBaseWithoutTrailingSlash() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = BrainstemClient(baseURL: "https://brainstem.example", session: stubbedURLSession())
        try await client.capture("no trailing slash on base")
        XCTAssertEqual(StubURLProtocol.requests.last?.url?.absoluteString, "https://brainstem.example/capture")
    }

    func test2xxStatusesSucceed() async throws {
        for code in [200, 201, 204, 299] {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = BrainstemClient(baseURL: "https://brainstem.example", session: stubbedURLSession())
            do {
                try await client.capture("text")
            } catch {
                XCTFail("status \(code) should succeed, threw \(error)")
            }
        }
    }

    func testNon2xxStatusThrows() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 413, httpVersion: nil, headerFields: nil)!
            return (response, Data("too large".utf8))
        }
        let client = BrainstemClient(baseURL: "https://brainstem.example", session: stubbedURLSession())
        do {
            try await client.capture("oversized text")
            XCTFail("expected an error for a 413 response")
        } catch let error as BrainstemClient.CaptureError {
            guard case .badStatus(let code, let body) = error else {
                return XCTFail("expected badStatus, got \(error)")
            }
            XCTAssertEqual(code, 413)
            XCTAssertEqual(body, "too large")
        }
    }

    func testBadStatusDescriptionOmitsResponseBody() {
        // The description is logged; a server echoing the request must not be
        // able to put transcript text there.
        let error = BrainstemClient.CaptureError.badStatus(500, body: "echo: my private note")
        XCTAssertEqual(error.errorDescription, "Brainstem HTTP 500")
    }

    func testNetworkFailureThrows() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = BrainstemClient(baseURL: "https://brainstem.example", session: stubbedURLSession())
        do {
            try await client.capture("text")
            XCTFail("expected an error when the network request fails")
        } catch let error as URLError {
            // capture() does not wrap transport errors in CaptureError.
            XCTAssertEqual(error.code, .notConnectedToInternet)
        }
    }

    // MARK: - URL scheme policy

    func testSchemePolicy() {
        XCTAssertTrue(BrainstemClient.isAllowed(scheme: "https", host: "example.com"))
        XCTAssertTrue(BrainstemClient.isAllowed(scheme: "http", host: "brainstem.tail1234.ts.net"))
        XCTAssertTrue(BrainstemClient.isAllowed(scheme: "http", host: "100.64.0.1"))
        XCTAssertTrue(BrainstemClient.isAllowed(scheme: "http", host: "100.127.255.255"))
        XCTAssertTrue(BrainstemClient.isAllowed(scheme: "http", host: "localhost"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "100.128.0.1"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "192.168.5.10"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "brainstem.example"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "evil-ts.net"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "ftp", host: "localhost"))
        // Public names that merely start with CGNAT-looking labels.
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "100.64.1.2.example.com"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "100.64.example.1.2"))
        // Non-canonical octets (octal to some resolvers) and empty labels.
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "100.064.0.1"))
        XCTAssertFalse(BrainstemClient.isAllowed(scheme: "http", host: "100.64..1"))
    }

    func testPlainHTTPToPublicHostIsRefusedBeforeSending() async {
        StubURLProtocol.handler = { _ in
            XCTFail("must not send")
            throw URLError(.cancelled)
        }
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: stubbedURLSession())
        do {
            try await client.capture("text")
            XCTFail("expected insecureURL")
        } catch BrainstemClient.CaptureError.insecureURL {
            // expected
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
