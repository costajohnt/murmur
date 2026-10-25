import Foundation

/// When the wake listener should try the mic again after `recorder.start()`
/// threw. A route change (AirPods connecting) restarts the listener while
/// the new device can still report a 0 Hz format or fail to bind; without a
/// retry the always-on mic stayed off until the next Settings change or
/// dictation. Pure, so the policy is tested without audio.
enum WakeRetry {
    /// Waits before each retry; one entry per retry.
    static let delays: [TimeInterval] = [2, 5]

    /// Seconds to wait before retry number `attempt` (0-based), or nil to
    /// give up and report the wake word off.
    /// Only a denied mic and a missing converter are permanent; anything
    /// else (including AVAudioEngine's own NSError from `engine.start()`) is
    /// treated as a device still settling.
    static func delay(after error: Error, attempt: Int) -> TimeInterval? {
        guard attempt < delays.count else { return nil }
        switch error as? AudioRecorder.RecorderError {
        case .micDenied, .converterUnavailable: return nil
        case .deviceNotReady, .engineFailed, nil: return delays[attempt]
        }
    }
}
