import Foundation
import XCTest

/// Shared URLProtocol stub so network-client tests (BrainstemClient,
/// OllamaClient) never touch the real network. Set `handler` per-test; it
/// receives the outgoing request and returns the (response, body) pair, or
/// throws to simulate a network failure. Every request seen is recorded in
/// `requests` (body materialized into `httpBody`). Handler and requests are
/// lock-guarded because URLSession calls `startLoading` on its loader thread.
/// Test classes using this subclass `StubbedNetworkTestCase` for the reset.
final class StubURLProtocol: URLProtocol {
    typealias Handler = (URLRequest) throws -> (HTTPURLResponse, Data)

    private static let lock = NSLock()
    private static var _handler: Handler?
    private static var _requests: [URLRequest] = []

    static var handler: Handler? {
        get { lock.withLock { _handler } }
        set { lock.withLock { _handler = newValue } }
    }

    static var requests: [URLRequest] { lock.withLock { _requests } }

    static func reset() {
        lock.withLock {
            _handler = nil
            _requests = []
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.unknown))
            return
        }
        // The body stream can only be read once; materialize it so both the
        // handler and later assertions see it.
        var seen = request
        seen.httpBody = request.httpBodyData
        Self.lock.withLock { Self._requests.append(seen) }
        do {
            let (response, data) = try handler(seen)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}

/// Clears the global stub before and after every test so a handler or
/// recorded request can never leak into the next test.
class StubbedNetworkTestCase: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }
}

func stubbedURLSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: config)
}

/// Captures the outgoing HTTP body during URLProtocol stubbing, since
/// `URLRequest.httpBody` is often nil for requests routed through
/// URLSession (the body moves to a stream) — URLProtocol exposes it via
/// `httpBodyStream` instead. This mirrors what `startLoading` sees.
extension URLRequest {
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
