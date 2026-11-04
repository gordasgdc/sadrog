// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// One point of a volume curve. `t` = LOCAL seconds from the start of the item (clip or audio item), never timeline seconds. `db` ≤ `VolumeKey.silenceDB` is silence.
public struct VolumeKey: Codable, Equatable, Sendable {
    public static let silenceDB = -90.0
    public static let maxDB = 12.0
    public var t: Double, db: Double
    /// The segment that STARTS at this point is a straight line in amplitude instead of in dB. Set by cuts and trims inside a segment that runs to or from silence,
    /// so that the pieces keep exactly the curve the original had (segments touching silence are always amplitude-linear).
    public var linear = false
    public init(t: Double, db: Double, linear: Bool = false) { self.t = t; self.db = db; self.linear = linear }
    enum CodingKeys: String, CodingKey { case t, db, linear }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        t = try c.decode(Double.self, forKey: .t); db = try c.decode(Double.self, forKey: .db); linear = try c.decodeIfPresent(Bool.self, forKey: .linear) ?? false
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self); try c.encode(t, forKey: .t); try c.encode(db, forKey: .db); if linear { try c.encode(true, forKey: .linear) }
    }
    public var isSilence: Bool { db <= Self.silenceDB }
}

/// Shape of a fade. `bend` (0…1, 0.5 by default) is how far the shape departs from a straight line (0 = straight for every shape).
/// Fade-in: gain = `gain(u)` for u = 0…1 through the fade. Fade-out: the mirror — gain = `gain(1 − u)`.
public enum FadeShape: String, Codable, CaseIterable, Sendable { case linear, easeIn, easeOut, sCurve }
public struct FadeCurve: Codable, Equatable, Sendable {
    public var shape: FadeShape = .linear
    public var bend = 0.5
    public init(shape: FadeShape = .linear, bend: Double = 0.5) { self.shape = shape; self.bend = max(0, min(1, bend)) }
    public static let linear = FadeCurve()
    /// 0 → 0, 1 → 1, monotonic, for every shape and bend.
    public func gain(_ u: Double) -> Double {
        let x = max(0, min(1, u)), p = 1 + 3 * max(0, min(1, bend))
        switch shape {
        case .linear: return x
        case .easeIn: return pow(x, p)                       // starts slowly, ends steeply
        case .easeOut: return 1 - pow(1 - x, p)              // starts steeply, ends slowly
        case .sCurve: let a = pow(x, p), b = pow(1 - x, p); return a / (a + b)
        }
    }
}

extension FadeCurve {
    /// Level reached half-way through the fade: where the curvature handle sits on the track.
    public var midGain: Double { gain(0.5) }
    /// The ease curve (or the S bend) whose half-way level is `g`: a continuous curvature, straight when `g` ≈ 0.5. Used by the on-track curvature handle.
    public static func fitting(midGain g: Double, from cur: FadeCurve) -> FadeCurve {
        let m = max(0.04, min(0.96, g))
        if abs(m - 0.5) < 0.005 { return FadeCurve(shape: .linear, bend: cur.bend) }
        if cur.shape == .sCurve { return FadeCurve(shape: .sCurve, bend: min(1, abs(m - 0.5) * 2)) }
        let p = log(m < 0.5 ? m : 1 - m) / log(0.5)
        return FadeCurve(shape: m < 0.5 ? .easeIn : .easeOut, bend: max(0, min(1, (p - 1) / 3)))
    }
}
extension CrossfadeShape {
    /// Level of the incoming sound half-way through the overlap (what the X shows at its centre).
    public var midIncoming: Double { gains(0.5).incoming }
    /// The shape whose incoming level half-way is `g` (mode kept): equal power maps through sin(c·π/2).
    public func fitting(midIncoming g: Double) -> CrossfadeShape {
        let m = max(0.04, min(0.96, g))
        let c = mode == .equalGain ? m : asin(m) * 2 / .pi
        return CrossfadeShape(mode: mode, curve: FadeCurve.fitting(midGain: c, from: curve))
    }
}

public enum CrossfadeMode: String, Codable, CaseIterable, Sendable {
    /// Gains add up to 1: the level stays constant for CORRELATED material (the same sound on both sides), and dips by up to 3 dB in the middle for unrelated sounds.
    case equalGain
    /// Gains are sin/cos: the POWER stays constant for unrelated sounds; for identical (correlated) material the middle is up to 3 dB (×1.41) louder.
    case equalPower
}

