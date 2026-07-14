import XCTest

/// Covers the "note to self" prefix-routing rule (pure string logic, no
/// network) and BrainstemClient.capture's request shape / success-failure
/// mapping (stubbed via URLProtocol — never hits the live brainstem endpoint
/// from tests).
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

    // MARK: - Routing must happen on the RAW transcript, before cleanup
    //
    // Live bug: routing used to check the CLEANED transcript. A tone preset
    // (Caveman especially) can rewrite or drop "note to self" entirely, so
    // the prefix silently stopped matching and the dictation pasted instead
    // of capturing. These tests pin the fix: the routing decision is made on
    // `raw`, and only the (already-stripped) remainder is ever handed to
    // cleanup — the trigger phrase is never in front of a rewriting model to
    // begin with.

    /// Stand-in for an aggressive cleanup pass (e.g. the Caveman tone): it
    /// can mangle or delete a literal phrase, same as the real Ollama
    /// cleanup is free to do.
    private func aggressiveRewrite(_ text: String) -> String {
        text
            .replacingOccurrences(of: "note to self", with: "reminder", options: .caseInsensitive)
            .uppercased()
    }

    func testPostCleanupRoutingIsBrokenByAnAggressiveRewrite() {
        // Sanity check pinning the live bug this fix addresses: if routing
        // ran AFTER cleanup, an aggressive rewrite that eats the trigger
        // phrase means routing never fires.
        let raw = "note to self, buy milk and eggs"
        let cleanedFullTranscriptBuggyOrder = aggressiveRewrite(raw)
        XCTAssertNil(BrainstemClient.noteToSelfRemainder(in: cleanedFullTranscriptBuggyOrder))
    }

    func testRawBasedRoutingSurvivesAnAggressiveCleanupRewrite() {
        let raw = "note to self, buy milk and eggs"

        // Fixed order: the routing decision uses raw, before cleanup ever
        // sees the transcript.
        let rawRemainder = BrainstemClient.noteToSelfRemainder(in: raw)
        XCTAssertEqual(rawRemainder, "buy milk and eggs", "capture must still fire off the raw transcript")

        // Cleanup then runs on the remainder ONLY — the trigger phrase was
        // already stripped, so even an aggressive rewrite can't reintroduce
        // it into what gets sent to the vault.
        let capturedText = aggressiveRewrite(rawRemainder!)
        XCTAssertFalse(
            capturedText.localizedCaseInsensitiveContains("note to self"),
            "the trigger phrase must never reach the captured vault text"
        )
        XCTAssertTrue(capturedText.localizedCaseInsensitiveContains("buy milk and eggs"))
    }

    func testCaseInsensitivePrefixSurvivesAggressiveRewriteToo() {
        let raw = "NOTE TO SELF: call the vet tomorrow"
        let rawRemainder = BrainstemClient.noteToSelfRemainder(in: raw)
        XCTAssertEqual(rawRemainder, "call the vet tomorrow")
        XCTAssertFalse(aggressiveRewrite(rawRemainder!).localizedCaseInsensitiveContains("note to self"))
    }

    // MARK: - capture (network, stubbed)

    func testCaptureSendsPostWithJSONBodyToCaptureEndpoint() async throws {
        var capturedRequest: URLRequest?
        StubURLProtocol.handler = { request in
            capturedRequest = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (response, Data())
        }

        let client = BrainstemClient(baseURL: "http://brainstem.example/", session: stubbedURLSession())
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
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: stubbedURLSession())
        try await client.capture("no trailing slash on base")
        XCTAssertEqual(capturedURL?.absoluteString, "http://brainstem.example/capture")
    }

    func test2xxStatusesSucceed() async throws {
        for code in [200, 201, 204, 299] {
            StubURLProtocol.handler = { request in
                let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
                return (response, Data())
            }
            let client = BrainstemClient(baseURL: "http://brainstem.example", session: stubbedURLSession())
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
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: stubbedURLSession())
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
        let client = BrainstemClient(baseURL: "http://brainstem.example", session: stubbedURLSession())
        do {
            try await client.capture("text")
            XCTFail("expected an error when the network request fails")
        } catch {
            // expected
        }
    }
}
