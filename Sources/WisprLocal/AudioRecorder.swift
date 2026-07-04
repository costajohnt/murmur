import AVFoundation
import Foundation

/// Records microphone input via AVAudioEngine, converting to 16 kHz mono
/// Float32 (what Parakeet expects). Samples accumulate in memory; `stop()`
/// returns them. `writeWav` persists them as a 16-bit PCM WAV for history /
/// v2 re-transcribe.
final class AudioRecorder {
    static let sampleRate = 16_000.0

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let lock = NSLock()

    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    enum RecorderError: LocalizedError {
        case micDenied
        case converterUnavailable

        var errorDescription: String? {
            switch self {
            case .micDenied: return "Microphone access denied (System Settings > Privacy & Security > Microphone)"
            case .converterUnavailable: return "Could not create audio converter for input format"
            }
        }
    }

    /// Requests mic permission if needed, then starts the engine tap.
    func start() async throws {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            break
        case .notDetermined:
            let granted = await AVCaptureDevice.requestAccess(for: .audio)
            guard granted else { throw RecorderError.micDenied }
        default:
            throw RecorderError.micDenied
        }

        lock.lock()
        samples.removeAll()
        lock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        converter = conv

        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.appendConverted(buffer)
        }
        engine.prepare()
        try engine.start()
    }

    /// Stops recording and returns the accumulated 16 kHz mono samples.
    func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        lock.lock()
        defer { lock.unlock() }
        return samples
    }

    private func appendConverted(_ buffer: AVAudioPCMBuffer) {
        guard let converter else { return }
        let ratio = AudioRecorder.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }

        var consumed = false
        var convError: NSError?
        converter.convert(to: out, error: &convError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return buffer
        }
        guard convError == nil, let channel = out.floatChannelData else { return }
        let chunk = Array(UnsafeBufferPointer(start: channel[0], count: Int(out.frameLength)))
        lock.lock()
        samples.append(contentsOf: chunk)
        lock.unlock()
    }

    /// Writes samples to a 16-bit PCM WAV at 16 kHz mono.
    static func writeWav(_ samples: [Float], to url: URL) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
        let file = try AVAudioFile(
            forWriting: url,
            settings: settings,
            commonFormat: .pcmFormatFloat32,
            interleaved: false
        )
        let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.sampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
            return
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: samples.count)
        }
        try file.write(from: buffer)
    }
}
