import CryptoKit
import Foundation

/// Pinned sha256 of the Parakeet TDT v2 files FluidAudio fetches from
/// `FluidInference/parakeet-tdt-0.6b-v2-coreml` at `main` (audit M3).
/// FluidAudio pins nothing: the branch floats and the download has no hash
/// check, yet these compiled CoreML bundles are code the app runs with its
/// Microphone and Accessibility grants. `DictationCoordinator.ensureAsr`
/// verifies the cache against this before `AsrModels.load`.
///
/// Values: sha256 of the cached files on 2026-10-31, cross-checked against
/// the Hugging Face tree API for that commit (LFS sha256 for the weights,
/// git blob ids for the rest). `analytics/coremldata.bin` is left out: it
/// is telemetry, not model input. Regenerate after a deliberate upstream
/// bump with:
///   cd ~/Library/Application\ Support/FluidAudio/Models/parakeet-tdt-0.6b-v2-coreml
///   find . -type f -not -path '*/analytics/*' | sort | xargs shasum -a 256
enum ModelManifest {
    static let parakeetV2: [String: String] = [
        "config.json": "ca3d163bab055381827226140568f3bef7eaac187cebd76878e0b63e9e442356",
        "Decoder.mlmodelc/coremldata.bin": "d200ca07694a347f6d02a3886a062ae839831e094e443222f2e48a14945966a8",
        "Decoder.mlmodelc/metadata.json": "90a279b822496316458febc0ce761ab05954fadd9d66aa97bea077a35fc8f2b2",
        "Decoder.mlmodelc/model.mil": "7b95a5a6b672c652000348a67b6d4d92bb8e176b978c6666fe73c28a4d7ec579",
        "Decoder.mlmodelc/weights/weight.bin": "27d26890221d82322c1092fd99d7b40578e435d5cf4b83c887c42603caf97aba",
        "Encoder.mlmodelc/coremldata.bin": "4def7aa848599ad0e17a8b9a982edcdbf33cf92e1f4b798de32e2ca0bc74b030",
        "Encoder.mlmodelc/metadata.json": "58222fbc48c13c49d9715567803cd50cb9c23e4360462e0f8ffcea59a2c73c63",
        "Encoder.mlmodelc/model.mil": "ed7b19156ca29fa7dfd6891deb9fda4b0e8893f68597c985d135736546a43808",
        "Encoder.mlmodelc/weights/weight.bin": "4adc7ad44f9d05e1bffeb2b06d3bb02861a5c7602dff63a6b494aed3bf8a6c3e",
        "JointDecision.mlmodelc/coremldata.bin": "e2c6752f1c8cf2d3f6f26ec93195c9bfa759ad59edf9f806696a138154f96f11",
        "JointDecision.mlmodelc/metadata.json": "ba8d309417b9acd4a175fdb15687de6a941db2f5b06666a60e7cf3cc8e2d3c3c",
        "JointDecision.mlmodelc/model.mil": "93bf82042235127cb81ab537dcae47a1c2e7e242ce4ffdaf772981b45eedc4f0",
        "JointDecision.mlmodelc/weights/weight.bin": "ca22a65903a05e64137677da608077578a8606090a598abf4875fa6199aaa19d",
        "parakeet_vocab.json": "57019fe3c745772ca83a1b048a4bb951cd51329504ea33d4d83316b96e279a97",
        "Preprocessor.mlmodelc/coremldata.bin": "d88ea1fc349459c9e100d6a96688c5b29a1f0d865f544be103001724b986b6d6",
        "Preprocessor.mlmodelc/metadata.json": "fb16c581ff5e1b962e7cb2181ed892cd32f9f84c12b6e80ff3e089f28e35bcbb",
        "Preprocessor.mlmodelc/model.mil": "3e06d16fd061294c8a75be68c43a3b1ed1f593d4a9c35249e9cdbccadc59721e",
        "Preprocessor.mlmodelc/weights/weight.bin": "a5f7df6c7f47147ae9486fe18cc7792f9a44d093ec3c6a11e91ef2dc363c48dc",
    ]

    struct Mismatch: LocalizedError {
        let path: String
        let reason: String
        var errorDescription: String? {
            "Speech model file \(path) \(reason). Delete ~/Library/Application Support/FluidAudio/Models and relaunch Murmur to download it again."
        }
    }

    /// Throws on the first file under `dir` that is missing or whose sha256
    /// differs from `manifest`.
    static func verify(_ manifest: [String: String] = parakeetV2, in dir: URL) throws {
        for (path, expected) in manifest.sorted(by: { $0.key < $1.key }) {
            let actual: String
            do {
                actual = try sha256(of: dir.appendingPathComponent(path))
            } catch {
                throw Mismatch(path: path, reason: "could not be read (\(error.localizedDescription))")
            }
            guard actual == expected else {
                throw Mismatch(path: path, reason: "does not match the pinned checksum")
            }
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
