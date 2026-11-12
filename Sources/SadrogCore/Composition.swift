// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation
import AppKit
import CoreImage

/// A built composition plus what is needed to (re)create the video composition and audio mix when only transforms/lane switches change.
public struct BuiltComposition {
    public let composition: AVMutableComposition
    public let renderSize: CGSize
    let frameDuration: CMTime
    /// Time-pitch algorithm for retimed sound (see `Retime.pitchAlgorithm`); set by `buildFull`.
    public var pitch: AVAudioTimePitchAlgorithm = .spectral
    let mainTrack: AVMutableCompositionTrack?
    let mainTrackB: AVMutableCompositionTrack?                // second main video track, only when a cross-dissolve makes two clips overlap
    /// One composition track per audio track of the main recordings (index = track in the file: system sound, microphone, input channels…).
    let mainAudio: [Int: AVMutableCompositionTrack]
    static let laneStride = 1000                              // mainAudio key = source index + lane × laneStride (lane 1 = the incoming side of a dissolve)
    let mainSize: [UUID: CGSize]                              // natural size of each main clip's source
    let layerTracks: [UUID: (track: AVMutableCompositionTrack, size: CGSize)]
    let layerAudio: [UUID: [AVMutableCompositionTrack]]   // every audio track of an independent (A2) item
    var sourceFps: Double = 0                              // nominal rate of the first source (a different document rate needs the compositor)

    /// Placement matrix in top-left (y-down) pixel space: aspect-fit the source into the frame (`fit`), scale about its centre, rotate clockwise, then move by the offset.
    public static func matrix(natural n: CGSize, render r: CGSize, _ t: Transform, fit: Bool = true) -> CGAffineTransform {
        let f = fit ? min(r.width / max(n.width, 1), r.height / max(n.height, 1)) : 1, s = f * t.scale
        return CGAffineTransform(translationX: -n.width / 2, y: -n.height / 2).concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(rotationAngle: t.rotation * .pi / 180))
            .concatenating(CGAffineTransform(translationX: r.width / 2 + t.x * r.width, y: r.height / 2 + t.y * r.height))
    }

    /// nil when the project is a plain sequence with identity transforms (then the composition plays/exports as before).
    /// Otherwise a custom CoreImage compositor draws, per frame: background, main clip, overlays, titles — the same code for preview and export.
    /// `framingGuide`: id of a circle item being framed in the EDITOR preview — its whole source rectangle is drawn faded outside the circle. Never set by an export.
    public func videoComposition(for p: SadrogProject, framingGuide: UUID? = nil) -> AVMutableVideoComposition? {
        let rateChange = p.canvas.map { abs($0.fps - sourceFps) > 0.01 } ?? false
        guard p.needsCompositing || rateChange || p.clips.contains(where: { mainSize[$0.id].map { $0 != renderSize } ?? false }) else { return nil }
        let total = max(p.timelineEnd, composition.duration.seconds)
        typealias Item = SadrogInstruction.Item
        var items: [Item] = []                                                      // bottom → top
        if !p.hiddenLanes.contains(.v1), let mt = mainTrack {
            let spans = p.clipSpans, lanes = p.clipLanes
            var mouseTracks: [String: MouseTrack] = [:]
            for (i, c) in p.clips.enumerated() {
                let n = mainSize[c.id] ?? renderSize, acc = spans[i].start
                let tid = lanes[i] == 1 ? (mainTrackB ?? mt).trackID : mt.trackID
                var mi = Item(source: .track(tid, n), start: acc, duration: c.duration, a: c.transform, b: c.endTransform, fit: true, crop: c.crop.map { CircleCropRender($0, source: n) }, rect: c.crop == nil ? c.rectCrop : nil)
                mi.motion = c.motion; mi.picture = c.picture; mi.dissolveIn = p.overlap(into: i); mi.guide = framingGuide == c.id && c.crop != nil
                if let fx = c.mouseFX, !fx.isOff, !c.held, let tr = mouseTracks[c.media] ?? MouseTrack.load(besideMedia: c.media) { mi.mouse = (tr, c.sourceStart, c.speed, fx) }
                if c.keyFX?.show ?? false, !c.held, let kt = KeyTrack.load(besideMedia: c.media) { mi.keys = (kt, c.sourceStart, c.speed) }
                items.append(mi)
            }
        }
        // a callout bound to a clip works on that clip's picture only (right after the main track, below the overlays) unless "overlays" is on
        let bound: (Callout) -> Bool = { $0.clipID != nil && !$0.overlays }
        let overlayIDs = Set(p.layers.filter { $0.kind == .video && layerTracks[$0.id] != nil }.map(\.id))
        let onOverlay: (Callout) -> Bool = { $0.layerID.map(overlayIDs.contains) ?? false }       // bound to a video overlay that exists here
        if !p.hiddenLanes.contains(.c) {
            for c in p.callouts where bound(c) { items.append(Item(source: .callout(c, CalloutMask.make(c.displayed, render: renderSize)), start: c.start, duration: c.duration, a: .identity, b: nil, fit: false)) }
        }
        if !p.hiddenLanes.contains(.v2) {
            for l in p.layers.filter({ $0.kind == .video }).sorted(by: { $0.row < $1.row }) {
                guard let lt = layerTracks[l.id] else { continue }
                var it = Item(source: .track(lt.track.trackID, lt.size), start: l.start, duration: l.duration, a: l.transform, b: l.endTransform, fit: true, crop: l.crop.map { CircleCropRender($0, source: lt.size) }, rect: l.crop == nil ? l.rectCrop : nil)
                it.layer = l.id; it.motion = l.motion; it.picture = l.picture; it.guide = framingGuide == l.id && l.crop != nil; items.append(it)
                if !p.hiddenLanes.contains(.c) {       // callouts bound to this overlay sit right above it and act inside its picture only
                    for c in p.callouts where c.layerID == l.id { var ci = Item(source: .callout(c, CalloutMask.make(c.displayed, render: renderSize)), start: c.start, duration: c.duration, a: .identity, b: nil, fit: false); ci.limitTo = l.id; items.append(ci) }
                }
            }
        }
        if !p.hiddenLanes.contains(.c) {
            for c in p.callouts where !bound(c) && !onOverlay(c) { items.append(Item(source: .callout(c, CalloutMask.make(c.displayed, render: renderSize)), start: c.start, duration: c.duration, a: .identity, b: nil, fit: false)) }
        }
        if !p.hiddenLanes.contains(.t) {
            for t in p.texts { if let img = TextRenderer.image(t, render: renderSize) { var ti = Item(source: .image(CIImage(cgImage: img), CGSize(width: img.width, height: img.height)), start: t.start, duration: t.duration, a: t.transform, b: t.endTransform, fit: false); ti.motion = t.motion; items.append(ti) } }
        }
        var cuts: Set<Double> = [0, total]
        for it in items { cuts.insert(it.start); cuts.insert(it.start + it.duration) }
        let times = cuts.filter { $0 >= 0 && $0 <= total }.sorted()
        var instructions: [AVVideoCompositionInstructionProtocol] = []
        for k in 0..<max(0, times.count - 1) {
            let a = times[k], b = times[k + 1]; guard b - a > 0.0005 else { continue }
            let range = CMTimeRange(start: CMTime(seconds: a, preferredTimescale: 6000), end: CMTime(seconds: b, preferredTimescale: 6000))
            instructions.append(SadrogInstruction(timeRange: range, items: items.filter { $0.start <= a + 1e-6 && $0.start + $0.duration >= b - 1e-6 }))
        }
        guard !instructions.isEmpty else { return nil }
        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = SadrogCompositor.self
        vc.renderSize = renderSize; vc.frameDuration = frameDuration; vc.instructions = instructions
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2; vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2; vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2
        return vc
    }

    /// Mute switches: a muted lane keeps its place on the timeline and plays silence (volume 0) — it never shortens or shifts anything.
    /// With more than one audio track (several sources of a recording, or A2 items) the mix lists EVERY track: the exporter then writes one mixed
    /// track — what the preview plays — instead of keeping the tracks apart (HighestQuality without a mix copies them as separate tracks,
    /// which most players do not sum). nil only for a single, unmuted track (passthrough stays possible).
