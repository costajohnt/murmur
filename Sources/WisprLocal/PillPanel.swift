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

enum PillPhase {
    case idle
    case listening
    case processing
}

final class PillState: ObservableObject {
    @Published var phase: PillPhase = .idle
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

    private let pillState = DictationCoordinator.shared.pillState

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
        // Spike B evidence line kept for regression checks: at click time,
        // frontmost must be the user's app, NOT WisprLocal.
        let front = NSWorkspace.shared.frontmostApplication
        Log.log("PILL CLICK: frontmostApplication = \(front?.bundleIdentifier ?? "nil") (\(front?.localizedName ?? "nil"))")
        DictationCoordinator.shared.pillTapped()
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
            // Dark tint over the blur; lightens a touch while active.
            Capsule().fill(Color.black.opacity(tintOpacity))
            phaseContent
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        .frame(width: PillMetrics.width, height: PillMetrics.height)
        .contentShape(Capsule())
    }

    private var tintOpacity: Double {
        switch state.phase {
        case .idle: return 0.35
        case .listening: return 0.20
        case .processing: return 0.28
        }
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .idle:
            StaticDots()
        case .listening:
            PulsingDots()
        case .processing:
            SweepDot()
        }
    }
}

// Idle / listening / processing are separate view identities so repeatForever
// animations are fully torn down on phase change (otherwise dots freeze
// mid-pulse — hit in v0).

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

/// Processing: a single bright dot sweeping side to side (distinct from the
/// pulsing row) — "working on it".
private struct SweepDot: View {
    @State private var sweeping = false

    var body: some View {
        Circle()
            .fill(Color.white.opacity(0.9))
            .frame(width: 5, height: 5)
            .offset(x: sweeping ? 16 : -16)
            .animation(
                .easeInOut(duration: 0.5).repeatForever(autoreverses: true),
                value: sweeping
            )
            .onAppear { sweeping = true }
    }
}
