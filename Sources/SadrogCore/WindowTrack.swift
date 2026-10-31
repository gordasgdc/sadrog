// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// The window in front at a moment of the recording: its place as a fraction of the captured frame (0,0 = top-left) and which application owns it.
/// The window TITLE and its contents are never stored (a title can hold private text); only geometry and the application's name/identifier.
public struct WindowSample: Codable, Equatable, Sendable {
    public var t: Double, x: Double, y: Double, w: Double, h: Double
    public var app: String, bundleID: String?, windowID: UInt32
    public init(t: Double, x: Double, y: Double, w: Double, h: Double, app: String, bundleID: String? = nil, windowID: UInt32) {
        self.t = t; self.x = x; self.y = y; self.w = w; self.h = h; self.app = app; self.bundleID = bundleID; self.windowID = windowID
    }
}

/// A window as the system reports it (global coordinates, top-left origin), before it is placed in a captured frame.
public struct ForegroundWindow: Equatable, Sendable {
    public var windowID: UInt32, app: String, bundleID: String?, frame: CGRect
    public init(windowID: UInt32, app: String, bundleID: String? = nil, frame: CGRect) { self.windowID = windowID; self.app = app; self.bundleID = bundleID; self.frame = frame }

    /// The topmost ordinary window from a `CGWindowListCopyWindowInfo` listing (front to back): layer 0, visible, not ours, not tiny.
    /// Pure, so it is tested with synthetic listings. `pidToBundle` resolves an owner pid to a bundle identifier (nil when unknown).
    public static func pick(from list: [[String: Any]], excludingPID: Int32, pidToBundle: (Int32) -> String? = { _ in nil }) -> ForegroundWindow? {
        for w in list {
            guard (w["kCGWindowLayer"] as? Int) == 0, (w["kCGWindowAlpha"] as? Double ?? 1) > 0.01,
                  let pid = (w["kCGWindowOwnerPID"] as? Int).map(Int32.init), pid != excludingPID,
                  let id = (w["kCGWindowNumber"] as? Int).map(UInt32.init),
                  let b = w["kCGWindowBounds"] as? [String: Any], let f = CGRect(dictionaryRepresentation: b as CFDictionary),
                  f.width >= 40, f.height >= 40 else { continue }
            let app = (w["kCGWindowOwnerName"] as? String) ?? ""
            return ForegroundWindow(windowID: id, app: app, bundleID: pidToBundle(pid), frame: f)
        }
        return nil
    }
    /// Reads the real window list. Called ONLY while a recording that opted in is running (never at launch, never on a timer of its own).
    public static func systemFront(excludingPID: Int32 = ProcessInfo.processInfo.processIdentifier, pidToBundle: (Int32) -> String? = { _ in nil }) -> ForegroundWindow? {
        guard let l = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        return pick(from: l, excludingPID: excludingPID, pidToBundle: pidToBundle)
    }
}

/// Which window was in front for one recording, kept next to it as `windows.json` (same clock and fraction-of-frame convention as `mouse.json`).
/// `syntheticFixture` marks a track made by a test, never by a person.
public struct WindowTrack: Codable, Equatable, Sendable {
    public static let fileName = "windows.json"
    public var schema = 1
    public var syntheticFixture = false
    public var samples: [WindowSample]
    /// File name of the recording this track belongs to. Several media can live in one folder (imports, added recordings), so a track never applies to a file it was not recorded with;
    /// nil = a track written before this field existed (one recording per folder), accepted for compatibility.
    public var mediaFile: String?
    public init(samples: [WindowSample], syntheticFixture: Bool = false, mediaFile: String? = nil) { self.samples = samples.sorted { $0.t < $1.t }; self.syntheticFixture = syntheticFixture; self.mediaFile = mediaFile }

