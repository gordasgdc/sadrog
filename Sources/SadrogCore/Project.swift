// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// Legacy (format 2) zoom/pan on one clip. Only read on load: it is converted into the two-state animation (`Clip.endTransform`), the single animation system.
struct LegacyZoom: Codable, Equatable {
    var startScale: Double, endScale: Double, centerX: Double, centerY: Double
    /// Zoom about the normalised point (cx, cy): at scale s the point stays put, i.e. the frame is shifted by (0.5 - c)(s - 1).
    func transforms() -> (Transform, Transform) {
        func at(_ s: Double) -> Transform { Transform(x: (0.5 - centerX) * (s - 1), y: (0.5 - centerY) * (s - 1), scale: s) }
        return (at(startScale), at(endScale))
    }
}

public enum TextAlign: String, Codable, Sendable, CaseIterable { case leading, center, trailing }

public struct TextColor: Codable, Equatable, Sendable {
    public var r: Double, g: Double, b: Double, a: Double
    public init(r: Double, g: Double, b: Double, a: Double = 1) { self.r = max(0, min(1, r)); self.g = max(0, min(1, g)); self.b = max(0, min(1, b)); self.a = max(0, min(1, a)) }
    public static let white = TextColor(r: 1, g: 1, b: 1)
    public static let black = TextColor(r: 0, g: 0, b: 0)
    /// "#RRGGBB" (the leading # is optional); nil when it is not exactly six hex digits.
    public init?(hex: String) {
        let h = hex.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        self.init(r: Double((v >> 16) & 255) / 255, g: Double((v >> 8) & 255) / 255, b: Double(v & 255) / 255)
    }
    public var hex: String { String(format: "#%02X%02X%02X", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded())) }
}

/// A title on the dedicated text lane. Position/scale/opacity/rotation are a `Transform` (centre offset as a fraction of the frame, like every other visual),
/// optionally animated towards `endTransform`. `size` is the font height as a fraction of the frame height at scale 1.
public struct TextOverlay: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var start: Double          // timeline seconds
    public var duration: Double
    public var font: String           // PostScript or family name
    public var size: Double
    public var color: TextColor
    public var align: TextAlign
    public var transform: Transform
    public var endTransform: Transform?
    public var motion: Motion?
    /// Style (format 14): bold/italic on top of the chosen font, soft shadow, a rounded box behind the text (its colour carries its opacity), line spacing as a multiplier.
    public var bold = false, italic = false, shadow = false
    public var box: TextColor?
    public var lineSpacing = 1.0
    /// Underline and outline (format 14): an outline is drawn around the letters in its own colour; nil = none.
    public var underline = false
    public var outline: TextColor?
    /// How the title comes in and goes out (presets baked into ordinary keyframes by `TextAnimation.bake`); nil = none or edited by hand.
    public var anim: TextAnimation?
    public var end: Double { start + duration }
    public static let defaultFont = "Helvetica Neue"
    public init(id: UUID = UUID(), text: String, start: Double, duration: Double = 3, font: String = TextOverlay.defaultFont, size: Double = 0.08, color: TextColor = .white,
                align: TextAlign = .center, transform: Transform = Transform(y: 0.35), endTransform: Transform? = nil,
                bold: Bool = false, italic: Bool = false, shadow: Bool = false, box: TextColor? = nil, lineSpacing: Double = 1) {
        self.id = id; self.text = text; self.start = max(0, start); self.duration = duration; self.font = font; self.size = max(0.01, min(0.5, size))
        self.color = color; self.align = align; self.transform = transform; self.endTransform = endTransform
        self.bold = bold; self.italic = italic; self.shadow = shadow; self.box = box; self.lineSpacing = max(0.6, min(3, lineSpacing))
    }
    enum CodingKeys: String, CodingKey { case id, text, start, duration, font, size, color, align, transform, endTransform, x, y, bold, italic, shadow, box, lineSpacing, motion, underline, outline, anim }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let tr: Transform
        if let t = try c.decodeIfPresent(Transform.self, forKey: .transform) { tr = t }
        else { tr = Transform(x: (try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5) - 0.5, y: (try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.85) - 0.5) }   // format 2 stored a top-left-normalised centre
        self.init(id: try c.decode(UUID.self, forKey: .id), text: try c.decode(String.self, forKey: .text), start: try c.decode(Double.self, forKey: .start), duration: try c.decode(Double.self, forKey: .duration),
                  font: try c.decodeIfPresent(String.self, forKey: .font) ?? Self.defaultFont, size: try c.decodeIfPresent(Double.self, forKey: .size) ?? 0.07,
                  color: try c.decodeIfPresent(TextColor.self, forKey: .color) ?? .white, align: try c.decodeIfPresent(TextAlign.self, forKey: .align) ?? .center,
                  transform: tr, endTransform: try c.decodeIfPresent(Transform.self, forKey: .endTransform),
                  bold: try c.decodeIfPresent(Bool.self, forKey: .bold) ?? false, italic: try c.decodeIfPresent(Bool.self, forKey: .italic) ?? false, shadow: try c.decodeIfPresent(Bool.self, forKey: .shadow) ?? false,
                  box: try c.decodeIfPresent(TextColor.self, forKey: .box), lineSpacing: try c.decodeIfPresent(Double.self, forKey: .lineSpacing) ?? 1)
        motion = try c.decodeIfPresent(Motion.self, forKey: .motion)
        underline = try c.decodeIfPresent(Bool.self, forKey: .underline) ?? false; outline = try c.decodeIfPresent(TextColor.self, forKey: .outline); anim = try c.decodeIfPresent(TextAnimation.self, forKey: .anim)
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(text, forKey: .text); try c.encode(start, forKey: .start); try c.encode(duration, forKey: .duration)
        try c.encode(font, forKey: .font); try c.encode(size, forKey: .size); try c.encode(color, forKey: .color); try c.encode(align, forKey: .align)
        try c.encode(transform, forKey: .transform); try c.encodeIfPresent(endTransform, forKey: .endTransform)
        if bold { try c.encode(true, forKey: .bold) }; if italic { try c.encode(true, forKey: .italic) }; if shadow { try c.encode(true, forKey: .shadow) }
        try c.encodeIfPresent(box, forKey: .box); if lineSpacing != 1 { try c.encode(lineSpacing, forKey: .lineSpacing) }
        if let motion, !motion.isNeutral { try c.encode(motion, forKey: .motion) }
        if underline { try c.encode(true, forKey: .underline) }; try c.encodeIfPresent(outline, forKey: .outline); try c.encodeIfPresent(anim, forKey: .anim)
    }
}

/// How a title enters and leaves. The choice is kept so the inspector can show it; the effect itself is ordinary keyframes (the same animation as everything else).
public enum TextIn: String, Codable, CaseIterable, Sendable { case none, fade, slide, pop }
public enum TextOut: String, Codable, CaseIterable, Sendable { case none, fade, slide, shrink }
public struct TextAnimation: Codable, Equatable, Sendable {
    public var appear: TextIn = .none, disappear: TextOut = .none
    public var seconds = 0.5
    public init(appear: TextIn = .none, disappear: TextOut = .none, seconds: Double = 0.5) { self.appear = appear; self.disappear = disappear; self.seconds = max(0.1, min(3, seconds)) }
    public var isNone: Bool { appear == .none && disappear == .none }
    static let slideDistance = 0.06, popScale = 0.7
    /// Writes the entrance/exit as start state, keys and fades around the title's resting placement `rest`, replacing its earlier animation.
    public func bake(_ t: inout TextOverlay, rest: Transform) {
        let s = min(seconds, max(0.1, t.duration / 2 - 0.01))
        var a = rest, b: Transform? = nil, m = Motion(); var keys: [MotionKey] = []
        switch appear {
        case .none: break
        case .fade: m.fadeIn = s
        case .slide: a.y += Self.slideDistance; m.fadeIn = s
        case .pop: a.scale = rest.scale * Self.popScale; m.fadeIn = s
        }
        if appear != .none { keys.append(MotionKey(t: s, transform: rest)) }
        if disappear != .none {
            keys.append(MotionKey(t: t.duration - s, transform: rest)); m.fadeOut = s
            var e = rest
            switch disappear { case .slide: e.y += Self.slideDistance; case .shrink: e.scale = rest.scale * Self.popScale; default: break }
            b = e
        }
        m.keys = keys; m.easing = .smooth; m.normalize()
        t.transform = a; t.endTransform = b; t.motion = m.isNeutral ? nil : m; t.anim = isNone ? nil : self
    }
}

/// Placement of a visual item in the frame: centre offset as a fraction of the frame (x right, y down), uniform scale, opacity, rotation in degrees (positive = clockwise).
public struct Transform: Codable, Equatable, Sendable {
    public static let identity = Transform()
    public var x: Double, y: Double, scale: Double, opacity: Double, rotation: Double
    public init(x: Double = 0, y: Double = 0, scale: Double = 1, opacity: Double = 1, rotation: Double = 0) {
        self.x = max(-2, min(2, x)); self.y = max(-2, min(2, y)); self.scale = max(0.05, min(8, scale)); self.opacity = max(0, min(1, opacity))
        var r = rotation.truncatingRemainder(dividingBy: 360); if r > 180 { r -= 360 } else if r < -180 { r += 360 }; self.rotation = r
    }
    enum CodingKeys: String, CodingKey { case x, y, scale, opacity, rotation }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(x: try c.decodeIfPresent(Double.self, forKey: .x) ?? 0, y: try c.decodeIfPresent(Double.self, forKey: .y) ?? 0, scale: try c.decodeIfPresent(Double.self, forKey: .scale) ?? 1,
                  opacity: try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 1, rotation: try c.decodeIfPresent(Double.self, forKey: .rotation) ?? 0)
    }
    public var isIdentity: Bool { self == .identity }
    /// Linear blend of two states (rotation by the short way round is not needed: animations keep rotation fixed at the start state's value).
    public static func blend(_ a: Transform, _ b: Transform, _ u: Double) -> Transform {
        func l(_ p: Double, _ q: Double) -> Double { p + (q - p) * u }
        return Transform(x: l(a.x, b.x), y: l(a.y, b.y), scale: l(a.scale, b.scale), opacity: l(a.opacity, b.opacity), rotation: l(a.rotation, b.rotation))
    }
    /// Smooth ease-in/ease-out used by every two-state animation (preview and export evaluate the same function).
    public static func ease(_ u: Double) -> Double { let t = max(0, min(1, u)); return t * t * (3 - 2 * t) }
    /// The state shown `elapsed` seconds into an item of `duration`, given its start state and optional end state.
    public static func state(start a: Transform, end b: Transform?, motion: Motion?, elapsed: Double, duration: Double) -> Transform {
        if let motion, !motion.isNeutral { return motion.state(start: a, end: b, elapsed: elapsed, duration: duration) }
        return state(start: a, end: b, elapsed: elapsed, duration: duration)
    }
    public static func state(start a: Transform, end b: Transform?, elapsed: Double, duration: Double) -> Transform {
        guard let b else { return a }
        return blend(a, b, ease(duration > 0 ? elapsed / duration : 0))
    }
}

