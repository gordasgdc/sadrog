// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Where the pointer was and whether a button was down, `t` seconds into the recording (pauses excluded, like the media), position as a fraction of the
/// captured frame (0,0 = top-left). Nothing else is ever stored: no keys, no typed text, no window contents.
public struct MouseSample: Codable, Equatable, Sendable {
    public var t: Double, x: Double, y: Double, down: Bool
    /// The secondary (right) button is down. Written only when true, by recordings made from 1.7.0 on; older tracks never have it.
    public var right: Bool?
    public init(t: Double, x: Double, y: Double, down: Bool = false, right: Bool = false) { self.t = t; self.x = x; self.y = y; self.down = down; self.right = right ? true : nil }
}

/// One click as the editor draws it. A double click is ONE event that starts at its first press (`gap` = seconds to the second press), so no
/// simple click marker is ever drawn on top of it.
public struct MouseClick: Equatable, Sendable {
    public enum Kind: String, Sendable { case left, right, double }
    public var t: Double, x: Double, y: Double, kind: Kind, gap: Double
}

/// The pointer's path for one recording, kept next to the recording as `mouse.json`. `syntheticFixture` marks a track made by a test, never by a person.
public struct MouseTrack: Codable, Equatable, Sendable {
    public static let fileName = "mouse.json"
    public var schema = 1
    public var syntheticFixture = false
    /// Seconds to add to a sample's time to land on the media's clock (the pointer starts being read slightly after the first frame): editable, default 0.
    public var syncOffset = 0.0
    /// true = the recorder also read the secondary button (1.7.0 on). nil/false = only the primary button is known: right clicks cannot be told apart.
    public var rightTracked: Bool?
    public var samples: [MouseSample]
    public init(samples: [MouseSample], syntheticFixture: Bool = false, syncOffset: Double = 0) { self.samples = samples.sorted { $0.t < $1.t }; self.syntheticFixture = syntheticFixture; self.syncOffset = syncOffset }

    /// Pointer position at recording time `t` (linear between samples, held before the first and after the last); nil when there are no samples.
    public func position(at t: Double) -> (x: Double, y: Double)? {
        let u = t - syncOffset
        guard let f = samples.first, let l = samples.last else { return nil }
        if u <= f.t { return (f.x, f.y) }; if u >= l.t { return (l.x, l.y) }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 { let m = (lo + hi) / 2; if samples[m].t <= u { lo = m } else { hi = m } }
        let a = samples[lo], b = samples[hi], k = (u - a.t) / max(1e-9, b.t - a.t)
        return (a.x + (b.x - a.x) * k, a.y + (b.y - a.y) * k)
    }
    /// Button presses (a sample with the button down after one with it up): time on the media's clock and place.
    public var clicks: [(t: Double, x: Double, y: Double)] {
        var out: [(Double, Double, Double)] = []; var was = false
        for s in samples { if s.down && !was { out.append((s.t + syncOffset, s.x, s.y)) }; was = s.down }
        return out
    }
    /// Two primary presses closer than this, at (nearly) the same place, are one double click.
    public static let doubleClickSeconds = 0.45, doubleClickDistance = 0.02
    /// Every click, typed: primary, secondary (only when the track has that button) and double (two close primary presses merged into one event).
    public var clickEvents: [MouseClick] {
        var out: [MouseClick] = []; var wasL = false, wasR = false
        for s in samples {
            let r = s.right ?? false
            if s.down && !wasL {
                let t = s.t + syncOffset
                if let l = out.last, l.kind == .left, t - l.t <= Self.doubleClickSeconds, abs(l.x - s.x) <= Self.doubleClickDistance, abs(l.y - s.y) <= Self.doubleClickDistance {
                    out[out.count - 1].kind = .double; out[out.count - 1].gap = t - l.t
                } else { out.append(MouseClick(t: t, x: s.x, y: s.y, kind: .left, gap: 0)) }
            }
            if r && !wasR { out.append(MouseClick(t: s.t + syncOffset, x: s.x, y: s.y, kind: .right, gap: 0)) }
            wasL = s.down; wasR = r
        }
        return out
    }
    /// Clicks whose effect is still visible at recording time `t` for an effect lasting `duration` seconds (a double click lasts `gap` longer).
    public func activeClicks(at t: Double, duration: Double, in events: [MouseClick]? = nil) -> [MouseClick] {
        (events ?? clickEvents).filter { t >= $0.t && t < $0.t + duration + $0.gap }
    }
    /// Seconds since the most recent click at recording time `t` (nil when none yet).
    public func sinceClick(at t: Double) -> (age: Double, x: Double, y: Double)? {
        guard let c = clicks.last(where: { $0.t <= t }) else { return nil }
        return (t - c.t, c.x, c.y)
    }
    /// Normalises a global pointer location (top-left origin, as CoreGraphics reports it) into the captured frame; outside it the value is clamped.
    public static func normalize(_ p: CGPoint, in frame: CGRect) -> (x: Double, y: Double) {
        guard frame.width > 0, frame.height > 0 else { return (0.5, 0.5) }
        return (max(0, min(1, Double((p.x - frame.minX) / frame.width))), max(0, min(1, Double((p.y - frame.minY) / frame.height))))
    }

