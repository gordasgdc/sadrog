// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

extension EditorModel {
    /// Visible items at the playhead, front first — the same placement maths as the compositor (`ViewerPick`).
    func viewerItems() -> [ViewerItem] {
        let R = renderSize
        return ViewerPick.items(in: project, at: time, render: R, natural: { self.media[$0]?.size }, textSize: { TextRenderer.layoutSize($0, render: R) })
    }
    /// Canvas point (render pixels) → the item a click selects. `cycle` moves to the next covered item under the same spot. Selection only: no playhead move, no history.
    @discardableResult func pick(canvas p: CGPoint, cycle: Bool) -> UUID? {
        let hits = ViewerPick.hits(viewerItems(), at: p)
        guard let t = cycle ? ViewerPick.next(after: selection, in: hits) : hits.first else { return nil }
        if t.id != selection { select(t.id) }
        return t.id
    }
}

/// Click-through layer between the picture and the selection frames: click = select what is visible under the pointer, drag = select and move it (one undo step),
/// hover = a thin outline of the target. Handles, drawing, crop and pan sit above it and keep their priority.
struct PickLayer: View {
    @ObservedObject var m: EditorModel
    let frame: CGRect
    @State private var hover: ViewerItem?
    @State private var dragID: UUID?
    @State private var base: Transform?
    @State private var began = false
    private var k: CGFloat { frame.width / max(1, m.renderSize.width) }
    private func canvas(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - frame.minX) / k, y: (p.y - frame.minY) / k) }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001).frame(width: frame.width, height: frame.height).position(x: frame.midX, y: frame.midY)
                .onContinuousHover(coordinateSpace: .named("viewer")) { phase in
                    switch phase {
                    case .active(let p): let h = ViewerPick.hits(m.viewerItems(), at: canvas(p)).first; if h?.id != hover?.id { hover = h }
                    case .ended: hover = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("viewer"))
                    .onChanged { v in
                        if !began { began = true; dragID = m.pick(canvas: canvas(v.startLocation), cycle: false) }
                        guard let id = dragID, hypot(v.translation.width, v.translation.height) > 2, let e = base ?? m.selectedTransform else { return }
                        base = e
                        m.liveTransform(id, Transform(x: e.x + Double(v.translation.width / frame.width), y: e.y + Double(v.translation.height / frame.height), scale: e.scale, opacity: e.opacity, rotation: e.rotation))
                    }
                    .onEnded { _ in
                        if base != nil, let id = dragID, let t = m.selectedTransform { m.commitTransform(id, t) }
                        began = false; dragID = nil; base = nil
                    })
            if let h = hover, h.id != m.selection {
                let w = h.size.width * k, ht = h.size.height * k
                Group { if h.circle { Circle().strokeBorder(Theme.C.sel.opacity(0.7), lineWidth: 1.5) } else { Rectangle().strokeBorder(Theme.C.sel.opacity(0.7), lineWidth: 1.5) } }
                    .frame(width: w, height: ht).rotationEffect(.degrees(h.rotation))
                    .overlay(alignment: .topLeading) { Text(h.name).font(Theme.F.caption).lineLimit(1).padding(.horizontal, 5).padding(.vertical, 1).background(Theme.C.bg0.opacity(0.85)).foregroundStyle(Theme.C.text).offset(y: -16).fixedSize().rotationEffect(.degrees(-h.rotation)) }
                    .position(x: frame.minX + h.center.x * k, y: frame.minY + h.center.y * k).allowsHitTesting(false)
            }
        }.frame(width: frame.maxX, height: frame.maxY, alignment: .topLeading)
    }
}