/// The crossfade that joins an outgoing item to an incoming one over `duration` seconds of REAL overlap.
public struct CrossfadeShape: Codable, Equatable, Sendable {
    public var mode: CrossfadeMode = .equalGain
    public var curve: FadeCurve = .linear
    public init(mode: CrossfadeMode = .equalGain, curve: FadeCurve = .linear) { self.mode = mode; self.curve = curve }
    /// Gains of (incoming, outgoing) at progress u = 0…1 through the overlap.
    public func gains(_ u: Double) -> (incoming: Double, outgoing: Double) {
        let c = curve.gain(u)
        switch mode {
        case .equalGain: return (c, 1 - c)
        case .equalPower: return (sin(c * .pi / 2), cos(c * .pi / 2))
        }
    }
    public var isLegacy: Bool { mode == .equalGain && curve == .linear }
}

/// Everything that shapes the level of one audio item over its own (local) time, in one place. The mixer, the editor’s drawing and the tests all ask THIS.
/// Order of the product (see docs): automation × fade-in × fade-out × crossfade-in × crossfade-out. The static gains (source, clip, master) are applied outside.
public struct AudioEnvelope: Equatable, Sendable {
    public var duration: Double
    public var points: [VolumeKey] = []
    public var fadeIn = 0.0, fadeOut = 0.0
    public var fadeInCurve = FadeCurve.linear, fadeOutCurve = FadeCurve.linear
    /// Crossfade with the previous / next item: length (≤ duration) and shape. nil = none.
    public var xIn: (seconds: Double, shape: CrossfadeShape)? = nil
    public var xOut: (seconds: Double, shape: CrossfadeShape)? = nil
    public init(duration: Double) { self.duration = duration }
    public static func == (a: Self, b: Self) -> Bool {
        a.duration == b.duration && a.points == b.points && a.fadeIn == b.fadeIn && a.fadeOut == b.fadeOut && a.fadeInCurve == b.fadeInCurve && a.fadeOutCurve == b.fadeOutCurve
            && a.xIn?.seconds == b.xIn?.seconds && a.xIn?.shape == b.xIn?.shape && a.xOut?.seconds == b.xOut?.seconds && a.xOut?.shape == b.xOut?.shape
    }
    /// True when this envelope is exactly what the earlier versions produced (straight fades, no points, no shaped crossfade): the mixer then writes the same keyframes as before.
    public var isLegacy: Bool { points.isEmpty && fadeInCurve == .linear && fadeOutCurve == .linear && (xIn?.shape.isLegacy ?? true) && (xOut?.shape.isLegacy ?? true) }

    /// Automation alone, linear amplitude. dB is interpolated between points (the ear is logarithmic); before the first / after the last point the level holds.
    public func automation(at t: Double) -> Double {
        guard let f = points.first, let l = points.last else { return 1 }
        func lin(_ db: Double) -> Double { db <= VolumeKey.silenceDB ? 0 : pow(10, db / 20) }
        if t <= f.t { return lin(f.db) }; if t >= l.t { return lin(l.db) }
        for i in 1..<points.count where t < points[i].t || i == points.count - 1 {
            let a = points[i - 1], b = points[i]; let u = b.t > a.t ? (t - a.t) / (b.t - a.t) : 1
            if a.isSilence && b.isSilence { return 0 }
            if a.isSilence || b.isSilence || a.linear {      // to/from silence: interpolate in amplitude, a dB line to −∞ would sit at −45 dB halfway
                return lin(a.db) + (lin(b.db) - lin(a.db)) * u
            }
            return lin(a.db + (b.db - a.db) * u)
        }
        return lin(l.db)
    }
    /// Total linear gain at local time `t`.
    public func gain(at t: Double) -> Double {
        var g = automation(at: t)
        let fi = min(fadeIn, duration), fo = min(fadeOut, duration)
        if fi > 0, t < fi { g *= fadeInCurve.gain(t / fi) }
        if fo > 0, t > duration - fo { g *= fadeOutCurve.gain((duration - t) / fo) }
        if let x = xIn, x.seconds > 0, t < x.seconds { g *= x.shape.gains(t / x.seconds).incoming }
        if let x = xOut, x.seconds > 0, t > duration - x.seconds { g *= x.shape.gains(1 - (duration - t) / x.seconds).outgoing }
        return g
    }
    /// Piecewise-linear description of `gain(at:)` for the mixer (which interpolates amplitude linearly between keyframes). Intervals that are straight stay one segment;
    /// curved ones are split until the straight-line error is under 0.003 (≈ 0.03 dB near unity) — at most 4096 segments for the whole item.
    public func breakpoints() -> [(t: Double, g: Double)] {
        var marks: Set<Double> = [0, duration]
        for p in points where p.t > 0 && p.t < duration { marks.insert(p.t) }
        for s in [fadeIn, fadeOut, xIn?.seconds ?? 0, xOut?.seconds ?? 0] where s > 0 && s < duration { marks.insert(s); marks.insert(duration - s) }
        let ts = marks.sorted(); var out: [(t: Double, g: Double)] = [(ts[0], gain(at: ts[0]))]
        var budget = 4096
        func refine(_ a: Double, _ b: Double, _ ga: Double, _ gb: Double, _ depth: Int) {
            let m = (a + b) / 2, gm = gain(at: m)
            // three probes (a symmetric S-shape crosses its chord exactly in the middle, so the middle alone would call it straight)
            var bad = false
            for k in [0.25, 0.5, 0.75] { if abs(gain(at: a + (b - a) * k) - (ga + (gb - ga) * k)) > 0.003 { bad = true; break } }
            if depth < 9, budget > 0, bad { refine(a, m, ga, gm, depth + 1); refine(m, b, gm, gb, depth + 1) }
            else { budget -= 1; out.append((b, gb)) }
        }
        for i in 1..<ts.count {
            let a = ts[i - 1], b = ts[i]; guard b - a > 1e-9 else { continue }
            let ga = out.last!.g, gb = gain(at: b)
            // just inside an interval the gain may differ from the value at the mark (a step): both ends are read from the interval itself
            refine(a, b, ga, gb, 0)
        }
        return out
    }
}

