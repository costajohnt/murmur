import XCTest

/// Covers the tone-preset system prompt layering (no network calls — pure
/// string composition; ports the non-live assertions from
/// scripts/test-settings.swift), plus clean()'s request shape and error
/// mapping against a stubbed session (see the "clean(): request shape"
/// section below).
final class OllamaClientTests: XCTestCase {
    func testFaithfulIsByteIdenticalToBasePrompt() {
        XCTAssertEqual(OllamaClient.systemPrompt(for: .faithful), OllamaClient.systemPrompt)
    }

    func testPolishedAndCasualContainTheFullBasePrompt() {
        let base = OllamaClient.systemPrompt
        for tone: TonePreset in [.polished, .casual] {
            let prompt = OllamaClient.systemPrompt(for: tone)
            XCTAssertTrue(prompt.hasPrefix(base), "\(tone.rawValue) should start with the full faithful prompt")
            XCTAssertGreaterThan(prompt.count, base.count, "\(tone.rawValue) should append a style layer")
        }
    }

    func testAllPromptsAreDistinct() {
        let prompts = Set(TonePreset.allCases.map { OllamaClient.systemPrompt(for: $0) })
        XCTAssertEqual(prompts.count, TonePreset.allCases.count)
    }

    // Caveman is the one preset that deliberately does NOT append to the
    // faithful core: compression requires rewording, which the core forbids.
    // These tests pin the guards it must still carry on its own.

    func testCavemanIsStandaloneNotAnAppendToTheBasePrompt() {
        let prompt = OllamaClient.systemPrompt(for: .caveman)
        XCTAssertFalse(prompt.hasPrefix(OllamaClient.systemPrompt),
                       "caveman must not inherit the no-reword core verbatim")
        XCTAssertFalse(prompt.contains("NEVER shorten or summarize"),
                       "compression is the point — the no-shorten rule must not leak in")
    }

    func testCavemanKeepsTheAnswerAndInventGuards() {
        let prompt = OllamaClient.systemPrompt(for: .caveman)
        XCTAssertTrue(prompt.contains("NEVER answer a question"),
                      "must stay a formatter, never an assistant")
        XCTAssertTrue(prompt.contains("NEVER add words or invent"),
                      "must not fabricate content")
        XCTAssertTrue(prompt.contains("verbatim"),
                      "technical terms / code / quoted strings must survive exactly")
    }

    func testCavemanLabelAndSummary() {
        XCTAssertEqual(TonePreset.caveman.label, "Caveman")
        XCTAssertFalse(TonePreset.caveman.summary.isEmpty)
    }

    // MARK: - clean(): request shape + error mapping (network, stubbed)
    //
    // OllamaClient used to hardcode URLSession.shared, so none of this was
    // testable. It now takes an injected session (mirrors BrainstemClient),
    // stubbed here via the shared StubURLProtocol so these never touch a
    // real Ollama instance.

    private struct DecodedMessage: Decodable {
        let role: String
        let content: String
    }

    private struct DecodedChatRequest: Decodable {
        let messages: [DecodedMessage]
    }

    func testCleanSendsSystemThenUserMessageWithNoContext() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONEncoder().encode(["message": ["role": "assistant", "content": "cleaned text"]])
            return (response, body)
        }

        let client = OllamaClient(session: stubbedURLSession())
        let result = try await client.clean("raw text", model: "llama3.2:3b")
        XCTAssertEqual(result, "cleaned text")

        let request = try XCTUnwrap(captured)
        XCTAssertEqual(request.url?.absoluteString, "http://localhost:11434/api/chat")
        let decoded = try JSONDecoder().decode(DecodedChatRequest.self, from: try XCTUnwrap(request.httpBodyData))
        XCTAssertEqual(decoded.messages.map(\.role), ["system", "user"])
        XCTAssertEqual(decoded.messages.last?.content, "raw text")
    }

    func testCleanPutsContextAsSecondSystemMessageBeforeUser() async throws {
        var captured: URLRequest?
        StubURLProtocol.handler = { request in
            captured = request
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONEncoder().encode(["message": ["role": "assistant", "content": "cleaned"]])
            return (response, body)
        }

        let client = OllamaClient(session: stubbedURLSession())
        _ = try await client.clean("raw text", model: "llama3.2:3b", context: "glossary context")

        let decoded = try JSONDecoder().decode(DecodedChatRequest.self, from: try XCTUnwrap(captured?.httpBodyData))
        XCTAssertEqual(decoded.messages.map(\.role), ["system", "system", "user"])
        XCTAssertEqual(decoded.messages[1].content, "glossary context")
    }

    func testCleanThrowsBadStatusOnNon200() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 500, httpVersion: nil, headerFields: nil)!
            return (response, Data("server error".utf8))
        }
        let client = OllamaClient(session: stubbedURLSession())
        do {
            _ = try await client.clean("raw", model: "llama3.2:3b")
            XCTFail("expected badStatus")
        } catch let error as OllamaClient.OllamaError {
            guard case .badStatus(let code, _) = error else {
                return XCTFail("expected badStatus, got \(error)")
            }
            XCTAssertEqual(code, 500)
        }
    }

    func testCleanThrowsUnreachableOnTransportError() async throws {
        StubURLProtocol.handler = { _ in
            throw URLError(.notConnectedToInternet)
        }
        let client = OllamaClient(session: stubbedURLSession())
        do {
            _ = try await client.clean("raw", model: "llama3.2:3b")
            XCTFail("expected unreachable")
        } catch let error as OllamaClient.OllamaError {
            guard case .unreachable = error else {
                return XCTFail("expected unreachable, got \(error)")
            }
        }
    }

    func testCleanThrowsEmptyResponseOnWhitespaceOnlyContent() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            let body = try! JSONEncoder().encode(["message": ["role": "assistant", "content": "   \n  "]])
            return (response, body)
        }
        let client = OllamaClient(session: stubbedURLSession())
        do {
            _ = try await client.clean("raw", model: "llama3.2:3b")
            XCTFail("expected emptyResponse")
        } catch let error as OllamaClient.OllamaError {
            guard case .emptyResponse = error else {
                return XCTFail("expected emptyResponse, got \(error)")
            }
        }
    }
}