/// How a segment between two states is traversed.
public enum Easing: String, Codable, CaseIterable, Sendable {
    case smooth, linear, easeIn, easeOut
    public func apply(_ u: Double) -> Double {
        let t = max(0, min(1, u))
        switch self {
        case .smooth: return t * t * (3 - 2 * t)
        case .linear: return t
        case .easeIn: return t * t
        case .easeOut: return 1 - (1 - t) * (1 - t)
        }
    }
}
/// A state at `t` seconds from the item's start (strictly inside the item; the item's own `transform`/`endTransform` are the first and last states).
public struct MotionKey: Codable, Equatable, Sendable {
    public var t: Double
    public var transform: Transform
    public init(t: Double, transform: Transform) { self.t = t; self.transform = transform }
}
/// Everything that moves or fades a visual item beyond its two-state animation: extra keyframes, the easing of every segment, and visual fades
/// (opacity ramps at the item's edges). nil on an item = none of it (older projects look exactly as before).
/// A cut or a trim never changes what is shown: the pieces keep the original curve through `headSlice`/`tailSlice` (the part of the first/last
/// segment's easing curve that the piece covers) and `fadeInStart`/`fadeOutEnd` (where on its ramp a fade begins/ends) — see `Animation.partition`.
public struct Motion: Codable, Equatable, Sendable {
    public var keys: [MotionKey] = []
    public var easing: Easing = .smooth
    public var fadeIn = 0.0, fadeOut = 0.0       // seconds
    public var headSlice = 0.0, tailSlice = 1.0
    public var fadeInStart = 0.0, fadeOutEnd = 0.0
    public init(keys: [MotionKey] = [], easing: Easing = .smooth, fadeIn: Double = 0, fadeOut: Double = 0) { self.keys = keys; self.easing = easing; self.fadeIn = max(0, fadeIn); self.fadeOut = max(0, fadeOut); normalize() }
    enum CodingKeys: String, CodingKey { case keys, easing, fadeIn, fadeOut, headSlice, tailSlice, fadeInStart, fadeOutEnd }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        keys = try c.decodeIfPresent([MotionKey].self, forKey: .keys) ?? []; easing = try c.decodeIfPresent(Easing.self, forKey: .easing) ?? .smooth
        fadeIn = try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0; fadeOut = try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0
        headSlice = try c.decodeIfPresent(Double.self, forKey: .headSlice) ?? 0; tailSlice = try c.decodeIfPresent(Double.self, forKey: .tailSlice) ?? 1
        fadeInStart = try c.decodeIfPresent(Double.self, forKey: .fadeInStart) ?? 0; fadeOutEnd = try c.decodeIfPresent(Double.self, forKey: .fadeOutEnd) ?? 0
        normalize()
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(keys, forKey: .keys); try c.encode(easing, forKey: .easing); try c.encode(fadeIn, forKey: .fadeIn); try c.encode(fadeOut, forKey: .fadeOut)
        if headSlice != 0 { try c.encode(headSlice, forKey: .headSlice) }; if tailSlice != 1 { try c.encode(tailSlice, forKey: .tailSlice) }
        if fadeInStart != 0 { try c.encode(fadeInStart, forKey: .fadeInStart) }; if fadeOutEnd != 0 { try c.encode(fadeOutEnd, forKey: .fadeOutEnd) }
    }
    public var isNeutral: Bool { keys.isEmpty && easing == .smooth && fadeIn == 0 && fadeOut == 0 && headSlice == 0 && tailSlice == 1 }
    public mutating func normalize() {
        keys.sort { $0.t < $1.t }; fadeIn = max(0, fadeIn); fadeOut = max(0, fadeOut)
        headSlice = max(0, min(1, headSlice)); tailSlice = max(0, min(1, tailSlice)); fadeInStart = max(0, min(1, fadeInStart)); fadeOutEnd = max(0, min(1, fadeOutEnd))
    }
    /// Points of the curve: the item's start state, the keys strictly inside it, and the end state when there is one.
    func points(start a: Transform, end b: Transform?, duration: Double) -> [(t: Double, v: Transform)] {
        var pts: [(t: Double, v: Transform)] = [(0, a)] + keys.filter { $0.t > 0.0001 && $0.t < duration - 0.0001 }.map { ($0.t, $0.transform) }
        if let b { pts.append((duration, b)) }
        return pts
    }
    /// Easing of segment `i` of `n`, restricted to the slice of the curve the item covers (identity for an untouched segment).
    func eased(_ v: Double, segment i: Int, of n: Int) -> Double {
        let u0 = i == 0 ? headSlice : 0, u1 = i == n - 1 ? tailSlice : 1
        if u0 == 0 && u1 == 1 { return easing.apply(v) }
        let den = easing.apply(u1) - easing.apply(u0)
        return abs(den) < 1e-12 ? v : (easing.apply(u0 + (u1 - u0) * max(0, min(1, v))) - easing.apply(u0)) / den
    }
    /// The geometric state (no fades) `elapsed` seconds into an item of `duration`.
    public func placement(start a: Transform, end b: Transform?, elapsed: Double, duration: Double) -> Transform {
        let pts = points(start: a, end: b, duration: duration)
        if elapsed <= 0 || pts.count == 1 { return elapsed <= 0 ? pts[0].v : pts.last!.v }
        if let i = pts.indices.dropLast().first(where: { elapsed < pts[$0 + 1].t }) {
            let (p0, p1) = (pts[i], pts[i + 1]); return Transform.blend(p0.v, p1.v, eased((elapsed - p0.t) / max(1e-9, p1.t - p0.t), segment: i, of: pts.count - 1))
        }
        return pts.last!.v
    }
    /// Opacity multiplier of the fades at `elapsed`.
    public func fadeFactor(elapsed: Double, duration: Double) -> Double {
        var k = 1.0
        if fadeIn > 0 { k *= Easing.smooth.apply(fadeInStart + (1 - fadeInStart) * min(1, elapsed / fadeIn)) }
        if fadeOut > 0 { k *= Easing.smooth.apply(fadeOutEnd + (1 - fadeOutEnd) * min(1, (duration - elapsed) / fadeOut)) }
        return k
    }
    /// The state `elapsed` seconds into an item of `duration`: start → keys → end (when there is one; otherwise the last key holds), each segment eased, then the fades.
    public func state(start a: Transform, end b: Transform?, elapsed: Double, duration: Double) -> Transform {
        var out = placement(start: a, end: b, elapsed: elapsed, duration: duration)
        out.opacity *= fadeFactor(elapsed: elapsed, duration: duration); return out
    }
}

/// The whole look-over-time of one visual item: start state, optional end state, optional motion. Cutting or trimming an item goes through here, in ONE place.
public struct Animation: Equatable, Sendable {
    public var a: Transform, b: Transform?, motion: Motion?
    public init(a: Transform, b: Transform?, motion: Motion?) { self.a = a; self.b = b; self.motion = motion }
    /// Placement without fades (what a held frame or a key must capture is the placement; fades are handled separately).
    public func placement(elapsed: Double, duration: Double) -> Transform {
        (motion ?? Motion()).placement(start: a, end: b, elapsed: elapsed, duration: duration)
    }
    public func state(elapsed: Double, duration: Double) -> Transform { Transform.state(start: a, end: b, motion: motion, elapsed: elapsed, duration: duration) }
    /// The two pieces of an item of `duration` cut `off` seconds in. Each piece shows, over its own time, exactly what the original showed there.
    public func partition(duration D: Double, at off: Double) -> (Animation, Animation) {
        let m = motion ?? Motion(), pts = m.points(start: a, end: b, duration: D), n = pts.count - 1
        let atCut = placement(elapsed: off, duration: D)
        // piece 1: start, keys before the cut, then the value at the cut as end state (when anything animates)
        var m1 = m, m2 = m
        m1.keys = m.keys.filter { $0.t < off - 0.0001 }
        m2.keys = m.keys.filter { $0.t > off + 0.0001 && $0.t < D - 0.0001 }.map { MotionKey(t: $0.t - off, transform: $0.transform) }
        func seg(_ lo: Bool) -> (i: Int, r: Double)? {     // segment holding the cut (cut on a key: the one before it for piece 1, the one after for piece 2)
            guard n >= 1 else { return nil }
            let idx = lo ? pts.indices.dropLast().last(where: { pts[$0].t < off - 0.0001 }) : pts.indices.dropLast().last(where: { pts[$0].t <= off + 0.0001 })
            guard let i = idx, off <= pts[i + 1].t + 0.0001 || !lo else { return nil }
            if !lo, off >= pts[n].t - 0.0001 { return nil }
            let w = max(0, min(1, (off - pts[i].t) / max(1e-9, pts[i + 1].t - pts[i].t)))
            let u0 = i == 0 ? m.headSlice : 0, u1 = i == n - 1 ? m.tailSlice : 1
            return (i, u0 + (u1 - u0) * w)
        }
        var b1: Transform? = nil
        if let s1 = seg(true) { b1 = atCut; m1.tailSlice = s1.r }
        else if n >= 1, off <= pts[n].t + 0.0001 { b1 = atCut }       // cut at/after the last point: hold or end state reached
        if let s2 = seg(false) { m2.headSlice = s2.r } else { m2.headSlice = 0 }
        if seg(false) == nil, m2.keys.isEmpty { m2.tailSlice = 1 }
        // fades: the fade-in stays on the first piece (the rest of its ramp goes on to the second), the fade-out on the second
        if m.fadeIn > 0, off < m.fadeIn {
            let ps = m.fadeInStart + (1 - m.fadeInStart) * off / m.fadeIn
            m2.fadeIn = m.fadeIn - off; m2.fadeInStart = ps
        } else { m2.fadeIn = 0; m2.fadeInStart = 0 }
        if m.fadeOut > 0, off > D - m.fadeOut {
            let pe = m.fadeOutEnd + (1 - m.fadeOutEnd) * (D - off) / m.fadeOut
            m1.fadeOut = off - (D - m.fadeOut); m1.fadeOutEnd = pe
        } else { m1.fadeOut = 0; m1.fadeOutEnd = 0 }
        // the second piece keeps the original end state; its start is what the original showed at the cut
        let two = Animation(a: atCut, b: b, motion: m2.isNeutral ? nil : m2)
        let one = Animation(a: a, b: b1, motion: m1.isNeutral ? nil : m1)
        return (one, two)
    }
}
/// Anything with a start state, an optional end state and a motion: clips, video layers and titles. `cut` is the ONLY way an item is split.
public protocol Animated { var transform: Transform { get set }; var endTransform: Transform? { get set }; var motion: Motion? { get set } }
extension Animated {
    public var animation: Animation { Animation(a: transform, b: endTransform, motion: motion) }
    /// Splits the animation of `self` (duration `d`) at `off`: `self` becomes the first piece, `other` the second.
    public mutating func cut(into other: inout Self, duration d: Double, at off: Double) {
        let (x, y) = animation.partition(duration: d, at: off)
        (transform, endTransform, motion) = (x.a, x.b, x.motion)
        (other.transform, other.endTransform, other.motion) = (y.a, y.b, y.motion)
    }
    /// A trim keeps what the item showed over the part that stays (extending is left alone: the end state holds).
    public mutating func trimmedFront(by d: Double, duration D: Double) { guard d > 0 else { return }; var t = self; cut(into: &t, duration: D, at: d); self = t }
    public mutating func trimmedBack(by d: Double, duration D: Double) { guard d > 0 else { return }; var t = self; cut(into: &t, duration: D, at: D - d) }
}

/// Sound settings of one recording file: muted tracks, track volumes (dB) and effect chains, all by the track index inside that file.
public struct RecordingSounds: Codable, Equatable, Sendable {
    public var muted: Set<Int> = []
    public var gains: [Int: Double] = [:]
    public var effects: [Int: [AudioEffect]] = [:]
    public var isEmpty: Bool { muted.isEmpty && gains.isEmpty && effects.isEmpty }
    public init(muted: Set<Int> = [], gains: [Int: Double] = [:], effects: [Int: [AudioEffect]] = [:]) { self.muted = muted; self.gains = gains; self.effects = effects }
}

/// Sound edits of one timeline item. A2 items use all fields; on A1 (main clips) only the fades apply — the recording's sources have their
/// own volume/mute (`sourceGains`, `mutedSources`). Neutral = all zero/false; projects without the key decode to neutral.
public struct AudioEdit: Codable, Equatable, Sendable {
    public var gainDB: Double = 0
    public var muted = false
    public var fadeIn: Double = 0      // seconds, linear volume ramp from silence at the item's start
    public var fadeOut: Double = 0     // seconds, linear ramp to silence at the item's end
    public init(gainDB: Double = 0, muted: Bool = false, fadeIn: Double = 0, fadeOut: Double = 0) { self.gainDB = gainDB; self.muted = muted; self.fadeIn = max(0, fadeIn); self.fadeOut = max(0, fadeOut) }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(gainDB: try c.decodeIfPresent(Double.self, forKey: .gainDB) ?? 0, muted: try c.decodeIfPresent(Bool.self, forKey: .muted) ?? false,
                  fadeIn: try c.decodeIfPresent(Double.self, forKey: .fadeIn) ?? 0, fadeOut: try c.decodeIfPresent(Double.self, forKey: .fadeOut) ?? 0)
    }
    public var isNeutral: Bool { gainDB == 0 && !muted && fadeIn == 0 && fadeOut == 0 }
    /// Fades actually applied to an item of `duration`. The stored values are kept as typed; if the item became shorter than both fades
    /// (trim), both are scaled down in proportion so they meet without overlapping — lengthening the item again restores them.
    public func effectiveFades(duration d: Double) -> (fadeIn: Double, fadeOut: Double) {
        let i = max(0, fadeIn), o = max(0, fadeOut)
        guard d > 0, i + o > d else { return (i, o) }
        let k = d / (i + o); return (i * k, o * k)          // in proportion to the stored values; each one then fits the item
    }
}

public enum LayerKind: String, Codable, Sendable { case video, audio }

/// The timeline lanes (t = titles, c = callouts, v2 = overlays, v1 = main video, a1 = sound linked to the main track, a2 = independent audio). Visual lanes (t, v2, v1) can be hidden; sound lanes (a1 = sound linked to the main track, a2 = independent audio) can be muted.
public enum TrackLane: String, Codable, Sendable, CaseIterable { case t, c, v2, v1, a1, a2
    public var isVideo: Bool { self != .a1 && self != .a2 }
}

