import XCTest

final class DictationControlTests: XCTestCase {
    func testTapStartsStopsOrIgnores() {
        XCTAssertEqual(DictationControl.tap(phase: .idle), .start)
        XCTAssertEqual(DictationControl.tap(phase: .listening), .stop)
        XCTAssertEqual(DictationControl.tap(phase: .processing), .ignore)
        XCTAssertEqual(DictationControl.tap(phase: .captured), .ignore)
    }

    /// Key up before the engine runs must still stop, once it does.
    func testPushToTalkReleaseWhileStartingDefersTheStop() {
        XCTAssertEqual(DictationControl.pushToTalkRelease(phase: .idle, isStarting: true), .stopWhenStarted)
        XCTAssertEqual(DictationControl.pushToTalkRelease(phase: .listening, isStarting: false), .stop)
        XCTAssertEqual(DictationControl.pushToTalkRelease(phase: .idle, isStarting: false), .none)
        XCTAssertEqual(DictationControl.pushToTalkRelease(phase: .processing, isStarting: false), .none)
    }

    func testWakeWordStartsOnlyFromASettledIdlePill() {
        XCTAssertTrue(DictationControl.wakeCanStart(phase: .idle, isStarting: false))
        XCTAssertFalse(DictationControl.wakeCanStart(phase: .idle, isStarting: true))
        XCTAssertFalse(DictationControl.wakeCanStart(phase: .listening, isStarting: false))
        XCTAssertFalse(DictationControl.wakeCanStart(phase: .processing, isStarting: false))
    }

    /// Cancel and auto-stop after a manual stop (phase already .processing)
    /// are no-ops, so neither runs twice.
    func testCancelAndAutoStopOnlyWhileListening() {
        XCTAssertTrue(DictationControl.canStop(phase: .listening))
        for phase in [PillPhase.idle, .processing, .captured] {
            XCTAssertFalse(DictationControl.canStop(phase: phase), "\(phase)")
        }
    }

    func testSpeechLengthThreshold() {
        XCTAssertFalse(DictationControl.isSpeechLength(4_800)) // exactly 0.3 s
        XCTAssertTrue(DictationControl.isSpeechLength(4_801))
    }

    func testSendWordCheckIsOneAtATimeAndNeverLoadsTheModel() {
        XCTAssertTrue(DictationControl.shouldCheckSendWord(phase: .listening, checking: false, asrReady: true))
        XCTAssertFalse(DictationControl.shouldCheckSendWord(phase: .listening, checking: true, asrReady: true))
        XCTAssertFalse(DictationControl.shouldCheckSendWord(phase: .listening, checking: false, asrReady: false))
        XCTAssertFalse(DictationControl.shouldCheckSendWord(phase: .processing, checking: false, asrReady: true))
    }

    func testSendWordCutNeedsTheSameLiveRecordingAndATrailingSendWord() {
        XCTAssertTrue(DictationControl.sendWordCuts("run the tests, send", sendWord: "send", phase: .listening, sameRecording: true))
        XCTAssertFalse(DictationControl.sendWordCuts("send the report", sendWord: "send", phase: .listening, sameRecording: true))
        // A manual stop or cancel landed while the check transcribed.
        XCTAssertFalse(DictationControl.sendWordCuts("run it, send", sendWord: "send", phase: .processing, sameRecording: true))
        XCTAssertFalse(DictationControl.sendWordCuts("run it, send", sendWord: "send", phase: .idle, sameRecording: true))
        // A new recording started since: the transcript belongs to the old one.
        XCTAssertFalse(DictationControl.sendWordCuts("run it, send", sendWord: "send", phase: .listening, sameRecording: false))
    }

    func testSendWordCutKeepsOnlyTheAudioUpToTheCheck() {
        let recorded: [Float] = [1, 2, 3, 4, 5]
        XCTAssertEqual(DictationControl.samplesToProcess(recorded, keeping: 3), [1, 2, 3])
        XCTAssertEqual(DictationControl.samplesToProcess(recorded, keeping: nil), recorded)
        XCTAssertEqual(DictationControl.samplesToProcess(recorded, keeping: 9), recorded)
    }
}

final class WakeListenerStateTests: XCTestCase {
    func testListensOnlyWhenEnabledAndNotPaused() {
        var s = WakeListenerState()
        XCTAssertTrue(s.shouldListen(enabled: true))
        XCTAssertFalse(s.shouldListen(enabled: false))
        s.pause()
        XCTAssertFalse(s.shouldListen(enabled: true))
        s.resume()
        XCTAssertTrue(s.shouldListen(enabled: true))
    }

    func testStartsAreNeverOverlapped() {
        var s = WakeListenerState()
        XCTAssertEqual(s.beginStart(), 0)
        XCTAssertNil(s.beginStart(), "a start is in flight")
        XCTAssertEqual(s.started(generation: 0), .current)
        XCTAssertTrue(s.running)
        XCTAssertNil(s.beginStart(), "already listening")
    }

    func testPauseDuringStartMakesItStale() {
        var s = WakeListenerState()
        let g = s.beginStart()!
        s.pause()
        XCTAssertFalse(s.stop(), "mic not open yet")
        XCTAssertEqual(s.started(generation: g), .stale)
        XCTAssertFalse(s.running, "a stale start must not count as listening")
        XCTAssertFalse(s.starting)
    }

    /// A pause and resume while the engine starts: the stale start re-syncs,
    /// and the next start can begin.
    func testPauseResumeDuringStartAllowsANewStartAfterIt() {
        var s = WakeListenerState()
        let g = s.beginStart()!
        s.pause(); _ = s.stop()
        s.resume()
        XCTAssertNil(s.beginStart(), "the first start is still in flight")
        XCTAssertEqual(s.started(generation: g), .stale)
        XCTAssertEqual(s.beginStart(), 1)
    }

    func testStopClosesTheMicOnlyWhenRunning() {
        var s = WakeListenerState()
        _ = s.started(generation: s.beginStart()!)
        XCTAssertTrue(s.stop())
        XCTAssertFalse(s.running)
        XCTAssertFalse(s.stop())
        XCTAssertEqual(s.generation, 2)
    }

    func testFailureIsReportedOnlyForTheCurrentStart() {
        var s = WakeListenerState()
        var g = s.beginStart()!
        XCTAssertEqual(s.failed(generation: g), .current)
        XCTAssertFalse(s.starting)
        g = s.beginStart()!
        _ = s.stop()
        XCTAssertEqual(s.failed(generation: g), .stale)
        XCTAssertFalse(s.running)
    }
}

extension DictationControlTests {
    /// Audit H1: the Accessibility guidance re-fires after a failed paste,
    /// throttled, instead of once per app session.
    func testSetupAutoOpenRefiresAfterCooldown() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertTrue(DictationControl.shouldAutoOpenSetup(lastOpened: nil, now: t0))
        XCTAssertFalse(DictationControl.shouldAutoOpenSetup(lastOpened: t0, now: t0.addingTimeInterval(60)))
        XCTAssertTrue(DictationControl.shouldAutoOpenSetup(lastOpened: t0, now: t0.addingTimeInterval(DictationControl.setupAutoOpenCooldown)))
    }
}
