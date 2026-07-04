import AppKit
import SwiftUI

// MARK: - Metrics

enum PillMetrics {
    /// Wispr Flow-style lozenge: distinctly wider than tall.
    static let width: CGFloat = 120
    static let height: CGFloat = 26
    static let bottomMargin: CGFloat = 24
}

// MARK: - State

final class PillState: ObservableObject {
    @Published var isListening = false
}

// MARK: - Hosting view (first-mouse fix)

/// The pill lives in a `.nonactivatingPanel` that never becomes key, so every
/// real click is a "first mouse" event. AppKit drops those unless the hit view
/// returns `acceptsFirstMouse == true` — which is why human clicks did nothing
/// while the CGEvent-driven Spike B test fired. This subclass opts in.
final class PillHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// MARK: - Panel

/// Spike B: non-activating floating pill.
///
/// Clicking this panel must NOT steal keyboard focus from the frontmost app:
///   - styleMask [.nonactivatingPanel, .borderless]
///   - level .statusBar, isFloatingPanel, hidesOnDeactivate = false
///   - collectionBehavior [.canJoinAllSpaces, .fullScreenAuxiliary]
///   - canBecomeKey / canBecomeMain overridden to false
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private let pillState = PillState()

    init() {
        let size = NSSize(width: PillMetrics.width, height: PillMetrics.height)
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

        let host = PillHostingView(rootView: PillView(state: pillState))
        host.frame = NSRect(origin: .zero, size: size)
        contentView = host

        // Single canonical click path at the AppKit layer: a gesture recognizer
        // on the hosting view. The SwiftUI content is purely visual, so there is
        // no SwiftUI Button competing for (or swallowing) the first-mouse event.
        let click = NSClickGestureRecognizer(target: self, action: #selector(pillClicked))
        host.addGestureRecognizer(click)

        positionBottomCenter()
    }

    @objc private func pillClicked() {
        pillState.isListening.toggle()
        // THE Spike B check: at click time, who is frontmost?
        // Must be the app the user was in (e.g. TextEdit), NOT WisprLocal.
        let front = NSWorkspace.shared.frontmostApplication
        let bundleId = front?.bundleIdentifier ?? "nil"
        let name = front?.localizedName ?? "nil"
        Log.log("SPIKE B CLICK: frontmostApplication = \(bundleId) (\(name)) — pill state: \(pillState.isListening ? "listening" : "idle")")
    }

    private func positionBottomCenter() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        let x = visible.midX - frame.width / 2
        let y = visible.minY + PillMetrics.bottomMargin
        setFrameOrigin(NSPoint(x: x, y: y))
    }
}

// MARK: - Views

/// Real behind-window blur for the capsule background (not just opacity).
private struct VisualEffectBlur: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct PillView: View {
    @ObservedObject var state: PillState

    var body: some View {
        ZStack {
            VisualEffectBlur()
            // Dark tint over the blur; lightens a touch while listening.
            Capsule().fill(Color.black.opacity(state.isListening ? 0.20 : 0.35))
            RestingDots(listening: state.isListening)
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .frame(width: PillMetrics.width, height: PillMetrics.height)
        .contentShape(Capsule())
    }
}

/// Idle: a subtle row of faint dots. Listening: the dots pulse in a staggered
/// bounce and brighten — the obvious click feedback / v1 state preview.
/// Idle and listening are separate view identities so the repeatForever
/// animation is fully torn down on toggle (otherwise dots freeze mid-pulse).
private struct RestingDots: View {
    let listening: Bool

    var body: some View {
        if listening {
            PulsingDots()
        } else {
            StaticDots()
        }
    }
}

private struct StaticDots: View {
    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { _ in
                Circle()
                    .fill(Color.white.opacity(0.45))
                    .frame(width: 4, height: 4)
            }
        }
    }
}

private struct PulsingDots: View {
    @State private var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<4, id: \.self) { index in
                Circle()
                    .fill(Color.white.opacity(0.95))
                    .frame(width: 4, height: 4)
                    .scaleEffect(pulsing ? 1.9 : 1.0)
                    .animation(
                        .easeInOut(duration: 0.45)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.12),
                        value: pulsing
                    )
            }
        }
        .onAppear { pulsing = true }
    }
}