/// An item on an independent lane (video overlay above the main track, or a separate audio lane). `start` is timeline seconds.
public struct Layer: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var kind: LayerKind
    public var media: String
    public var start: Double
    public var sourceStart: Double
    public var duration: Double
    public var transform: Transform
    public var endTransform: Transform?       // two-state animation (video layers): start state = `transform`
    public var motion: Motion?                // extra keyframes, easing and visual fades (format 14); nil = none
    public var audio: AudioEdit?              // sound edits (audio items); nil = neutral
    public var crop: CircleCrop?              // „Prezentator în cerc” (video items); nil = the full rectangle
    public var rectCrop: RectCrop?            // rectangular crop of the picture (video items); nil = uncropped. Ignored while the circle crop is on.
    /// Row of the item inside its lane (0 = the first V2 / A2 row). Items overlap only on DIFFERENT rows; a higher video row is drawn on top.
    /// nil (older projects) = row 0.
    public var track: Int?
    public var label: String?                 // user name; nil = the file name
    /// Audio items only: the main-track clip whose sound this item was detached from (format 15). Informational link — the item is fully independent; nil = not detached.
    public var linkedClip: UUID?
    /// Audio items only: the sound comes from a recording whose per-source identity (stem, volume, mute, effects) it keeps. Independent of the montage link
    /// `linkedClip`: a copy loses the link (it is its own item) but keeps its sound. nil = not set (older projects derive it from `linkedClip`).
    public var sourceIdentity: Bool?
    public var keepsSource: Bool { sourceIdentity == true || linkedClip != nil }
    public var row: Int { track ?? 0 }
    public var end: Double { start + duration }
    public init(id: UUID = UUID(), kind: LayerKind, media: String, start: Double, sourceStart: Double = 0, duration: Double, transform: Transform = .identity, endTransform: Transform? = nil) {
        self.id = id; self.kind = kind; self.media = media; self.start = max(0, start); self.sourceStart = sourceStart; self.duration = duration; self.transform = transform; self.endTransform = endTransform
    }
}

/// One piece of a source recording placed on the timeline. Times in seconds.
public struct Clip: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var media: String          // path of the recording file (absolute)
    public var sourceStart: Double
    public var duration: Double
    public var transform: Transform
    public var endTransform: Transform?       // two-state animation: start state = `transform`
    public var motion: Motion?                // extra keyframes, easing and visual fades (format 14); nil = none
    public var audio: AudioEdit?              // fades of the linked sound (A1); nil = neutral
    public var crop: CircleCrop?              // „Prezentator în cerc”; nil = the full rectangle
    public var rectCrop: RectCrop?            // rectangular crop of the picture; nil = uncropped. Ignored while the circle crop is on.
    public var label: String?                 // user name of the clip; nil = the file name
    /// Freeze frame: the picture at `sourceStart` is held for the whole duration; it has no sound. Trims change only the length.
    public var held = false
    /// Cross-dissolve with the PREVIOUS clip: the first `dissolve` seconds of this clip overlap the last seconds of the previous one (picture and sound blend, the timeline gets that much shorter). 0 = a plain cut.
    public var dissolve = 0.0
    /// Cursor highlight / click rings drawn from the recording's pointer track (`mouse.json` next to the media); nil = none.
    public var mouseFX: MouseFX?
    /// The clip's own sound was detached into an independent audio item (format 15): the picture stays, its A1 sound is no longer played by the clip.
    public var audioDetached = false
    public init(id: UUID = UUID(), media: String, sourceStart: Double, duration: Double, transform: Transform = .identity, endTransform: Transform? = nil) {
        self.id = id; self.media = media; self.sourceStart = sourceStart; self.duration = duration; self.transform = transform; self.endTransform = endTransform
    }
    enum CodingKeys: String, CodingKey { case id, media, sourceStart, duration, zoom, transform, endTransform, audio, crop, rectCrop, label, held, motion, dissolve, mouseFX, audioDetached }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(media, forKey: .media); try c.encode(sourceStart, forKey: .sourceStart); try c.encode(duration, forKey: .duration)
        try c.encode(transform, forKey: .transform); try c.encodeIfPresent(endTransform, forKey: .endTransform)
        try c.encodeIfPresent(audio, forKey: .audio)
        try c.encodeIfPresent(crop, forKey: .crop); try c.encodeIfPresent(rectCrop, forKey: .rectCrop); try c.encodeIfPresent(label, forKey: .label)
        if held { try c.encode(true, forKey: .held) }
        if audioDetached { try c.encode(true, forKey: .audioDetached) }
        if dissolve > 0 { try c.encode(dissolve, forKey: .dissolve) }
        if let mouseFX, !mouseFX.isOff { try c.encode(mouseFX, forKey: .mouseFX) }
        if let motion, !motion.isNeutral { try c.encode(motion, forKey: .motion) }
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        label = try c.decodeIfPresent(String.self, forKey: .label)
        held = try c.decodeIfPresent(Bool.self, forKey: .held) ?? false
        audioDetached = try c.decodeIfPresent(Bool.self, forKey: .audioDetached) ?? false
        dissolve = max(0, try c.decodeIfPresent(Double.self, forKey: .dissolve) ?? 0)
        mouseFX = try c.decodeIfPresent(MouseFX.self, forKey: .mouseFX)
        motion = try c.decodeIfPresent(Motion.self, forKey: .motion)
        audio = try c.decodeIfPresent(AudioEdit.self, forKey: .audio)
        crop = try c.decodeIfPresent(CircleCrop.self, forKey: .crop); rectCrop = try c.decodeIfPresent(RectCrop.self, forKey: .rectCrop)
        id = try c.decode(UUID.self, forKey: .id); media = try c.decode(String.self, forKey: .media)
        sourceStart = try c.decode(Double.self, forKey: .sourceStart); duration = try c.decode(Double.self, forKey: .duration)
        transform = try c.decodeIfPresent(Transform.self, forKey: .transform) ?? .identity
        endTransform = try c.decodeIfPresent(Transform.self, forKey: .endTransform)
        if let z = try c.decodeIfPresent(LegacyZoom.self, forKey: .zoom), endTransform == nil { (transform, endTransform) = (z.transforms().0, z.transforms().1) }     // format 2 zoom → the one animation system
    }
}

/// Non-destructive rectangular crop of a picture: how much is cut from each side, as a fraction of the SOURCE picture (0…0.9 per side, left+right and top+bottom < 0.95).
/// The cropped picture is what the clip transform (position/scale/rotation) then places, so the crop never depends on the viewer zoom or the output size.
public struct RectCrop: Codable, Equatable, Sendable {
    public var left: Double, right: Double, top: Double, bottom: Double
    public init(left: Double = 0, right: Double = 0, top: Double = 0, bottom: Double = 0) { self.left = left; self.right = right; self.top = top; self.bottom = bottom; normalize() }
    public var isNone: Bool { left == 0 && right == 0 && top == 0 && bottom == 0 }
    public mutating func normalize() {
        func c(_ v: Double) -> Double { max(0, min(0.9, v.isFinite ? v : 0)) }
        left = c(left); right = c(right); top = c(top); bottom = c(bottom)
        if left + right > 0.95 { let k = 0.95 / (left + right); left *= k; right *= k }
        if top + bottom > 0.95 { let k = 0.95 / (top + bottom); top *= k; bottom *= k }
    }
    /// The placement (centre, scale) that keeps every kept pixel at the same canvas position when the crop of a picture of size `n0` changes from `old` to `new`
    /// (the cropped picture is centred on the transform and fitted into the canvas `render`, so a bare crop change would move and rescale the content).
    public static func placement(from old: RectCrop?, to new: RectCrop, _ t: Transform, natural n0: CGSize, render R: CGSize) -> Transform {
        let w0 = (old ?? RectCrop()).window(of: n0), w1 = new.window(of: n0)
        guard w0.width > 0, w0.height > 0, w1.width > 0, w1.height > 0, R.width > 0, R.height > 0 else { return t }
        let f0 = min(R.width / w0.width, R.height / w0.height), f1 = min(R.width / w1.width, R.height / w1.height)
        let s = f0 * t.scale, a = t.rotation * .pi / 180
        let dx = (w1.midX - w0.midX) * s, dy = (w1.midY - w0.midY) * s
        let cx = R.width / 2 + t.x * R.width + dx * cos(a) - dy * sin(a), cy = R.height / 2 + t.y * R.height + dx * sin(a) + dy * cos(a)
        return Transform(x: (cx - R.width / 2) / R.width, y: (cy - R.height / 2) / R.height, scale: s / f1, opacity: t.opacity, rotation: t.rotation)
    }
    /// Kept part of a picture of size `n` in top-left, y-down pixel coordinates.
    public func window(of n: CGSize) -> CGRect { CGRect(x: left * n.width, y: top * n.height, width: n.width * (1 - left - right), height: n.height * (1 - top - bottom)) }
}

/// The shape of a callout's selection. All shapes share the same box (`x, y, w, h`), so move/resize/guides/snapping work identically for each.
public enum CalloutShape: String, Codable, Sendable, CaseIterable { case rect, ellipse, freehand, line, arrow }

/// A point of a freehand outline, relative to the callout's box (0…1 on each axis), so moving or resizing the box moves/scales the outline.
public struct CalloutPoint: Codable, Equatable, Sendable { public var x: Double, y: Double; public init(x: Double, y: Double) { self.x = x; self.y = y } }

/// A local region effect, split into SELECTION (shape + box, `invert`, `feather`) and EFFECT (`dim`, `blur`). The effect is applied OUTSIDE the selection
/// (highlight), or INSIDE it when `invert` is on (e.g. blurring something to hide it). The region lives in frame coordinates (0…1 of width/height, origin top-left,
/// y down) — independent of the viewer zoom and of the window size.
public struct Callout: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var start: Double          // timeline seconds
    public var duration: Double
    public var x: Double, y: Double, w: Double, h: Double   // box: top-left corner and size, fractions of the frame
    public var dim: Double            // 0…1: how much the affected area is darkened
    public var blur: Double           // 0…1: blur of the affected area (1 = 3% of the frame height as Gaussian radius)
    public var corner: Double         // 0…0.5: rect only — corner radius as a fraction of the shorter side
    public var shape: CalloutShape
    public var points: [CalloutPoint] // freehand outline relative to the box (≥ 3 points, else the shape falls back to a rectangle)
    public var invert: Bool           // false: effect outside the selection; true: effect inside it
    public var feather: Double        // 0…1: soft edge (1 = 5% of the frame height)
    public var magnify: Double        // 0…4: local magnification INSIDE the selection, extra on top of 1× (0 = off, 1 = 200%); about the box centre
    public var outline: Double        // 0…1: outline width around the selection (1 = 5% of the frame height); 0 = none
    public var outlineColor: TextColor
    public var shadow: Double         // 0…1: soft shadow just outside the selection (1 = 4% of the frame height of blur); 0 = none
    /// Line/arrow only: stroke thickness (1 = 2% of the frame height). The stroke is painted in `outlineColor`; `points` = start and end, relative to the box.
    public var lineWidth = 0.4
    public var overlays = false       // bound callouts act on their clip's picture only; true = also on the overlays above it (presenter, V2). Unbound callouts always act on everything below them.
    public var layerID: UUID?         // the video overlay (V2) this callout belongs to: moves with it, is cut with it, disappears with it, and acts only inside that overlay's picture. Never combined with clipID.
    public var clipID: UUID?          // the clip this callout belongs to: it moves with the clip, is cut with it and disappears with it. nil = independent (older projects)
    public var end: Double { start + duration }
    public static let minSide = 0.02
    public init(id: UUID = UUID(), start: Double, duration: Double = 3, x: Double = 0.3, y: Double = 0.3, w: Double = 0.4, h: Double = 0.4, dim: Double = 0.6, blur: Double = 0, corner: Double = 0.1,
                shape: CalloutShape = .rect, points: [CalloutPoint] = [], invert: Bool = false, feather: Double = 0,
                magnify: Double = 0, outline: Double = 0, outlineColor: TextColor = TextColor(r: 1, g: 0.85, b: 0.2), shadow: Double = 0, clipID: UUID? = nil, layerID: UUID? = nil) {
        self.id = id; self.start = max(0, start); self.duration = duration; self.x = x; self.y = y; self.w = w; self.h = h; self.dim = dim; self.blur = blur; self.corner = corner
        self.shape = shape; self.points = points; self.invert = invert; self.feather = feather
        self.magnify = magnify; self.outline = outline; self.outlineColor = outlineColor; self.shadow = shadow; self.clipID = clipID; self.layerID = layerID
        normalize()
    }
    enum CodingKeys: String, CodingKey { case id, start, duration, x, y, w, h, dim, blur, corner, shape, points, invert, feather, magnify, outline, outlineColor, shadow, clipID, overlays, layerID, lineWidth }
    public init(from d: Decoder) throws {   // projects saved before shapes existed have none of the new keys
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); start = try c.decode(Double.self, forKey: .start); duration = try c.decode(Double.self, forKey: .duration)
        x = try c.decode(Double.self, forKey: .x); y = try c.decode(Double.self, forKey: .y); w = try c.decode(Double.self, forKey: .w); h = try c.decode(Double.self, forKey: .h)
        dim = try c.decode(Double.self, forKey: .dim); blur = try c.decode(Double.self, forKey: .blur); corner = try c.decode(Double.self, forKey: .corner)
        shape = try c.decodeIfPresent(CalloutShape.self, forKey: .shape) ?? .rect
        points = try c.decodeIfPresent([CalloutPoint].self, forKey: .points) ?? []
        invert = try c.decodeIfPresent(Bool.self, forKey: .invert) ?? false
        feather = try c.decodeIfPresent(Double.self, forKey: .feather) ?? 0
        magnify = try c.decodeIfPresent(Double.self, forKey: .magnify) ?? 0       // older projects: no magnification, outline or shadow → look unchanged
        outline = try c.decodeIfPresent(Double.self, forKey: .outline) ?? 0
        outlineColor = try c.decodeIfPresent(TextColor.self, forKey: .outlineColor) ?? TextColor(r: 1, g: 0.85, b: 0.2)
        shadow = try c.decodeIfPresent(Double.self, forKey: .shadow) ?? 0
        clipID = try c.decodeIfPresent(UUID.self, forKey: .clipID)
        overlays = try c.decodeIfPresent(Bool.self, forKey: .overlays) ?? false
        lineWidth = try c.decodeIfPresent(Double.self, forKey: .lineWidth) ?? 0.4
        layerID = try c.decodeIfPresent(UUID.self, forKey: .layerID)
        normalize()
    }
    /// Clamps every value into its valid range; the box always stays inside the frame and at least `minSide` wide/high.
    public mutating func normalize() {
        w = max(Self.minSide, min(1, w)); h = max(Self.minSide, min(1, h))
        x = max(0, min(1 - w, x)); y = max(0, min(1 - h, y))
        dim = max(0, min(1, dim)); blur = max(0, min(1, blur)); corner = max(0, min(0.5, corner)); feather = max(0, min(1, feather))
        lineWidth = max(0.1, min(3, lineWidth.isFinite ? lineWidth : 0.4)); magnify = max(0, min(4, magnify)); outline = max(0, min(1, outline)); shadow = max(0, min(1, shadow))
        start = max(0, start)
        if points.count > 4000 { points = Array(points.prefix(4000)) }
        points = points.map { CalloutPoint(x: max(0, min(1, $0.x)), y: max(0, min(1, $0.y))) }
    }
    /// A rectangle/ellipse that only draws its frame: no darkening, blur or magnification, a visible outline. This is the "rectangular annotation".
    public var isFrameOnly: Bool { (shape == .rect || shape == .ellipse) && dim == 0 && blur == 0 && magnify == 0 && outline > 0 }
    /// Turns the region into a frame-only annotation (keeps the colour and a chosen thickness; 0.35 when there was none).
    public mutating func makeFrameOnly() { dim = 0; blur = 0; magnify = 0; shadow = 0; if outline < 0.05 { outline = 0.35 }; invert = false }
    /// Back to a spotlight: darkens what is outside the region again.
    public mutating func makeSpotlight() { if dim < 0.05 { dim = 0.6 } }
    /// Makes this a straight line or an arrow from `a` to `b` (frame fractions): the box is their bounding box (at least `minSide`, centred on the stroke), the points relative to it.
    /// A line/arrow paints a stroke, it does not dim the picture, so the dim goes to 0.
    public mutating func setStroke(_ kind: CalloutShape, from a: CalloutPoint, to b: CalloutPoint) {
        guard kind == .line || kind == .arrow else { return }
        let ex = abs(b.x - a.x), ey = abs(b.y - a.y), w0 = max(Self.minSide, ex), h0 = max(Self.minSide, ey)
        let x0 = min(a.x, b.x) - (w0 - ex) / 2, y0 = min(a.y, b.y) - (h0 - ey) / 2
        shape = kind; dim = 0; blur = 0; feather = 0; invert = false; w = w0; h = h0; x = x0; y = y0
        points = [CalloutPoint(x: (a.x - x0) / w0, y: (a.y - y0) / h0), CalloutPoint(x: (b.x - x0) / w0, y: (b.y - y0) / h0)]
        normalize()
    }
    /// Sets a freehand outline from points in frame coordinates: the box becomes their bounding box (at least `minSide`), the points are stored relative to it.
    public mutating func setFreehand(frame pts: [CalloutPoint]) {
        guard pts.count >= 3, let x0 = pts.map(\.x).min(), let x1 = pts.map(\.x).max(), let y0 = pts.map(\.y).min(), let y1 = pts.map(\.y).max() else { return }
        let w0 = max(Self.minSide, x1 - x0), h0 = max(Self.minSide, y1 - y0)
        shape = .freehand; x = x0; y = y0; w = w0; h = h0
        points = pts.map { CalloutPoint(x: ($0.x - x0) / w0, y: ($0.y - y0) / h0) }
        normalize()
    }
}

