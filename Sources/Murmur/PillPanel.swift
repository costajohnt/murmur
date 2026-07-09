import AppKit
import SwiftUI

// MARK: - Metrics

enum PillMetrics {
    /// Idle: tiny, empty, near-transparent — a barely-there lozenge.
    static let idleWidth: CGFloat = 40
    static let idleHeight: CGFloat = 10
    /// Every state is a translucent BLACK lozenge (no gray hudWindow frost) —
    /// idle is the most see-through; expanded is a touch more opaque so the
    /// meter and ✕/✓ read. Border stays near-invisible.
    static let idleTintOpacity: Double = 0.30
    static let idleBorderOpacity: Double = 0.05
    /// Extra horizontal slop added to the idle capsule's half-width when
    /// hit-testing a click — the thin/narrow idle pill needs a generous
    /// margin so it stays reliably clickable.
    static let idleHitSlop: CGFloat = 12
    /// Active (listening/processing): expands to ✕ | waveform | ✓.
    static let activeWidth: CGFloat = 150
    static let activeHeight: CGFloat = 32
    /// The panel itself stays a fixed size that fits both shapes (plus spring
    /// overshoot); the SwiftUI capsule animates inside it. Animating the
    /// NSPanel frame instead would fight the non-activating first-mouse setup.
    static let panelWidth: CGFloat = 170
    static let panelHeight: CGFloat = 44
    /// Hit-region width for the ✕ (left) and ✓ (right) ends of the active
    /// capsule; the middle (meter) is not a click target.
    static let buttonRegion: CGFloat = 44
    /// Diameter of the ✕ / ✓ circles.
    static let circleSize: CGFloat = 22
    static let bottomMargin: CGFloat = 18
}

// MARK: - State

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

final class PillState: ObservableObject {
    /// Number of bars in the listening-state level meter.
    static let historyLength = 7

    @Published var phase: PillPhase = .idle
    /// Live mic level 0..1 (dB-mapped, smoothed in AudioRecorder).
    @Published var audioLevel: Float = 0
    /// Rolling window of recent levels — the listening histogram, newest last.
    @Published var levelHistory: [Float] = Array(repeating: 0, count: PillState.historyLength)

    func pushLevel(_ level: Float) {
        // Ignore stragglers queued on main after recording stopped.
        guard phase == .listening else { return }
        audioLevel = level
        levelHistory.removeFirst()
        levelHistory.append(level)
    }

