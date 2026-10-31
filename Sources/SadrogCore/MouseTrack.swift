// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Where the pointer was and whether a button was down, `t` seconds into the recording (pauses excluded, like the media), position as a fraction of the
/// captured frame (0,0 = top-left). Nothing else is ever stored: no keys, no typed text, no window contents.
public struct MouseSample: Codable, Equatable, Sendable {
    public var t: Double, x: Double, y: Double, down: Bool
    public init(t: Double, x: Double, y: Double, down: Bool = false) { self.t = t; self.x = x; self.y = y; self.down = down }
}

/// The pointer's path for one recording, kept next to the recording as `mouse.json`. `syntheticFixture` marks a track made by a test, never by a person.
public struct MouseTrack: Codable, Equatable, Sendable {
    public static let fileName = "mouse.json"
    public var schema = 1
    public var syntheticFixture = false
    /// Seconds to add to a sample's time to land on the media's clock (the pointer starts being read slightly after the first frame): editable, default 0.
    public var syncOffset = 0.0
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
    private let lock = NSLock()
    private var samples: [MouseSample] = [], timer: DispatchSourceTimer?, running = false, clockStart = 0.0, paused = false, pausedTotal = 0.0, pausedAt = 0.0
    private let now: () -> Double
    public init(frame: CGRect, interval: Double = 1.0 / 60, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, read: @escaping Reading) {
        self.frame = frame; self.interval = interval; self.now = now; self.read = read
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
        let r = read(), p = MouseTrack.normalize(r.point, in: frame)
        lock.lock(); defer { lock.unlock() }
        if let l = samples.last, l.x == p.x, l.y == p.y, l.down == r.down, t - l.t < 1 { return }
        samples.append(MouseSample(t: max(0, t), x: p.x, y: p.y, down: r.down))
    }
    /// Stops reading and returns what was collected (empty → no file should be written).
    public func stop() -> MouseTrack {
        lock.lock(); let t = timer; timer = nil; running = false; let s = samples; samples = []; lock.unlock()
        t?.cancel(); return MouseTrack(samples: s)
    }
}

/// What the editor draws from a recording's pointer track, per clip: a soft highlight under the pointer and a ring at every click.
public struct MouseFX: Codable, Equatable, Sendable {
    public var highlight = true, clickRing = true
    public init(highlight: Bool = true, clickRing: Bool = true) { self.highlight = highlight; self.clickRing = clickRing }
    public var isOff: Bool { !highlight && !clickRing }
    public static let ringSeconds = 0.5
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