public struct TimelineMarker: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var time: Double
    public var name: String = ""
    public init(time: Double, name: String = "") { self.time = time; self.name = name }
}

public struct SadrogProject: Codable, Equatable, Sendable {
    public static let currentFormat = 16   // 16 keys source volume/mute/effects by recording (media path);  15 adds detached clip audio (an independent A2 item linked to its clip);  13 adds locked lanes and optional clip/overlay names; 12 adds the circle crop of video clips/overlays („Prezentator în cerc”); 11 adds audio effect chains (Audio Units) per recording source; 10 adds the master (mix) volume; 9 adds per-clip audio edits (A2 volume/mute, fades on A1 clips and A2 items); 8 adds per-source volume in dB; 7 adds the document format (canvas size + frame rate); 2 adds clip zoom + text overlays; 3 adds transforms, overlay/audio layers and a material library; 4 adds muted/hidden lanes; 5 adds callouts; 6 adds muted sources of the main sound (all optional on load)
    public var formatVersion = SadrogProject.currentFormat
    public var name: String
    public var clips: [Clip]
    public var texts: [TextOverlay]
    public var callouts: [Callout] = []
    public var layers: [Layer]       // video overlays (lane V2) and independent audio (lane A2)
    public var library: [String]     // imported material paths, in import order
    public var hiddenLanes: Set<TrackLane>   // video lanes not rendered (preview and export)
    public var mutedLanes: Set<TrackLane>    // sound lanes not mixed (preview and export)
    /// Lanes whose items cannot be edited (move, trim, cut, delete, paste into). Hiding/muting is separate. No key = nothing locked.
    public var lockedLanes: Set<TrackLane> = []
    /// Sound settings of each RECORDING (keyed by the media path of its clips): per-track mute, volume (dB) and Audio Unit chains, by the
    /// track's index IN THAT FILE. The association is explicit and persistent (format 16): reordering, importing or adding another
    /// recording never changes which file a control works on. Absent entry = neutral.
    public var recordings: [String: RecordingSounds] = [:]
    /// The recording shown by default (first clip's media): what the single-recording shortcuts below act on.
    public var primaryMedia: String { clips.first?.media ?? layers.first(where: { $0.keepsSource })?.media ?? "" }
    public func recording(_ media: String) -> RecordingSounds { recordings[media] ?? RecordingSounds() }
    public func isMuted(source k: Int, media: String) -> Bool { recordings[media]?.muted.contains(k) ?? false }
    /// Single-recording shortcuts (act on `primaryMedia`; the editor always passes the recording explicitly).
    public var mutedSources: Set<Int> {
        get { recording(primaryMedia).muted }
        set { var r = recording(primaryMedia); r.muted = newValue; recordings[primaryMedia] = r.isEmpty ? nil : r }
    }
    public var sourceGains: [Int: Double] {
        get { recording(primaryMedia).gains }
        set { var r = recording(primaryMedia); r.gains = newValue; recordings[primaryMedia] = r.isEmpty ? nil : r }
    }
    public var sourceEffects: [Int: [AudioEffect]] {
        get { recording(primaryMedia).effects }
        set { var r = recording(primaryMedia); r.effects = newValue; recordings[primaryMedia] = r.isEmpty ? nil : r }
    }
    /// Names of the rows of the V2 / A2 lanes, keyed `"v2.1"` / `"a2.0"` (format 15). No key = the default name.
    public var trackNames: [String: String] = [:]
    /// Lane heights and display order (presentation only; no key = default layout).
    public var layout = TimelineLayout()
    /// Rows kept on the V2 / A2 lanes even when empty (a track created on purpose), keyed `"v2"` / `"a2"`; the lane never shows fewer rows than items need (format 15).
    public var reservedRows: [String: Int] = [:]
    public static func rowKey(_ lane: TrackLane, _ row: Int) -> String { "\(lane.rawValue).\(row)" }
    /// Rows shown on a layer lane (video V2 or audio A2): what the items use, or more when tracks were created empty.
    public func rowCount(_ lane: TrackLane) -> Int {
        let kind: LayerKind = lane == .a2 ? .audio : .video
        return max(1, reservedRows[lane.rawValue] ?? 0, (layers.filter { $0.kind == kind }.map(\.row).max() ?? 0) + 1)
    }
    /// Volume of the whole mix in dB (0 = neutral), applied AFTER every source/item volume and fade. Not applied to separate-source files.
    public var masterGainDB: Double = 0
    public func activeEffects(ofSource k: Int, media: String? = nil) -> [AudioEffect] { (recording(media ?? primaryMedia).effects[k] ?? []).filter { !$0.bypassed } }
    public func gain(ofSource k: Int, media: String? = nil) -> Double { recording(media ?? primaryMedia).gains[k] ?? 0 }
    public static let gainRange: ClosedRange<Double> = -40...12
    /// True when any recording has an active (not bypassed) effect chain.
    public var hasActiveEffects: Bool { recordings.values.contains { $0.effects.values.contains { $0.contains { !$0.bypassed } } } }
    /// Linear amplitude factor for a dB value.
    public static func linear(dB: Double) -> Float { Float(pow(10, dB / 20)) }
    /// Size and frame rate of the edit document; nil = legacy (first source decides). Never derived from the window or the viewer zoom.
    public var canvas: DocumentFormat?
    /// Named points on the timeline (not created while recording). Sorted by time; 14 adds them with `rangeIn`/`rangeOut`.
    public var markers: [TimelineMarker] = []
    /// True for a project/media archive: its own media is written as `Media/NN/file`, relative to the project folder, so a copy or a move of the folder is self-contained.
    public var archived = false
    /// Work range In/Out (seconds on the timeline); nil = open end. Only the export uses it, on request; nothing is cut.
    public var rangeIn: Double?
    public var rangeOut: Double?
    /// The In–Out range clamped to the timeline, or nil when none is set or it is empty.
    public var exportRange: ClosedRange<Double>? {
        guard rangeIn != nil || rangeOut != nil else { return nil }
        let a = max(0, rangeIn ?? 0), b = min(timelineEnd, rangeOut ?? timelineEnd)
        return b - a > 0.01 ? a...b : nil
    }
    public init(name: String, clips: [Clip] = [], texts: [TextOverlay] = [], layers: [Layer] = [], library: [String] = [], hiddenLanes: Set<TrackLane> = [], mutedLanes: Set<TrackLane> = []) {
        self.name = name; self.clips = clips; self.texts = texts; self.layers = layers; self.library = library; self.hiddenLanes = hiddenLanes; self.mutedLanes = mutedLanes
    }
    private enum LegacyKeys: String, CodingKey { case mutedSources, sourceGains, sourceEffects }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        formatVersion = try c.decode(Int.self, forKey: .formatVersion)
        name = try c.decode(String.self, forKey: .name)
        clips = try c.decode([Clip].self, forKey: .clips)
        texts = try c.decodeIfPresent([TextOverlay].self, forKey: .texts) ?? []
        callouts = try c.decodeIfPresent([Callout].self, forKey: .callouts) ?? []
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        library = try c.decodeIfPresent([String].self, forKey: .library) ?? []
        hiddenLanes = try c.decodeIfPresent(Set<TrackLane>.self, forKey: .hiddenLanes) ?? []
        mutedLanes = try c.decodeIfPresent(Set<TrackLane>.self, forKey: .mutedLanes) ?? []
        lockedLanes = try c.decodeIfPresent(Set<TrackLane>.self, forKey: .lockedLanes) ?? []
        recordings = try c.decodeIfPresent([String: RecordingSounds].self, forKey: .recordings) ?? [:]
        trackNames = try c.decodeIfPresent([String: String].self, forKey: .trackNames) ?? [:]
        reservedRows = try c.decodeIfPresent([String: Int].self, forKey: .reservedRows) ?? [:]
        layout = try c.decodeIfPresent(TimelineLayout.self, forKey: .layout) ?? TimelineLayout()
        masterGainDB = try c.decodeIfPresent(Double.self, forKey: .masterGainDB) ?? 0
        // formats ≤ 15 kept ONE set of source settings for the whole project: it goes to every recording of the project (what it did)
        let old = try d.container(keyedBy: LegacyKeys.self)
        let lm = try old.decodeIfPresent(Set<Int>.self, forKey: .mutedSources) ?? [], lg = try old.decodeIfPresent([Int: Double].self, forKey: .sourceGains) ?? [:]
        let le = try old.decodeIfPresent([Int: [AudioEffect]].self, forKey: .sourceEffects) ?? [:]
        let legacy = RecordingSounds(muted: lm, gains: lg, effects: le)
        if !legacy.isEmpty {
            for m in Set(clips.map(\.media) + layers.filter(\.keepsSource).map(\.media)) where recordings[m] == nil { recordings[m] = legacy }
        }
        canvas = try c.decodeIfPresent(DocumentFormat.self, forKey: .canvas)
        markers = try c.decodeIfPresent([TimelineMarker].self, forKey: .markers) ?? []
        archived = try c.decodeIfPresent(Bool.self, forKey: .archived) ?? false
        rangeIn = try c.decodeIfPresent(Double.self, forKey: .rangeIn)
        rangeOut = try c.decodeIfPresent(Double.self, forKey: .rangeOut)
    }
    /// Length of the main (sequential) track.
    public var duration: Double { clipSpans.last?.end ?? 0 }
    /// Length of the whole timeline: main track, last layer or last title, whichever ends later. Hiding or muting a lane never changes it (hidden = background shows, muted = silence).
    /// Where each main-track clip sits on the timeline (clips are laid end to end).
    public var clipSpans: [(id: UUID, start: Double, end: Double)] {
        var end = 0.0
        return clips.enumerated().map { i, c in let st = max(0, end - overlap(into: i)); end = st + c.duration; return (c.id, st, end) }
    }
    /// Seconds clip `i` overlaps the previous one (its cross-dissolve), never more than either clip allows.
    public func overlap(into i: Int) -> Double { i > 0 && i < clips.count ? max(0, min(clips[i].dissolve, clips[i - 1].duration, clips[i].duration)) : 0 }
    /// Which of the two alternating main video/audio tracks each clip uses: a dissolve puts the incoming clip on the other one, so the two can overlap.
    public var clipLanes: [Int] { var out: [Int] = []; for i in clips.indices { out.append(i == 0 ? 0 : (overlap(into: i) > 0 ? 1 - out[i - 1] : out[i - 1])) }; return out }
    /// Keeps every dissolve possible after an edit (trim, cut, delete, reorder): none on the first clip, none longer than the material that overlaps,
    /// and the two dissolves of one clip never meet.
    mutating func normalizeDissolves() {
        for i in clips.indices {
            guard i > 0 else { clips[i].dissolve = 0; continue }
            let room = min(clips[i - 1].duration - clips[i - 1].dissolve, clips[i].duration) - ProjectEditor.minClip
            clips[i].dissolve = clips[i].dissolve > 0 && room >= ProjectEditor.minClip ? min(clips[i].dissolve, room) : 0
        }
    }
    /// Keeps clip-bound callouts with their clip after an edit that changed `old` into `self`: they move with it, are shortened when it is trimmed,
    /// follow a cut to the piece they now lie in, and go away with a deleted clip. A callout dragged outside every clip becomes independent.
    /// Callouts without `clipID` (older projects, or released on purpose) are never touched.
    mutating func reanchorCallouts(from old: SadrogProject) {
        guard callouts.contains(where: { $0.clipID != nil }), old.clipSpans.map(\.id) != clipSpans.map(\.id) || old.clipSpans.map(\.end) != clipSpans.map(\.end) else { return }
        let o = Dictionary(old.clipSpans.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a }), nSpans = clipSpans
        let n = Dictionary(nSpans.map { ($0.id, $0.start) }, uniquingKeysWith: { a, _ in a })
        var out: [Callout] = []
        for var c in callouts {
            guard let id = c.clipID else { out.append(c); continue }
            if o[id] != nil, n[id] == nil { continue }                                  // its clip was deleted
            if let os = o[id], let ns = n[id], os != ns { c.start = max(0, c.start + (ns - os)) }
            if let oc = old.clips.first(where: { $0.id == id }), let nc = clips.first(where: { $0.id == id }), !nc.held, nc.sourceStart != oc.sourceStart, let ns = n[id] {
                c.start -= nc.sourceStart - oc.sourceStart                                 // front trim: the effect keeps its place in the picture
                if c.start < ns { c.duration -= ns - c.start; c.start = ns }
                if c.duration < Self.minCalloutLength { continue }
            }
            let here = nSpans.first(where: { c.start >= $0.start - 1e-6 && c.start < $0.end - 1e-6 })
            var span: (id: UUID, start: Double, end: Double)? = nil
            if let h = here, h.id == id { span = h }
            else if let h = here, o[h.id] == nil { span = h; c.clipID = h.id }          // a cut made a new piece: the callout follows the piece it starts in
            else if n[id] != nil { continue }                                           // its clip is still there but no longer covers the callout: trimmed away
            else { c.clipID = nil; out.append(c); continue }                            // unknown clip (not in this project): leave it independent
            if let sp = span {
                if c.end > sp.end + 1e-6 { c.duration = sp.end - c.start }
                if c.duration < Self.minCalloutLength { continue }
            }
            out.append(c)
        }
        callouts = out
    }
    /// Same idea for callouts bound to a video overlay: they follow it when it moves, are shortened/removed when it is trimmed or deleted, and a callout dragged
    /// out of its overlay's span (the overlay itself unchanged) becomes independent. An id that is not a video overlay of this project releases the callout.
    mutating func reanchorLayerCallouts(from old: SadrogProject) {
        guard callouts.contains(where: { $0.layerID != nil }) else { return }
        let o = Dictionary(old.layers.filter { $0.kind == .video }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let n = Dictionary(layers.filter { $0.kind == .video }.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [Callout] = []
        for var c in callouts {
            guard let id = c.layerID else { out.append(c); continue }
            if o[id] != nil, n[id] == nil { continue }                                   // its overlay was deleted
            guard let l = n[id] else { c.layerID = nil; out.append(c); continue }        // unknown overlay: independent
            let before = o[id]
            if let b = before, b.start != l.start || b.end != l.end {                    // the overlay moved or was trimmed
                if b.start != l.start && abs((b.end - b.start) - (l.end - l.start)) < 1e-9 { c.start = max(0, c.start + (l.start - b.start)) }   // pure move
                if let h = layers.first(where: { $0.kind == .video && o[$0.id] == nil && c.start >= $0.start - 1e-6 && c.start < $0.end - 1e-6 }), c.start >= l.end - 1e-6 {
                    c.layerID = h.id; c.duration = max(Self.minCalloutLength, min(c.duration, h.end - c.start)); out.append(c); continue      // a cut made a new piece: it follows the piece it starts in
                }
                if c.end <= l.start + 1e-6 || c.start >= l.end - 1e-6 { continue }       // trimmed away
                c.start = max(c.start, l.start); c.duration = min(c.end, l.end) - c.start
                if c.duration < Self.minCalloutLength { continue }
            } else if c.start < l.start - 1e-6 || c.end > l.end + 1e-6 {                 // the callout itself left its overlay
                if c.start >= l.end - 1e-6 || c.end <= l.start + 1e-6 { c.layerID = nil }
                else { c.start = max(c.start, l.start); c.duration = max(Self.minCalloutLength, min(c.end, l.end) - c.start) }
            }
            out.append(c)
        }
        callouts = out
    }
    public static let minCalloutLength = 0.05
    /// Display rows of the effect lane: callouts that overlap in time sit on different rows (greedy, in start order; a pure view of the data — nothing stored).
    public func calloutRows() -> [UUID: Int] {
        var rows: [UUID: Int] = [:], ends: [Double] = []
        for c in callouts.sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }) {
            if let r = ends.firstIndex(where: { $0 <= c.start + 1e-6 }) { rows[c.id] = r; ends[r] = c.end } else { rows[c.id] = ends.count; ends.append(c.end) }
        }
        return rows
    }
    /// An effect that belongs to a clip or to a video overlay is shown INSIDE that item (a band in its tile); only independent ones (older projects) stay on the effect lane.
    public func isAttached(_ c: Callout) -> Bool { c.clipID != nil || c.layerID != nil }
    private func stackRows(_ list: [Callout]) -> [UUID: Int] {
        var rows: [UUID: Int] = [:], ends: [Double] = []
        for c in list.sorted(by: { ($0.start, $0.id.uuidString) < ($1.start, $1.id.uuidString) }) {
            if let r = ends.firstIndex(where: { $0 <= c.start + 1e-6 }) { rows[c.id] = r; ends[r] = c.end } else { rows[c.id] = ends.count; ends.append(c.end) }
        }
        return rows
    }
    /// Band rows (0 = the one nearest the tile's bottom edge) of the attached effects, stacked per target in start order — a pure view, nothing stored, nothing shifted in time.
    public func attachedCalloutRows() -> [UUID: Int] {
        var out: [UUID: Int] = [:]
        for key in Set(callouts.filter(isAttached).map { $0.clipID ?? $0.layerID! }) {
            out.merge(stackRows(callouts.filter { isAttached($0) && ($0.clipID ?? $0.layerID) == key })) { a, _ in a }
        }
        return out
    }
    /// Deepest stack of attached effects on a clip / on an overlay: the timeline grows the tile so every band keeps its own row.
    public var attachedRowDepth: (clips: Int, layers: Int) {
        let rows = attachedCalloutRows(); var c = 0, l = 0
        for k in callouts where isAttached(k) { let n = (rows[k.id] ?? 0) + 1; if k.clipID != nil { c = max(c, n) } else { l = max(l, n) } }
        return (c, l)
    }
    /// Rows of the effect lane, which now holds only the independent effects.
    public func globalCalloutRows() -> [UUID: Int] { stackRows(callouts.filter { !isAttached($0) }) }
    /// True when the items of `lane` are identical in `other` (used to refuse edits of a locked lane).
    func sameItems(of lane: TrackLane, as other: SadrogProject) -> Bool {
        switch lane {
        case .v1, .a1: return clips == other.clips
        case .t: return texts == other.texts
        case .c: return callouts == other.callouts
        case .v2: return layers.filter { $0.kind == .video } == other.layers.filter { $0.kind == .video }
        case .a2: return layers.filter { $0.kind == .audio } == other.layers.filter { $0.kind == .audio }
        }
    }
    public func clipID(at t: Double) -> UUID? { clipSpans.first { t >= $0.start - 1e-6 && t < $0.end - 1e-6 }?.id }
    public var timelineEnd: Double { max(duration, layers.map(\.end).max() ?? 0, texts.map(\.end).max() ?? 0, callouts.map(\.end).max() ?? 0) }
    /// True when the picture must go through the compositor (overlays, titles, any transform/animation, hidden main video).
    public var needsCompositing: Bool {
        !texts.isEmpty || !callouts.isEmpty || clips.contains { $0.dissolve > 0 || !($0.mouseFX?.isOff ?? true) } || layers.contains { $0.kind == .video } || hiddenLanes.contains(.v1) || clips.contains { !$0.transform.isIdentity || $0.endTransform != nil || !($0.motion?.isNeutral ?? true) || $0.crop != nil || !($0.rectCrop?.isNone ?? true) }
    }
    public func start(ofClip id: Clip.ID) -> Double? { clipSpans.first { $0.id == id }?.start }

    /// Index of the clip containing timeline time `t`, with the offset inside it.
    public func locate(_ t: Double) -> (index: Int, offset: Double)? {
        for (i, sp) in clipSpans.enumerated() where t >= sp.start && t < sp.end { return (i, t - sp.start) }
        return nil
    }
}