/// Which sound a mix renders: everything (preview, video export, full-mix audio file), or one stem. A stem is ONE source of the recording (A1,
    /// by its track index in the file) or the whole A2 lane; stems keep the source's own volume/mute/fades but NOT the master volume.
    /// `.source(k)`: track k of EVERY recording; `.recording(media, k)`: track k of that one recording; `.a2`: the separate A2 sound.
    public enum MixSelection: Equatable, Sendable {
        case all, source(Int), recording(String, Int), a2
        func includes(media: String, track k: Int) -> Bool { self == .all || self == .source(k) || self == .recording(media, k) }
    }
    public func audioMix(for p: SadrogProject) -> AVMutableAudioMix? { audioMix(for: p, selection: .all) }
    public func audioMix(for p: SadrogProject, selection: MixSelection) -> AVMutableAudioMix? {
        // One volume timeline per composition track, built from the items placed on it: level × fade envelope. No normalisation,
        // no limiter — sources that add up above full scale can clip; the editor shows a conservative estimate instead.
        struct Seg { var start: Double, duration: Double, level: Float, fadeIn: Double, fadeOut: Double; var env: AudioEnvelope? = nil }
        var lines: [(AVMutableCompositionTrack, [Seg])] = []
        var clipSegs: [(lane: Int, media: String, seg: Seg)] = []
        let spans = p.clipSpans, lanes = p.clipLanes
        for (i, c) in p.clips.enumerated() where !c.audioDetached {
            let f = (c.audio ?? AudioEdit()).effectiveFades(duration: c.duration)
            // a cross-dissolve crossfades the sound over the same span as the picture: the outgoing clip fades out, the incoming one fades in
            let fin = max(f.fadeIn, p.overlap(into: i)), fout = max(f.fadeOut, i + 1 < p.clips.count ? p.overlap(into: i + 1) : 0)
            var seg = Seg(start: spans[i].start, duration: c.duration, level: 1, fadeIn: fin, fadeOut: fout)
            // volume curve, shaped fades or a shaped dissolve crossfade: the envelope describes the clip; otherwise the original straight-fade keyframes are written
            var env = (c.audio ?? AudioEdit()).envelope(duration: c.duration)
            let oi = p.overlap(into: i), oo = i + 1 < p.clips.count ? p.overlap(into: i + 1) : 0
            if oi > 0, !c.dissolveShape.isLegacy { env.xIn = (oi, c.dissolveShape) }
            if oo > 0, !p.clips[i + 1].dissolveShape.isLegacy { env.xOut = (oo, p.clips[i + 1].dissolveShape) }
            if !env.isLegacy { seg.env = env }
            clipSegs.append((lanes[i], c.media, seg))
        }
        // master applies to the full mix only; a stem renders its own source alone, every other track silent
        let master: Float = selection == .all ? SadrogProject.linear(dB: p.masterGainDB) : 1
        for (key, t) in mainAudio.sorted(by: { $0.key < $1.key }) {
            let k = key % Self.laneStride, lane = key / Self.laneStride
            // the level is decided per clip from ITS recording: two recordings share the composition track, never the settings
            lines.append((t, clipSegs.filter { $0.lane == lane }.map { cs in
                var s = cs.seg
                let on = selection.includes(media: cs.media, track: k) && !p.mutedLanes.contains(.a1) && !p.isMuted(source: k, media: cs.media)
                s.level = on ? SadrogProject.linear(dB: p.gain(ofSource: k, media: cs.media)) * master : 0
                return s
            }))
        }
        for l in p.layers where l.kind == .audio {
            let e = l.audio ?? AudioEdit(), f = e.effectiveFades(duration: l.duration)
            var env = e.envelope(duration: l.duration)
            // crossfade with the item that plays before / after: a real overlap, complementary gains on the two tracks
            let xs = p.crossfadeSeconds(l)
            if xs > 0, let link = e.crossfade { env.xIn = (xs, link.shape) }
            if let inc = p.layers.first(where: { $0.kind == .audio && $0.audio?.crossfade?.outgoing == l.id && p.crossfadeSeconds($0) > 0 }), let link = inc.audio?.crossfade { env.xOut = (p.crossfadeSeconds(inc), link.shape) }
            let linked = l.keepsSource      // sound detached from a clip keeps the identity of its recording source: its stem, volume and mute
            for (k, t) in (layerAudio[l.id] ?? []).enumerated() {
                let sel = linked ? selection.includes(media: l.media, track: k) : (selection == .all || selection == .a2)
                let src: Float = linked ? (p.isMuted(source: k, media: l.media) ? 0 : SadrogProject.linear(dB: p.gain(ofSource: k, media: l.media))) : 1
                let lv: Float = !sel || p.mutedLanes.contains(.a2) || e.muted ? 0 : SadrogProject.linear(dB: e.gainDB) * src * master
                lines.append((t, [Seg(start: l.start, duration: l.duration, level: lv, fadeIn: f.fadeIn, fadeOut: f.fadeOut, env: env.isLegacy && env.xIn == nil && env.xOut == nil ? nil : env)]))
            }
        }
        let neutral = lines.allSatisfy { $0.1.allSatisfy { $0.level == 1 && $0.fadeIn == 0 && $0.fadeOut == 0 && $0.env == nil } }
        guard lines.count > 1 || !neutral || selection != .all else { return nil }
        func ct(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 48000) }
        let tick = 1.0 / 48000
        let m = AVMutableAudioMix()
        m.inputParameters = lines.map { t, segs in
            let ip = AVMutableAudioMixInputParameters(track: t)
            // before the first item the volume would default to 1: the mixer works in blocks, so a block straddling an item that starts
            // with a fade-in played its first ~50 ms at full level (click found 2026-10-29). Pin the level explicitly from time 0.
            if let f = segs.first, f.start > 0 { ip.setVolume(f.env.map { Float($0.gain(at: 0)) * f.level } ?? (f.fadeIn > 0 ? 0 : f.level), at: .zero) }
            for s in segs {
                if let env = s.env {          // shaped envelope: amplitude ramps between breakpoints, scaled by the item level
                    let bp = env.breakpoints(); var prev = (t: bp[0].t, v: Float(bp[0].g) * s.level)
                    ip.setVolume(prev.v, at: ct(s.start + prev.t))
                    for q in bp.dropFirst() {
                        let v = Float(q.g) * s.level
                        if abs(v - prev.v) < 1e-6 { if q.t - prev.t > 2 * tick, q.t < env.duration - 2 * tick { ip.setVolume(v, at: ct(s.start + q.t)) } }
                        else { ip.setVolumeRamp(fromStartVolume: prev.v, toEndVolume: v, timeRange: CMTimeRange(start: ct(s.start + prev.t), duration: ct(q.t - prev.t))) }
                        prev = (q.t, v)
                    }
                    if prev.t < env.duration - 2 * tick { ip.setVolume(prev.v, at: ct(s.start + env.duration - tick)) }
                    continue
                }
                if s.fadeIn > 0 { ip.setVolumeRamp(fromStartVolume: 0, toEndVolume: s.level, timeRange: CMTimeRange(start: ct(s.start), duration: ct(s.fadeIn))) }
                else { ip.setVolume(s.level, at: ct(s.start)) }
                // The mixer interpolates linearly between consecutive keyframes. A level change from one item to the next (two recordings
                // on one composition track, each with its own settings) therefore glided over the WHOLE item (measured on exported stems
                // 2026-10-31). Hold the level to one tick before the item ends, so the change between items takes a single tick.
                if s.fadeOut == 0, s.duration > 2 * tick { ip.setVolume(s.level, at: ct(s.start + s.duration - tick)) }
                if s.fadeOut > 0 {
                    let fs = s.start + s.duration - s.fadeOut
                    // the level set at the start (or reached at the end of the fade-in ramp) holds until the fade-out ramp
                    ip.setVolumeRamp(fromStartVolume: s.level, toEndVolume: 0, timeRange: CMTimeRange(start: ct(fs), duration: ct(s.fadeOut)))
                }
            }
            return ip
        }
        return m
    }

}

