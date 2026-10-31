// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Magnetic alignment of timeline edges to other edges and the playhead (pure maths; the UI only draws the guide).
public enum Snapping {
    /// Snaps one time to the nearest point within `threshold` seconds; `point` is the point it snapped to.
    public static func snap(_ t: Double, to points: [Double], threshold: Double) -> (value: Double, point: Double?) {
        var best: Double?
        for p in points where abs(p - t) <= threshold && (best == nil || abs(p - t) < abs(best! - t)) { best = p }
        return (best ?? t, best)
    }
    /// Snaps a block `[start, start+duration]` by whichever of its two edges is closest to a point; the block keeps its length.
    public static func snapBlock(start: Double, duration: Double, to points: [Double], threshold: Double) -> (start: Double, point: Double?) {
        let a = snap(start, to: points, threshold: threshold), b = snap(start + duration, to: points, threshold: threshold)
        switch (a.point, b.point) {
        case (nil, nil): return (start, nil)
        case (_?, nil): return (a.value, a.point)
        case (nil, _?): return (b.value - duration, b.point)
        case (let pa?, let pb?): return abs(pa - start) <= abs(pb - (start + duration)) ? (a.value, pa) : (b.value - duration, pb)
        }
    }
    /// Every edge worth snapping to: 0, the playhead, main-clip boundaries and layer edges, excluding the edges of the item being dragged.
    public static func points(of p: SadrogProject, playhead: Double, excluding id: UUID? = nil) -> [Double] {
        var out: [Double] = [0, playhead]
        for sp in p.clipSpans { if sp.id != id { out += [sp.start, sp.end] } }
        out.append(p.duration)
        for l in p.layers where l.id != id { out += [l.start, l.end] }
        for t in p.texts where t.id != id { out += [t.start, t.end] }
        for c in p.callouts where c.id != id { out += [c.start, c.end] }
        return out
    }
}

/// Where the video frame sits in the viewer. `zoom == nil` is "Potrivire" (aspect-fit); otherwise the frame is `zoom` × its pixel size, centred and shifted by `pan`.
/// This is view state only: it never touches the project or the composition, so it cannot change an export.
public enum ViewerFrame {
    public static let steps: [Double] = [0.25, 0.5, 1, 2, 4]
    public static func fit(_ size: CGSize, in area: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0, area.width > 0, area.height > 0 else { return area }
        let k = min(area.width / size.width, area.height / size.height), w = size.width * k, h = size.height * k
        return CGRect(x: area.midX - w / 2, y: area.midY - h / 2, width: w, height: h)
    }
    public static func frame(render size: CGSize, area: CGRect, zoom: Double?, pan: CGSize = .zero) -> CGRect {
        guard let z = zoom, size.width > 0, size.height > 0 else { return fit(size, in: area) }
        let w = size.width * z, h = size.height * z
        let p = clampedPan(pan, frame: CGSize(width: w, height: h), area: area.size)
        return CGRect(x: area.midX - w / 2 + p.width, y: area.midY - h / 2 + p.height, width: w, height: h)
    }
    /// Pan keeps the frame covering the area when it is larger, and centred when it is smaller.
    public static func clampedPan(_ pan: CGSize, frame f: CGSize, area a: CGSize) -> CGSize {
        func axis(_ v: CGFloat, _ fs: CGFloat, _ as_: CGFloat) -> CGFloat { fs <= as_ ? 0 : max(-(fs - as_) / 2, min((fs - as_) / 2, v)) }
        return CGSize(width: axis(pan.width, f.width, a.width), height: axis(pan.height, f.height, a.height))
    }
    /// The zoom factor currently displayed (for the label).
    public static func displayedZoom(render size: CGSize, area: CGRect, zoom: Double?) -> Double {
        zoom ?? (size.width > 0 ? Double(fit(size, in: area).width / size.width) : 1)
    }
}