// MARK: AudioEdit — points and curves

extension AudioEdit {
    /// Clamped, sorted copy of the points inside `duration` (times to 1 ms, levels to 0.1 dB); a point at the same time as another replaces it.
    public static func cleaned(_ pts: [VolumeKey], duration d: Double) -> [VolumeKey] {
        var out: [VolumeKey] = []
        for p in pts.sorted(by: { $0.t < $1.t }) {
            let t = (max(0, min(d, p.t)) * 1000).rounded() / 1000, db = p.db <= VolumeKey.silenceDB ? VolumeKey.silenceDB : (min(VolumeKey.maxDB, p.db) * 10).rounded() / 10
            if let l = out.last, abs(l.t - t) < 0.0005 { out[out.count - 1] = VolumeKey(t: t, db: db, linear: p.linear) } else { out.append(VolumeKey(t: t, db: db, linear: p.linear)) }
        }
        return out
    }
    /// The envelope of this edit for an item of `duration` (fades scaled as before when they would overlap).
    public func envelope(duration d: Double) -> AudioEnvelope {
        var e = AudioEnvelope(duration: d); let f = effectiveFades(duration: d)
        e.points = points; e.fadeIn = f.fadeIn; e.fadeOut = f.fadeOut; e.fadeInCurve = fadeInCurve; e.fadeOutCurve = fadeOutCurve
        return e
    }
    /// Level of the automation (dB) at local time `t` — what a point added there should start from.
    public func automationDB(at t: Double, duration d: Double) -> Double {
        let g = envelope(duration: d).automation(at: t); return g <= 0.0000316 ? VolumeKey.silenceDB : 20 * log10(g)
    }
    /// Loudest the automation can make the item, in dB above the item gain (≥ 0 when there are no points).
    public var automationPeakDB: Double { max(0, points.map(\.db).max() ?? 0) }
    /// Index of the nearest point at or after `t` / before `t` (navigation between points).
    public func nextPoint(after t: Double) -> Int? { points.firstIndex { $0.t > t + 0.0005 } }
    public func previousPoint(before t: Double) -> Int? { points.lastIndex { $0.t < t - 0.0005 } }