/// One time segment of the video composition: the visual items (bottom → top) that are on screen during it.
final class SadrogInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    struct Item {
        enum Source { case track(CMPersistentTrackID, CGSize), image(CIImage, CGSize), callout(Callout, CIImage) }
        let source: Source
        let start: Double, duration: Double          // timeline seconds
        let a: Transform, b: Transform?
        var motion: Motion? = nil
        var keys: (track: KeyTrack, sourceStart: Double, speed: Double)? = nil     // main track: key commands drawn as keycaps in the picture's own space
        var mouse: (track: MouseTrack, sourceStart: Double, speed: Double, fx: MouseFX)? = nil     // main track: pointer effects drawn in the picture's own space (so they follow zoom and animation)
        var dissolveIn = 0.0                    // main track: the item fades in over this many seconds on top of the previous clip (cross-dissolve)
        let fit: Bool
        var crop: CircleCropRender? = nil       // „Prezentator în cerc”: the picture is cut to a circle (+ outline) before it is placed
        var rect: RectCrop? = nil               // rectangular crop (not combined with the circle)
        var picture: PictureAdjust? = nil       // colour controls and person background of the item's own picture
        var layer: UUID? = nil                  // set on an overlay's item: its picture's footprint is remembered for callouts bound to it
        var guide = false                       // editor-only framing guide: the part of the source outside the circle, faded
        var limitTo: UUID? = nil                // set on a callout bound to an overlay: the effect stays inside that overlay's footprint
    }
    let timeRange: CMTimeRange
    let items: [Item]
    let enablePostProcessing = false
    let containsTweening = true
    let passthroughTrackID = kCMPersistentTrackID_Invalid
    let requiredSourceTrackIDs: [NSValue]?
    init(timeRange: CMTimeRange, items: [Item]) {
        self.timeRange = timeRange; self.items = items
        requiredSourceTrackIDs = items.compactMap { if case .track(let id, _) = $0.source { return NSNumber(value: id) as NSValue } else { return nil } }
        super.init()
    }
}

