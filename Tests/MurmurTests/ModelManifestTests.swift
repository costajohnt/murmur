import XCTest

/// Audit M3: the pinned-checksum gate in front of the speech model load.
final class ModelManifestTests: XCTestCase {
    private var tmp: URL!
    private let abc = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp.appendingPathComponent("Enc.mlmodelc"), withIntermediateDirectories: true)
        try Data("abc".utf8).write(to: tmp.appendingPathComponent("Enc.mlmodelc/weight.bin"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    func testMatchingManifestPasses() throws {
        XCTAssertNoThrow(try ModelManifest.verify(["Enc.mlmodelc/weight.bin": abc], in: tmp))
    }

    func testChangedFileFails() throws {
        try Data("abd".utf8).write(to: tmp.appendingPathComponent("Enc.mlmodelc/weight.bin"))
        XCTAssertThrowsError(try ModelManifest.verify(["Enc.mlmodelc/weight.bin": abc], in: tmp)) { error in
            XCTAssertEqual((error as? ModelManifest.Mismatch)?.path, "Enc.mlmodelc/weight.bin")
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
    }

    func testMissingFileFails() {
        XCTAssertThrowsError(try ModelManifest.verify(["missing.bin": abc], in: tmp)) { error in
            XCTAssertEqual((error as? ModelManifest.Mismatch)?.path, "missing.bin")
        }
    }

    func testShippedManifestCoversTheFourModelsAndVocab() {
        let keys = ModelManifest.parakeetV2.keys
        for model in ["Preprocessor", "Encoder", "Decoder", "JointDecision"] {
            XCTAssertTrue(keys.contains("\(model).mlmodelc/weights/weight.bin"), model)
            XCTAssertTrue(keys.contains("\(model).mlmodelc/model.mil"), model)
        }
        XCTAssertTrue(keys.contains("parakeet_vocab.json"))
        XCTAssertTrue(ModelManifest.parakeetV2.values.allSatisfy { $0.count == 64 })
    }
}
