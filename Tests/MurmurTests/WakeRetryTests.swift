import XCTest

final class WakeRetryTests: XCTestCase {
    func testDeviceNotReadyRetriesTwiceThenGivesUp() {
        let error = AudioRecorder.RecorderError.deviceNotReady
        XCTAssertEqual(WakeRetry.delay(after: error, attempt: 0), 2)
        XCTAssertEqual(WakeRetry.delay(after: error, attempt: 1), 5)
        XCTAssertNil(WakeRetry.delay(after: error, attempt: 2))
    }

    func testEngineFailureRetries() {
        let error = AudioRecorder.RecorderError.engineFailed(step: "start", reason: "busy")
        XCTAssertEqual(WakeRetry.delay(after: error, attempt: 0), 2)
    }

    /// Retrying cannot fix these: report the wake word off right away.
    func testPermanentFailuresDoNotRetry() {
        XCTAssertNil(WakeRetry.delay(after: AudioRecorder.RecorderError.micDenied, attempt: 0))
        XCTAssertNil(WakeRetry.delay(after: AudioRecorder.RecorderError.converterUnavailable, attempt: 0))
        XCTAssertNil(WakeRetry.delay(after: URLError(.unknown), attempt: 0))
    }
}