/// CoreImage compositor shared by preview and export. Colour management is off on purpose (values pass through untouched, like a plain passthrough).
final class SadrogCompositor: NSObject, AVVideoCompositing {
    private static let attrs: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
    var sourcePixelBufferAttributes: [String: any Sendable]? { Self.attrs }
    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] { Self.attrs }
    private let ci = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {}
    func cancelAllPendingVideoCompositionRequests() {}

    /// Applies the callout's effect (darken and/or blur) to the area selected by `mask` — outside the selection, or inside it when `invert` is on; the rest is untouched.
    /// Pure CoreImage, identical for preview and export.
    static func apply(_ c: Callout, mask selection: CIImage, to img: CIImage, size r: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: r)
        var affected = img
        if c.blur > 0.001 { affected = img.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: c.blur * 0.03 * r.height]).cropped(to: rect) }
        if c.dim > 0.001 { let k = CGFloat(1 - c.dim); affected = affected.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: k, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: k, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: k, w: 0)]) }
        var keep = selection                                   // white = keep the original
        if c.invert && !c.isLens { keep = keep.applyingFilter("CIColorInvert") }
        var out = img.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: affected, kCIInputMaskImageKey: keep]).cropped(to: rect)
        // shadow (just outside the selection) → local magnification (inside it) → outline (a ring around it); each only when set, so older callouts look as before
        if c.shadow > 0.001 {
            let off = CGAffineTransform(translationX: 0, y: -0.006 * r.height)
            let sh = selection.transformed(by: off).clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: c.shadow * 0.04 * r.height]).cropped(to: rect)
            let outside = sh.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: selection.applyingFilter("CIColorInvert")])
            let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.7 * c.shadow)).cropped(to: rect)
            out = black.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: outside]).cropped(to: rect)
        }
        if c.isLens {       // the whole source box, scaled to the display box (same proportions, so nothing is cut or distorted), on top of what is below
            let b = c.displayBox, k = CGFloat(c.lensEffective)
            let sx = c.x * r.width, sy = (1 - (c.y + c.h)) * r.height          // source box bottom-left, CoreImage's y-up space
            let dx = b.minX * r.width, dy = (1 - b.maxY) * r.height
            let m = CGAffineTransform(translationX: dx, y: dy).scaledBy(x: k, y: k).translatedBy(x: -sx, y: -sy)
            let big = img.transformed(by: m).cropped(to: rect)
            out = big.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: selection]).cropped(to: rect)
        } else if c.magnify > 0.001 {
            let k = CGFloat(1 + c.magnify)
            let cx = (c.x + c.w / 2) * r.width, cy = (1 - (c.y + c.h / 2)) * r.height       // box centre in CoreImage's y-up space
            let m = CGAffineTransform(translationX: cx, y: cy).scaledBy(x: k, y: k).translatedBy(x: -cx, y: -cy)
            let big = img.transformed(by: m).cropped(to: rect)
            out = big.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: selection]).cropped(to: rect)
        }
        if c.shape == .line || c.shape == .arrow {      // the stroke itself is the annotation: paint it, no ring
            let col = CIImage(color: CIColor(red: c.outlineColor.r, green: c.outlineColor.g, blue: c.outlineColor.b, alpha: c.outlineColor.a)).cropped(to: rect)
            out = col.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: selection]).cropped(to: rect)
        } else if c.outline > 0.001 {
            let px = max(1, c.outline * 0.05 * r.height)
            let grown = selection.clampedToExtent().applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: px]).cropped(to: rect)
            let ring = grown.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: selection.applyingFilter("CIColorInvert")])
            let col = CIImage(color: CIColor(red: c.outlineColor.r, green: c.outlineColor.g, blue: c.outlineColor.b, alpha: c.outlineColor.a)).cropped(to: rect)
            out = col.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: out, kCIInputMaskImageKey: ring]).cropped(to: rect)
        }
        return out
    }

    /// Pointer highlight and click ring, drawn into the source picture at its own pixel size (CoreImage, y-up): same code for preview and export.
    static func drawPointer(_ track: MouseTrack, fx: MouseFX, at t: Double, on img: CIImage, size n: CGSize) -> CIImage {
        guard let p = track.position(at: t) else { return img }
        let rect = CGRect(origin: .zero, size: n), cx = p.x * n.width, cy = (1 - p.y) * n.height, base = 0.035 * n.height
        func disc(_ r: CGFloat, _ c: CIColor) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: cx, y: cy), "inputRadius0": r, "inputRadius1": r + max(1.5, r * 0.04), "inputColor0": c, "inputColor1": CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0)])!.outputImage!.cropped(to: rect)
        }
        /// Filled disc of radius `r` centred at (x, y) with a 1.5 px soft edge; an annulus is one disc with a smaller one cut out of it.
        func solid(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ c: CIColor) -> CIImage {
            CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: x, y: y), "inputRadius0": max(0, r), "inputRadius1": max(0, r) + 1.5, "inputColor0": c, "inputColor1": CIColor(red: c.red, green: c.green, blue: c.blue, alpha: 0)])!.outputImage!.cropped(to: rect)
        }
        func annulus(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat, _ w: CGFloat, _ c: CIColor) -> CIImage {
            solid(x, y, r, c).applyingFilter("CISourceOutCompositing", parameters: [kCIInputBackgroundImageKey: solid(x, y, max(0, r - w), CIColor(red: 1, green: 1, blue: 1, alpha: 1))])
        }
        var out = img
        let radius = base * fx.size
        if fx.highlight {
            let col = CIColor(red: fx.color.r, green: fx.color.g, blue: fx.color.b, alpha: fx.opacity)
            switch fx.style {
            case .disc: out = disc(radius, col).composited(over: out)
            case .ring: out = annulus(cx, cy, radius, max(1.5, radius * fx.stroke), col).composited(over: out)
            case .halo:      // brightest at the pointer, fading to nothing at 1.8 × the radius: nothing has a hard edge
                let g = CIFilter(name: "CIRadialGradient", parameters: ["inputCenter": CIVector(x: cx, y: cy), "inputRadius0": radius * 0.15, "inputRadius1": radius * 1.8, "inputColor0": col, "inputColor1": CIColor(red: col.red, green: col.green, blue: col.blue, alpha: 0)])!.outputImage!.cropped(to: rect)
                out = g.composited(over: out)
            }
        }
        if fx.clickRing {
            let life = fx.clickSeconds, cc = fx.clickColor
            /// One radar ring born at `age` 0: grows from 0.6 to 2.2 radii and fades out over `life`.
            func ripple(_ c: MouseClick, age: Double, width: CGFloat, fill: Bool) {
                guard age >= 0, age < life else { return }
                let k = age / life, r = radius * (0.6 + 1.6 * k), a = fx.clickStrength * (1 - k)
                let x = c.x * n.width, y = (1 - c.y) * n.height
                if fill { out = solid(x, y, r, CIColor(red: cc.r, green: cc.g, blue: cc.b, alpha: a * 0.28)).composited(over: out) }
                out = annulus(x, y, r, max(2, radius * width), CIColor(red: cc.r, green: cc.g, blue: cc.b, alpha: a)).composited(over: out)
            }
            for c in track.activeClicks(at: t, duration: life) {
                let age = t - c.t
                switch c.kind {
                case .left: ripple(c, age: age, width: 0.18, fill: false)                        // one ring
                case .right: ripple(c, age: age, width: 0.10, fill: true)                        // a thinner ring with a tinted inside
                case .double: ripple(c, age: age, width: 0.18, fill: false); ripple(c, age: age - max(c.gap, 0.12), width: 0.18, fill: false)   // two rings, the second born at the second press
                }
            }
        }
        return out.cropped(to: rect)
    }


    /// Key commands as rounded keycaps at the bottom centre of the source picture (CoreText → CGImage → CoreImage, y-up): same code for preview and export.
    static func drawKeys(_ track: KeyTrack, at t: Double, on img: CIImage, size n: CGSize) -> CIImage {
        let vis = track.visible(at: t)
        guard !vis.isEmpty, n.width > 8, n.height > 8 else { return img }
        let fs = max(12, 0.045 * n.height), pad = fs * 0.55, gap = fs * 0.4
        var out = img, y = 0.07 * n.height
        for item in vis.reversed() {                        // newest at the bottom, older ones above
            let fade = item.age < 0.75 ? 1 : max(0, 1 - (item.age - 0.75) / 0.25)
            guard let cap = keycap(item.label, fontSize: fs, padding: pad) else { continue }
            let w = CGFloat(cap.width), h = CGFloat(cap.height)
            var ci = CIImage(cgImage: cap)
            if fade < 1 { ci = ci.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: fade)]) }
            out = ci.transformed(by: CGAffineTransform(translationX: (n.width - w) / 2, y: y)).composited(over: out)
            y += h + gap
        }
        return out.cropped(to: CGRect(origin: .zero, size: n))
    }
    static func keycap(_ text: String, fontSize: CGFloat, padding: CGFloat) -> CGImage? {
        let font = CTFontCreateWithName("Helvetica Neue Bold" as CFString, fontSize, nil)
        let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 1)])
        let line = CTLineCreateWithAttributedString(attr), tb = CTLineGetBoundsWithOptions(line, [])
        let w = Int(ceil(tb.width + padding * 2)), h = Int(ceil(fontSize + padding * 1.2))
        guard w > 0, h > 0, let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let r = CGRect(x: 0, y: 0, width: w, height: h), path = CGPath(roundedRect: r, cornerWidth: CGFloat(h) * 0.28, cornerHeight: CGFloat(h) * 0.28, transform: nil)
        ctx.addPath(path); ctx.setFillColor(CGColor(red: 0.08, green: 0.09, blue: 0.1, alpha: 0.82)); ctx.fillPath()
        ctx.addPath(path); ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.35)); ctx.setLineWidth(max(1, fontSize * 0.05)); ctx.strokePath()
        ctx.textPosition = CGPoint(x: padding - tb.minX, y: (CGFloat(h) - fontSize) / 2 + fontSize * 0.22)
        CTLineDraw(line, ctx)
        return ctx.makeImage()
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        guard let ins = request.videoCompositionInstruction as? SadrogInstruction, let out = request.renderContext.newPixelBuffer() else {
            request.finish(with: NSError(domain: "SADROG", code: 1)); return
        }
        let r = request.renderContext.size, rect = CGRect(origin: .zero, size: r), now = request.compositionTime.seconds
        var img = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
        func flip(_ h: CGFloat) -> CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: h) }
        var keyLabels: (track: KeyTrack, at: Double)?
        var footprints: [UUID: CIImage] = [:]           // overlay id → white where that overlay's picture is (alpha), for callouts bound to it
        for it in ins.items {
            var src: CIImage; let n: CGSize; var guideSrc: CIImage?
            switch it.source {
            case .callout(let c, let mask):
                if let lid = it.limitTo {
                    guard let fp = footprints[lid] else { continue }       // its overlay is not on screen in this frame
                    img = Self.apply(c, mask: mask, to: img, size: r).applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: img, kCIInputMaskImageKey: fp]).cropped(to: rect)
                } else { img = Self.apply(c, mask: mask, to: img, size: r) }
                continue
            case .track(let id, let size):
                guard let pb = request.sourceFrame(byTrackID: id) else { continue }
                var full = CIImage(cvPixelBuffer: pb)
                if let pa = it.picture, pa.background != .off { full = pa.applyBackground(to: full, buffer: pb) }      // on the whole frame, before any crop
                // pointer effects are positions in the WHOLE recorded frame: drawn before any crop, so a cropped clip shows them where the pointer really was
                if let mo = it.mouse { full = Self.drawPointer(mo.track, fx: mo.fx, at: mo.sourceStart + (now - it.start) * mo.speed, on: full, size: size) }
                if let cr = it.crop {
                    src = cr.apply(to: full, source: size); n = CGSize(width: cr.side, height: cr.side)
                    if it.guide { guideSrc = full.transformed(by: CGAffineTransform(translationX: -cr.window.minX, y: -(size.height - cr.window.maxY))) }
                }
                else if let rc = it.rect, !rc.isNone {
                    let w = rc.window(of: size), ciY = size.height - w.maxY                  // top-left window → CoreImage (y-up)
                    src = full.cropped(to: CGRect(x: w.minX, y: ciY, width: w.width, height: w.height)).transformed(by: CGAffineTransform(translationX: -w.minX, y: -ciY))
                    n = w.size
                }
                else { src = full; n = size }
                if let pa = it.picture { src = pa.applyColor(to: src) }
            case .image(let image, let size): src = image; n = size
            }
            if let ky = it.keys, now >= it.start, now < it.start + it.duration { keyLabels = (ky.track, ky.sourceStart + (now - it.start) * ky.speed) }       // drawn last, in screen space: never zoomed, cropped or dimmed
            var t = Transform.state(start: it.a, end: it.b, motion: it.motion, elapsed: now - it.start, duration: it.duration)
            let m = flip(n.height).concatenating(BuiltComposition.matrix(natural: n, render: r, t, fit: it.fit)).concatenating(flip(r.height))
            var placed = src.transformed(by: m)
            if let lid = it.layer {
                let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: rect)
                footprints[lid] = placed.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 1), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0), "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 1)]).composited(over: black).cropped(to: rect)
            }
            if it.dissolveIn > 0 { t.opacity *= Easing.smooth.apply((now - it.start) / it.dissolveIn) }
            if t.opacity < 0.9999 { placed = placed.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: t.opacity)]) }
            if let g = guideSrc {       // framing guide: the whole camera rectangle, faded, under the circle (preview only)
                let gp = g.transformed(by: m).applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.38)])
                img = gp.composited(over: img)
            }
            img = placed.composited(over: img)
        }
        if let kl = keyLabels { img = Self.drawKeys(kl.track, at: kl.at, on: img, size: r) }
        ci.render(img.cropped(to: rect), to: out, bounds: rect, colorSpace: nil)
        request.finish(withComposedVideoFrame: out)
    }
}