    /// Is the segment containing `t` a straight line in amplitude (touches silence or was marked by an earlier cut)?
    func segmentIsLinear(at t: Double) -> Bool {
        guard points.count > 1, let i = points.indices.dropLast().last(where: { points[$0].t <= t + 0.0005 }) else { return false }
        return points[i].linear || points[i].isSilence || points[i + 1].isSilence
    }
    /// The two edits of an item cut `off` seconds in: automation continues across the cut (each side gets the value at the cut), fades stay on the outer edges.
    public func cut(at off: Double, duration d: Double) -> (AudioEdit, AudioEdit) {
        var a = self, b = self
        a.fadeOut = 0; b.fadeIn = 0; b.crossfade = nil
        if !points.isEmpty {
            let env = envelope(duration: d), g = env.automation(at: off), db = g <= 0.0000316 ? VolumeKey.silenceDB : 20 * log10(g)
            let lin = segmentIsLinear(at: off)
            var head = points.filter { $0.t < off - 0.0005 }
            if lin, !head.isEmpty, points.contains(where: { $0.t > off + 0.0005 }) { head[head.count - 1].linear = true }      // the piece before the cut keeps its amplitude line
            a.points = head + [VolumeKey(t: off, db: db)]
            b.points = [VolumeKey(t: 0, db: db, linear: lin && points.contains { $0.t > off + 0.0005 })] + points.filter { $0.t > off + 0.0005 }.map { VolumeKey(t: $0.t - off, db: $0.db, linear: $0.linear) }
        }
        return (a, b)
    }
    /// After the front of the item was trimmed by `delta` seconds (positive = shortened): points move earlier; the value at the new start is kept as the first point.
    public func trimmedFront(by delta: Double, duration d: Double) -> AudioEdit {
        guard !points.isEmpty, delta != 0 else { return self }
        var e = self
        if delta > 0 {
            let db = automationDB(at: delta, duration: d), lin = segmentIsLinear(at: delta) && points.contains { $0.t > delta + 0.0005 }
            e.points = [VolumeKey(t: 0, db: db, linear: lin)] + points.filter { $0.t > delta + 0.0005 }.map { VolumeKey(t: $0.t - delta, db: $0.db, linear: $0.linear) }
        } else { e.points = points.map { VolumeKey(t: $0.t - delta, db: $0.db, linear: $0.linear) } }       // extended at the front: everything keeps its place
        return e
    }
    /// After the back was trimmed to `newDuration`: points beyond it go; the value at the new end is kept.
    public func trimmedBack(toDuration n: Double, from d: Double) -> AudioEdit {
        guard !points.isEmpty, n < d else { return self }
        var e = self; let db = automationDB(at: n, duration: d)
        var head = points.filter { $0.t < n - 0.0005 }
        if segmentIsLinear(at: n), !head.isEmpty { head[head.count - 1].linear = true }
        e.points = head + [VolumeKey(t: n, db: db)]
        return e
    }
    /// Retiming scales the item’s local time: the curve keeps its place relative to the picture.
    public func scaled(by r: Double) -> AudioEdit { var e = self; e.points = points.map { VolumeKey(t: $0.t * r, db: $0.db, linear: $0.linear) }; return e }
}

/// The crossfade of an A2 item with the item that plays before it. `outgoing` must really overlap the start of the owner and end inside it; the crossfade lasts exactly the overlap
/// (to change its length, change the overlap: trim or move the owner).
public struct CrossfadeLink: Codable, Equatable, Sendable {
    public var outgoing: UUID
    public var shape = CrossfadeShape()
    public init(outgoing: UUID, shape: CrossfadeShape = CrossfadeShape()) { self.outgoing = outgoing; self.shape = shape }
}

extension SadrogProject {
    /// Seconds of real audio overlap between the owner of `link` (`layer`) and its outgoing item, or 0 when the link is not valid:
    /// the outgoing item must start before the owner and end inside it.
    public func crossfadeSeconds(_ layer: Layer) -> Double {
        guard layer.kind == .audio, let link = layer.audio?.crossfade, let o = layers.first(where: { $0.id == link.outgoing && $0.kind == .audio }),
              o.start < layer.start - 1e-6, o.end <= layer.end + 1e-6 else { return 0 }
        let s = o.end - layer.start; return s >= 0.01 ? s : 0
    }
    /// Drops crossfade links that no longer describe a real overlap (item deleted, moved apart, trimmed away) so none stays behind as a hidden, silent setting.
    mutating func normalizeCrossfades() {
        for i in layers.indices where layers[i].audio?.crossfade != nil && crossfadeSeconds(layers[i]) == 0 {
            layers[i].audio?.crossfade = nil; if layers[i].audio?.isNeutral == true { layers[i].audio = nil }
        }
    }
}

extension ProjectEditor {
    /// Splits the audio edit of a clip being cut: curve continues across the cut, fades stay outside.
    static func cutAudio(_ a: inout Clip, _ b: inout Clip, at off: Double, duration d: Double) {
        guard let e = a.audio else { return }
        let (x, y) = e.cut(at: off, duration: d); a.audio = x.isNeutral ? nil : x; b.audio = y.isNeutral ? nil : y
    }
}

