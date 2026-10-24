import AVFoundation
import XCTest

/// Tap-format choice and the configuration-change decision behind #57
/// (pinned built-in mic at 48 kHz, Bluetooth system default at 24 kHz). Pure
/// statics: no engine, no hardware.
final class AudioRecorderRouteTests: XCTestCase {
    private func format(_ rate: Double, _ channels: AVAudioChannelCount = 1) -> AVAudioFormat {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
    }

    // MARK: - Tap format

    /// The hardware side is what the tap must use. After binding the 48 kHz
    /// mic on a node materialized on the 24 kHz headset, the node's output
    /// side still reports 24 kHz, and a tap in that format raises.
    func testTapUsesTheHardwareFormatNotTheStaleOutputFormat() {
        let chosen = AudioRecorder.tapFormat(hardware: format(48_000))
        XCTAssertEqual(chosen?.sampleRate, 48_000)
        XCTAssertEqual(chosen?.channelCount, 1)
    }

    /// Mid A2DP to HFP handoff the hardware reports 0 Hz / 0 channels; that
    /// must never reach installTap.
    func testTransientInvalidHardwareFormatIsRejected() {
        let zeroRate = AVAudioFormat(streamDescription: &Self.zeroASBD)!
        XCTAssertNil(AudioRecorder.tapFormat(hardware: zeroRate))
    }

    /// Both rates in the #57 setup convert to the 16 kHz mono Parakeet input.
    func testConverterExistsForBothRatesInTheReportedSetup() {
        let recorder = AudioRecorder(accumulates: false)
        for rate in [24_000.0, 48_000.0] {
            XCTAssertNotNil(AVAudioConverter(from: format(rate), to: recorder.targetFormat), "\(rate) Hz")
        }
    }

    private static var zeroASBD = AudioStreamBasicDescription(
        mSampleRate: 0, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved,
        mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
        mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0
    )

    // MARK: - Configuration change

    private func action(_ state: AudioRecorder.RecordingState, fired: Bool = false,
                        sinceStart: TimeInterval? = 5, running: Bool = true)
        -> AudioRecorder.ConfigurationChangeAction {
        AudioRecorder.configurationChangeAction(state: state, didFireAutoStop: fired,
                                                secondsSinceEngineStart: sinceStart, engineRunning: running)
    }

    func testChangeWhileStartingIsTheEchoOfOurOwnBind() {
        XCTAssertEqual(action(.starting), .ignore)
    }

    func testChangeRightAfterStartWithTheEngineRunningKeepsRecording() {
        XCTAssertEqual(action(.recording, sinceStart: 0.3, running: true), .keepThroughStartEcho)
    }

    func testChangeRightAfterStartThatStoppedTheEngineStopsTheRecording() {
        XCTAssertEqual(action(.recording, sinceStart: 0.3, running: false), .stopRecording)
    }

    func testRouteChangeMidRecordingStopsTheRecording() {
        XCTAssertEqual(action(.recording, sinceStart: 5), .stopRecording)
    }

    func testOnlyOneAutoStopPerRecording() {
        XCTAssertEqual(action(.recording, fired: true), .ignore)
    }

    func testChangeWhileIdleResetsTheEngine() {
        XCTAssertEqual(action(.idle, sinceStart: nil, running: false), .resetEngine)
    }
}