    /// The window in front at recording time `t`, as a rectangle (fractions of the frame) with its owner; nil before the first sample or with no samples.
    /// Between two samples of the SAME window the rectangle glides linearly (window being moved/resized); a change of window is a cut, not a glide.
    public func window(at t: Double) -> (rect: CGRect, app: String, bundleID: String?, windowID: UInt32)? {
        guard let f = samples.first, t >= f.t else { return nil }
        var lo = 0, hi = samples.count - 1
        if t >= samples[hi].t { lo = hi } else { while hi - lo > 1 { let m = (lo + hi) / 2; if samples[m].t <= t { lo = m } else { hi = m } } }
        let a = samples[lo]
        func rect(_ s: WindowSample) -> CGRect { CGRect(x: s.x, y: s.y, width: s.w, height: s.h) }
        if lo + 1 < samples.count, samples[lo + 1].windowID == a.windowID, t < samples[lo + 1].t {
            let b = samples[lo + 1], k = (t - a.t) / max(1e-9, b.t - a.t)
            let r = CGRect(x: a.x + (b.x - a.x) * k, y: a.y + (b.y - a.y) * k, width: a.w + (b.w - a.w) * k, height: a.h + (b.h - a.h) * k)
            return (r, a.app, a.bundleID, a.windowID)
        }
        return (rect(a), a.app, a.bundleID, a.windowID)
    }
    /// A global window rectangle expressed as fractions of the captured frame, clamped to it (a window partly off the capture is cut at the edge).
    public static func normalize(_ r: CGRect, in frame: CGRect) -> CGRect? {
        guard frame.width > 0, frame.height > 0 else { return nil }
        let c = r.intersection(frame); guard !c.isNull, c.width > 0, c.height > 0 else { return nil }
        return CGRect(x: (c.minX - frame.minX) / frame.width, y: (c.minY - frame.minY) / frame.height, width: c.width / frame.width, height: c.height / frame.height)
    }
    public static func url(besideMedia media: String) -> URL { URL(fileURLWithPath: media).deletingLastPathComponent().appendingPathComponent(fileName) }
    public static func load(besideMedia media: String) -> WindowTrack? {
        guard let d = try? Data(contentsOf: url(besideMedia: media)), let t = try? JSONDecoder().decode(WindowTrack.self, from: d), t.schema == 1, !t.samples.isEmpty else { return nil }
        if let owner = t.mediaFile, owner.caseInsensitiveCompare(URL(fileURLWithPath: media).lastPathComponent) != .orderedSame { return nil }      // another recording's track is no metadata for this file
        return t
    }
    public func save(to folder: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
}

/// Reads the front window ONLY between `start()` and `stop()`, and only when the caller decided to (setting on). Geometry and owner, nothing else.
/// The reading is injected, so the logic is tested without touching the desktop.
public final class WindowRecorder: @unchecked Sendable {
    public typealias Reading = () -> ForegroundWindow?
    private let frame: CGRect, read: Reading, interval: Double, now: () -> Double
    private let lock = NSLock()
    private var samples: [WindowSample] = [], timer: DispatchSourceTimer?, running = false, clockStart = 0.0, paused = false, pausedTotal = 0.0, pausedAt = 0.0
    public init(frame: CGRect, interval: Double = 0.25, now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }, read: @escaping Reading) {
        self.frame = frame; self.interval = interval; self.now = now; self.read = read
    }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard !running else { return }
        running = true; clockStart = now(); samples = []; paused = false; pausedTotal = 0
        guard interval > 0 else { return }       // interval 0 = no timer: the caller ticks (tests)
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "dev.gordas.sadrog.windows", qos: .utility))
        t.schedule(deadline: .now(), repeating: interval); t.setEventHandler { [weak self] in self?.tick() }; timer = t; t.resume()
    }
    public func pause() { lock.lock(); if running, !paused { paused = true; pausedAt = now() }; lock.unlock() }
    public func resume() { lock.lock(); if paused { paused = false; pausedTotal += now() - pausedAt }; lock.unlock() }
    /// One reading; kept when the window or its place changed, plus a heartbeat every two seconds. A window outside the captured frame is skipped.
    func tick() {
        lock.lock(); let skip = paused || !running; let t = now() - clockStart - pausedTotal; lock.unlock()
        guard !skip, let w = read(), let r = WindowTrack.normalize(w.frame, in: frame) else { return }
        let s = WindowSample(t: max(0, t), x: r.minX, y: r.minY, w: r.width, h: r.height, app: w.app, bundleID: w.bundleID, windowID: w.windowID)
        lock.lock(); defer { lock.unlock() }
        if let l = samples.last, l.windowID == s.windowID, abs(l.x - s.x) < 0.0005, abs(l.y - s.y) < 0.0005, abs(l.w - s.w) < 0.0005, abs(l.h - s.h) < 0.0005, t - l.t < 2 { return }
        samples.append(s)
    }
    public func stop() -> WindowTrack {
        lock.lock(); let t = timer; timer = nil; running = false; let s = samples; samples = []; lock.unlock()
        t?.cancel(); return WindowTrack(samples: s)
    }
}