/// Edit operations with unlimited undo/redo (value-type snapshots; projects are small).
public final class ProjectEditor {
    public private(set) var project: SadrogProject
    private var undoStack: [SadrogProject] = []
    private var redoStack: [SadrogProject] = []
    public static let minClip = 0.05
    public var canUndo: Bool { !undoStack.isEmpty }
    public var canRedo: Bool { !redoStack.isEmpty }
    public init(project: SadrogProject) { self.project = project }

    func commit(_ change: (inout SadrogProject) -> Bool) {
        var p = project
        guard change(&p) else { return }
        if project.lockedLanes.contains(where: { !project.sameItems(of: $0, as: p) }) { return }    // a locked lane is never edited (reanchoring below is the consequence of an allowed edit)
        p.normalizeDissolves()
        p.layout.pruneRows(.v2, keeping: p.rowCount(.v2)); p.layout.pruneRows(.a2, keeping: p.rowCount(.a2))
        p.reanchorCallouts(from: project); p.reanchorLayerCallouts(from: project)
        guard p != project else { return }
        undoStack.append(project); project = p; redoStack.removeAll()
    }

    @discardableResult public func undo() -> Bool {
        guard let p = undoStack.popLast() else { return false }
        redoStack.append(project); project = p; return true
    }
    @discardableResult public func redo() -> Bool {
        guard let p = redoStack.popLast() else { return false }
        undoStack.append(project); project = p; return true
    }

