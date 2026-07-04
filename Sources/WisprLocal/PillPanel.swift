import AppKit
import SwiftUI

/// Spike B: non-activating floating pill.
///
/// The entire point: clicking this panel must NOT steal keyboard focus from
/// the frontmost app. Config per docs/v0-spikes.md:
///   - styleMask [.nonactivatingPanel, .borderless]
///   - level .statusBar, isFloatingPanel, hidesOnDeactivate = false
///   - collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]
///   - canBecomeKey / canBecomeMain overridden to false
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    init() {
        let size = NSSize(width: 160, height: 44)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        isFloatingPanel = true
        hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = false

        contentView = NSHostingView(rootView: PillView())

        positionBottomCenter()
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + 24
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

struct PillView: View {
    @State private var clickCount = 0

    var body: some View {
        Button(action: pillClicked) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill")
                Text(clickCount == 0 ? "wispr" : "wispr (\(clickCount))")
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(Color.black.opacity(0.85)))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    private func pillClicked() {
        clickCount += 1
        // THE Spike B check: at click time, who is frontmost?
        // Must be the app the user was in (e.g. TextEdit), NOT WisprLocal.
        let front = NSWorkspace.shared.frontmostApplication
        let bundleId = front?.bundleIdentifier ?? "nil"
        let name = front?.localizedName ?? "nil"
        Log.log("SPIKE B CLICK: frontmostApplication = \(bundleId) (\(name))")
    }
}
