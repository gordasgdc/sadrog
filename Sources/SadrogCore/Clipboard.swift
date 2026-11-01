// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// One copied item. Main-track clips carry their bound callouts; everything else is a plain value with new ids on paste.
public enum ClipboardItem: Equatable, Sendable {
    case clip(ProjectEditor.ClipSnapshot), layer(Layer, callouts: [Callout]), text(TextOverlay), callout(Callout)
}

extension ProjectEditor {
    /// The lane an item lives on (nil = unknown id).
    public func lane(of id: UUID) -> TrackLane? {
        if project.clips.contains(where: { $0.id == id }) { return .v1 }
        if let l = project.layers.first(where: { $0.id == id }) { return l.kind == .video ? .v2 : .a2 }
        if project.texts.contains(where: { $0.id == id }) { return .t }
        if project.callouts.contains(where: { $0.id == id }) { return .c }
        return nil
    }
    /// Copies of the given items in timeline order. A callout bound to a selected clip travels with that clip, not on its own.
    public func clipboardItems(for ids: [UUID]) -> [ClipboardItem] {
        let set = Set(ids)
        var out: [(Double, ClipboardItem)] = []
        let spans = project.clipSpans
        for c in project.clips where set.contains(c.id) { if let s = snapshot(clip: c.id), let sp = spans.first(where: { $0.id == c.id }) { out.append((sp.start, .clip(s))) } }
        for l in project.layers where set.contains(l.id) { out.append((l.start, .layer(l, callouts: project.callouts.filter { $0.layerID == l.id }))) }
        for t in project.texts where set.contains(t.id) { out.append((t.start, .text(t))) }
        for c in project.callouts where set.contains(c.id) && !(c.clipID.map(set.contains) ?? false) && !(c.layerID.map(set.contains) ?? false) { out.append((c.start, .callout(c))) }
        return out.sorted { $0.0 < $1.0 }.map(\.1)
    }
    private func start(of item: ClipboardItem) -> (start: Double, end: Double)? {
        switch item {
        case .clip: return nil
        case .layer(let l, _): return (l.start, l.end)
        case .text(let t): return (t.start, t.end)
        case .callout(let c): return (c.start, c.end)
        }
    }
    /// Pastes items as copies with new ids, in ONE undo step; returns the new ids (empty = refused, e.g. a locked lane).
    /// Clips are inserted contiguously at main-track index `clipIndex`. The other items keep their relative spacing and start at `time`
    /// (nil = right after the originals); overlay/audio items go to the first free row, titles/callouts to the first free slot.
    @discardableResult public func paste(_ items: [ClipboardItem], clipIndex: Int, at time: Double? = nil) -> [UUID] {
        var created: [UUID] = []
        commit { p in
            let spans = items.compactMap(start(of:))
            let delta: Double = spans.isEmpty ? 0 : (time.map { $0 - spans.map(\.start).min()! } ?? (spans.map(\.end).max()! - spans.map(\.start).min()!))
            var idx = max(0, min(clipIndex, p.clips.count))
            for item in items {
                switch item {
                case .clip(let s):
                    var c = s.clip; c.id = UUID(); c.dissolve = 0; p.clips.insert(c, at: idx); idx += 1
                    let clipStart = p.start(ofClip: c.id) ?? 0
                    for (off, var k) in s.callouts { k.id = UUID(); k.clipID = c.id; k.start = clipStart + off; p.callouts.append(k) }
                    created.append(c.id)
                case .layer(var l, let bound):
                    let oldID = l.id, oldStart = l.start
                    l.id = UUID(); l.start = max(0, l.start + delta); if l.linkedClip != nil { l.sourceIdentity = true }; l.linkedClip = nil      // a copy is its own item: it never claims to be the original's detached sound
                    var row = l.row
                    func busy(_ r: Int) -> Bool { p.layers.contains { $0.kind == l.kind && $0.row == r && $0.start < l.end - 1e-6 && l.start < $0.end - 1e-6 } }
                    while busy(row) && row < 64 { row += 1 }
                    guard !busy(row) else { return false }
                    l.track = row == 0 ? nil : row; p.layers.append(l); created.append(l.id)
                    for var k in bound where k.layerID == oldID { k.id = UUID(); k.layerID = l.id; k.clipID = nil; k.start = l.start + (k.start - oldStart); p.callouts.append(k) }     // the callouts follow the copy, bound to it
                case .text(var t):
                    t.id = UUID(); t.start = max(0, t.start + delta)
                    while let b = p.texts.first(where: { $0.start < t.end - 1e-6 && t.start < $0.end - 1e-6 }) { t.start = b.end }
                    p.texts.append(t); created.append(t.id)
                case .callout(var c):
                    c.id = UUID()
                    var target: (start: Double, end: Double)? = nil
                    if let id = c.clipID, let sp = p.clipSpans.first(where: { $0.id == id }) { target = (sp.start, sp.end) }
                    else if let id = c.layerID, let l = p.layers.first(where: { $0.id == id && $0.kind == .video }) { target = (l.start, l.end) }
                    if let sp = target {                                               // an effect of a clip / overlay stays on it, inside it, and never pushes its neighbours: bands stack
                        var s = max(sp.start, c.start + delta); if s > sp.end - SadrogProject.minCalloutLength { s = max(sp.start, sp.end - c.duration) }
                        c.start = s; c.duration = min(c.duration, sp.end - s)
                    } else {
                        c.start = max(0, c.start + delta)
                        while let b = p.callouts.first(where: { $0.start < c.end - 1e-6 && c.start < $0.end - 1e-6 }) { c.start = b.end }
                        c.clipID = nil; c.layerID = nil
                    }
                    p.callouts.append(c); created.append(c.id)
                }
            }
            return !created.isEmpty
        }
        return created
    }
    /// Duplicates the items right after themselves (clips after the last selected clip), as ONE undo step; returns the new ids.
    @discardableResult public func duplicate(items ids: [UUID]) -> [UUID] {
        let items = clipboardItems(for: ids)
        let lastClip = project.clips.lastIndex { c in ids.contains(c.id) }
        return paste(items, clipIndex: (lastClip ?? project.clips.count - 1) + 1)
    }
    /// Deletes items of any lane as ONE undo step.
    public func delete(items ids: [UUID]) {
        let set = Set(ids)
        commit { p in
            let before = (p.clips.count, p.texts.count, p.callouts.count, p.layers.count)
            p.clips.removeAll { set.contains($0.id) }; p.texts.removeAll { set.contains($0.id) }
            p.callouts.removeAll { set.contains($0.id) }; p.layers.removeAll { set.contains($0.id) }
            return before != (p.clips.count, p.texts.count, p.callouts.count, p.layers.count)
        }
    }
    public func setLock(_ lane: TrackLane, _ on: Bool) {
        commit { p in if on { p.lockedLanes.insert(lane) } else { p.lockedLanes.remove(lane) }; return true }
    }
    /// Names a main-track clip or an overlay/audio item (empty = back to the file name), as ONE undo step.
    public func rename(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), v: String? = n.isEmpty ? nil : n
        commit { p in
            if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].label = v; return true }
            if let i = p.layers.firstIndex(where: { $0.id == id }) { p.layers[i].label = v; return true }
            return false
        }
    }
}

