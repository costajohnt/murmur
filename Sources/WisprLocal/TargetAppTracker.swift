import AppKit

/// Tracks the app the user is actually working in.
///
/// v0 lesson: `NSWorkspace.frontmostApplication` reads stale inside an idle
/// background app at event-delivery time. So instead of point-in-time reads,
/// we subscribe to `didActivateApplicationNotification` and remember the last
/// activated app that isn't us. The dictation pipeline snapshots this at
/// record-start and injects into it explicitly.
final class TargetAppTracker {
    static let shared = TargetAppTracker()

    private(set) var lastActiveApp: NSRunningApplication?

    private init() {
        // Seed with the current frontmost app (accurate at launch time, before
        // we've gone idle) unless it's us.
        if let front = NSWorkspace.shared.frontmostApplication,
           front.bundleIdentifier != Bundle.main.bundleIdentifier {
            lastActiveApp = front
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            if app.bundleIdentifier == Bundle.main.bundleIdentifier { return }
            self?.lastActiveApp = app
        }
    }
}
