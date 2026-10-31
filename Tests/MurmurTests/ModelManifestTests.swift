import XCTest

/// Audit M3: the pinned-checksum gate in front of the speech model load.
/// `populate` keeps matching files, fetches the rest from the pinned
/// revision through the stubbed session, and refuses anything that does not
/// hash as pinned.
final class ModelManifestTests: StubbedNetworkTestCase {
    private var tmp: URL!
    private let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    private let path = "Enc.mlmodelc/weights/weight.bin"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ text: String) throws {
        let file = tmp.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file)
    }

    private func stub(status: Int, body: String) {
        StubURLProtocol.handler = { request in
            (HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, Data(body.utf8))
        }
    }

    func testMatchingFileIsKeptWithoutNetwork() async throws {
        try write("abc")
        var progress: [(Int, Int, Bool)] = []
        try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession()) { progress.append(($0, $1, $2)) }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(progress.map(\.0), [1])
        XCTAssertEqual(progress.map(\.2), [false])
    }

    func testDownloadReportsInFlightThenDone() async throws {
        stub(status: 200, body: "abc")
        var progress: [(Int, Int, Bool)] = []
        try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession()) { progress.append(($0, $1, $2)) }
        XCTAssertEqual(progress.map(\.2), [true, false])
        XCTAssertEqual(progress.map(\.0), [0, 1])
    }

    func testTransportErrorIsRetriedOnce() async throws {
        let attempts = Counter()
        StubURLProtocol.handler = { request in
            if attempts.next() == 1 { throw URLError(.networkConnectionLost) }
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, Data("abc".utf8))
        }
        try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession())
        XCTAssertEqual(attempts.next(), 3, "exactly one retry")
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent(path), encoding: .utf8), "abc")
    }

    func testTransportErrorTwiceSurfaces() async throws {
        StubURLProtocol.handler = { _ in throw URLError(.networkConnectionLost) }
        do {
            try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession())
            XCTFail("expected the second failure to surface")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .networkConnectionLost)
        }
        XCTAssertEqual(StubURLProtocol.requests.count, 2)
    }

    func testMissingOrChangedFileIsFetchedFromThePinnedRevision() async throws {
        try write("abd")
        stub(status: 200, body: "abc")
        try await ModelManifest.populate([path: abc], in: tmp, revision: "deadbeef", session: stubbedURLSession())
        let request = try XCTUnwrap(StubURLProtocol.requests.first)
        XCTAssertEqual(request.url?.absoluteString, "https://huggingface.co/\(ModelManifest.repo)/resolve/deadbeef/\(path)")
        XCTAssertEqual(try String(contentsOf: tmp.appendingPathComponent(path), encoding: .utf8), "abc")
    }

    func testDownloadThatDoesNotMatchIsRejected() async throws {
        stub(status: 200, body: "tampered")
        do {
            try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession())
            XCTFail("expected a mismatch")
        } catch let error as ModelManifest.Mismatch {
            XCTAssertEqual(error.path, path)
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent(path).path))
    }

    func testHTTPErrorIsReported() async throws {
        stub(status: 404, body: "")
        do {
            try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession())
            XCTFail("expected a download failure")
        } catch let error as ModelManifest.Mismatch {
            XCTAssertTrue(error.localizedDescription.contains("huggingface.co (HTTP 404)"), error.localizedDescription)
        }
    }

    func testShippedManifestCoversTheFourModelsAndVocab() {
        let keys = ModelManifest.parakeetV2.keys
        for model in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
            XCTAssertTrue(keys.contains("\(model).mlmodelc/weights/weight.bin"), model)
            XCTAssertTrue(keys.contains("\(model).mlmodelc/model.mil"), model)
            XCTAssertTrue(keys.contains("\(model).mlmodelc/coremldata.bin"), model)
        }
        XCTAssertTrue(keys.contains("parakeet_vocab.json"))
        XCTAssertTrue(ModelManifest.parakeetV2.values.allSatisfy { $0.count == 64 })
        XCTAssertEqual(ModelManifest.pinnedRevision.count, 40)
    }
}

/// Lock-guarded attempt counter for handlers, which run on URLSession's thread.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
}
