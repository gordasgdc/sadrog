// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation

/// Clip speed. Three clocks, never mixed:
/// - SOURCE time: seconds inside the recorded file (`sourceStart`, waveform, thumbnails, pointer track, In/Out of the material);
/// - LOCAL time: seconds from the start of the item on the timeline (`0 … duration`; motion keys, fades, effects, callout offsets);
/// - TIMELINE time: seconds from the start of the document.
/// `source = sourceStart + local × speed`. `duration` is always LOCAL length, so cuts, fades, keys and dissolves keep working in the time the viewer sees.
public enum Retime {
    /// Safe range: 0.1× … 16×. Beyond it a frame would be shown for more than 10 s, or more than 16 source frames would pass in one output frame.
    public static let range: ClosedRange<Double> = 0.1...16
    public static let presets: [Double] = [0.25, 0.5, 1, 2, 4, 6]
    public static func clamp(_ v: Double) -> Double { v.isFinite ? max(range.lowerBound, min(range.upperBound, (v * 1000).rounded() / 1000)) : 1 }
    public static func source(start: Double, speed: Double, local: Double) -> Double { start + local * speed }
    public static func local(sourceStart: Double, speed: Double, source: Double) -> Double { (source - sourceStart) / speed }
    /// Timeline length of `span` seconds of source played at `speed`.
    public static func duration(sourceSpan span: Double, speed: Double) -> Double { span / clamp(speed) }
    /// “×” text for the UI: 2× / 0.5× / 1.25×.
    public static func label(_ v: Double) -> String {
        let s = String(format: "%.3f", v); var t = s; while t.contains(".") && (t.hasSuffix("0")) { t.removeLast() }; if t.hasSuffix(".") { t.removeLast() }; return t + "×"
    }
    /// Pitch handling for retimed sound (applied by the player, the export session and the readers — one setting for the mix).
    public static func pitchAlgorithm(for p: SadrogProject) -> AVAudioTimePitchAlgorithm { p.keepPitch ? .spectral : .varispeed }
    /// Does anything in the project play at a speed other than 1×?
    public static func isRetimed(_ p: SadrogProject) -> Bool { p.clips.contains { !$0.held && $0.speed != 1 } || p.layers.contains { $0.speed != 1 } }
}

extension ProjectEditor {
    /// Why the clip cannot be retimed (nil = it can): a freeze frame has no source motion.
    public func retimeBlocker(ofClip id: Clip.ID) -> String? {
        guard let c = project.clips.first(where: { $0.id == id }) else { return "missing" }
        return c.held ? "held" : nil
    }
    /// Sets the speed of a main-track clip. The material it plays (source start and span) stays; its timeline length becomes `span / speed`, so the montage after it
    /// moves (ripple) and the clip’s own keys, bound highlights and detached sound scale with it. One undo step. Speed outside `Retime.range` is clamped; a result
    /// shorter than the minimum clip is clamped to it.
    @discardableResult public func setSpeed(clip id: Clip.ID, _ speed: Double) -> Bool {
        var ok = false; let before = project
        commit { p in
            guard let i = p.clips.firstIndex(where: { $0.id == id }), !p.clips[i].held else { return false }
            let c = p.clips[i], span = c.sourceSpan, start = p.clipSpans[i].start
            var s = Retime.clamp(speed); if span / s < Self.minClip { s = span / Self.minClip }
            guard abs(s - c.speed) > 1e-9 else { return false }
            let ratio = c.speed / s
            p.clips[i].speed = s; p.clips[i].duration = c.duration * ratio
            Self.scaleMotion(&p.clips[i].motion, by: ratio)
            for k in p.callouts.indices where p.callouts[k].clipID == id { p.callouts[k].start = start + (p.callouts[k].start - start) * ratio; p.callouts[k].duration *= ratio }
            for k in p.layers.indices where p.layers[k].kind == .audio && p.layers[k].linkedClip == id {
                p.layers[k].speed = s; p.layers[k].start = start + (p.layers[k].start - start) * ratio; p.layers[k].duration *= ratio
                p.layers[k].audio = p.layers[k].audio?.scaled(by: ratio); Self.clampFades(&p.layers[k].audio, duration: p.layers[k].duration)
            }
            p.clips[i].audio = p.clips[i].audio?.scaled(by: ratio)
            Self.clampFades(&p.clips[i].audio, duration: p.clips[i].duration)
            ok = true; return true
        }
        return ok && project != before
    }
    /// Plays no sound of its own while retimed (or restores it). One undo step.
    public func setSpeedMute(clip id: Clip.ID, _ muted: Bool) {
        commit { p in guard let i = p.clips.firstIndex(where: { $0.id == id }), p.clips[i].speedMute != muted else { return false }; p.clips[i].speedMute = muted; return true }
    }
    /// Pitch policy of retimed sound for the whole mix. One undo step.
    public func setKeepPitch(_ keep: Bool) { commit { p in guard p.keepPitch != keep else { return false }; p.keepPitch = keep; return true } }

    /// Why an overlay / independent audio item cannot take this speed (nil = it can): the new length would run into the next item on its row.
    public func layerSpeedBlocker(_ id: Layer.ID, speed: Double) -> String? {
        guard let l = project.layers.first(where: { $0.id == id }) else { return "missing" }
        var q = l; let s = Retime.clamp(speed); q.duration = l.sourceSpan / s; q.speed = s
        if q.duration < Self.minClip { return "short" }
        return Self.overlaps(q, in: project) ? "overlap" : nil
    }
    /// Sets the speed of a video overlay or an independent audio item. The item keeps its start; if the new length would overlap another item on its row nothing is
    /// changed (nothing else is moved). One undo step.
    @discardableResult public func setSpeed(layer id: Layer.ID, _ speed: Double) -> Bool {
        guard layerSpeedBlocker(id, speed: speed) == nil else { return false }
        var ok = false; let before = project
        commit { p in
            guard let i = p.layers.firstIndex(where: { $0.id == id }) else { return false }
            let l = p.layers[i], s = Retime.clamp(speed); guard abs(s - l.speed) > 1e-9 else { return false }
            let ratio = l.speed / s
            p.layers[i].speed = s; p.layers[i].duration = l.duration * ratio
            Self.scaleMotion(&p.layers[i].motion, by: ratio); p.layers[i].audio = p.layers[i].audio?.scaled(by: ratio); Self.clampFades(&p.layers[i].audio, duration: p.layers[i].duration)
            for k in p.callouts.indices where p.callouts[k].layerID == id { p.callouts[k].start = l.start + (p.callouts[k].start - l.start) * ratio; p.callouts[k].duration *= ratio }
            ok = true; return true
        }
        return ok && project != before
    }
    static func scaleMotion(_ m: inout Motion?, by r: Double) {
        guard var mm = m, !mm.keys.isEmpty else { return }
        for k in mm.keys.indices { mm.keys[k].t *= r }
        m = mm
    }
    static func clampFades(_ a: inout AudioEdit?, duration d: Double) {
        guard var e = a else { return }
        e.fadeIn = min(e.fadeIn, d); e.fadeOut = min(e.fadeOut, d); a = e.isNeutral ? nil : e
    }
}