    public static func url(besideMedia media: String) -> URL { URL(fileURLWithPath: media).deletingLastPathComponent().appendingPathComponent(fileName) }
    public static func load(besideMedia media: String) -> MouseTrack? {
        guard let d = try? Data(contentsOf: url(besideMedia: media)), let t = try? JSONDecoder().decode(MouseTrack.self, from: d), t.schema == 1, !t.samples.isEmpty else { return nil }
        return t
    }
    public func save(to folder: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Reads the pointer ONLY between `start()` and `stop()` — never on its own, never when the setting is off (the caller decides). A position and a
/// button state, nothing else; keyboard input is not read at all. The location source is injected, so the logic is tested without a real pointer.
public final class MouseRecorder: @unchecked Sendable {
    public typealias Reading = () -> (point: CGPoint, down: Bool)
    private let frame: CGRect, read: Reading, interval: Double
    private let readRight: (() -> Bool)?
    private let lock = NSLock()
    private var samples: [MouseSample] = [], timer: DispatchSourceTimer?, running = false, clockStart = 0.0, paused = false, pausedTotal = 0.0, pausedAt = 0.0
    private let now: () -> Double
    /// `readRight`: state of the secondary button (nil = not read: the track then says nothing about right clicks).
    public init(frame: CGRect, interval: Double = 1.0 / 60, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, readRight: (() -> Bool)? = nil, read: @escaping Reading) {
        self.frame = frame; self.interval = interval; self.now = now; self.read = read; self.readRight = readRight
    }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true
        clockStart = now(); samples = []; paused = false; pausedTotal = 0
        guard interval > 0 else { return }       // interval 0 = no timer: the caller ticks (tests)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.gordas.sadrog.mouse", qos: .utility))
        t.schedule(deadline: .now(), repeating: interval); t.setEventHandler { [weak self] in self?.tick() }; timer = t; t.resume()
    }
    public func pause() { lock.lock(); if running, !paused { paused = true; pausedAt = now() }; lock.unlock() }
    public func resume() { lock.lock(); if paused { paused = false; pausedTotal += now() - pausedAt }; lock.unlock() }
    /// One reading (also called by the timer); a sample is kept when the pointer moved or the button changed, plus a heartbeat every second.
    func tick() {
        lock.lock(); let skip = paused || !running; let t = now() - clockStart - pausedTotal; lock.unlock()
        guard !skip else { return }
        let r = read(), p = MouseTrack.normalize(r.point, in: frame), rb = readRight?() ?? false
        lock.lock(); defer { lock.unlock() }
        if let l = samples.last, l.x == p.x, l.y == p.y, l.down == r.down, (l.right ?? false) == rb, t - l.t < 1 { return }
        samples.append(MouseSample(t: max(0, t), x: p.x, y: p.y, down: r.down, right: rb))
    }
    /// Stops reading and returns what was collected (empty → no file should be written).
    public func stop() -> MouseTrack {
        lock.lock(); let t = timer; timer = nil; running = false; let s = samples; samples = []; lock.unlock()
        t?.cancel(); var tr = MouseTrack(samples: s); if readRight != nil { tr.rightTracked = true }; return tr
    }
}

/// What the editor draws from a recording's pointer track, per clip: a soft highlight under the pointer and a ring at every click.
public struct MouseFX: Codable, Equatable, Sendable {
    /// How the continuous highlight is drawn: an outline with nothing inside, a soft glow, or a flat disc (the look before 1.7.0).
    public enum Style: String, Codable, Sendable, CaseIterable { case ring, halo, disc }
    public var highlight = true, clickRing = true
    public var style = Style.disc
    public var color = MouseFX.legacyColor            // highlight colour (its own opacity is `opacity`)
    public var size = 1.0                             // radius multiplier (1 = 3.5 % of the picture height)
    public var opacity = 0.35
    public var stroke = 0.12                          // outline thickness as a fraction of the radius (ring style)
    public var clickColor = TextColor.white
    public var clickSeconds = MouseFX.ringSeconds     // how long a click ring lives
    public var clickStrength = 0.9                    // opacity of a click ring when it appears
    public init(highlight: Bool = true, clickRing: Bool = true) { self.highlight = highlight; self.clickRing = clickRing }
    public var isOff: Bool { !highlight && !clickRing }
    public static let ringSeconds = 0.5
    public static let legacyColor = TextColor(r: 1, g: 0.85, b: 0.2)
    public static let sizeRange = 0.4...3.0, opacityRange = 0.05...1.0, strokeRange = 0.04...0.5, clickSecondsRange = 0.2...1.5, clickStrengthRange = 0.1...1.0
    /// What a clip gets when the effect is switched on for the first time from 1.7.0: an outline (nothing covers the content under the pointer).
    /// Click rings are blue: white (the old colour) cannot be seen on a light page, and blue reads on light and dark content alike.
    public static let modernClickColor = TextColor(r: 0.04, g: 0.52, b: 1)
    public static var modern: MouseFX { var f = MouseFX(); f.style = .ring; f.opacity = 0.9; f.stroke = 0.12; f.clickColor = modernClickColor; return f }
    /// The look only (switches untouched) back to the modern defaults.
    public mutating func resetLook() { let m = MouseFX.modern; style = m.style; color = m.color; size = m.size; opacity = m.opacity; stroke = m.stroke; clickColor = m.clickColor; clickSeconds = m.clickSeconds; clickStrength = m.clickStrength }
    public var lookIsDefault: Bool { var a = self; a.resetLook(); return a == self }
    public mutating func normalize() {
        func cl(_ v: Double, _ r: ClosedRange<Double>, _ d: Double) -> Double { v.isFinite ? min(r.upperBound, max(r.lowerBound, v)) : d }
        size = cl(size, Self.sizeRange, 1); opacity = cl(opacity, Self.opacityRange, 0.35); stroke = cl(stroke, Self.strokeRange, 0.12)
        clickSeconds = cl(clickSeconds, Self.clickSecondsRange, Self.ringSeconds); clickStrength = cl(clickStrength, Self.clickStrengthRange, 0.9)
    }
    enum CodingKeys: String, CodingKey { case highlight, clickRing, style, color, size, opacity, stroke, clickColor, clickSeconds, clickStrength }
    /// Only what differs from the pre-1.7.0 look is written, so a project that never touched the new controls is saved exactly as before.
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self); let d = MouseFX()
        try c.encode(highlight, forKey: .highlight); try c.encode(clickRing, forKey: .clickRing)
        if style != d.style { try c.encode(style, forKey: .style) }
        if color != d.color { try c.encode(color, forKey: .color) }
        if size != d.size { try c.encode(size, forKey: .size) }
        if opacity != d.opacity { try c.encode(opacity, forKey: .opacity) }
        if stroke != d.stroke { try c.encode(stroke, forKey: .stroke) }
        if clickColor != d.clickColor { try c.encode(clickColor, forKey: .clickColor) }
        if clickSeconds != d.clickSeconds { try c.encode(clickSeconds, forKey: .clickSeconds) }
        if clickStrength != d.clickStrength { try c.encode(clickStrength, forKey: .clickStrength) }
    }
    public init(from dec: Decoder) throws {
        let c = try dec.container(keyedBy: CodingKeys.self)
        highlight = try c.decodeIfPresent(Bool.self, forKey: .highlight) ?? true; clickRing = try c.decodeIfPresent(Bool.self, forKey: .clickRing) ?? true
        style = (try c.decodeIfPresent(String.self, forKey: .style)).flatMap(Style.init(rawValue:)) ?? .disc
        color = try c.decodeIfPresent(TextColor.self, forKey: .color) ?? MouseFX.legacyColor
        size = try c.decodeIfPresent(Double.self, forKey: .size) ?? 1; opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.35
        stroke = try c.decodeIfPresent(Double.self, forKey: .stroke) ?? 0.12
        clickColor = try c.decodeIfPresent(TextColor.self, forKey: .clickColor) ?? .white
        clickSeconds = try c.decodeIfPresent(Double.self, forKey: .clickSeconds) ?? MouseFX.ringSeconds
        clickStrength = try c.decodeIfPresent(Double.self, forKey: .clickStrength) ?? 0.9
        normalize()
    }
}