    public func split(at t: Double) {
        commit { p in
            guard let (i, off) = p.locate(t), off >= Self.minClip, p.clips[i].duration - off >= Self.minClip, off >= p.overlap(into: i) + Self.minClip || p.overlap(into: i) == 0,
                  i + 1 >= p.clips.count || t < p.clipSpans[i + 1].start else { return false }       // not inside a dissolve: two clips are on screen there
            var a = p.clips[i], b = p.clips[i]
            a.duration = off
            b.dissolve = 0; b.id = UUID(); if !b.held { b.sourceStart += off }; b.duration -= off
            // fades stay on the item's outer edges: no fade is created at the cut
            if a.audio != nil { a.audio?.fadeOut = 0; b.audio?.fadeIn = 0 }
            a.cut(into: &b, duration: a.duration + b.duration, at: off)
            p.clips.replaceSubrange(i...i, with: [a, b]); return true
        }
    }
    /// Freeze frame: holds the picture at `t` for `length` seconds, inserted at that point (the clip is cut there; at a clip's very start or end it is
    /// inserted before/after it). The held clip has no sound; the rest of the timeline shifts later. One undo step. Returns the new clip's id.
    @discardableResult public func freezeFrame(at t: Double, length: Double = 2) -> Clip.ID? {
        var made: Clip.ID?
        commit { p in
            guard length >= Self.minClip, let (i, off) = p.locate(t), !p.clips[i].held, i + 1 >= p.clips.count || t < p.clipSpans[i + 1].start else { return false }
            let c = p.clips[i]
            var h = Clip(media: c.media, sourceStart: c.sourceStart + min(off, max(0, c.duration - 0.04)), duration: length, transform: c.animation.state(elapsed: min(off, c.duration), duration: c.duration), endTransform: nil)
            h.held = true; h.crop = c.crop; h.rectCrop = c.rectCrop; h.label = c.label.map { $0 + " ❄" }
            if off < Self.minClip { h.dissolve = c.dissolve; p.clips[i].dissolve = 0; p.clips.insert(h, at: i) }
            else if c.duration - off < Self.minClip { h.sourceStart = c.sourceStart + max(0, c.duration - 0.04); p.clips.insert(h, at: i + 1) }
            else {
                var a = c, b = c; a.duration = off; b.dissolve = 0; b.id = UUID(); b.sourceStart += off; b.duration -= off
                if a.audio != nil { a.audio?.fadeOut = 0; b.audio?.fadeIn = 0 }
                a.cut(into: &b, duration: c.duration, at: off)
                p.clips.replaceSubrange(i...i, with: [a, h, b])
            }
            made = h.id; return true
        }
        return made
    }
    /// A main-track clip together with the callouts bound to it (start relative to the clip), for copy/cut/paste and duplication.
    public struct ClipSnapshot: Equatable, Sendable {
        public var clip: Clip
        public var callouts: [(offset: Double, callout: Callout)]
        public static func == (a: ClipSnapshot, b: ClipSnapshot) -> Bool { a.clip == b.clip && a.callouts.map(\.offset) == b.callouts.map(\.offset) && a.callouts.map(\.callout) == b.callouts.map(\.callout) }
    }
    public func snapshot(clip id: Clip.ID) -> ClipSnapshot? {
        guard let sp = project.clipSpans.first(where: { $0.id == id }), let c = project.clips.first(where: { $0.id == id }) else { return nil }
        return ClipSnapshot(clip: c, callouts: project.callouts.filter { $0.clipID == id }.map { ($0.start - sp.start, $0) })
    }
    /// Inserts a copy of the snapshot at `index` (ripple). The copy gets new ids; its callouts are copied and bound to the COPY, never to the original.
    @discardableResult public func paste(_ s: ClipSnapshot, atIndex index: Int) -> Clip.ID? {
        var newID: Clip.ID?
        commit { p in
            let i = max(0, min(index, p.clips.count))
            var c = s.clip; c.id = UUID(); c.dissolve = 0
            p.clips.insert(c, at: i)
            let start = p.start(ofClip: c.id) ?? 0
            for (off, var k) in s.callouts { k.id = UUID(); k.clipID = c.id; k.start = start + off; p.callouts.append(k) }
            newID = c.id; return true
        }
        return newID
    }
    /// Duplicates the clip right after itself, with its bound callouts. Returns the new clip's id.
    @discardableResult public func duplicate(clip id: Clip.ID) -> Clip.ID? {
        guard let i = project.clips.firstIndex(where: { $0.id == id }), let s = snapshot(clip: id) else { return nil }
        return paste(s, atIndex: i + 1)
    }
    /// Longest cross-dissolve the clip can have with the previous one (0 = none possible: first clip, or too little material).
    public func maxDissolve(forClip id: Clip.ID) -> Double {
        guard let i = project.clips.firstIndex(where: { $0.id == id }), i > 0 else { return 0 }
        return max(0, min(project.clips[i - 1].duration - project.clips[i - 1].dissolve, project.clips[i].duration) - Self.minClip)
    }
    /// Sets the cross-dissolve of the clip with the PREVIOUS one (0 removes it). The overlap is taken from both clips' own material — nothing outside
    /// the trimmed parts is needed — so the timeline becomes `seconds` shorter and everything after it (and clip-bound callouts) moves earlier. One undo step.
    public func setDissolve(clip id: Clip.ID, seconds: Double) {
        let d = max(0, min(seconds, maxDissolve(forClip: id)))
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }), i > 0, p.clips[i].dissolve != d else { return false }
            p.clips[i].dissolve = d >= Self.minClip ? d : 0; return true
        }
    }
    /// Sets what is drawn from the pointer track on a clip (nil/off = nothing). One undo step.
    public func setMouseFX(clip id: Clip.ID, _ fx: MouseFX?) {
        commit { p in guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return false }; p.clips[i].mouseFX = (fx?.isOff ?? true) ? nil : fx; return true }
    }
    /// Magnifies the clip and makes the frame follow the pointer (see `MouseFollow`): the clip's start state and keys are replaced; fades and easing stay. One undo step.
    @discardableResult public func followMouse(clip id: Clip.ID, track: MouseTrack, scale: Double) -> Bool {
        guard let c = project.clips.first(where: { $0.id == id }), !c.held, let plan = MouseFollow.plan(track, sourceStart: c.sourceStart, duration: c.duration, scale: scale) else { return false }
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return false }
            var m = p.clips[i].motion ?? Motion(); m.keys = plan.keys; m.easing = .linear; m.headSlice = 0; m.tailSlice = 1; m.normalize()
            p.clips[i].transform = plan.start; p.clips[i].endTransform = nil; p.clips[i].motion = m; return true
        }
        return true
    }
    public func delete(clip id: Clip.ID) {
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return false }
            p.clips.remove(at: i); return true
        }
    }
    /// Trim the clip start (positive = cut from the front) keeping the end fixed.
    public func trimStart(clip id: Clip.ID, by delta: Double) {
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return false }
            let d = max(p.clips[i].held ? -Double.infinity : -p.clips[i].sourceStart, min(delta, p.clips[i].duration - Self.minClip))
            guard d != 0 else { return false }
            p.clips[i].trimmedFront(by: d, duration: p.clips[i].duration)
            if !p.clips[i].held { p.clips[i].sourceStart += d }; p.clips[i].duration -= d; return true
        }
    }
    /// Trim the clip end (positive = cut from the back) keeping the start fixed.
    public func trimEnd(clip id: Clip.ID, by delta: Double) {
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }), delta != 0 else { return false }
            let d = min(delta, p.clips[i].duration - Self.minClip)
            p.clips[i].trimmedBack(by: d, duration: p.clips[i].duration)
            p.clips[i].duration -= d; return true
        }
    }
    public func rename(_ name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        commit { p in guard !n.isEmpty, n.count <= 120 else { return false }; p.name = n; return true }
    }
    /// Hides (video lanes) or mutes (sound lanes) a whole lane; one undo step.
    /// Sets the edit document's size and frame rate (one undo step). nil returns to "same as the first source".
    public func setCanvas(_ f: DocumentFormat?) { commit { p in p.canvas = f; return true } }
    /// Mutes or unmutes one audio track of the main recording (preview and export); one call = one undo step.
    /// Sets the sound edits of an A1 clip or an A2 item (gain clamped to `gainRange`, fades ≥ 0 and each ≤ the item's duration).
    /// One call = one undo step; a neutral result removes the key.
    public func setAudio(_ id: UUID, _ e: AudioEdit) {
        commit { p in
            func clean(_ e: AudioEdit, _ d: Double) -> AudioEdit? {
                var v = e; v.gainDB = (max(SadrogProject.gainRange.lowerBound, min(SadrogProject.gainRange.upperBound, e.gainDB)) * 10).rounded() / 10
                v.fadeIn = min(max(0, (e.fadeIn * 100).rounded() / 100), d); v.fadeOut = min(max(0, (e.fadeOut * 100).rounded() / 100), d)
                return v.isNeutral ? nil : v
            }
            if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].audio = clean(e, p.clips[i].duration); return true }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .audio }) { p.layers[i].audio = clean(e, p.layers[i].duration); return true }
            return false
        }
    }
    /// Binds a callout to a video overlay (V2) that covers its start (the callout is cut to the overlay), or (nil) releases it. A callout belongs to a clip OR an overlay, never both.
    @discardableResult public func bindCallout(_ id: UUID, toLayer layer: UUID?) -> Bool {
        var done = false
        commit { p in
            guard let i = p.callouts.firstIndex(where: { $0.id == id }) else { return false }
            if let lid = layer {
                guard let l = p.layers.first(where: { $0.id == lid && $0.kind == .video }), p.callouts[i].start >= l.start - 1e-6, p.callouts[i].start < l.end - 1e-6 else { return false }
                p.callouts[i].layerID = lid; p.callouts[i].clipID = nil
                p.callouts[i].duration = max(SadrogProject.minCalloutLength, min(p.callouts[i].duration, l.end - p.callouts[i].start))
            } else { p.callouts[i].layerID = nil }
            done = true; return true
        }
        return done
    }
    /// Points every use of a media file (V1 clips, overlays, audio layers, the library) at a new path: relinking a file that went missing. One call = one undo step.
    public func relinkMedia(from old: String, to new: String) {
        commit { p in
            guard old != new else { return false }
            var changed = false
            for i in p.clips.indices where p.clips[i].media == old { p.clips[i].media = new; changed = true }
            for i in p.layers.indices where p.layers[i].media == old { p.layers[i].media = new; changed = true }
            for i in p.library.indices where p.library[i] == old { p.library[i] = new; changed = true }
            if let r = p.recordings[old] { if p.recordings[new] == nil { p.recordings[new] = r }; p.recordings[old] = nil; changed = true }   // sound settings follow the file
            return changed
        }
    }
    /// Adds a marker at `t` (one per 0.05 s; a second one there is not created) and returns its id.
    @discardableResult public func addMarker(at t: Double, name: String = "") -> UUID? {
        let t = max(0, min(project.timelineEnd, t)); guard !project.markers.contains(where: { abs($0.time - t) < 0.05 }) else { return nil }
        let m = TimelineMarker(time: t, name: name); commit { $0.markers.append(m); $0.markers.sort { $0.time < $1.time }; return true }; return m.id
    }
    public func renameMarker(_ id: UUID, _ name: String) { commit { p in guard let i = p.markers.firstIndex(where: { $0.id == id }) else { return false }; p.markers[i].name = name; return true } }
    public func removeMarker(_ id: UUID) { commit { p in let n = p.markers.count; p.markers.removeAll { $0.id == id }; return p.markers.count != n } }
    /// Sets the In and/or Out point (nil argument = leave; use `clearRange` to open it). In never passes Out.
    public func setRange(in a: Double? = nil, out b: Double? = nil) {
        commit { p in
            if let a { p.rangeIn = max(0, a); if let o = p.rangeOut, o <= p.rangeIn! { p.rangeOut = nil } }
            if let b { p.rangeOut = max(0, b); if let i = p.rangeIn, i >= p.rangeOut! { p.rangeIn = nil } }
            return true
        }
    }
    public func clearRange() { commit { $0.rangeIn = nil; $0.rangeOut = nil; return true } }
    /// Sets the mix volume in dB (clamped to `gainRange`, 0.1 dB steps). One call = one undo step.
    public func setMasterGain(_ dB: Double) {
        commit { p in p.masterGainDB = (max(SadrogProject.gainRange.lowerBound, min(SadrogProject.gainRange.upperBound, dB)) * 10).rounded() / 10; return true }
    }
    /// Shows a video clip (V1) or video overlay (V2) as a circle, changes its framing/outline, or (nil) gives the full rectangle back.
    /// The picture itself is never changed. One call = one undo step.
    /// `transform` (optional) places the item in the same step, e.g. a new presenter circle moved to a corner — still one undo step.
    public func setCrop(_ id: UUID, _ crop: CircleCrop?, transform: Transform? = nil) {
        commit { p in
            var c = crop; c?.normalize()
            if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].crop = c; if let t = transform { p.clips[i].transform = t }; return true }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .video }) { p.layers[i].crop = c; if let t = transform { p.layers[i].transform = t }; return true }
            return false
        }
    }
    /// Crops a video clip (V1) or video overlay (V2) to a rectangle, or (nil / no sides) removes the crop. The source is never changed. One call = one undo step.
    /// `transform` (optional) re-places the item in the same step so the kept pixels stay where they were on the canvas — still one undo step.
    public func setRectCrop(_ id: UUID, _ crop: RectCrop?, transform: Transform? = nil) {
        commit { p in
            var c = crop; c?.normalize(); if c?.isNone == true { c = nil }
            if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].rectCrop = c; if let t = transform { p.clips[i].transform = t }; return true }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .video }) { p.layers[i].rectCrop = c; if let t = transform { p.layers[i].transform = t }; return true }
            return false
        }
    }
    /// Replaces the effect chain of one source of ONE recording (`media`, default the primary one). One undo step; empty chain removes it.
    public func setEffects(_ index: Int, _ chain: [AudioEffect], media: String? = nil) {
        commit { p in
            guard index >= 0 else { return false }
            let m = media ?? p.primaryMedia; var r = p.recording(m)
            r.effects[index] = chain.isEmpty ? nil : chain
            p.recordings[m] = r.isEmpty ? nil : r
            return true
        }
    }
    /// Sets the volume of one source of one recording in dB (clamped, 0.1 dB steps); 0 dB removes the entry. One undo step.
    public func setSourceGain(_ index: Int, dB: Double, media: String? = nil) {
        commit { p in
            guard index >= 0 else { return false }
            let v = (max(SadrogProject.gainRange.lowerBound, min(SadrogProject.gainRange.upperBound, dB)) * 10).rounded() / 10
            let m = media ?? p.primaryMedia; var r = p.recording(m)
            if v == 0 { r.gains[index] = nil } else { r.gains[index] = v }
            p.recordings[m] = r.isEmpty ? nil : r
            return true
        }
    }
    public func setSourceMuted(_ index: Int, _ muted: Bool, media: String? = nil) {
        commit { p in
            let m = media ?? p.primaryMedia; var r = p.recording(m)
            guard index >= 0, r.muted.contains(index) != muted else { return false }
            if muted { r.muted.insert(index) } else { r.muted.remove(index) }
            p.recordings[m] = r.isEmpty ? nil : r
            return true
        }
    }
    public func setLane(_ lane: TrackLane, off: Bool) {
        commit { p in
            if lane.isVideo { if off { p.hiddenLanes.insert(lane) } else { p.hiddenLanes.remove(lane) } }
            else { if off { p.mutedLanes.insert(lane) } else { p.mutedLanes.remove(lane) } }
            return true
        }
    }
    // MARK: titles (their own lane; items on it never overlap)
    private static func overlaps(_ t: TextOverlay, in p: SadrogProject) -> Bool {
        p.texts.contains { $0.id != t.id && $0.start < t.end - 1e-6 && t.start < $0.end - 1e-6 }
    }
    @discardableResult public func addText(_ t: TextOverlay) -> Bool {
        var ok = false
        commit { p in guard !t.text.isEmpty, t.duration >= Self.minClip, !Self.overlaps(t, in: p) else { return false }; p.texts.append(t); ok = true; return true }
        return ok
    }
    public func removeText(_ id: TextOverlay.ID) { commit { p in guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return false }; p.texts.remove(at: i); return true } }
    /// Edits any property of a title (content, font, size, colour, alignment, start, duration) as ONE undo step; refused if the result would overlap another title.
    @discardableResult public func updateText(_ id: TextOverlay.ID, _ edit: (inout TextOverlay) -> Void) -> Bool {
        var ok = false
        commit { p in
            guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return false }
            var t = p.texts[i]; edit(&t)
            t.start = max(0, t.start); t.duration = max(Self.minClip, t.duration); t.size = max(0.01, min(0.5, t.size))
            guard !t.text.isEmpty, !Self.overlaps(t, in: p) else { return false }
            p.texts[i] = t; ok = true; return true
        }
        return ok
    }
    /// Moves a title so it starts at `start`; refused if it would overlap another title.
    @discardableResult public func moveText(_ id: TextOverlay.ID, to start: Double) -> Bool { updateText(id) { $0.start = start } }
    /// Trims a title's left edge (positive = cut from the front); the right edge stays.
    public func trimTextStart(_ id: TextOverlay.ID, by delta: Double) {
        updateText(id) { let d = max(-$0.start, min(delta, $0.duration - Self.minClip)); $0.trimmedFront(by: d, duration: $0.duration); $0.start += d; $0.duration -= d }
    }
    /// Edits the motion (extra keyframes, easing, fades) of a clip, a video overlay or a title; a neutral result removes it. One undo step.
    public func updateMotion(_ id: UUID, _ edit: @escaping (inout Motion) -> Void) {
        commit { p in
            func upd(_ m: inout Motion?) { var v = m ?? Motion(); edit(&v); v.normalize(); m = v.isNeutral ? nil : v }
            if let i = p.clips.firstIndex(where: { $0.id == id }) { upd(&p.clips[i].motion); return true }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .video }) { upd(&p.layers[i].motion); return true }
            if let i = p.texts.firstIndex(where: { $0.id == id }) { upd(&p.texts[i].motion); return true }
            return false
        }
    }
    /// A keyframe `rel` seconds into the item with state `t` (inside the item, not on its edges; an existing key within 50 ms is replaced). One undo step.
    public func setKey(_ id: UUID, at rel: Double, _ t: Transform) {
        updateMotion(id) { m in m.keys.removeAll { abs($0.t - rel) < 0.05 }; m.keys.append(MotionKey(t: rel, transform: t)) }
    }
    public func removeKey(_ id: UUID, at index: Int) { updateMotion(id) { if $0.keys.indices.contains(index) { $0.keys.remove(at: index) } } }
    /// Splits the title under `t` in two (same look, the second one starts at `t`).
    public func splitText(at t: Double) {
        commit { p in
            guard let i = p.texts.firstIndex(where: { $0.start + Self.minClip <= t && t <= $0.end - Self.minClip }) else { return false }
            var a = p.texts[i], b = a; b.id = UUID(); b.start = t; b.duration = a.end - t; a.duration = t - a.start
            let D = a.duration + b.duration
            a.cut(into: &b, duration: D, at: a.duration)
            if let an = a.anim { let inZone = a.duration < an.seconds || a.duration > D - an.seconds; a.anim = inZone ? nil : TextAnimation(appear: an.appear, disappear: .none, seconds: an.seconds); b.anim = inZone ? nil : TextAnimation(appear: .none, disappear: an.disappear, seconds: an.seconds); if a.anim?.isNone == true { a.anim = nil }; if b.anim?.isNone == true { b.anim = nil } }
            p.texts[i] = a; p.texts.insert(b, at: i + 1); return true
        }
    }
    /// Sets how a title enters and leaves (replaces its animation by the preset's keyframes around its current resting placement). One undo step.
    public func setTextAnimation(_ id: TextOverlay.ID, _ a: TextAnimation) {
        commit { p in
            guard let i = p.texts.firstIndex(where: { $0.id == id }) else { return false }
            let rest = p.texts[i].anim == nil ? p.texts[i].transform : p.texts[i].animation.placement(elapsed: p.texts[i].duration / 2, duration: p.texts[i].duration)
            a.bake(&p.texts[i], rest: rest); return true
        }
    }
    /// Trims a title's right edge (positive = cut from the back).
    public func trimTextEnd(_ id: TextOverlay.ID, by delta: Double) { updateText(id) { let d = min(delta, $0.duration - Self.minClip); $0.trimmedBack(by: d, duration: $0.duration); $0.duration -= d } }
    // MARK: callouts (their own lane; items MAY overlap in time — each acts on its own target, composited in the order of `project.callouts`)
    @discardableResult public func addCallout(_ c: Callout) -> Bool {
        var ok = false
        commit { p in var c = c; c.normalize(); guard c.duration >= Self.minClip else { return false }; p.callouts.append(c); ok = true; return true }
        return ok
    }
    public func removeCallout(_ id: Callout.ID) { commit { p in guard let i = p.callouts.firstIndex(where: { $0.id == id }) else { return false }; p.callouts.remove(at: i); return true } }
    /// Edits any property of a callout as ONE undo step (values are clamped to their valid ranges); never refused for overlapping another callout (different targets, or the same one, may be active together).
    @discardableResult public func updateCallout(_ id: Callout.ID, _ edit: (inout Callout) -> Void) -> Bool {
        var ok = false
        commit { p in
            guard let i = p.callouts.firstIndex(where: { $0.id == id }) else { return false }
            var c = p.callouts[i]; edit(&c); c.normalize(); c.duration = max(Self.minClip, c.duration)
            if c.clipID != nil, let sp = p.clipSpans.first(where: { c.start >= $0.start - 1e-6 && c.start < $0.end - 1e-6 }) { c.clipID = sp.id; c.duration = max(Self.minClip, min(c.duration, sp.end - c.start)) }   // dragged onto another clip: it belongs there now
            p.callouts[i] = c; ok = true; return true
        }
        return ok
    }
    @discardableResult public func moveCallout(_ id: Callout.ID, to start: Double) -> Bool { updateCallout(id) { $0.start = start } }
    public func trimCalloutStart(_ id: Callout.ID, by delta: Double) { updateCallout(id) { let d = max(-$0.start, min(delta, $0.duration - Self.minClip)); $0.start += d; $0.duration -= d } }
    public func trimCalloutEnd(_ id: Callout.ID, by delta: Double) { updateCallout(id) { $0.duration -= min(delta, $0.duration - Self.minClip) } }
    // MARK: layers, transforms, library
    static func overlaps(_ l: Layer, in p: SadrogProject) -> Bool {
        p.layers.contains { $0.id != l.id && $0.kind == l.kind && $0.row == l.row && $0.start < l.end - 1e-6 && l.start < $0.end - 1e-6 }
    }
    @discardableResult public func addLayer(_ l: Layer) -> Bool {
        var ok = false
        commit { p in guard l.duration >= Self.minClip, !Self.overlaps(l, in: p) else { return false }; p.layers.append(l); ok = true; return true }
        return ok
    }
    /// Moves a layer to another row of its lane (one undo step); refused if it would overlap an item there.
    @discardableResult public func setLayerRow(_ id: Layer.ID, _ row: Int) -> Bool {
        var ok = false
        commit { p in
            guard row >= 0, let i = p.layers.firstIndex(where: { $0.id == id }) else { return false }
            var l = p.layers[i]; l.track = row == 0 ? nil : row
            guard !Self.overlaps(l, in: p) else { return false }
            p.layers[i] = l; ok = true; return true
        }
        return ok
    }
    // MARK: tracks (rows) of the V2 / A2 lanes
    private static func kind(of lane: TrackLane) -> LayerKind? { lane == .v2 ? .video : (lane == .a2 ? .audio : nil) }
    /// Places a layer at a new time AND row in one undo step; refused (false) on overlap in the destination row. A row one past the last creates a new track.
    @discardableResult public func placeLayer(_ id: Layer.ID, start: Double, row: Int) -> Bool {
        var ok = false; let before = project
        commit { p in
            guard row >= 0, let i = p.layers.firstIndex(where: { $0.id == id }) else { return false }
            var l = p.layers[i]; l.start = max(0, start); l.track = row == 0 ? nil : row
            guard !Self.overlaps(l, in: p) else { return false }
            p.layers[i] = l; ok = true; return true
        }
        return ok && project != before
    }
    /// Exchanges two whole tracks (their items and names). For V2 this changes the stacking order of the pictures (higher row = on top); for A2 it is organisational only.
    @discardableResult public func swapRows(_ lane: TrackLane, _ a: Int, _ b: Int) -> Bool {
        var ok = false; let before = project
        commit { p in
            guard let k = Self.kind(of: lane), a != b, a >= 0, b >= 0, a < p.rowCount(lane), b < p.rowCount(lane) else { return false }
            for i in p.layers.indices where p.layers[i].kind == k {
                if p.layers[i].row == a { p.layers[i].track = b == 0 ? nil : b } else if p.layers[i].row == b { p.layers[i].track = a == 0 ? nil : a }
            }
            let ka = SadrogProject.rowKey(lane, a), kb = SadrogProject.rowKey(lane, b), na = p.trackNames[ka], nb = p.trackNames[kb]
            p.trackNames[ka] = nb; p.trackNames[kb] = na
            p.layout.remapRows(lane) { $0 == a ? b : ($0 == b ? a : $0) }
            ok = true; return true
        }
        return ok && project != before
    }
    /// Moves one whole track to another position of its lane; the tracks in between shift by one (items, names, per-row heights follow).
    /// One undo step. Same effect as a chain of adjacent swaps, so V2 keeps its meaning (higher row = on top).
    @discardableResult public func moveRow(_ lane: TrackLane, from a: Int, to b: Int) -> Bool {
        var ok = false; let before = project
        commit { p in
            guard let k = Self.kind(of: lane), a != b, a >= 0, b >= 0, a < p.rowCount(lane), b < p.rowCount(lane) else { return false }
            func newRow(_ r: Int) -> Int { r == a ? b : (a < b ? (r > a && r <= b ? r - 1 : r) : (r >= b && r < a ? r + 1 : r)) }
            for i in p.layers.indices where p.layers[i].kind == k { let r = newRow(p.layers[i].row); p.layers[i].track = r == 0 ? nil : r }
            var names: [String: String] = [:]
            for (key, v) in p.trackNames {
                let parts = key.split(separator: ".")
                if parts.count == 2, parts[0] == lane.rawValue, let r = Int(parts[1]) { names[SadrogProject.rowKey(lane, newRow(r))] = v } else { names[key] = v }
            }
            p.trackNames = names
            p.layout.remapRows(lane, newRow)
            ok = true; return true
        }
        return ok && project != before
    }
    /// Creates an empty track at the top of the lane.
    @discardableResult public func addRow(_ lane: TrackLane) -> Bool {
        var ok = false; let before = project
        commit { p in guard Self.kind(of: lane) != nil, p.rowCount(lane) < 12 else { return false }; p.reservedRows[lane.rawValue] = p.rowCount(lane) + 1; ok = true; return true }
        return ok && project != before
    }
    /// Removes an EMPTY track; the tracks above it move down one place (their items keep their time). Refused while it holds items.
    @discardableResult public func removeRow(_ lane: TrackLane, _ row: Int) -> Bool {
        var ok = false; let before = project
        commit { p in
            guard let k = Self.kind(of: lane), p.rowCount(lane) > 1, row >= 0, row < p.rowCount(lane), !p.layers.contains(where: { $0.kind == k && $0.row == row }) else { return false }
            for i in p.layers.indices where p.layers[i].kind == k && p.layers[i].row > row { let r = p.layers[i].row - 1; p.layers[i].track = r == 0 ? nil : r }
            var names: [String: String] = [:]
            for (key, v) in p.trackNames {
                let parts = key.split(separator: ".")
                if parts.count == 2, parts[0] == lane.rawValue, let r = Int(parts[1]) { if r == row { continue }; names[SadrogProject.rowKey(lane, r > row ? r - 1 : r)] = v } else { names[key] = v }
            }
            p.trackNames = names
            p.layout.remapRows(lane) { $0 == row ? nil : ($0 > row ? $0 - 1 : $0) }
            p.reservedRows[lane.rawValue] = max(1, p.rowCount(lane) - 1); ok = true; return true
        }
        return ok && project != before
    }
    @discardableResult public func setTrackName(_ lane: TrackLane, _ row: Int, _ name: String) -> Bool {
        var ok = false; let before = project
        commit { p in
            guard Self.kind(of: lane) != nil, row >= 0, row < p.rowCount(lane) else { return false }
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines), key = SadrogProject.rowKey(lane, row)
            guard p.trackNames[key] != (n.isEmpty ? nil : n) else { return false }
            p.trackNames[key] = n.isEmpty ? nil : n; ok = true; return true
        }
        return ok && project != before
    }
    /// Moves a layer so it starts at `start`; refused (false) if it would overlap another item on its lane.
    @discardableResult public func moveLayer(_ id: Layer.ID, to start: Double) -> Bool {
        var ok = false
        commit { p in
            guard let i = p.layers.firstIndex(where: { $0.id == id }) else { return false }
            var l = p.layers[i]; l.start = max(0, start)
            guard !Self.overlaps(l, in: p) else { return false }
            p.layers[i] = l; ok = true; return true
        }
        return ok
    }
    public func deleteLayer(_ id: Layer.ID) { commit { p in guard let i = p.layers.firstIndex(where: { $0.id == id }) else { return false }; p.layers.remove(at: i); return true } }
    /// Trims the layer's left edge (positive = cut from the front); the right edge stays where it is.
    public func trimLayerStart(_ id: Layer.ID, by delta: Double) {
        commit { p in
            guard let i = p.layers.firstIndex(where: { $0.id == id }) else { return false }
            let d = max(-min(p.layers[i].sourceStart, p.layers[i].start), min(delta, p.layers[i].duration - Self.minClip)); guard d != 0 else { return false }
            var l = p.layers[i]; l.trimmedFront(by: d, duration: l.duration); l.start += d; l.sourceStart += d; l.duration -= d
            guard !Self.overlaps(l, in: p) else { return false }
            p.layers[i] = l; return true
        }
    }
    /// Trims the layer's right edge (positive = cut from the back). Extending is bounded by `sourceLength` when given.
    public func trimLayerEnd(_ id: Layer.ID, by delta: Double, sourceLength: Double? = nil) {
        commit { p in
            guard let i = p.layers.firstIndex(where: { $0.id == id }), delta != 0 else { return false }
            var d = min(delta, p.layers[i].duration - Self.minClip)
            if let n = sourceLength { d = max(d, -(n - p.layers[i].sourceStart - p.layers[i].duration)) }
            var l = p.layers[i]; l.trimmedBack(by: d, duration: l.duration); l.duration -= d
            guard d != 0, !Self.overlaps(l, in: p) else { return false }
            p.layers[i] = l; return true
        }
    }
    /// Splits the layer of `kind` that contains timeline time `t`.
    public func splitLayer(kind: LayerKind, at t: Double) {
        commit { p in
            guard let i = p.layers.firstIndex(where: { $0.kind == kind && t - $0.start >= Self.minClip && $0.end - t >= Self.minClip }) else { return false }
            var a = p.layers[i], b = p.layers[i]; let off = t - a.start
            a.duration = off; b.id = UUID(); b.start = t; b.sourceStart += off; b.duration -= off
            if a.audio != nil { a.audio?.fadeOut = 0; b.audio?.fadeIn = 0 }
            a.cut(into: &b, duration: a.duration + b.duration, at: off)
            p.layers.replaceSubrange(i...i, with: [a, b]); return true
        }
    }
    // MARK: detach / reattach the sound of a clip
    /// Detaches the clip's sound into an independent audio item (A2): same source file, same source offset, same timeline position — so sync is exact — with the
    /// clip's gain/mute/fades (and the crossfade of a dissolve) carried over. The clip keeps its picture and stops playing its own sound (no doubling); the media file is untouched.
    @discardableResult public func detachAudio(of clipID: Clip.ID) -> Layer.ID? {
        var made: Layer.ID?; let before = project
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == clipID }), !p.clips[i].held, !p.clips[i].audioDetached else { return false }
            let c = p.clips[i], start = p.clipSpans[i].start
            var l = Layer(kind: .audio, media: c.media, start: start, sourceStart: c.sourceStart, duration: c.duration)
            var e = AudioEdit()      // an A1 clip carries only fades (its volume/mute are the per-source ones, which stay in force for the detached sound too)
            let f = (c.audio ?? AudioEdit()).effectiveFades(duration: c.duration)
            e.fadeIn = max(f.fadeIn, p.overlap(into: i)); e.fadeOut = max(f.fadeOut, i + 1 < p.clips.count ? p.overlap(into: i + 1) : 0)
            l.audio = e.isNeutral ? nil : e; l.label = c.label ?? URL(fileURLWithPath: c.media).lastPathComponent; l.linkedClip = c.id; l.sourceIdentity = true
            var row = 0; l.track = nil
            while Self.overlaps(l, in: p) { row += 1; l.track = row }
            p.layers.append(l); p.clips[i].audioDetached = true; p.clips[i].audio = nil
            made = l.id; return true
        }
        return project != before ? made : nil
    }
    /// Audio items still linked to the clip (a cut leaves several pieces, all linked to the same clip), ordered by position.
    public func linkedAudio(of clipID: Clip.ID) -> [Layer] { project.layers.filter { $0.kind == .audio && $0.linkedClip == clipID }.sorted { $0.start < $1.start } }
    /// Do the linked audio items together still cover exactly the clip's own sound (same file, contiguous pieces in the right place, nothing moved or trimmed)?
    public func detachedAudioInSync(_ layerID: Layer.ID) -> Bool {
        guard let l = project.layers.first(where: { $0.id == layerID }), let cid = l.linkedClip, let i = project.clips.firstIndex(where: { $0.id == cid }) else { return false }
        let c = project.clips[i], s = project.clipSpans[i], pieces = linkedAudio(of: cid)
        var t = s.start
        for q in pieces {
            guard q.media == c.media, abs(q.start - t) < 1e-6, abs(q.sourceStart - (c.sourceStart + (t - s.start))) < 1e-6 else { return false }
            t += q.duration
        }
        return abs(t - s.end) < 1e-6
    }
    /// Why reattaching is refused, or nil when it is possible: the clip's own sound (A1) cannot carry a gain, mute or a detached item's own edits.
    public func reattachBlocker(of clipID: Clip.ID) -> String? {
        let pieces = linkedAudio(of: clipID)
        guard let f = pieces.first else { return nil }
        if !detachedAudioInSync(f.id) { return "moved" }
        if pieces.contains(where: { let a = $0.audio; return (a?.muted ?? false) || abs(a?.gainDB ?? 0) > 1e-9 }) { return "edited" }
        return nil
    }
    /// Gives the clip its own sound back. With its detached item still in sync, the item is removed (one sound, no doubling); with the item moved/trimmed/cut it is
    /// refused while that item exists (it would play twice) — delete the item first. With no item left, the clip simply plays its sound again.
    @discardableResult public func reattachAudio(of clipID: Clip.ID) -> Bool {
        var ok = false; let before = project
        let pieces = linkedAudio(of: clipID)
        if !pieces.isEmpty, reattachBlocker(of: clipID) != nil { return false }
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == clipID }), p.clips[i].audioDetached else { return false }
            if let first = pieces.first, let last = pieces.last {
                let ov = (p.overlap(into: i), i + 1 < p.clips.count ? p.overlap(into: i + 1) : 0)
                let fi = (first.audio?.fadeIn ?? 0) > ov.0 + 1e-9 ? first.audio!.fadeIn : 0, fo = (last.audio?.fadeOut ?? 0) > ov.1 + 1e-9 ? last.audio!.fadeOut : 0     // the dissolve's share is re-derived from the dissolve itself
                p.clips[i].audio = fi == 0 && fo == 0 ? nil : AudioEdit(fadeIn: fi, fadeOut: fo)
                let ids = Set(pieces.map(\.id)); p.layers.removeAll { ids.contains($0.id) }
            }
            p.clips[i].audioDetached = false; ok = true; return true
        }
        return ok && project != before
    }
    /// Sets the transform of a main-track clip, a video layer or a title. `end: true` sets the animation's end state instead of its start state.
    public func setTransform(_ id: UUID, _ t: Transform, end: Bool = false) {
        commit { p in
            if let i = p.clips.firstIndex(where: { $0.id == id }) { if end { p.clips[i].endTransform = t } else { p.clips[i].transform = t }; return true }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .video }) { if end { p.layers[i].endTransform = t } else { p.layers[i].transform = t }; return true }
            if let i = p.texts.firstIndex(where: { $0.id == id }) {
                if end { p.texts[i].endTransform = t; p.texts[i].anim = nil }
                else if let an = p.texts[i].anim { an.bake(&p.texts[i], rest: t) }        // moving a title with an entrance/exit moves its resting place; the preset follows
                else { p.texts[i].transform = t }
                return true
            }
            return false
        }
    }
    /// Turns the two-state animation on (end state starts as a copy of the start state, so nothing moves until it is edited) or off (the end state is dropped).
    public func setAnimated(_ id: UUID, _ on: Bool) {
        commit { p in
            if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].endTransform = on ? (p.clips[i].endTransform ?? p.clips[i].transform) : nil; return true }
            if let i = p.layers.firstIndex(where: { $0.id == id && $0.kind == .video }) { p.layers[i].endTransform = on ? (p.layers[i].endTransform ?? p.layers[i].transform) : nil; return true }
            if let i = p.texts.firstIndex(where: { $0.id == id }) { p.texts[i].endTransform = on ? (p.texts[i].endTransform ?? p.texts[i].transform) : nil; return true }
            return false
        }
    }
    public func addToLibrary(_ paths: [String]) {
        commit { p in
            let new = paths.filter { !p.library.contains($0) }; guard !new.isEmpty else { return false }
            p.library += Array(NSOrderedSet(array: new)) as! [String]; return true
        }
    }
    /// Appends a whole source to the main track (also records it in the library).
    public func appendClip(media: String, duration: Double) {
        commit { p in
            guard duration >= Self.minClip else { return false }
            p.clips.append(Clip(media: media, sourceStart: 0, duration: duration))
            if !p.library.contains(media) { p.library.append(media) }
            return true
        }
    }
    public func move(clip id: Clip.ID, toIndex j: Int) {
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }), j >= 0, j < p.clips.count, i != j else { return false }
            let c = p.clips.remove(at: i); p.clips.insert(c, at: j); return true
        }
    }
}

