import Foundation

/// `WakeWordListener`'s start/stop bookkeeping, pure so the races (a start
/// still awaiting the engine when a pause or stop lands) are tested without
/// a mic. The listener performs the side effects each transition asks for.
struct WakeListenerState: Equatable {
    private(set) var running = false
    /// A `recorder.start()` is in flight. Starts are never overlapped on the
    /// one recorder; a stale start re-syncs via `apply()` when it lands.
    private(set) var starting = false
    /// Paused by the coordinator while a dictation owns the mic.
    private(set) var paused = false
    /// Bumped on every stop, so a start still awaiting the engine can tell it
    /// was cancelled meanwhile.
    private(set) var generation = 0

    /// What `apply()` should do: listen only when enabled and not paused.
    func shouldListen(enabled: Bool) -> Bool {
        enabled && !paused
    }

    mutating func pause() { paused = true }
    mutating func resume() { paused = false }

    /// nil when already listening or a start is in flight; otherwise the
    /// generation the new start belongs to.
    mutating func beginStart() -> Int? {
        guard !running, !starting else { return nil }
        starting = true
        return generation
    }

    /// Returns whether the mic was open and must be closed.
    mutating func stop() -> Bool {
        generation += 1
        guard running else { return false }
        running = false
        return true
    }

    enum Settled: Equatable {
        case current
        /// A pause/stop ran while the engine was starting: shut it if it
        /// opened, then follow whatever is wanted now.
        case stale
    }

    /// `recorder.start()` returned for the start begun at `generation`.
    mutating func started(generation startGeneration: Int) -> Settled {
        starting = false
        guard generation == startGeneration else { return .stale }
        running = true
        return .current
    }

    /// `recorder.start()` threw for the start begun at `generation`.
    mutating func failed(generation startGeneration: Int) -> Settled {
        starting = false
        return generation == startGeneration ? .current : .stale
    }
}