/// Rasterizes a callout's selection (white = selected) once per build: rectangle (rounded), ellipse or freehand outline, then the soft edge.
/// One path for every shape, so preview and export see the same mask.
enum CalloutMask {
    static func make(_ c: Callout, render r: CGSize) -> CIImage {
        let W = max(1, Int(r.width.rounded())), H = max(1, Int(r.height.rounded())), rect = CGRect(x: 0, y: 0, width: W, height: H)
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return CIImage(color: .black).cropped(to: rect) }
        ctx.setFillColor(gray: 0, alpha: 1); ctx.fill(rect)
        ctx.translateBy(x: 0, y: CGFloat(H)); ctx.scaleBy(x: 1, y: -1)              // draw in top-left, y-down frame coordinates
        let box = CGRect(x: c.x * Double(W), y: c.y * Double(H), width: c.w * Double(W), height: c.h * Double(H))
        ctx.setFillColor(gray: 1, alpha: 1); ctx.setStrokeColor(gray: 1, alpha: 1); ctx.setAllowsAntialiasing(true)
        switch c.shape {
        case .ellipse: ctx.fillEllipse(in: box)
        case .freehand where c.points.count >= 3:
            ctx.beginPath()
            for (i, p) in c.points.enumerated() { let q = CGPoint(x: box.minX + p.x * box.width, y: box.minY + p.y * box.height); if i == 0 { ctx.move(to: q) } else { ctx.addLine(to: q) } }
            ctx.closePath(); ctx.fillPath()
        case .line where c.points.count >= 2, .arrow where c.points.count >= 2:
            let a = CGPoint(x: box.minX + c.points[0].x * box.width, y: box.minY + c.points[0].y * box.height)
            let b = CGPoint(x: box.minX + c.points[1].x * box.width, y: box.minY + c.points[1].y * box.height)
            let lw = max(1.5, c.lineWidth * 0.02 * Double(H)); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.setLineWidth(lw)
            let len = hypot(b.x - a.x, b.y - a.y)
            if c.shape == .arrow, len > lw * 3 {
                let head = min(len * 0.6, lw * 5), ux = (b.x - a.x) / len, uy = (b.y - a.y) / len, base = CGPoint(x: b.x - ux * head, y: b.y - uy * head), half = lw * 2.4
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
                ctx.beginPath(); ctx.move(to: b); ctx.addLine(to: CGPoint(x: base.x - uy * half, y: base.y + ux * half)); ctx.addLine(to: CGPoint(x: base.x + uy * half, y: base.y - ux * half)); ctx.closePath(); ctx.fillPath()
            } else { ctx.setStrokeColor(gray: 1, alpha: 1); ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: b); ctx.strokePath() }
        default:
            let rad = c.corner * min(box.width, box.height)
            ctx.addPath(CGPath(roundedRect: box, cornerWidth: rad, cornerHeight: rad, transform: nil)); ctx.fillPath()
        }
        guard let cg = ctx.makeImage() else { return CIImage(color: .black).cropped(to: rect) }
        var m = CIImage(cgImage: cg, options: [.colorSpace: NSNull()])
        if c.feather > 0.001 { m = m.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: c.feather * 0.05 * r.height]).cropped(to: rect) }
        return m
    }
}

