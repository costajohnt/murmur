import XCTest

/// Covers Task C of docs/superpowers/plans/2026-07-08-voice-loop.md: the
/// "note to self" prefix-routing rule (pure string logic, no network) and
/// BrainstemClient.capture's request shape / success-failure mapping (stubbed
/// via URLProtocol — never hits the live brainstem endpoint from tests).
final class BrainstemClientTests: XCTestCase {

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
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = BrainstemClient(baseURL: "http://brainstem.example/", session: Self.stubbedSession())
        try await client.capture("buy milk")

        let request = try XCTUnwrap(capturedRequest)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "http://brainstem.example/capture")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 10)

        let body = try XCTUnwrap(request.httpBodyData)
        let decoded = try JSONDecoder().decode([String: String].self, from: body)
        XCTAssertEqual(decoded["text"], "buy milk")
    }

    func testCaptureStripsNoTrailingSlashDuplication() async throws {
        var capturedURL: URL?
        StubURLProtocol.handler = { request in
            capturedURL = request.url
            let response = HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: Self.stubbedSession())
        try await client.capture("no trailing slash on base")
        XCTAssertEqual(capturedURL?.absoluteString, "http://brainstem.example/capture")
    }

    func test2xxStatusesSucceed() async throws {
        for code in [200, 201, 204, 299] {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = BrainstemClient(baseURL: "http://brainstem.example", session: Self.stubbedSession())
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
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: Self.stubbedSession())
        do {
            try await client.capture("oversized text")
            XCTFail("expected an error for a 413 response")
        } catch {
            // expected
        }
    }

    func testNetworkFailureThrows() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: Self.stubbedSession())
        do {
            try await client.capture("text")
            XCTFail("expected an error when the network request fails")
        } catch {
            // expected
        }
    }

    // MARK: - Stub plumbing

    private static func stubbedSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: config)
    }
}

/// Captures the outgoing HTTP body during URLProtocol stubbing, since
/// `URLRequest.httpBody` is often nil for requests routed through
/// URLSession (the body moves to a stream) — URLProtocol exposes it via
/// `httpBodyStream` instead. This mirrors what `startLoading` sees.
private extension URLRequest {
    var httpBodyData: Data? {
        if let httpBody { return httpBody }
        guard let stream = httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 { data.append(buffer, count: read) }
            else { break }
        }
        return data
    }
}

/// URLProtocol stub so BrainstemClient tests never touch the network. Set
/// `handler` per-test; it receives the outgoing request and returns the
/// (response, body) pair, or throws to simulate a network failure.
final class StubURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
