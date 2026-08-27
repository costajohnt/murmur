import AVFoundation
import CoreAudio
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
    /// the existing input tap — no second tap. Set on the main thread, called
    /// on the audio thread; both sides go through `lock` (same one guarding
    /// `samples`) since a plain var would let the audio thread read a torn/
    /// stale reference while the main thread reassigns it. The consumer is
    /// responsible for hopping to the main actor.
    var onLevel: ((Float) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onLevel }
        set { lock.lock(); defer { lock.unlock() }; _onLevel = newValue }
    }
    private var _onLevel: ((Float) -> Void)?
    private var smoothedLevel: Float = 0

    /// Why a recording stopped itself.
    enum AutoStopReason {
        /// Sustained near-silence for `AppSettings.silenceAutoStopSeconds`.
        case silence
        /// Hit `maxRecordingSeconds`; the buffer is not allowed to grow further.
        case maxDuration
    }

    /// Fires at most once per recording, on the audio thread, when the
    /// recording stops itself — sustained near-silence, or the length cap.
    /// Same cross-thread setup/guard as `onLevel` above. The consumer is
    /// responsible for hopping to the main actor and driving the same
    /// stop-and-process path as a manual stop.
    var onAutoStop: ((AutoStopReason) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onAutoStop }
        set { lock.lock(); defer { lock.unlock() }; _onAutoStop = newValue }
    }
    private var _onAutoStop: ((AutoStopReason) -> Void)?
    /// `recordStartTime`/`silenceStartTime`/`didFireAutoStop`/
    /// `silenceAutoStopDuration` below are written on the main thread in
    /// `start()` and read/written on the audio thread in
    /// `checkSilenceAutoStop()` — every access to them goes through `lock`.
    private var recordStartTime: Date?
    private var silenceStartTime: Date?
    private var didFireAutoStop = false
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

    /// Hard ceiling on a single recording. `samples` grows for the entire
    /// recording at 16 kHz mono Float32 — ~64 KB/s, ~230 MB/hour — and silence
    /// auto-stop can be switched off entirely, so a forgotten recording in a
    /// room with any ambient noise otherwise grows until the process is killed
    /// (#36). 15 minutes is ~58 MB and far longer than any real dictation.
    static let maxRecordingSeconds: TimeInterval = 15 * 60
    private static let maxSamples = Int(sampleRate * maxRecordingSeconds)

    let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: AudioRecorder.sampleRate,
        channels: 1,
        interleaved: false
    )!

    enum RecorderError: LocalizedError {
        case micDenied
        case converterUnavailable
        case engineFailed(step: String, reason: String)

        var errorDescription: String? {
            switch self {
            case .micDenied: return "Microphone access denied (System Settings > Privacy & Security > Microphone)"
            case .converterUnavailable: return "Could not create audio converter for input format"
            case .engineFailed(let step, let reason):
                return "Could not start the microphone (\(step): \(reason)). Try again, or reconnect the input device."
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
        recordStartTime = Date()
        silenceStartTime = nil
        didFireAutoStop = false
        silenceAutoStopDuration = AppSettings.silenceAutoStopSeconds
        lock.unlock()
        smoothedLevel = 0

        // A previous recording can leave the engine running (e.g. stop() ran
        // while the hardware was mid-reset, or a device change restarted it
        // under us). Reconfiguring a running engine is what leaves the input
        // node in the inconsistent state that makes installTap raise.
        if engine.isRunning {
            // Best-effort: if the graph is already stale this raises, and there
            // is nothing to recover here — the guards below decide whether the
            // recording can proceed.
            _ = try? catchingNSException("engine reset") {
                self.engine.inputNode.removeTap(onBus: 0)
                self.engine.stop()
            }
        }

        // Materializing the input node builds the underlying AUGraph, which is
        // exactly what raises when that graph is stale (#35).
        let input = try catchingNSException("input node") { self.engine.inputNode }
        // Bind the user-chosen input device (e.g. the RØDE on the dock) before
        // reading its format or installing the tap. Empty UID = System Default,
        // in which case we leave the engine on its default input untouched.
        // Must happen before `outputFormat(forBus:)` below, because switching
        // the underlying device changes that format. If the chosen device isn't
        // currently connected we fall through to the system default rather than
        // failing the recording.
        bindPreferredInputDevice(on: input)
        // Bluetooth mics (AirPods) switch from A2DP to HFP call mode the moment
        // recording starts; mid-handoff the input node reports a transient
        // invalid format (0 Hz / 0 channels). `installTap` with such a format
        // raises an Objective-C NSException that Swift's `try` cannot catch, so
        // the process aborts (SIGABRT). Wait for the device to settle to a valid
        // format before reading it once for both the converter and the tap.
        var inputFormat = try catchingNSException("input format") { input.outputFormat(forBus: 0) }
        for _ in 0..<20 where inputFormat.sampleRate == 0 || inputFormat.channelCount == 0 {
            try await Task.sleep(for: .milliseconds(100))
            inputFormat = try catchingNSException("input format") { input.outputFormat(forBus: 0) }
        }
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw RecorderError.micDenied
        }
        guard let conv = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw RecorderError.converterUnavailable
        }
        converter = conv

        do {
            try catchingNSException("install tap") {
                input.removeTap(onBus: 0)
                // ~1600 frames at 48 kHz ≈ 33 ms per buffer → ~30 Hz level updates.
                input.installTap(onBus: 0, bufferSize: 1600, format: inputFormat) { [weak self] buffer, _ in
                    self?.appendConverted(buffer)
                }
                self.engine.prepare()
            }
        } catch {
            converter = nil
            throw error
        }
        try engine.start()
    }

    /// Runs `body`, turning an Objective-C NSException into a Swift error.
    /// Every AVAudioEngine call that materializes or mutates the input graph
    /// can raise one once that graph is stale (sleep/wake, device change), and
    /// Swift `try` cannot intercept a raise — the process aborts instead (#33,
    /// #35). Callers doing best-effort cleanup use `try?`.
    @discardableResult
    private func catchingNSException<T>(_ step: String, _ body: () -> T) throws -> T {
        var value: T?
        var raised: NSError?
        let ok = MurmurCatchNSException({ value = body() }, &raised)
        guard ok, let value else {
            let reason = raised?.localizedDescription ?? "unknown"
            Log.log("recorder: \(step) raised \(reason)")
            throw RecorderError.engineFailed(step: step, reason: reason)
        }
        return value
    }

    /// Points the engine's input node at the device stored in
    /// `AppSettings.preferredInputDeviceUID`. No-op when that's empty (System
    /// Default) or when the stored device isn't currently connected — either
    /// way the engine keeps its existing default input. Setting
    /// `kAudioOutputUnitProperty_CurrentDevice` on the input node's audio unit
    /// is the supported way to make AVAudioEngine capture from a specific
    /// CoreAudio device on macOS; it must be done before the format is read.
    private func bindPreferredInputDevice(on input: AVAudioInputNode) {
        let uid = AppSettings.preferredInputDeviceUID
        guard !uid.isEmpty else { return }
        guard var deviceID = AudioInputDevice.deviceID(forUID: uid) else {
            Log.log("recorder: preferred input '\(uid)' not connected; using system default")
            return
        }
        let unit = input.audioUnit
        guard let unit else { return }
        let status = AudioUnitSetProperty(
            unit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &deviceID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        if status != noErr {
            Log.log("recorder: failed to bind input device \(deviceID) (status \(status)); using system default")
        }
    }

    /// Stops recording and returns the accumulated 16 kHz mono samples.
    func stop() -> [Float] {
        // Teardown touches the same graph start() does, so it can raise for the
        // same reasons. The samples are already captured and there is nothing
        // to recover, so log and carry on rather than aborting the process.
        _ = try? catchingNSException("engine teardown") {
            self.engine.inputNode.removeTap(onBus: 0)
            self.engine.stop()
        }
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
        // The bound is enforced here rather than by reacting to the callback
        // below, so memory stays capped even if the consumer never stops us.
        if samples.count < Self.maxSamples {
            samples.append(contentsOf: chunk)
        }
        let hitCap = samples.count >= Self.maxSamples && !didFireAutoStop
        if hitCap { didFireAutoStop = true }
        lock.unlock()
        updateLevel(chunk)
        if hitCap {
            Log.log("recorder: hit the \(Int(Self.maxRecordingSeconds / 60))-minute recording cap, stopping")
            onAutoStop?(.maxDuration)
        }
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
    /// `onAutoStop` once that exceeds `silenceAutoStopDuration`, after
    /// the grace period and skipped entirely when auto-stop is off (0).
    /// Runs on the audio thread, right after each level update. The
    /// shared-state check runs under `lock`; the callback itself is invoked
    /// after releasing it, both to avoid holding the (non-reentrant) lock
    /// during arbitrary consumer code and because `onAutoStop`'s own
    /// getter re-locks.
    private func checkSilenceAutoStop() {
        let shouldFire: Bool = {
            lock.lock()
            defer { lock.unlock() }
            guard silenceAutoStopDuration > 0, !didFireAutoStop,
                  let recordStartTime else { return false }
            let now = Date()
            guard now.timeIntervalSince(recordStartTime) >= Self.silenceGraceSeconds else { return false }

            guard smoothedLevel <= Self.silenceThreshold else {
                silenceStartTime = nil
                return false
            }
            let start = silenceStartTime ?? now
            silenceStartTime = start
            guard now.timeIntervalSince(start) >= silenceAutoStopDuration else { return false }
            didFireAutoStop = true
            return true
        }()
        if shouldFire {
            onAutoStop?(.silence)
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
