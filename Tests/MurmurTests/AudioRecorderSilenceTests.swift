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

    private func track(_ level: Float, _ floor: AudioRecorder.NoiseFloor?, _ elapsed: TimeInterval)
        -> AudioRecorder.NoiseFloor {
        AudioRecorder.trackNoiseFloor(level: level, floor: floor, elapsed: elapsed)
    }

    func testFloorFollowsASustainedLowerLevelAfterTheHold() {
        var floor = AudioRecorder.NoiseFloor(level: 0.3)
        for _ in 0..<29 { floor = track(0.1, floor, 0.033) }
        XCTAssertEqual(floor.level, 0.3, "under the 1 s hold: not yet")
        for _ in 0..<2 { floor = track(0.1, floor, 0.033) }
        XCTAssertEqual(floor.level, 0.1, "past the hold the floor drops to the quieter level")
    }

    /// A mic mute, a Bluetooth handoff or a hand over the mic drives the level
    /// to the bottom of the meter for well under a second. That must not
    /// erase the floor, or the room tone after it reads as speech until the
    /// floor climbs back at 1 dB/s.
    func testSubSecondDropoutLeavesTheFloorAlone() {
        let room = level(-34)
        var floor = AudioRecorder.NoiseFloor(level: room)
        for _ in 0..<27 { floor = track(0, floor, 0.033) }  // ~0.9 s of nothing
        XCTAssertEqual(floor.level, room)
        floor = track(room, floor, 0.033)
        for _ in 0..<27 { floor = track(0, floor, 0.033) }  // a second dropout right after
        XCTAssertEqual(floor.level, room, "the hold restarts once the level is back")
    }

    func testFloorRisesOnlySlowly() {
        let floor = track(0.9, AudioRecorder.NoiseFloor(level: 0.2), 1.0)
        XCTAssertEqual(floor.level, 0.2 + AudioRecorder.noiseFloorRisePerSecond, accuracy: 1e-6,
                       "one second of speech lifts the floor by the rise rate, not to the speech level")
    }

    func testFirstLevelSeedsTheFloor() {
        XCTAssertEqual(track(0.4, nil, 0.033).level, 0.4)
    }

    func testFloorIsCapped() {
        XCTAssertEqual(track(1, nil, 0.033).level, AudioRecorder.maxNoiseFloor)
        XCTAssertEqual(track(1, AudioRecorder.NoiseFloor(level: AudioRecorder.maxNoiseFloor), 60).level,
                       AudioRecorder.maxNoiseFloor)
    }

    /// At the cap, silence must still sit well under speech: at least 6 dB
    /// under the -15 dBFS speech level the #82 test uses, while still above
    /// the #82 room tone (about -28 dBFS at its loudest).
    func testCapThresholdStaysWellUnderSpeech() {
        let threshold = AudioRecorder.silenceThreshold(noiseFloor: AudioRecorder.maxNoiseFloor)
        XCTAssertLessThanOrEqual(threshold, level(-21) + 1e-6)
        XCTAssertGreaterThan(threshold, level(-28))
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
        var floor: AudioRecorder.NoiseFloor?
        var adaptive: (fire: Bool, silenceStart: Date?) = (false, nil)
        var fixed: (fire: Bool, silenceStart: Date?) = (false, nil)
        var firedAt: TimeInterval?
        for i in 0..<300 {
            let t = Double(i) * chunk
            // 3 s of speech (-15 dB with gaps of room tone), then room tone.
            let speaking = t < 3 && i % 4 != 3
            let lvl = level(speaking ? -15 : -30.6 + jitter[i % jitter.count])
            floor = track(lvl, floor, chunk)
            let now = t0.addingTimeInterval(t)
            adaptive = AudioRecorder.silenceStep(level: lvl, now: now, recordStart: t0,
                                                 silenceStart: adaptive.silenceStart, duration: 10,
                                                 threshold: AudioRecorder.silenceThreshold(noiseFloor: floor!.level))
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
