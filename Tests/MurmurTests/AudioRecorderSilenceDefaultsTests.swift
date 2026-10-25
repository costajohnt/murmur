import XCTest

/// `silenceStep` with its default grace and threshold, so the production
/// constants are pinned (the other silence tests pass their own).
final class AudioRecorderSilenceDefaultsTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    private func step(_ level: Float, at seconds: TimeInterval, _ silenceStart: Date?)
        -> (fire: Bool, silenceStart: Date?) {
        AudioRecorder.silenceStep(level: level, now: t0.addingTimeInterval(seconds), recordStart: t0,
                                  silenceStart: silenceStart, duration: 2)
    }

    func testGraceIsOneAndAHalfSeconds() {
        XCTAssertNil(step(0, at: 1.4, nil).silenceStart, "silence inside the grace period is not counted")
        let counted = step(0, at: 1.5, nil)
        XCTAssertEqual(counted.silenceStart, t0.addingTimeInterval(1.5))
        XCTAssertFalse(step(0, at: 3.4, counted.silenceStart).fire)
        XCTAssertTrue(step(0, at: 3.5, counted.silenceStart).fire, "grace plus the 2 s window")
    }

    func testThresholdIsFiveDbAboveTheFloor() {
        // 5 dB of the 40 dB meter range: 0.125.
        XCTAssertNotNil(step(0.12, at: 2, nil).silenceStart)
        XCTAssertNil(step(0.13, at: 2, nil).silenceStart)
    }
}