/// Renders a title into an image once per build (the compositor then only places it), so the font/size/colour/alignment are identical in preview and export.
public enum TextRenderer {
    static let pad: CGFloat = 4
    /// Space around the text: a box needs room to breathe; a shadow needs room to fall.
    static func inset(_ t: TextOverlay, render r: CGSize) -> CGFloat { let pt = max(4, t.size * r.height); return t.box != nil ? max(pad, pt * 0.3) : (t.shadow ? max(pad, pt * 0.15) : (t.outline != nil ? max(pad, pt * 0.06) : pad)) }
    static func font(_ t: TextOverlay, _ pt: CGFloat) -> NSFont {
        var f = NSFont(name: t.font, size: pt) ?? NSFontManager.shared.font(withFamily: t.font, traits: [], weight: 5, size: pt) ?? NSFont.systemFont(ofSize: pt)
        if t.bold { f = NSFontManager.shared.convert(f, toHaveTrait: .boldFontMask) }
        if t.italic { f = NSFontManager.shared.convert(f, toHaveTrait: .italicFontMask) }
        return f
    }
    static func attributed(_ t: TextOverlay, render r: CGSize) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = t.align == .leading ? .left : t.align == .trailing ? .right : .center
        para.lineHeightMultiple = CGFloat(t.lineSpacing)
        let c = t.color, pt = max(4, t.size * r.height)
        var attrs: [NSAttributedString.Key: Any] = [.font: font(t, pt), .foregroundColor: NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a), .paragraphStyle: para]
        if t.underline { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue; attrs[.underlineColor] = NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a) }
        if let o = t.outline { attrs[.strokeColor] = NSColor(srgbRed: o.r, green: o.g, blue: o.b, alpha: o.a); attrs[.strokeWidth] = -6.0 }       // negative: stroke AND fill, 6 % of the font size
        if t.shadow { let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.7); sh.shadowBlurRadius = pt * 0.08; sh.shadowOffset = NSSize(width: 0, height: -pt * 0.05); attrs[.shadow] = sh }
        return NSAttributedString(string: t.text, attributes: attrs)
    }
    static let opts: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
    /// Size of the title's image in render pixels at scale 1 (also the unrotated selection frame in the viewer).
    public static func layoutSize(_ t: TextOverlay, render r: CGSize) -> CGSize {
        let b = attributed(t, render: r).boundingRect(with: CGSize(width: r.width * 0.9, height: 10_000), options: opts)
        let p = inset(t, render: r)
        return CGSize(width: ceil(b.width) + 2 * p, height: ceil(b.height) + 2 * p)
    }
    public static func image(_ t: TextOverlay, render r: CGSize) -> CGImage? {
        let size = layoutSize(t, render: r), w = Int(size.width), h = Int(size.height)
        guard w > 0, h > 0, let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let g = NSGraphicsContext(cgContext: cg, flipped: false)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = g
        let p = inset(t, render: r)
        if let b = t.box { NSColor(srgbRed: b.r, green: b.g, blue: b.b, alpha: b.a).setFill(); let rr = max(2, t.size * r.height * 0.18); NSBezierPath(roundedRect: CGRect(x: 0, y: 0, width: size.width, height: size.height), xRadius: rr, yRadius: rr).fill() }
        attributed(t, render: r).draw(with: CGRect(x: p, y: p, width: size.width - 2 * p, height: size.height - 2 * p), options: opts)
        NSGraphicsContext.restoreGraphicsState()
        return cg.makeImage()
    }
}

