import Foundation

enum PillPhase {
    case idle
    case listening
    case processing
    /// Brief post-processing confirmation that a "note to self" dictation
    /// was captured to the vault instead of pasted — pasting has the pasted
    /// text itself as visible proof it worked; a vault capture has nothing
    /// to look at, so this state exists purely to give that same "it
    /// worked" signal. Mirrors `.processing`'s SweepDot: shown briefly, then
    /// DictationCoordinator returns the pill to `.idle`.
    case captured
}

/// The decisions behind `DictationCoordinator`'s entry points (tap,
/// push-to-talk, wake word, cancel, auto-stop, send word), split out pure so
/// they are tested without a mic, a model or the pill. The coordinator owns
/// the side effects.
enum DictationControl {
    enum TapAction: Equatable { case start, stop, ignore }

    /// A click on the pill. Clicks while the pipeline runs or the capture
    /// confirmation is showing are ignored; both return to idle on their own.
    static func tap(phase: PillPhase) -> TapAction {
        switch phase {
        case .idle: return .start
        case .listening: return .stop
        case .processing, .captured: return .ignore
        }
    }

    enum ReleaseAction: Equatable { case stopWhenStarted, stop, none }

    /// Push-to-talk key up: stop if listening; if still starting, stop once
    /// the engine is running.
    static func pushToTalkRelease(phase: PillPhase, isStarting: Bool) -> ReleaseAction {
        if isStarting { return .stopWhenStarted }
        return phase == .listening ? .stop : .none
    }

    /// The wake phrase starts a dictation only from a settled idle pill.
    static func wakeCanStart(phase: PillPhase, isStarting: Bool) -> Bool {
        phase == .idle && !isStarting
    }

    /// Cancel and auto-stop act only on a listening pill: a manual stop or
    /// cancel has already moved the phase on, so neither can fire twice.
    static func canStop(phase: PillPhase) -> Bool {
        phase == .listening
    }

    /// Under ~0.3 s of audio is a stray double-click, not speech.
    static func isSpeechLength(_ sampleCount: Int) -> Bool {
        sampleCount > Int(AudioRecorder.sampleRate * 0.3)
    }

    /// Start a send-word check on this pause: one at a time, and never one
    /// that would trigger a model load.
    static func shouldCheckSendWord(phase: PillPhase, checking: Bool, asrReady: Bool) -> Bool {
        phase == .listening && !checking && asrReady
    }

    /// The check's transcript came back: cut there only if the same
    /// recording is still running and what was said ends with the send word.
    static func sendWordCuts(_ transcript: String, sendWord: String, phase: PillPhase, sameRecording: Bool) -> Bool {
        phase == .listening && sameRecording
            && VoiceCommands.stripSendWord(from: transcript, sendWord: sendWord) != nil
    }

    /// `keeping`: process only the first N samples (the send word cut).
    static func samplesToProcess(_ recorded: [Float], keeping: Int?) -> [Float] {
        keeping.map { Array(recorded.prefix($0)) } ?? recorded
    }
}
