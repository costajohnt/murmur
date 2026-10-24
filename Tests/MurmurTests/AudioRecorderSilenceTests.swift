import XCTest

/// Silence auto-stop decision, driven with explicit times: no engine, no clock.
final class AudioRecorderSilenceTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)
    private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
    private let quiet: Float = 0
    private let loud: Float = 1

    private func step(_ level: Float, _ now: TimeInterval, _ silenceStart: Date?, duration: TimeInterval = 2)
        -> (fire: Bool, silenceStart: Date?) {
        AudioRecorder.silenceStep(level: level, now: at(now), recordStart: t0,
                                  silenceStart: silenceStart, duration: duration, grace: 1.5, threshold: 0.1)
    }

    func testNothingHappensInsideTheGracePeriod() {
        let r = step(quiet, 1.0, nil)
        XCTAssertFalse(r.fire)
        XCTAssertNil(r.silenceStart, "silence before the grace period ends is not counted")
    }

    func testSilenceAccumulatesThenFires() {
        var r = step(quiet, 2.0, nil)
        XCTAssertFalse(r.fire)
        XCTAssertEqual(r.silenceStart, at(2.0))
        r = step(quiet, 3.5, r.silenceStart)
        XCTAssertFalse(r.fire, "1.5 s of a 2 s window")
        r = step(quiet, 4.0, r.silenceStart)
        XCTAssertTrue(r.fire)
    }

    func testLoudAudioResetsAccumulatedSilence() {
        var r = step(quiet, 2.0, nil)
        r = step(loud, 3.9, r.silenceStart)
        XCTAssertFalse(r.fire)
        XCTAssertNil(r.silenceStart)
        r = step(quiet, 4.0, r.silenceStart)
        XCTAssertFalse(r.fire, "the silence window restarts after speech")
        XCTAssertEqual(r.silenceStart, at(4.0))
    }

    func testDisabledAtZeroDuration() {
        XCTAssertFalse(step(quiet, 100, at(2), duration: 0).fire)
    }
}

/// Silence relative to the measured noise floor (#82): a fixed -45 dBFS cutoff
/// never fires in a room whose tone sits above it.
final class AudioRecorderNoiseFloorTests: XCTestCase {
    /// Same dB -> 0..1 mapping as the recorder's level meter.
    private func level(_ db: Float) -> Float { (db + 50) / 40 }

    func testFloorFollowsALowerLevelImmediately() {
        XCTAssertEqual(AudioRecorder.trackNoiseFloor(level: 0.3, floor: 0.5, elapsed: 0.033), 0.3)
    }

    func testFloorRisesOnlySlowly() {
        let floor = AudioRecorder.trackNoiseFloor(level: 0.9, floor: 0.2, elapsed: 1.0)
        XCTAssertEqual(floor, 0.2 + AudioRecorder.noiseFloorRisePerSecond, accuracy: 1e-6,
                       "one second of speech lifts the floor by the rise rate, not to the speech level")
    }

    func testFirstLevelSeedsTheFloor() {
        XCTAssertEqual(AudioRecorder.trackNoiseFloor(level: 0.4, floor: nil, elapsed: 0.033), 0.4)
    }

    func testFloorIsCapped() {
        XCTAssertEqual(AudioRecorder.trackNoiseFloor(level: 1, floor: nil, elapsed: 0.033), AudioRecorder.maxNoiseFloor)
        XCTAssertEqual(AudioRecorder.trackNoiseFloor(level: 1, floor: AudioRecorder.maxNoiseFloor, elapsed: 60),
                       AudioRecorder.maxNoiseFloor)
    }

    /// Floor at the bottom of the meter (-50 dB or quieter): silence is
    /// anything up to -42 dB, still far under speech.
    func testQuietRoomThresholdNeverDropsBelowTheFixedCutoff() {
        let threshold = AudioRecorder.silenceThreshold(noiseFloor: 0)
        XCTAssertGreaterThanOrEqual(threshold, AudioRecorder.fixedSilenceThreshold)
        XCTAssertEqual(threshold, level(-42), accuracy: 1e-6)
    }

    func testNoisyRoomRaisesTheThresholdAboveTheFloor() {
        let floor = level(-34)
        XCTAssertEqual(AudioRecorder.silenceThreshold(noiseFloor: floor),
                       floor + AudioRecorder.silenceMarginAboveFloor, accuracy: 1e-6)
    }

    /// The #82 room: tone around -30.6 dB with a few dB of jitter, after a
    /// sentence of speech. The fixed threshold never starts the silence timer;
    /// the floor-relative one fires once the silence window has passed.
    func testRoomToneAboveTheFixedCutoffStillAutoStops() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        let chunk: TimeInterval = 0.1
        let jitter: [Float] = [-2.5, 1.5, -1, 2.5, 0, -2, 1, 2, -1.5, 0.5]
        var floor: Float?
        var adaptive: (fire: Bool, silenceStart: Date?) = (false, nil)
        var fixed: (fire: Bool, silenceStart: Date?) = (false, nil)
        var firedAt: TimeInterval?
        for i in 0..<300 {
            let t = Double(i) * chunk
            // 3 s of speech (-15 dB with gaps of room tone), then room tone.
            let speaking = t < 3 && i % 4 != 3
            let lvl = level(speaking ? -15 : -30.6 + jitter[i % jitter.count])
            floor = AudioRecorder.trackNoiseFloor(level: lvl, floor: floor, elapsed: chunk)
            let now = t0.addingTimeInterval(t)
            adaptive = AudioRecorder.silenceStep(level: lvl, now: now, recordStart: t0,
                                                 silenceStart: adaptive.silenceStart, duration: 10,
                                                 threshold: AudioRecorder.silenceThreshold(noiseFloor: floor!))
            if adaptive.fire, firedAt == nil { firedAt = t }
            fixed = AudioRecorder.silenceStep(level: lvl, now: now, recordStart: t0,
                                              silenceStart: fixed.silenceStart, duration: 10,
                                              threshold: AudioRecorder.fixedSilenceThreshold)
            XCTAssertFalse(fixed.fire, "the old fixed cutoff never fires in this room")
            XCTAssertFalse(speaking && adaptive.silenceStart != nil, "speech must not count as silence")
        }
        let fired = try? XCTUnwrap(firedAt)
        XCTAssertNotNil(fired, "floor-relative silence must auto-stop")
        XCTAssertLessThan(fired ?? .infinity, 14, "within the 10 s window after speech ends, plus slack")
    }
}