// MARK: editing — one call = one undo step

extension ProjectEditor {
    func editAudio(_ id: UUID, _ change: @escaping (inout AudioEdit, Double) -> Bool) {
        commit { p in
            var e: AudioEdit, d: Double
            if let i = p.clips.firstIndex(where: { $0.id == id }) {
                e = p.clips[i].audio ?? AudioEdit(); d = p.clips[i].duration
                guard change(&e, d) else { return false }
                e.points = AudioEdit.cleaned(e.points, duration: d); p.clips[i].audio = e.isNeutral ? nil : e; return true
            }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .audio }) {
                e = p.layers[i].audio ?? AudioEdit(); d = p.layers[i].duration
                guard change(&e, d) else { return false }
                e.points = AudioEdit.cleaned(e.points, duration: d); p.layers[i].audio = e.isNeutral ? nil : e; return true
            }
            return false
        }
    }
    /// Adds a volume point at local time `t` of the clip / audio item; its level defaults to the curve’s current level there (so the curve does not change shape). Returns its index.
    @discardableResult public func addVolumePoint(_ id: UUID, at t: Double, db: Double? = nil) -> Int? {
        var idx: Int?
        editAudio(id) { e, d in
            let tt = (max(0, min(d, t)) * 1000).rounded() / 1000
            if e.points.contains(where: { abs($0.t - tt) < 0.0005 }) { return false }
            let level = db ?? e.automationDB(at: tt, duration: d)
            let lin = e.segmentIsLinear(at: tt)
            if lin, let pi = e.points.lastIndex(where: { $0.t < tt }) { e.points[pi].linear = true }      // splitting an amplitude line keeps it a line
            e.points.append(VolumeKey(t: tt, db: level, linear: lin && e.points.contains { $0.t > tt })); idx = e.points.sorted { $0.t < $1.t }.firstIndex { abs($0.t - tt) < 0.0005 }; return true
        }
        return idx
    }
    /// Moves point `index` in time and level. Its time stays between its neighbours (points never swap places).
    public func moveVolumePoint(_ id: UUID, index: Int, t: Double, db: Double) {
        editAudio(id) { e, d in
            guard e.points.indices.contains(index) else { return false }
            let lo = index > 0 ? e.points[index - 1].t + 0.002 : 0, hi = index + 1 < e.points.count ? e.points[index + 1].t - 0.002 : d
            guard lo <= hi else { return false }
            e.points[index] = VolumeKey(t: max(lo, min(hi, t)), db: db, linear: e.points[index].linear); return true
        }
    }
    public func removeVolumePoint(_ id: UUID, index: Int) { editAudio(id) { e, _ in guard e.points.indices.contains(index) else { return false }; e.points.remove(at: index); return true } }
    /// Numeric edit of the whole curve (a list of points). Replaces; sorted and clamped to the item.
    public func setVolumePoints(_ id: UUID, _ pts: [VolumeKey]) { editAudio(id) { e, _ in guard e.points != pts else { return false }; e.points = pts; return true } }
    /// Removes the volume curve only; gain, mute and fades stay.
    public func resetVolumePoints(_ id: UUID) { editAudio(id) { e, _ in guard !e.points.isEmpty else { return false }; e.points = []; return true } }
    /// Sets the shape of the fade-in and/or fade-out (nil = leave); lengths and every other edit stay.
    public func setFadeCurves(_ id: UUID, fadeIn: FadeCurve? = nil, fadeOut: FadeCurve? = nil) {
        editAudio(id) { e, _ in
            var ch = false
            if let f = fadeIn, f != e.fadeInCurve { e.fadeInCurve = f; ch = true }
            if let f = fadeOut, f != e.fadeOutCurve { e.fadeOutCurve = f; ch = true }
            return ch
        }
    }
    /// Straightens the fade shapes without touching lengths or points.
    public func resetFadeCurves(_ id: UUID) { setFadeCurves(id, fadeIn: .linear, fadeOut: .linear) }

    // MARK: crossfade between two independent audio items (A2)
    public enum CrossfadeResult: Equatable, Sendable { case created(seconds: Double), noMaterial, locked, invalid(String) }
    /// Why the pair cannot be crossfaded (nil = it can, provided they overlap): both must be independent audio items, the outgoing one starting first and ending inside the incoming one.
    public func crossfadeBlocker(outgoing: Layer.ID, incoming: Layer.ID) -> String? {
        guard let o = project.layers.first(where: { $0.id == outgoing }), let i = project.layers.first(where: { $0.id == incoming }) else { return "missing" }
        if o.kind != .audio || i.kind != .audio || o.id == i.id { return "notAudio" }
        if project.lockedLanes.contains(.a2) { return "locked" }
        if o.start >= i.start - 1e-6 { return "order" }
        if o.end > i.end + 1e-6 { return "contained" }
        return nil
    }
    /// Crossfade of two A2 items. With a real overlap it only records the shape (the overlap is the crossfade). Items that merely touch get an overlap of `seconds` made from
    /// material that exists: the incoming item’s head is extended earlier, or — when it has no head material — the outgoing item’s tail is extended (`outgoingSourceLength` =
    /// length of its file). With neither, nothing changes and `.noMaterial` is returned: a crossfade is never faked by fading both items to silence.
    @discardableResult public func crossfade(outgoing: Layer.ID, incoming: Layer.ID, seconds: Double = 0.5, shape: CrossfadeShape = CrossfadeShape(), outgoingSourceLength: Double? = nil) -> CrossfadeResult {
        if let b = crossfadeBlocker(outgoing: outgoing, incoming: incoming) { return b == "locked" ? .locked : .invalid(b) }
        guard let o = project.layers.first(where: { $0.id == outgoing }), let l = project.layers.first(where: { $0.id == incoming }) else { return .invalid("missing") }
        let overlap = o.end - l.start
        var result = CrossfadeResult.invalid("noOverlap")
        commit { p in
            guard let ii = p.layers.firstIndex(where: { $0.id == incoming }), let oi = p.layers.firstIndex(where: { $0.id == outgoing }) else { return false }
            func link() { var e = p.layers[ii].audio ?? AudioEdit(); e.crossfade = CrossfadeLink(outgoing: outgoing, shape: shape); p.layers[ii].audio = e }
            if overlap >= 0.01 { link(); result = .created(seconds: overlap); return true }
            guard abs(overlap) <= 0.01 || overlap < 0 && -overlap <= 0.01 else { result = .invalid("gap"); return false }       // a gap is not a crossfade: move the item first
            let d = max(0.02, seconds)
            var q = p.layers[ii]
            if q.sourceStart >= d * q.speed - 1e-9, q.start - d >= 0 {          // head material of the incoming item
                q.start -= d; q.sourceStart -= d * q.speed; q.duration += d
                var row = q.row; while Self.overlaps(q, in: p) { row += 1; q.track = row }       // they overlap now: the incoming item takes the first free row
                p.layers[ii] = q; link(); result = .created(seconds: d); return true
            }
            if let n = outgoingSourceLength, n - p.layers[oi].sourceStart - p.layers[oi].sourceSpan >= d * p.layers[oi].speed - 1e-9 {   // tail material of the outgoing item
                var ext = p.layers[oi]; ext.duration += d
                guard !p.layers.contains(where: { $0.id != ext.id && $0.id != incoming && $0.kind == ext.kind && $0.row == ext.row && $0.start < ext.end - 1e-6 && ext.start < $0.end - 1e-6 }) else { result = .invalid("overlap"); return false }     // only the incoming item may be in the way (it moves to another row)
                p.layers[oi] = ext
                var q = p.layers[ii]; var row = q.row; while Self.overlaps(q, in: p) { row += 1; q.track = row }; p.layers[ii] = q
                link(); result = .created(seconds: d); return true
            }
            result = .noMaterial; return false
        }
        return result
    }
    /// Removes the crossfade (the overlap stays; both items then simply play together).
    public func removeCrossfade(incoming: Layer.ID) { editAudio(incoming) { e, _ in guard e.crossfade != nil else { return false }; e.crossfade = nil; return true } }
    /// Changes mode/curve of an existing crossfade.
    public func setCrossfadeShape(incoming: Layer.ID, _ shape: CrossfadeShape) {
        editAudio(incoming) { e, _ in guard var c = e.crossfade, c.shape != shape else { return false }; c.shape = shape; e.crossfade = c; return true }
    }
    /// Shape of the sound crossfade of a dissolve between main-track clips (`clip` = the incoming one).
    public func setDissolveShape(clip id: Clip.ID, _ shape: CrossfadeShape) {
        commit { p in guard let i = p.clips.firstIndex(where: { $0.id == id }), p.clips[i].dissolveShape != shape else { return false }; p.clips[i].dissolveShape = shape; return true }
    }
}