public enum ProjectStoreError: Error, Equatable { case unsupportedFormat(Int), missingMedia([String]) }

/// A project is a folder `<name>.sadrogproj` with `project.json`. Media stays where it was recorded; nothing is copied or deleted.
public enum ProjectStore {
    public static let fileName = "project.json"

    public static func save(_ p: SadrogProject, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        var p = p; if p.formatVersion < SadrogProject.currentFormat { p.formatVersion = SadrogProject.currentFormat }
        if p.archived { p.mapMedia { Self.relativeToArchive($0, folder: folder) } }     // saved by this build, so it is a current-format file
        try enc.encode(p).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
    /// Writes the project exactly as given (paths untouched): used by the archive writer, whose paths are already relative.
    static func writeRaw(_ p: SadrogProject, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(p).write(to: folder.appendingPathComponent(fileName), options: .atomic)
    }
    public static func load(from folder: URL) throws -> SadrogProject {
        let data = try Data(contentsOf: folder.appendingPathComponent(fileName))
        var p = try JSONDecoder().decode(SadrogProject.self, from: data)
        guard p.formatVersion <= SadrogProject.currentFormat else { throw ProjectStoreError.unsupportedFormat(p.formatVersion) }
        if p.archived { p.mapMedia { Self.absoluteInArchive($0, folder: folder) } }
        return p
    }
    public static func missingMedia(_ p: SadrogProject) -> [String] {
        Array(Set(p.clips.map(\.media) + p.layers.map(\.media))).filter { !FileManager.default.fileExists(atPath: $0) }.sorted()
    }
}

extension TextOverlay: Animated {}
extension Layer: Animated {}
extension Clip: Animated {}