/// Turns a pointer track into keyframes for the existing animation (`Motion`): the frame is magnified by `scale` and follows the pointer, smoothed so it
/// does not shake, never showing beyond the picture's edge. No second animation system: the result is ordinary keys of the clip.
public enum MouseFollow {
    public static func plan(_ track: MouseTrack, sourceStart: Double, duration: Double, scale: Double, step: Double = 0.5, smoothing: Double = 1.2) -> (start: Transform, keys: [MotionKey])? {
        guard duration > 0.2, scale > 1.01, track.position(at: sourceStart) != nil else { return nil }
        let s = max(1.05, min(4, scale)), lim = (s - 1) / 2
        func target(_ e: Double) -> Transform {      // pointer averaged over a short window around e: stable, but still follows
            var sx = 0.0, sy = 0.0, w = 0.0
            for k in -4...4 { let ee = max(0, min(duration, e + Double(k) * smoothing / 8)); if let p = track.position(at: sourceStart + ee) { let wt = 1 - abs(Double(k)) / 5; sx += p.x * wt; sy += p.y * wt; w += wt } }
            let cx = sx / w, cy = sy / w
            return Transform(x: max(-lim, min(lim, (0.5 - cx) * s)), y: max(-lim, min(lim, (0.5 - cy) * s)), scale: s)
        }
        var keys: [MotionKey] = []; var e = step
        while e < duration - 0.05 { keys.append(MotionKey(t: e, transform: target(e))); e += step }
        return (target(0), keys)
    }
}
