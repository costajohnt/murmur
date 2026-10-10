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
