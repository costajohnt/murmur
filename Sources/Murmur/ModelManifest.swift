import CryptoKit
import Foundation

/// Pinned Parakeet TDT v2 weights (audit M3). FluidAudio fetches
/// `FluidInference/parakeet-tdt-0.6b-v2-coreml` at `main` with no hash
/// check, and the compiled CoreML bundles are code the app runs with its
/// Microphone and Accessibility grants. So Murmur fills FluidAudio's cache
/// itself from `pinnedRevision`, verifying every file as it lands, and runs
/// FluidAudio offline (`DownloadUtils.enforceOffline`) so it never fetches
/// or replaces anything; see `DictationCoordinator.ensureAsr`.
///
/// Provenance: sha256 of every file the loader needs in the Hugging Face
/// repo at commit ee09c569f73759e6d44c9bd16766f477b2b36d39 (main on
/// 2026-10-31), from the tree API (LFS sha256 for the weights, git blob ids
/// for the rest) and cross-checked against a cache FluidAudio 0.15.4 had
/// downloaded. To bump: pick the new commit, download each path below from
/// `https://huggingface.co/<repo>/resolve/<commit>/<path>`, `shasum -a 256`.
enum ModelManifest {
    static let repo = "FluidInference/parakeet-tdt-0.6b-v2-coreml"
    static let pinnedRevision = "ee09c569f73759e6d44c9bd16766f477b2b36d39"

    static let parakeetV2: [String: String] = [
        "config.json": "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356",
        "Decoder.mlmodelc/analytics/coremldata.bin": "46de1a6fe2e49d19a2125bc91acf020df7f2aea84ba821532aade8427a440b05",
        "Decoder.mlmodelc/coremldata.bin": "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8",
        "Decoder.mlmodelc/metadata.json": "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2",
        "Decoder.mlmodelc/model.mil": "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579",
        "Decoder.mlmodelc/weights/weight.bin": "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba",
        "Encoder.mlmodelc/analytics/coremldata.bin": "42e638870d73f26b332918a3496ce36793fbb413a81cbd3d16ba01328637a105",
        "Encoder.mlmodelc/coremldata.bin": "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030",
        "Encoder.mlmodelc/metadata.json": "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63",
        "Encoder.mlmodelc/model.mil": "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808",
        "Encoder.mlmodelc/weights/weight.bin": "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e",
        "JointDecision.mlmodelc/analytics/coremldata.bin": "f1183ba213bb94a918c8d2cad19ab045320618f97f6ca662245b3936d7b090f7",
        "JointDecision.mlmodelc/coremldata.bin": "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11",
        "JointDecision.mlmodelc/metadata.json": "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c",
        "JointDecision.mlmodelc/model.mil": "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0",
        "JointDecision.mlmodelc/weights/weight.bin": "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d",
        "parakeet_vocab.json": "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97",
        "Preprocessor.mlmodelc/analytics/coremldata.bin": "03ab3c1327a054c54c07a40325db967ec574f2c91dcc8192bfa44aa561bcf2d8",
        "Preprocessor.mlmodelc/coremldata.bin": "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6",
        "Preprocessor.mlmodelc/metadata.json": "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb",
        "Preprocessor.mlmodelc/model.mil": "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e",
        "Preprocessor.mlmodelc/weights/weight.bin": "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc",
    ]

    struct Mismatch: LocalizedError {
        let path: String
        let reason: String
        var errorDescription: String? {
            "Speech model file \(path) \(reason). This build of Murmur pins the model files; check your network or update Murmur."
        }
    }

    /// Makes `dir` hold exactly `manifest`: a file that already matches is
    /// kept, anything missing or different is fetched from `revision` and
    /// verified before it replaces the old file. `progress` gets
    /// (files done, files total).
    static func populate(
        _ manifest: [String: String] = parakeetV2,
        in dir: URL,
        revision: String = pinnedRevision,
        session: URLSession = .shared,
        progress: ((Int, Int) -> Void)? = nil
    ) async throws {
        let fm = FileManager.default
        let entries = manifest.sorted { $0.key < $1.key }
        for (index, (path, expected)) in entries.enumerated() {
            let file = dir.appendingPathComponent(path)
            if (try? sha256(of: file)) != expected {
                let url = URL(string: "https://huggingface.co/\(repo)/resolve/\(revision)/\(path)")!
                let (downloaded, response) = try await session.download(from: url)
                defer { try? fm.removeItem(at: downloaded) }
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    throw Mismatch(path: path, reason: "could not be downloaded (HTTP \(status))")
                }
                guard try sha256(of: downloaded) == expected else {
                    throw Mismatch(path: path, reason: "downloaded from the pinned revision but does not match its checksum")
                }
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fm.fileExists(atPath: file.path) { try fm.removeItem(at: file) }
                try fm.moveItem(at: downloaded, to: file)
            }
            progress?(index + 1, entries.count)
        }
    }

    /// Streaming sha256 (the encoder weights are 445 MB).
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