public enum CompositionBuilder {
    /// Compatibility entry point: the plain composition.
    public static func build(_ p: SadrogProject) async throws -> AVMutableComposition { try await buildFull(p).composition }

    /// One composition for preview and export: main track (video + its audio), one track per video overlay, one per independent audio item.
    /// Every lane is always built; hiding (compositor) and muting (audio mix) only change what is seen or heard, never the length or the positions.
    /// `fx`: processed copies of recording sources (by `EffectRenderer.slot`), aligned on the file's own time — used in place of the original
    /// track with the SAME source ranges, so cuts, sync, volumes and fades work exactly as on the original.
    public static func buildFull(_ p: SadrogProject, fx: [String: URL] = [:]) async throws -> BuiltComposition {
        let comp = AVMutableComposition()
        var fxAssets: [AVURLAsset] = []                       // keeps the processed assets alive while their tracks are inserted
        let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
        let lanes = p.clipLanes, starts = p.clipSpans.map(\.start)
        let vTrackB = lanes.contains(1) ? comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) : nil     // only a cross-dissolve needs a second one
        var aTracks: [Int: AVMutableCompositionTrack] = [:]   // per source track index, created on the first clip that has it (an empty audio track makes the exporter fail)
        var mainSize: [UUID: CGSize] = [:]; var render = CGSize.zero; var fps: Float = 0
        var padSource: AVAssetTrack?; var padAsset: AVURLAsset?        // an AVAssetTrack does not keep its asset alive
        for (ci, c) in p.clips.enumerated() {
            let cursor = CMTime(seconds: starts[ci], preferredTimescale: 6000), vt = lanes[ci] == 1 ? vTrackB : vTrack, lane = lanes[ci]
            let asset = AVURLAsset(url: URL(fileURLWithPath: c.media))
            let range = CMTimeRange(start: CMTime(seconds: c.sourceStart, preferredTimescale: 6000), duration: CMTime(seconds: c.sourceSpan, preferredTimescale: 6000))
            let slot = CMTimeRange(start: cursor, duration: CMTime(seconds: c.duration, preferredTimescale: 6000))       // the clip's place on the timeline; a retimed clip stretches its source range into it
            let retimed = !c.held && c.speed != 1
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                if c.held {      // freeze frame: the same source frame laid end to end, one frame at a time (a stretched single frame makes the encoder fail)
                    let nfr = Double(try await v.load(.nominalFrameRate)); let fr = nfr >= 1 ? 1 / nfr : 1.0 / 30
                    let n = max(1, Int((c.duration / fr).rounded())); let step = CMTime(seconds: c.duration / Double(n), preferredTimescale: 60000)
                    let one = CMTimeRange(start: CMTime(seconds: c.sourceStart, preferredTimescale: 6000), duration: CMTime(seconds: fr, preferredTimescale: 6000))
                    for i in 0..<n {
                        let at = cursor + CMTimeMultiply(step, multiplier: Int32(i))
                        try vt?.insertTimeRange(one, of: v, at: at)
                        if one.duration != step { vt?.scaleTimeRange(CMTimeRange(start: at, duration: one.duration), toDuration: step) }
                    }
                } else {
                    try vt?.insertTimeRange(range, of: v, at: cursor)
                    if retimed { vt?.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: slot.duration) }
                }
                let size = try await v.load(.naturalSize); mainSize[c.id] = size; if padSource == nil { padSource = v; padAsset = asset }
                if render == .zero { render = size; fps = try await v.load(.nominalFrameRate) }
            }
            // every audio track takes the SAME source range as the picture: each keeps its own start offset from the file, so sync is preserved
            for (k, a) in (c.held || c.audioDetached || (retimed && c.speedMute) ? [] : try await asset.loadTracks(withMediaType: .audio)).enumerated() {
                let key = k + lane * BuiltComposition.laneStride       // the incoming clip of a dissolve plays on its own set of audio tracks
                if aTracks[key] == nil { aTracks[key] = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) }
                var src = a
                if let u = fx[EffectRenderer.slot(c.media, k)] {
                    let pa = AVURLAsset(url: u); fxAssets.append(pa)
                    guard let pt = try await pa.loadTracks(withMediaType: .audio).first else { throw EffectError.render(T("fișier procesat fără sunet")) }
                    src = pt
                }
                try aTracks[key]?.insertTimeRange(range, of: src, at: cursor)
                if retimed { aTracks[key]?.scaleTimeRange(CMTimeRange(start: cursor, duration: range.duration), toDuration: slot.duration) }
            }
        }
        var layerTracks: [UUID: (AVMutableCompositionTrack, CGSize)] = [:]
        var layerAudio: [UUID: [AVMutableCompositionTrack]] = [:]
        for l in p.layers {
            let asset = AVURLAsset(url: URL(fileURLWithPath: l.media))
            let range = CMTimeRange(start: CMTime(seconds: l.sourceStart, preferredTimescale: 6000), duration: CMTime(seconds: l.sourceSpan, preferredTimescale: 6000))
            let at = CMTime(seconds: l.start, preferredTimescale: 6000), slot = CMTimeRange(start: at, duration: CMTime(seconds: l.duration, preferredTimescale: 6000)), lRetimed = l.speed != 1
            switch l.kind {
            case .video:
                guard let v = try await asset.loadTracks(withMediaType: .video).first, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try t.insertTimeRange(range, of: v, at: at)
                if lRetimed { t.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: slot.duration) }
                let size = try await v.load(.naturalSize); layerTracks[l.id] = (t, size)
                if render == .zero { render = size; fps = try await v.load(.nominalFrameRate) }
            case .audio:
                for (k, a) in try await asset.loadTracks(withMediaType: .audio).enumerated() {
                    guard let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    var src = a
                    if l.keepsSource, let u = fx[EffectRenderer.slot(l.media, k)] {      // detached sound keeps the audio effects of its recording source
                        let pa = AVURLAsset(url: u); fxAssets.append(pa)
                        guard let pt = try await pa.loadTracks(withMediaType: .audio).first else { throw EffectError.render(T("fișier procesat fără sunet")) }
                        src = pt
                    }
                    try t.insertTimeRange(range, of: src, at: at); layerAudio[l.id, default: []].append(t)
                    if lRetimed { t.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: slot.duration) }
                }
            }
        }
        if render == .zero { render = CGSize(width: 1280, height: 720) }
        let sourceFps = fps
        if let f = p.canvas { render = f.size; fps = Float(f.fps) }       // the document decides; the source is fitted into it by the compositor
        // Titles may run past every media track. An empty range at the end would be dropped, so a one-off padding track holds a short piece of
        // source at the very end instead (the compositor never reads it): the project length then never depends on what is shown.
        let need = p.timelineEnd
        _ = fxAssets
        if comp.duration.seconds < need - 0.001, let src = padSource, let pad = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
            _ = padAsset; let d = min(0.1, need, src.timeRange.duration.seconds)
            try pad.insertTimeRange(CMTimeRange(start: src.timeRange.start, duration: CMTime(seconds: d, preferredTimescale: 6000)), of: src, at: CMTime(seconds: need - d, preferredTimescale: 6000))
        }
        var built = BuiltComposition(composition: comp, renderSize: render, frameDuration: CMTime(value: 1, timescale: CMTimeScale(max(1, min(120, Int((fps > 1 ? fps : 30).rounded()))))), mainTrack: vTrack, mainTrackB: vTrackB, mainAudio: aTracks, mainSize: mainSize, layerTracks: layerTracks, layerAudio: layerAudio, sourceFps: Double(sourceFps))
        built.pitch = Retime.pitchAlgorithm(for: p)
        return built
    }
}

