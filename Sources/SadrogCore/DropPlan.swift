// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// A file that is being dragged into the editor (library entry or Finder file), with what the app knows about it.
public struct DropMaterial: Equatable, Sendable {
    public var path: String; public var duration: Double; public var hasVideo: Bool; public var hasAudio: Bool
    public init(path: String, duration: Double, hasVideo: Bool, hasAudio: Bool) { self.path = path; self.duration = duration; self.hasVideo = hasVideo; self.hasAudio = hasAudio }
}

/// Where the pointer is: the main track (V1, appended at its end), a V2 / A2 row, or the row one past the last = the drop zone that creates a track.
public enum DropDestination: Equatable, Sendable { case main, overlay(row: Int), audio(row: Int) }

public enum DropRefusal: Equatable, Sendable { case nothing, incompatible, locked, overlap, tooManyTracks, unreadable }

/// What a drop WOULD do, computed without touching the project: the live preview and the real drop use the same plan, so they cannot disagree.
public struct DropPlan: Equatable, Sendable {
    public struct Placement: Equatable, Sendable { public var material: DropMaterial; public var start: Double; public var row: Int }
    public var destination: DropDestination
    public var placements: [Placement] = []
    public var createsTrack = false
    public var refusal: DropRefusal?
    /// Time the first item snapped to (for the guide line), nil = no snapping.
    public var guide: Double?
    public var isValid: Bool { refusal == nil && !placements.isEmpty }
    public var start: Double { placements.first?.start ?? 0 }
    public var end: Double { placements.last.map { $0.start + $0.material.duration } ?? 0 }
}

public enum DropPlanner {
    /// Items dropped together keep their order and sit one after the other (no gaps) from `time`; a refusal is explicit and nothing is shifted silently.
    public static func plan(_ p: SadrogProject, materials: [DropMaterial], destination: DropDestination, at time: Double, snapPoints: [Double] = [], threshold: Double = 0) -> DropPlan {
        var plan = DropPlan(destination: destination)
        guard !materials.isEmpty else { plan.refusal = .nothing; return plan }
        guard materials.allSatisfy({ $0.duration >= ProjectEditor.minClip }) else { plan.refusal = .unreadable; return plan }
        let lane: TrackLane, row: Int
        switch destination {
        case .main: lane = .v1; row = 0
        case .overlay(let r): lane = .v2; row = r
        case .audio(let r): lane = .a2; row = r
        }
        if lane == .a2 ? !materials.allSatisfy(\.hasAudio) : !materials.allSatisfy(\.hasVideo) { plan.refusal = .incompatible; return plan }
        if p.lockedLanes.contains(lane) { plan.refusal = .locked; return plan }
        var t = max(0, time)
        if destination == .main { t = p.clipSpans.last?.end ?? 0 }
        else if !snapPoints.isEmpty, threshold > 0 {
            let total = materials.reduce(0) { $0 + $1.duration }
            let s = Snapping.snapBlock(start: t, duration: total, to: snapPoints, threshold: threshold)
            t = max(0, s.start); plan.guide = s.point
        }
        if destination != .main {
            let count = p.rowCount(lane)
            guard row >= 0, row <= count else { plan.refusal = .incompatible; return plan }
            if row == count { guard count < 12 else { plan.refusal = .tooManyTracks; return plan }; plan.createsTrack = true }
        }
        let kind: LayerKind = lane == .a2 ? .audio : .video
        for m in materials {
            if destination != .main {
                let hit = p.layers.contains { $0.kind == kind && $0.row == row && $0.start < t + m.duration - 1e-6 && t < $0.end - 1e-6 }
                if hit { plan.placements = []; plan.refusal = .overlap; return plan }
            }
            plan.placements.append(.init(material: m, start: t, row: row)); t += m.duration
        }
        return plan
    }
}

public extension ProjectEditor {
    /// Performs a valid plan as ONE undo step (the new track, if any, and every item together). Returns the ids created; nil when refused (nothing changes).
    @discardableResult func perform(_ plan: DropPlan, transform: Transform = Transform(x: 0.22, y: -0.2, scale: 0.4)) -> [UUID]? {
        guard plan.isValid else { return nil }
        var made: [UUID] = []
        commit { p in
            switch plan.destination {
            case .main:
                for pl in plan.placements { let c = Clip(media: pl.material.path, sourceStart: 0, duration: pl.material.duration); p.clips.append(c); made.append(c.id) }
            case .overlay, .audio:
                let isAudio: Bool = { if case .audio = plan.destination { return true }; return false }()
                let lane: TrackLane = isAudio ? .a2 : .v2
                if plan.createsTrack { p.reservedRows[lane.rawValue] = p.rowCount(lane) + 1 }
                for pl in plan.placements {
                    var l = Layer(kind: isAudio ? .audio : .video, media: pl.material.path, start: pl.start, duration: pl.material.duration, transform: isAudio ? .identity : transform)
                    l.track = pl.row == 0 ? nil : pl.row
                    if Self.overlaps(l, in: p) { made = []; return false }
                    p.layers.append(l); made.append(l.id)
                }
            }
            for pl in plan.placements where !p.library.contains(pl.material.path) { p.library.append(pl.material.path) }
            return !made.isEmpty
        }
        return made.isEmpty ? nil : made
    }
}

public extension ProjectEditor {
    /// An effect (callout) dropped on a clip or an overlay: it now acts on THAT item. Its start moves to `time` clamped inside the target (so it begins where it was dropped),
    /// its length is cut to the end of the target, and the other target kind is released — one undo step. Refused (false) when the target does not exist or is not video.
    @discardableResult func retargetCallout(_ id: UUID, toClip clip: UUID?, toLayer layer: UUID?, at time: Double) -> Bool {
        var done = false
        commit { p in
            guard let i = p.callouts.firstIndex(where: { $0.id == id }) else { return false }
            let span: (start: Double, end: Double)
            if let c = clip, let sp = p.clipSpans.first(where: { $0.id == c }) { span = (sp.start, sp.end) }
            else if let l = layer, let ly = p.layers.first(where: { $0.id == l && $0.kind == .video }) { span = (ly.start, ly.end) }
            else { return false }
            let minLen = SadrogProject.minCalloutLength
            guard span.end - span.start >= minLen else { return false }
            let start = max(span.start, min(time, span.end - minLen))
            p.callouts[i].start = start
            p.callouts[i].duration = max(minLen, min(p.callouts[i].duration, span.end - start))
            p.callouts[i].clipID = clip; p.callouts[i].layerID = clip == nil ? layer : nil
            done = true; return true
        }
        return done
    }
}