// MARK: group move (multiple selection)

/// Outcome of moving a multiple selection. One rule for the model and the interface:
/// timed items (overlay/audio items, titles, callouts) move together by the same time, keeping their distances, in ONE undo step;
/// main-track clips are sequential, so they never move by time: a selection made only of main-track clips moves as one block by index,
/// and a mixed selection (main-track clips + other items) is refused as a whole (`mainTrack`): nothing moves, so nothing can drift out of sync. The group stops at time 0 (the delta is clamped),
/// and is refused as a whole when one moving item lies on a locked lane or would overlap an item that is not moving.
public enum GroupMove: Equatable, Sendable {
    case moved(dx: Double, mainStayed: Bool)
    case refused(Reason)
    public enum Reason: Sendable { case locked, overlap, nothing, mainTrack, notAdjacent, dissolve }
}

extension ProjectEditor {
    /// Ids of the selected items that move by time.
    public func timedItems(in ids: [UUID]) -> [UUID] {
        let s = Set(ids)
        return project.layers.filter { s.contains($0.id) }.map(\.id) + project.texts.filter { s.contains($0.id) }.map(\.id) + project.callouts.filter { s.contains($0.id) }.map(\.id)
    }
    /// The delta that will really be applied for a requested `dx` (the group never starts before 0).
    public func clampedGroupDelta(_ ids: [UUID], _ dx: Double) -> Double {
        let t = Set(timedItems(in: ids))
        let starts = project.layers.filter { t.contains($0.id) }.map(\.start) + project.texts.filter { t.contains($0.id) }.map(\.start) + project.callouts.filter { t.contains($0.id) }.map(\.start)
        guard let m = starts.min() else { return 0 }
        return max(dx, -m)
    }
    @discardableResult public func moveGroup(_ ids: [UUID], by dx: Double) -> GroupMove {
        let timed = Set(timedItems(in: ids)); let mainSel = project.clips.contains { ids.contains($0.id) }
        if mainSel { return moveMixed(ids, by: dx) }
        guard !timed.isEmpty else { return .refused(.nothing) }
        let d = clampedGroupDelta(ids, dx)
        guard abs(d) > 1e-9 else { return .refused(.nothing) }
        var result: GroupMove = .refused(.nothing)
        commit { p in
            for l in p.layers where timed.contains(l.id) { if p.lockedLanes.contains(l.kind == .video ? .v2 : .a2) { result = .refused(.locked); return false } }
            if p.texts.contains(where: { timed.contains($0.id) }) && p.lockedLanes.contains(.t) { result = .refused(.locked); return false }
            if p.callouts.contains(where: { timed.contains($0.id) }) && p.lockedLanes.contains(.c) { result = .refused(.locked); return false }
            for i in p.layers.indices where timed.contains(p.layers[i].id) { p.layers[i].start += d }
            for i in p.texts.indices where timed.contains(p.texts[i].id) { p.texts[i].start += d }
            for i in p.callouts.indices where timed.contains(p.callouts[i].id) && !(p.callouts[i].layerID.map { timed.contains($0) } ?? false) {      // one bound to a moving overlay is carried by the overlay (reanchoring), not twice
                p.callouts[i].start += d
                if p.callouts[i].clipID != nil {                                    // a bound callout follows the clip it now lies in, or becomes independent
                    if let sp = p.clipSpans.first(where: { p.callouts[i].start >= $0.start - 1e-6 && p.callouts[i].start < $0.end - 1e-6 }) {
                        p.callouts[i].clipID = sp.id; p.callouts[i].duration = max(SadrogProject.minCalloutLength, min(p.callouts[i].duration, sp.end - p.callouts[i].start))
                    } else { p.callouts[i].clipID = nil }
                }
            }
            func hit(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { a.0 < b.1 - 1e-6 && b.0 < a.1 - 1e-6 }
            for l in p.layers where timed.contains(l.id) {
                if p.layers.contains(where: { !timed.contains($0.id) && $0.kind == l.kind && $0.row == l.row && hit(($0.start, $0.end), (l.start, l.end)) }) { result = .refused(.overlap); return false }
            }
            for t in p.texts where timed.contains(t.id) { if p.texts.contains(where: { !timed.contains($0.id) && hit(($0.start, $0.end), (t.start, t.end)) }) { result = .refused(.overlap); return false } }
            for c in p.callouts where timed.contains(c.id) { if p.callouts.contains(where: { !timed.contains($0.id) && hit(($0.start, $0.end), (c.start, c.end)) }) { result = .refused(.overlap); return false } }
            result = .moved(dx: d, mainStayed: mainSel); return true
        }
        return result
    }
    /// Plan of a move of a selection that includes main-track (V1) clips. V1 is sequential, so the clips move as ONE block that is re-inserted between two other
    /// clips: the block lands on the boundary nearest to the requested time, and every other selected item (overlays, camera, audio, titles, effects, and the
    /// detached sound linked to a moved clip) moves by exactly the SAME effective delta — so all relations between them stay identical. The clips that were
    /// displaced move to fill the gap (as in any reorder); nothing is converted, overwritten or dropped.
    public struct MixedPlan: Equatable, Sendable {
        public let dx: Double                 // effective delta applied to every selected item
        public let order: [UUID]              // main-track order after the move
        public let linked: [UUID]             // detached sounds linked to a moved clip, carried with it
        public let insertBefore: UUID?        // the clip the block is placed in front of (nil = at the end)
        public let blockStart: Double         // where the block starts after the move
    }
    public func planMixedMove(_ ids: [UUID], by dx: Double) -> (plan: MixedPlan?, refused: GroupMove.Reason?) {
        let sel = Set(ids)
        let idx = project.clips.indices.filter { sel.contains(project.clips[$0].id) }
        guard let first = idx.first, let last = idx.last else { return (nil, .nothing) }
        guard last - first + 1 == idx.count else { return (nil, .notAdjacent) }
        if project.lockedLanes.contains(.v1) { return (nil, .locked) }
        let block = Array(project.clips[first...last]); let blockIDs = Set(block.map(\.id))
        let rest = Array(project.clips[..<first]) + Array(project.clips[(last + 1)...])
        let spans = project.clipSpans; let s0 = spans[first].start
        // a cross-dissolve ties a clip to its neighbour: moving would silently change it, so refuse instead of converting it
        if block[0].dissolve > 0 { return (nil, .dissolve) }
        let after = last + 1 < project.clips.count ? project.clips[last + 1] : nil
        if (after?.dissolve ?? 0) > 0 { return (nil, .dissolve) }
        let linked = project.layers.filter { $0.kind == .audio && $0.linkedClip.map(blockIDs.contains) == true && !sel.contains($0.id) }.map(\.id)
        let timed = Set(timedItems(in: ids) + linked)
        let starts = project.layers.filter { timed.contains($0.id) }.map(\.start) + project.texts.filter { timed.contains($0.id) }.map(\.start) + project.callouts.filter { timed.contains($0.id) }.map(\.start)
        let minStart = starts.min() ?? 0
        var best: (k: Int, d: Double, st: Double)? = nil
        for k in 0...rest.count {
            if k < rest.count && rest[k].dissolve > 0 { continue }
            var t = project; t.clips = Array(rest[..<k]) + block + Array(rest[k...])
            let st = t.clipSpans[k].start, d = st - s0
            if d < -minStart - 1e-9 { continue }
            if best == nil || abs(d - dx) < abs(best!.d - dx) - 1e-9 { best = (k, d, st) }
        }
        guard let b = best, abs(b.d) > 1e-9 else { return (nil, .nothing) }
        let order = (Array(rest[..<b.k]) + block + Array(rest[b.k...])).map(\.id)
        return (MixedPlan(dx: b.d, order: order, linked: linked, insertBefore: b.k < rest.count ? rest[b.k].id : nil, blockStart: b.st), nil)
    }
    func moveMixed(_ ids: [UUID], by dx: Double) -> GroupMove {
        let pl = planMixedMove(ids, by: dx)
        guard let plan = pl.plan else { return .refused(pl.refused ?? .nothing) }
        let sel = Set(ids), d = plan.dx, old = project
        let blockIDs = Set(project.clips.filter { sel.contains($0.id) }.map(\.id))
        let timed = Set(timedItems(in: ids) + plan.linked)
        var result: GroupMove = .refused(.nothing)
        commit { p in
            for l in p.layers where timed.contains(l.id) { if p.lockedLanes.contains(l.kind == .video ? .v2 : .a2) { result = .refused(.locked); return false } }
            if p.texts.contains(where: { timed.contains($0.id) }) && p.lockedLanes.contains(.t) { result = .refused(.locked); return false }
            if p.callouts.contains(where: { timed.contains($0.id) }) && p.lockedLanes.contains(.c) { result = .refused(.locked); return false }
            let byID = Dictionary(p.clips.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            p.clips = plan.order.compactMap { byID[$0] }
            for i in p.layers.indices where timed.contains(p.layers[i].id) { p.layers[i].start += d }
            for i in p.texts.indices where timed.contains(p.texts[i].id) { p.texts[i].start += d }
            let nSpans = p.clipSpans, oStart = Dictionary(old.clipSpans.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
            for i in p.callouts.indices where timed.contains(p.callouts[i].id) {
                let c = p.callouts[i]
                if let l = c.layerID, timed.contains(l) { continue }                          // carried by its overlay (reanchoring)
                if let cid = c.clipID, blockIDs.contains(cid) { continue }                     // carried by its clip (reanchoring)
                let target = c.start + d
                if c.clipID == nil { p.callouts[i].start = target; continue }
                // bound to a clip that is NOT moving: it follows the clip it now lies in; compensate the displacement reanchoring will add
                if let sp = nSpans.first(where: { target >= $0.start - 1e-6 && target < $0.end - 1e-6 }), let os = oStart[sp.id] {
                    p.callouts[i].clipID = sp.id; p.callouts[i].start = target - (sp.start - os)
                    p.callouts[i].duration = max(SadrogProject.minCalloutLength, min(c.duration, sp.end - target))
                } else { p.callouts[i].clipID = nil; p.callouts[i].start = target }
            }
            func hit(_ a: (Double, Double), _ b: (Double, Double)) -> Bool { a.0 < b.1 - 1e-6 && b.0 < a.1 - 1e-6 }
            for l in p.layers where timed.contains(l.id) {
                if p.layers.contains(where: { !timed.contains($0.id) && $0.kind == l.kind && $0.row == l.row && hit(($0.start, $0.end), (l.start, l.end)) }) { result = .refused(.overlap); return false }
            }
            for t in p.texts where timed.contains(t.id) { if p.texts.contains(where: { !timed.contains($0.id) && hit(($0.start, $0.end), (t.start, t.end)) }) { result = .refused(.overlap); return false } }
            result = .moved(dx: d, mainStayed: false); return true
        }
        return result
    }
    /// Moves a selection made only of main-track clips as one block by `offset` positions. Refused if the clips are not adjacent, the lane is locked or nothing changes.
    @discardableResult public func moveBlock(_ ids: [UUID], byIndex offset: Int) -> Bool {
        let idx = project.clips.indices.filter { ids.contains(project.clips[$0].id) }
        guard let first = idx.first, let last = idx.last, last - first + 1 == idx.count, offset != 0, idx.count == ids.count else { return false }
        let target = max(0, min(project.clips.count - idx.count, first + offset)); guard target != first else { return false }
        let before = project
        commit { p in
            let block = Array(p.clips[first...last]); p.clips.removeSubrange(first...last); p.clips.insert(contentsOf: block, at: target); return true
        }
        return project != before
    }
}

/// Outcome of „Taie elementele selectate la cursor”.
public enum SplitSelection: Equatable, Sendable {
    case split(Int)                 // number of items cut
    case locked                     // a selected item that the cursor crosses lies on a locked lane: nothing is cut
    case nothing                    // no selected item crosses the cursor (or the cut would leave a piece shorter than the minimum)
}

extension ProjectEditor {
    /// Cuts ONLY the selected items that cross time `t`, in one undo step; everything else stays untouched. Main-track clips, overlay/audio items and titles are cut
    /// (an effect highlight is trimmed, not cut, so it is left as it is). Refused whole when a crossed selected item lies on a locked lane — never a partial cut.
    @discardableResult public func splitSelection(_ ids: [UUID], at t: Double) -> SplitSelection {
        let s = Set(ids), minLen = ProjectEditor.minClip
        let clips = project.clipSpans.filter { s.contains($0.id) && t - $0.start >= minLen && $0.end - t >= minLen }.map(\.id)
        let layers = project.layers.filter { s.contains($0.id) && t - $0.start >= minLen && $0.end - t >= minLen }
        let texts = project.texts.filter { s.contains($0.id) && t - $0.start >= minLen && $0.end - t >= minLen }.map(\.id)
        if (!clips.isEmpty && project.lockedLanes.contains(.v1)) || layers.contains(where: { project.lockedLanes.contains($0.kind == LayerKind.video ? TrackLane.v2 : TrackLane.a2) }) || (!texts.isEmpty && project.lockedLanes.contains(.t)) { return .locked }
        var n = 0
        commit { p in
            for id in clips where Self.splitClip(&p, at: t, only: id) { n += 1 }
            for l in layers where Self.splitItem(&p, kind: l.kind, at: t, only: l.id) { n += 1 }
            for id in texts where Self.splitTitle(&p, at: t, only: id) { n += 1 }
            return n > 0
        }
        return n > 0 ? .split(n) : .nothing
    }
}
