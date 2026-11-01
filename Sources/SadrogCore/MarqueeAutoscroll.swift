// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import CoreGraphics

/// The pure part of the rectangle selection's autoscroll (the timeline view calls it on every 1/30 s tick while the pointer is held near an edge): how far the
/// scroll offsets move, clamped to the content, and where the rectangle's moving corner lies in content coordinates afterwards.
public enum MarqueeAutoscroll {
    public static let edge: CGFloat = 28
    public struct Step: Equatable { public let offsetX: CGFloat, offsetY: CGFloat, corner: CGPoint }
    /// - pointer: the pointer in viewport coordinates (x from the left of the visible part, y from the top of the timeline view, ruler included).
    /// - viewW: visible width; contentW: full scrollable width; viewportH/contentH: visible and total height of the track area; rulerH: ruler height at the top.
    public static func step(pointer: CGPoint, viewW: CGFloat, contentW: CGFloat, viewportH: CGFloat, contentH: CGFloat, rulerH: CGFloat,
                            zoom: Double, offsetX: CGFloat, offsetY: CGFloat) -> Step {
        var dx: CGFloat = 0, dy: CGFloat = 0
        if pointer.x < edge { dx = -max(4, (edge - pointer.x) / 2) } else if pointer.x > viewW - edge { dx = max(4, (pointer.x - (viewW - edge)) / 2) }
        if pointer.y < rulerH + edge { dy = -max(4, (rulerH + edge - pointer.y) / 2) } else if pointer.y > viewportH - edge { dy = max(4, (pointer.y - (viewportH - edge)) / 2) }
        if zoom <= 1.01 { dx = 0 }
        if dy != 0 && contentH <= viewportH { dy = 0 }
        let nx = dx == 0 ? offsetX : max(0, min(max(0, contentW - viewW), offsetX + dx))
        let ny = dy == 0 ? offsetY : max(0, min(max(0, contentH - viewportH), offsetY + dy))
        return Step(offsetX: nx, offsetY: ny, corner: CGPoint(x: pointer.x + nx, y: pointer.y + ny))
    }
}