public enum ExportMode: Sendable, Equatable {
    case passthrough                    // no re-encode: fast, lossless; cuts follow the edit list
    case reencode(preset: String)       // e.g. AVAssetExportPresetHighestQuality
}

public enum ProjectExporter {
    /// An export never falls back to the unprocessed sound: every active effect chain must have its processed file.
    public static func requireProcessed(_ p: SadrogProject, _ fx: EffectPlan?) throws {
        let active = p.hasActiveEffects
        guard active else { return }
        guard let fx, fx.jobs.isEmpty else { throw EffectError.render(T("efectele audio nu sunt încă procesate; exportul așteaptă finalul procesării")) }
    }
    /// Exports to `url` (must not exist), .mov. Progress 0...1 on `progress`. Overlays/transforms force a re-encode (they need the compositor).
    public static func export(_ p: SadrogProject, to url: URL, mode: ExportMode = .reencode(preset: AVAssetExportPresetHighestQuality), effects: EffectPlan? = nil, range: ClosedRange<Double>? = nil, replaceExisting: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        try await SafePublish.run(to: url, replaceExisting: replaceExisting) { tmp in try await exportInto(p, to: tmp, mode: mode, effects: effects, range: range, progress: progress) }
    }
    private static func exportInto(_ p: SadrogProject, to url: URL, mode: ExportMode, effects: EffectPlan?, range: ClosedRange<Double>?, progress: (@Sendable (Double) -> Void)?) async throws {
        try ProjectExporter.requireProcessed(p, effects)
        let built = try await CompositionBuilder.buildFull(p, fx: effects?.ready ?? [:])
        let vc = built.videoComposition(for: p), mix = built.audioMix(for: p)
        // passthrough copies the streams as they are: it can neither composite nor apply a mute, so either forces a re-encode
        let preset: String = { if case .reencode(let n) = mode { return n } else { return vc == nil && mix == nil ? AVAssetExportPresetPassthrough : AVAssetExportPresetHighestQuality } }()
        guard let s = AVAssetExportSession(asset: built.composition, presetName: preset) else { throw CocoaError(.fileWriteUnknown) }
        s.audioTimePitchAlgorithm = built.pitch
        if let vc { s.videoComposition = vc }
        if let mix { s.audioMix = mix }
        if let range { s.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 6000), end: CMTime(seconds: range.upperBound, preferredTimescale: 6000)) }
        let watcher = Task { for await state in s.states(updateInterval: 0.2) { if case .exporting(let p) = state { progress?(p.fractionCompleted) } } }
        defer { watcher.cancel() }
        try await s.export(to: url, as: .mov)
        progress?(1)
    }
}
