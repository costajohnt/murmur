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

    /// Live audio level (0..1, dB-mapped + attack/decay smoothed), computed in
    /// the existing input tap — no second tap. Called on the audio thread;
    /// the consumer is responsible for hopping to the main actor.
    var onLevel: ((Float) -> Void)?
    private var smoothedLevel: Float = 0

    /// Fires at most once per recording, on the audio thread, when the
    /// smoothed level has stayed at/below `silenceThreshold` for
    /// `silenceAutoStopDuration` seconds (after the grace period). The
    /// consumer is responsible for hopping to the main actor and driving the
    /// same stop-and-process path as a manual stop.
    var onSilenceTimeout: (() -> Void)?
    private var recordStartTime: Date?
    private var silenceStartTime: Date?
    private var didFireSilenceTimeout = false
    /// Snapshotted from AppSettings at `start()` so the audio thread never
    /// touches UserDefaults mid-recording. 0 disables auto-stop.
    private var silenceAutoStopDuration: TimeInterval = 0

    /// Level mapping/smoothing constants: speech RMS maps to roughly
    /// -50 dB (very quiet) .. -10 dB (loud), so quiet speech still moves the
    /// bars. Attack is fast (bars jump on speech onset), decay slower (no
    /// jitter between words).
    private static let dbFloor: Float = -50
    private static let dbCeiling: Float = -10
    private static let attackAlpha: Float = 0.6
    private static let decayAlpha: Float = 0.2

    /// Near-silence, for auto-stop purposes: a small margin above dbFloor so
    /// room tone / mic hiss (which sits at the floor) doesn't need to hit
    /// literal zero to count as "silence". Expressed in the same normalized
    /// 0..1 space as `smoothedLevel`.
    private static let silenceMarginDb: Float = 5
    private static let silenceThreshold: Float = silenceMarginDb / (dbCeiling - dbFloor)
    /// Never auto-stop this early — the user hasn't necessarily started
    /// talking yet.
    private static let silenceGraceSeconds: TimeInterval = 1.5

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
        smoothedLevel = 0
        recordStartTime = Date()
        silenceStartTime = nil
        didFireSilenceTimeout = false
        silenceAutoStopDuration = AppSettings.silenceAutoStopSeconds

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        converter = conv

        input.removeTap(onBus: 0)
        // ~1600 frames at 48 kHz ≈ 33 ms per buffer → ~30 Hz level updates.
        input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
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
        updateLevel(chunk)
    }

    /// RMS → dB → normalized 0..1 with asymmetric smoothing. Runs on the
    /// audio thread; only touches `smoothedLevel` (audio thread only) and the
    /// `onLevel` callback.
    private func updateLevel(_ chunk: [Float]) {
        guard !chunk.isEmpty else { return }
        var sum: Float = 0
        for sample in chunk { sum += sample * sample }
        let rms = (sum / Float(chunk.count)).squareRoot()
        let db = 20 * log10(max(rms, 1e-7))
        let normalized = min(max((db - Self.dbFloor) / (Self.dbCeiling - Self.dbFloor), 0), 1)
        let alpha = normalized > smoothedLevel ? Self.attackAlpha : Self.decayAlpha
        smoothedLevel += alpha * (normalized - smoothedLevel)
        onLevel?(smoothedLevel)
        checkSilenceAutoStop()
    }

    /// Accumulates time spent at/below `silenceThreshold` and fires
    /// `onSilenceTimeout` once that exceeds `silenceAutoStopDuration`, after
    /// the grace period and skipped entirely when auto-stop is off (0).
    /// Runs on the audio thread, right after each level update.
    private func checkSilenceAutoStop() {
        guard silenceAutoStopDuration > 0, !didFireSilenceTimeout,
              let recordStartTime else { return }
        let now = Date()
        guard now.timeIntervalSince(recordStartTime) >= Self.silenceGraceSeconds else { return }

        guard smoothedLevel <= Self.silenceThreshold else {
            silenceStartTime = nil
            return
        }
        let start = silenceStartTime ?? now
        silenceStartTime = start
        if now.timeIntervalSince(start) >= silenceAutoStopDuration {
            didFireSilenceTimeout = true
            onSilenceTimeout?()
        }
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
