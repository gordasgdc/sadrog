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
/// and in a mixed selection the main-track clips stay where they are (`mainStayed`). The group stops at time 0 (the delta is clamped),
/// and is refused as a whole when one moving item lies on a locked lane or would overlap an item that is not moving.
public enum GroupMove: Equatable, Sendable {
    case moved(dx: Double, mainStayed: Bool)
    case refused(Reason)
    public enum Reason: Sendable { case locked, overlap, nothing }
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
