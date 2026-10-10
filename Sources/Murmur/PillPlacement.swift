import AppKit

/// Pure pill-placement math, split out of PillPanel so the hostless test
/// bundle can check it without NSScreen.
enum PillPlacement {
    /// Bottom-center origin for a panel of `size` on the screen containing
    /// `mouse` (NSEvent.mouseLocation coordinates), falling back to `main`.
    /// `screens` pairs each screen's frame with its visible frame. Returns nil
    /// only when there is no screen at all.
    static func origin(
        size: CGSize,
        mouse: CGPoint,
        screens: [(frame: CGRect, visibleFrame: CGRect)],
        main: CGRect?,
        bottomMargin: CGFloat
    ) -> CGPoint? {
        // NSMouseInRect, not CGRect.contains: the pointer on a screen's top
        // row reports y == frame.maxY, which contains() would reject.
        let hit = screens.first { NSMouseInRect(mouse, $0.frame, false) }?.visibleFrame
        guard let visible = hit ?? main else { return nil }
        return CGPoint(x: visible.midX - size.width / 2, y: visible.minY + bottomMargin)
    }
}