    func resetLevels() {
        audioLevel = 0
        levelHistory = Array(repeating: 0, count: Self.historyLength)
    }
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
        let size = NSSize(width: PillMetrics.panelWidth, height: PillMetrics.panelHeight)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false
        )
        // Above .statusBar deliberately: another always-on-top overlay (seen
        // with a competing dictation app) can keep an invisible-but-clickable
        // window at CGWindowLevel 1000 over bottom-center, which intercepted
        // clicks on our pill's right side (✓ button) when we sat at .statusBar.
        // One level above screensaver guarantees the pill wins the hit-test
        // whenever it's visible.
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
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
        // on the hosting view with LOCATION-BASED hit-testing (✕ left / ✓
        // right while active). The SwiftUI content stays purely visual — no
        // SwiftUI Button competing for (or swallowing) the first-mouse event,
        // which is the proven-with-real-clicks arrangement from Spike B.
        let click = NSClickGestureRecognizer(target: self, action: #selector(pillClicked(_:)))
        host.addGestureRecognizer(click)

        positionBottomCenter()

        // A4: the pill anchors to NSScreen.main. If the display config changes
        // (screen added/removed, resolution/arrangement change) the old main
        // screen — and the pill with it — can end up off-screen. Re-anchor to
        // the current main screen whenever the parameters change.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func screenParametersChanged(_ note: Notification) {
        Log.log("pill: screen parameters changed, repositioning to current main screen")
        positionBottomCenter()
    }

    @objc private func pillClicked(_ recognizer: NSClickGestureRecognizer) {
        guard let view = contentView else { return }
        let x = recognizer.location(in: view).x
        // Spike B evidence line kept for regression checks: at click time,
        // frontmost must be the user's app, NOT Murmur.
        let front = NSWorkspace.shared.frontmostApplication
        Log.log("PILL CLICK: x = \(Int(x)), frontmostApplication = \(front?.bundleIdentifier ?? "nil") (\(front?.localizedName ?? "nil"))")

        let mid = view.bounds.width / 2
        switch pillState.phase {
        case .idle:
            // Whole tiny capsule (plus a little slop) starts recording.
            if abs(x - mid) <= PillMetrics.idleWidth / 2 + PillMetrics.idleHitSlop {
                DictationCoordinator.shared.pillTapped()
            } else {
                Log.log("PILL CLICK: outside idle capsule, ignored")
            }
        case .listening:
            let capMinX = mid - PillMetrics.activeWidth / 2
            let capMaxX = mid + PillMetrics.activeWidth / 2
            if x >= capMinX - 4 && x < capMinX + PillMetrics.buttonRegion {
                Log.log("PILL CLICK: cancel (✕)")
                DictationCoordinator.shared.cancel()
            } else if x > capMaxX - PillMetrics.buttonRegion && x <= capMaxX + 4 {
                Log.log("PILL CLICK: confirm (✓)")
                DictationCoordinator.shared.pillTapped()
            } else {
                Log.log("PILL CLICK: center/outside region ignored while listening")
            }
        case .processing, .captured:
            Log.log("pipeline: click ignored (\(pillState.phase))")
        }
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

struct PillView: View {
    @ObservedObject var state: PillState

    /// Listening AND processing use the expanded shape; only idle is tiny.
    private var isExpanded: Bool { state.phase != .idle }

    var body: some View {
        ZStack {
            // Uniform translucent-BLACK fill for every state — no gray
            // hudWindow frost. Idle and expanded share the same styling.
            Capsule().fill(Color.black.opacity(tintOpacity))
            phaseContent
        }
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(borderOpacity), lineWidth: 1))
        .frame(
            width: isExpanded ? PillMetrics.activeWidth : PillMetrics.idleWidth,
            height: isExpanded ? PillMetrics.activeHeight : PillMetrics.idleHeight
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isExpanded)
        // Center the animating capsule in the fixed-size panel.
        .frame(width: PillMetrics.panelWidth, height: PillMetrics.panelHeight)
    }

    private var tintOpacity: Double {
        switch state.phase {
        case .idle: return PillMetrics.idleTintOpacity   // most see-through at rest
        case .listening: return 0.42
        case .processing: return 0.48
        case .captured: return 0.48
        }
    }

    /// Border softens at rest too, so the idle pill reads as a whisper of a
    /// shape rather than an outlined control.
    private var borderOpacity: Double {
        state.phase == .idle ? PillMetrics.idleBorderOpacity : 0.18
    }

    @ViewBuilder
    private var phaseContent: some View {
        switch state.phase {
        case .idle:
            // Intentionally empty: the idle pill is just a translucent
            // lozenge — no dots, no icons (John's call; if it proves too
            // invisible, add a whisper-faint indicator later).
            EmptyView()
        case .listening:
            ListeningControls(levels: state.levelHistory)
        case .processing:
            SweepDot()
        case .captured:
            CapturedCheck()
        }
    }
}

/// Active pill content: ✕ cancel (left, subtle dark circle) | live meter |
/// ✓ confirm (right, prominent white circle). The circles are VISUAL ONLY —
/// clicks are routed by the panel's location-based hit-test, so nothing here
/// competes for the first-mouse event.
private struct ListeningControls: View {
    let levels: [Float]

    var body: some View {
        HStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.14))
                    .frame(width: PillMetrics.circleSize, height: PillMetrics.circleSize)
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(0.9))
            }
            Spacer(minLength: 4)
            LevelMeterBars(levels: levels)
            Spacer(minLength: 4)
            ZStack {
                Circle()
                    .fill(Color.white)
                    .frame(width: PillMetrics.circleSize, height: PillMetrics.circleSize)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black)
            }
        }
        .padding(.horizontal, 5)
    }
}

// Idle / listening / processing are separate view identities so repeatForever
// animations are fully torn down on phase change (otherwise dots freeze
// mid-pulse — hit in v0).

/// Listening: a live rolling audio-level histogram — 7 thin vertical bars
/// whose heights follow the recent mic levels (newest on the right). Silence
/// = low flat bars; speech = bars rise. Levels are reset on stop, and the
/// phase change swaps this view out entirely, so no frozen bars.
private struct LevelMeterBars: View {
    let levels: [Float]

    private static let barWidth: CGFloat = 3
    private static let minHeight: CGFloat = 3
    private static let maxHeight: CGFloat = 16

    var body: some View {
        HStack(spacing: 4) {
            ForEach(levels.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.white.opacity(0.92))
                    .frame(
                        width: Self.barWidth,
                        height: Self.minHeight + CGFloat(levels[index]) * (Self.maxHeight - Self.minHeight)
                    )
            }
        }
        .animation(.linear(duration: 0.08), value: levels)
    }
}

/// Captured: a single checkmark that pops in and gently fades — "saved to
/// the vault, nothing more to do here" (there's no pasted text to look at,
/// so this is the only proof the capture worked). Own view identity like
/// SweepDot so the animation always starts clean on phase change.
private struct CapturedCheck: View {
    @State private var shown = false

    var body: some View {
        Image(systemName: "checkmark.circle.fill")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white.opacity(0.95))
            .scaleEffect(shown ? 1 : 0.6)
            .opacity(shown ? 1 : 0)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: shown)
            .onAppear { shown = true }
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
