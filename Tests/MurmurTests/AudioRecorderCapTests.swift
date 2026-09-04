import XCTest

/// The 15-minute recording cap is enforced per converted chunk, so the only
/// promises worth holding are: the buffer stops growing at the cap, it can
/// overshoot by at most one chunk, and the auto-stop fires exactly once.
/// Pure function, tiny cap: no engine, no clock.
final class AudioRecorderCapTests: XCTestCase {
    private func chunk(_ n: Int) -> [Float] { [Float](repeating: 0.5, count: n) }

    func testFiresWhenTheCapIsReachedExactly() {
        var samples: [Float] = []
        var didFire = false

        XCTAssertFalse(AudioRecorder.append(chunk(4), to: &samples, cap: 8, didFireAutoStop: &didFire))
        XCTAssertEqual(samples.count, 4)
        XCTAssertFalse(didFire)

        XCTAssertTrue(AudioRecorder.append(chunk(4), to: &samples, cap: 8, didFireAutoStop: &didFire))
        XCTAssertEqual(samples.count, 8, "reaching the cap exactly keeps the whole chunk")
        XCTAssertTrue(didFire)
    }

    func testOvershootsByAtMostOneChunk() {
        var samples: [Float] = []
        var didFire = false
        let cap = 10

        XCTAssertFalse(AudioRecorder.append(chunk(4), to: &samples, cap: cap, didFireAutoStop: &didFire))
        XCTAssertFalse(AudioRecorder.append(chunk(4), to: &samples, cap: cap, didFireAutoStop: &didFire))
        XCTAssertEqual(samples.count, 8)

        XCTAssertTrue(AudioRecorder.append(chunk(4), to: &samples, cap: cap, didFireAutoStop: &didFire))
        XCTAssertEqual(samples.count, 12, "the chunk that crosses the cap is kept whole")
        XCTAssertLessThanOrEqual(samples.count - cap, 4, "overshoot is bounded by one chunk")

        XCTAssertFalse(AudioRecorder.append(chunk(4), to: &samples, cap: cap, didFireAutoStop: &didFire))
        XCTAssertEqual(samples.count, 12, "nothing is appended once the cap is reached")
    }

    func testFiresOnlyOnce() {
        var samples: [Float] = []
        var didFire = false

        XCTAssertTrue(AudioRecorder.append(chunk(8), to: &samples, cap: 8, didFireAutoStop: &didFire))
        for _ in 0..<3 {
            XCTAssertFalse(AudioRecorder.append(chunk(8), to: &samples, cap: 8, didFireAutoStop: &didFire))
        }
        XCTAssertEqual(samples.count, 8)
        XCTAssertTrue(didFire)
    }

    /// The silence auto-stop shares the once-latch: if it already fired, the
    /// cap must not fire a second auto-stop for the same recording.
    func testDoesNotFireWhenAnotherAutoStopAlreadyDid() {
        var samples: [Float] = []
        var didFire = true

        XCTAssertFalse(AudioRecorder.append(chunk(8), to: &samples, cap: 8, didFireAutoStop: &didFire))
        XCTAssertEqual(samples.count, 8, "the buffer still fills up to the cap")
    }
}
