// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// How the timeline LOOKS for one project: the height each lane was given and the order the lanes are shown in. Pure presentation — it never changes
/// what is composited or mixed (video stacking follows the lane roles, the mix follows the lanes' own settings), so reordering is organisational only.
/// Lanes are identified by `TrackLane`, so heights and order follow the lane, never a position. No key in the file = the default layout (format-compatible).
public struct TimelineLayout: Codable, Equatable, Sendable {
    public static let defaultOrder: [TrackLane] = [.t, .c, .v2, .v1, .a1, .a2]
    public static let heightRange: ClosedRange<Double> = 18...420
    /// Height chosen by the user per lane (points, whole lane); no entry = the automatic height.
    public var heights: [String: Double] = [:]
    /// Height chosen by the user for ONE track (row) of V2 / A2 / effects, keyed like `SadrogProject.trackNames` ("a2.1"); the key follows the track when tracks move.
    /// No entry = the track shares the automatic height. Absent in files written before it existed.
    public var rowHeights: [String: Double] = [:]
    /// Display order top → bottom; may be partial or stale: `displayOrder` always completes it.
    public var order: [String] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case heights, rowHeights, order }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        heights = try c.decodeIfPresent([String: Double].self, forKey: .heights) ?? [:]
        rowHeights = try c.decodeIfPresent([String: Double].self, forKey: .rowHeights) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(heights, forKey: .heights); if !rowHeights.isEmpty { try c.encode(rowHeights, forKey: .rowHeights) }; try c.encode(order, forKey: .order)
    }
    public var isDefault: Bool { heights.isEmpty && rowHeights.isEmpty && displayOrder == Self.defaultOrder }
    public func rowHeight(_ lane: TrackLane, _ row: Int) -> Double? { rowHeights[SadrogProject.rowKey(lane, row)] }
    public mutating func setRowHeight(_ lane: TrackLane, _ row: Int, _ h: Double?) {
        rowHeights[SadrogProject.rowKey(lane, row)] = h.map { max(Self.heightRange.lowerBound, min(Self.heightRange.upperBound, $0.rounded())) }
    }
    /// Re-keys the heights of `lane` after tracks moved: `newRow` maps an old row to its new one (nil = the track is gone).
    mutating func remapRows(_ lane: TrackLane, _ newRow: (Int) -> Int?) {
        var out: [String: Double] = [:]
        for (k, v) in rowHeights {
            let parts = k.split(separator: ".")
            if parts.count == 2, parts[0] == lane.rawValue, let r = Int(parts[1]) { if let n = newRow(r) { out[SadrogProject.rowKey(lane, n)] = v } } else { out[k] = v }
        }
        rowHeights = out
    }
    /// Drops the heights of rows that no longer exist (`count` = rows now on the lane), so a deleted track never leaves a stale key that a later track would inherit.
    mutating func pruneRows(_ lane: TrackLane, keeping count: Int) {
        rowHeights = rowHeights.filter { k, _ in
            let parts = k.split(separator: ".")
            guard parts.count == 2, parts[0] == lane.rawValue, let r = Int(parts[1]) else { return true }
            return r < count
        }
    }
    public func height(_ lane: TrackLane) -> Double? { heights[lane.rawValue] }
    public var displayOrder: [TrackLane] {
        var out: [TrackLane] = []
        for s in order { if let l = TrackLane(rawValue: s), !out.contains(l) { out.append(l) } }
        for l in Self.defaultOrder where !out.contains(l) { out.append(l) }
        return out
    }
    public mutating func setHeight(_ lane: TrackLane, _ h: Double) {
        heights[lane.rawValue] = max(Self.heightRange.lowerBound, min(Self.heightRange.upperBound, h.rounded()))
    }
    public mutating func resetHeight(_ lane: TrackLane) { heights[lane.rawValue] = nil }
    /// A whole-lane height replaces the heights of the lane's single tracks.
    mutating func clearRows(_ lane: TrackLane) { rowHeights = rowHeights.filter { !$0.key.hasPrefix(lane.rawValue + ".") } }
    /// Moves `lane` so it ends at `index` of the display order (clamped). Returns false when nothing changes.
    @discardableResult public mutating func move(_ lane: TrackLane, to index: Int) -> Bool {
        var o = displayOrder; guard let from = o.firstIndex(of: lane) else { return false }
        let to = max(0, min(o.count - 1, index)); guard to != from else { return false }
        o.remove(at: from); o.insert(lane, at: to); order = o.map(\.rawValue); return true
    }
}

public extension ProjectEditor {
    /// One call = one undo step (a drag commits once, at its end).
    func setLaneHeight(_ lane: TrackLane, _ h: Double?) {
        commit { p in
            var l = p.layout; if let h { l.setHeight(lane, h) } else { l.resetHeight(lane) }
            l.clearRows(lane)
            guard l != p.layout else { return false }; p.layout = l; return true
        }
    }
    /// Height of one track of a lane (nil = automatic). One call = one undo step.
    func setRowHeight(_ lane: TrackLane, _ row: Int, _ h: Double?) {
        commit { p in var l = p.layout; l.setRowHeight(lane, row, h); guard l != p.layout else { return false }; p.layout = l; return true }
    }
    func resetLayout() { commit { p in guard !p.layout.isDefault else { return false }; p.layout = TimelineLayout(); return true } }
    func moveLane(_ lane: TrackLane, to index: Int) {
        commit { p in var l = p.layout; guard l.move(lane, to: index) else { return false }; p.layout = l; return true }
    }
}
