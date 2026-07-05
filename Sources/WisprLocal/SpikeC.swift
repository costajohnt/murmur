#if DEBUG
import AppKit

/// Spike C (kept as a debug menu item): paste-inject a fixed string.
/// The actual injection logic lives in `TextInjector` (used by the v1
/// pipeline and the history window).
enum SpikeC {
    static let payload = "hello from wispr-local"

    /// Waits 3 seconds so the user can put the target app frontmost.
    static func run() {
        Log.log("SPIKE C: armed — injecting in 3s; focus the target app now")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil"
            Log.log("SPIKE C: injecting into frontmost = \(front)")
            TextInjector.inject(payload) { ok, error in
                Log.log("SPIKE C result: \(ok ? "ok (clipboard restored)" : "FAILED: \(error ?? "?")")")
            }
        }
    }
}
#endif
