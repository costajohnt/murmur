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
        var progress: [(Int, Int)] = []
        try await ModelManifest.populate([path: abc], in: tmp, session: stubbedURLSession()) { progress.append(($0, $1)) }
        XCTAssertTrue(StubURLProtocol.requests.isEmpty)
        XCTAssertEqual(progress.map(\.0), [1])
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
            XCTAssertTrue(error.localizedDescription.contains("HTTP 404"))
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
