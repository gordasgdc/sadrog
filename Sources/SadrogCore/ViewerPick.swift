// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Direct selection in the viewer: which visible item is under a canvas point. Same placement maths as the compositor (fit, scale, rotation, crop, animation at the
/// playhead); a hidden lane, a fully transparent item or the outside of a circle crop never catches the click, so the layer underneath does.
public struct ViewerItem: Equatable, Sendable {
    public var id: UUID
    public var lane: TrackLane
    public var name: String
    public var center: CGPoint            // canvas pixels
    public var size: CGSize               // canvas pixels before rotation
    public var rotation: Double           // degrees
    public var circle: Bool
    public var opacity: Double
    /// Is the canvas point inside the item's visible area (inverse rotation, then rectangle or inscribed circle)?
    public func contains(_ p: CGPoint) -> Bool {
        guard opacity > 0.001, size.width > 0, size.height > 0 else { return false }
        let a = -rotation * .pi / 180, dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let lx = dx * cos(a) - dy * sin(a), ly = dx * sin(a) + dy * cos(a)
        if circle { let r = Double(min(size.width, size.height)) / 2; return lx * lx + ly * ly <= r * r }
        return abs(lx) <= Double(size.width) / 2 && abs(ly) <= Double(size.height) / 2
    }
}

public enum ViewerPick {
    /// Visible items at `time`, FRONT first: titles, then video layers (higher row in front), then the main-track clip at the back.
    public static func items(in p: SadrogProject, at time: Double, render R: CGSize, natural: (String) -> CGSize?, textSize: (TextOverlay) -> CGSize) -> [ViewerItem] {
        func fit(_ n: CGSize) -> CGFloat { min(R.width / max(n.width, 1), R.height / max(n.height, 1)) }
        func make(id: UUID, lane: TrackLane, name: String, n: CGSize, fitted: Bool, t: Transform, circle: Bool) -> ViewerItem {
            let f = fitted ? fit(n) : 1
            return ViewerItem(id: id, lane: lane, name: name, center: CGPoint(x: R.width / 2 + t.x * R.width, y: R.height / 2 + t.y * R.height),
                              size: CGSize(width: n.width * f * t.scale, height: n.height * f * t.scale), rotation: t.rotation, circle: circle, opacity: t.opacity)
        }
        func shown(_ n0: CGSize, circle: Bool, rect: RectCrop?) -> CGSize {
            if circle { let s = min(n0.width, n0.height); return CGSize(width: s, height: s) }
            return rect?.window(of: n0).size ?? n0
        }
        var out: [ViewerItem] = []
        if !p.hiddenLanes.contains(.t) {
            for t in p.texts.reversed() where time >= t.start && time < t.end {
                out.append(make(id: t.id, lane: .t, name: t.text, n: textSize(t), fitted: false, t: Transform.state(start: t.transform, end: t.endTransform, elapsed: time - t.start, duration: t.duration), circle: false))
            }
        }
        if !p.hiddenLanes.contains(.v2) {
            let vs = p.layers.enumerated().filter { $0.element.kind == .video && time >= $0.element.start && time < $0.element.end }
                .sorted { ($0.element.row, $0.offset) > ($1.element.row, $1.offset) }
            for (_, l) in vs {
                guard let n0 = natural(l.media), n0.width > 0 else { continue }
                out.append(make(id: l.id, lane: .v2, name: l.label ?? URL(fileURLWithPath: l.media).lastPathComponent, n: shown(n0, circle: l.crop != nil, rect: l.rectCrop), fitted: true,
                                t: Transform.state(start: l.transform, end: l.endTransform, elapsed: time - l.start, duration: l.duration), circle: l.crop != nil))
            }
        }
        if !p.hiddenLanes.contains(.v1), let (i, off) = p.locate(time) {
            let c = p.clips[i]
            if let n0 = natural(c.media), n0.width > 0 {
                out.append(make(id: c.id, lane: .v1, name: c.label ?? URL(fileURLWithPath: c.media).lastPathComponent, n: shown(n0, circle: c.crop != nil, rect: c.rectCrop), fitted: true,
                                t: Transform.state(start: c.transform, end: c.endTransform, elapsed: off, duration: c.duration), circle: c.crop != nil))
            }
        }
        return out
    }
    /// Every item under the point, front first (the first is what a plain click selects; the rest is the "covered items" list).
    public static func hits(_ items: [ViewerItem], at point: CGPoint) -> [ViewerItem] { items.filter { $0.contains(point) } }
    /// After a click on the SAME spot, the next covered item (cycling), so an item hidden behind another can be reached without the timeline.
    public static func next(after current: UUID?, in hits: [ViewerItem]) -> ViewerItem? {
        guard let first = hits.first else { return nil }
        guard let c = current, let i = hits.firstIndex(where: { $0.id == c }) else { return first }
        return hits[(i + 1) % hits.count]
    }
}
