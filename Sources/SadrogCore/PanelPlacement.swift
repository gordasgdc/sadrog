// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Where the floating capture panel goes: a saved position is kept as long as enough of it is still on a screen, otherwise it is pulled back
/// (monitor unplugged, resolution changed). Pure geometry in AppKit global coordinates, so it is testable without a window.
public enum PanelPlacement {
    public static let margin: CGFloat = 40
    /// A saved frame counts as lost when less than this much of it (width and height) lies on any screen.
    public static let minVisible = CGSize(width: 80, height: 24)

    public static func resolve(saved: CGRect?, size: CGSize, screens: [CGRect]) -> CGRect {
        guard let first = screens.first else { return CGRect(origin: .zero, size: size) }
        let fallback = CGRect(x: first.maxX - size.width - margin, y: first.maxY - size.height - 28, width: size.width, height: size.height)
        guard let s = saved else { return clamp(fallback, in: first) }
        let frame = CGRect(origin: s.origin, size: size)
        var best: (CGRect, CGFloat)?
        for scr in screens {
            let i = scr.intersection(frame)
            guard !i.isNull, i.width >= min(minVisible.width, size.width), i.height >= min(minVisible.height, size.height) else { continue }
            let area = i.width * i.height
            if best == nil || area > best!.1 { best = (scr, area) }
        }
        guard let (scr, _) = best else { return clamp(fallback, in: first) }
        return clamp(frame, in: scr)
    }

    static func clamp(_ f: CGRect, in scr: CGRect) -> CGRect {
        var o = f.origin
        o.x = min(max(o.x, scr.minX), max(scr.minX, scr.maxX - f.width))
        o.y = min(max(o.y, scr.minY), max(scr.minY, scr.maxY - f.height))
        return CGRect(origin: o, size: f.size)
    }
}