public extension WindowTrack {
    /// A window that appears in the track: its owner, how long it was in front and its identity (to choose which one to follow).
    struct Seen: Equatable, Sendable { public var windowID: UInt32, app: String, bundleID: String?, seconds: Double }
    /// The distinct windows of the track in front-time order (most time first). A sample's time runs until the next sample (the last one counts 2 s, the heartbeat).
    var windowsSeen: [Seen] {
        var acc: [UInt32: Seen] = [:]
        for (i, s) in samples.enumerated() {
            let dur = i + 1 < samples.count ? samples[i + 1].t - s.t : 2
            var e = acc[s.windowID] ?? Seen(windowID: s.windowID, app: s.app, bundleID: s.bundleID, seconds: 0); e.seconds += max(0, dur); acc[s.windowID] = e
        }
        return acc.values.sorted { $0.seconds > $1.seconds }
    }
}

/// Turns the recorded front window into the same kind of motion the pointer-follow produces: plain keys on the clip (zoom so the window fills the frame, panned onto it).
/// Behaviour when the window is missing is explicit: before the first reading, or when the last reading is older than `maxAge` (the heartbeat is 2 s, so a longer silence means
/// the window left the capture / the recorder was not reading), the frame goes back to the full picture instead of staying on a stale rectangle. `only` restricts it to one window.
public enum WindowFollow {
    public static func plan(_ track: WindowTrack, sourceStart: Double, duration: Double, only: UInt32? = nil, fill: Double = 0.92, maxAge: Double = 3, step: Double = 0.5)
        -> (start: Transform, keys: [MotionKey])? {
        guard duration > 0.2, !track.samples.isEmpty else { return nil }
        let usable = only == nil ? track : WindowTrack(samples: track.samples.filter { $0.windowID == only })
        guard !usable.samples.isEmpty else { return nil }
        func target(_ e: Double) -> Transform {
            let t = sourceStart + e
            guard let w = window(usable, at: t, maxAge: maxAge), w.width > 0.02, w.height > 0.02 else { return .identity }
            let s = max(1, min(4, min(1 / w.width, 1 / w.height) * fill))
            guard s > 1.05 else { return .identity }                               // the window already fills the frame
            let lim = (s - 1) / 2
            return Transform(x: max(-lim, min(lim, (0.5 - w.midX) * s)), y: max(-lim, min(lim, (0.5 - w.midY) * s)), scale: s)
        }
        var keys: [MotionKey] = []; var e = step
        while e < duration - 0.05 { keys.append(MotionKey(t: e, transform: target(e))); e += step }
        guard keys.contains(where: { $0.transform != .identity }) || target(0) != .identity else { return nil }
        return (target(0), keys)
    }
    /// The window rectangle at `t`, or nil when there is no reading at or before `t`, or the last one is older than `maxAge`.
    static func window(_ track: WindowTrack, at t: Double, maxAge: Double) -> CGRect? {
        guard let w = track.window(at: t)?.rect else { return nil }
        let last = track.samples.last { $0.t <= t }?.t ?? -1
        return t - last <= maxAge ? w : nil
    }
}

public extension ProjectEditor {
    /// Zooms the clip onto the recorded front window and follows it (see `WindowFollow`). Replaces the clip's start state and keys, like the pointer follow. One undo step.
    @discardableResult func followWindow(clip id: Clip.ID, track: WindowTrack, only: UInt32? = nil) -> Bool {
        guard let c = project.clips.first(where: { $0.id == id }), !c.held, let plan = WindowFollow.plan(track, sourceStart: c.sourceStart, duration: c.duration, only: only) else { return false }
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }) else { return false }
            var m = p.clips[i].motion ?? Motion(); m.keys = plan.keys; m.easing = .linear; m.headSlice = 0; m.tailSlice = 1; m.normalize()
            p.clips[i].transform = plan.start; p.clips[i].endTransform = nil; p.clips[i].motion = m; return true
        }
        return true
    }
}
