// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// How a video export is configured WITHOUT touching the montage document: the project is only read; the output size and rate are applied to an in-memory copy, so every
/// effect (callouts, crop, titles, cursor, transforms are all stored relative to the frame) is laid out in the output's own coordinates, not scaled after the fact.
public struct ExportSettings: Equatable, Sendable {
    /// What happens to the pixels — kept apart because each says something different about quality.
    public enum Mode: String, CaseIterable, Identifiable, Sendable {
        case copy            // existing streams copied: nothing is decoded, nothing is lost, nothing can be processed
        case compressed      // processed, then lossy-compressed (H.264 / HEVC)
        case master          // processed, then a high-quality intermediate (Apple ProRes): very high quality, NOT lossless
        case lossless        // processed, then written without loss (Apple Animation, 8-bit RGB) + uncompressed audio: identical to the processed frames
        public var id: String { rawValue }
    }
    public enum Size: Equatable, Sendable { case document, longSide(Int), custom(Int, Int) }
    public enum Codec: String, CaseIterable, Identifiable, Sendable { case h264, hevc; public var id: String { rawValue } }
    public enum Tier: String, CaseIterable, Identifiable, Sendable { case high, medium; public var id: String { rawValue } }
    public enum ProRes: String, CaseIterable, Identifiable, Sendable { case p422, p4444; public var id: String { rawValue } }
    /// File format of a COMPRESSED export. MP4 is what web players and upload forms expect; QuickTime is what editors expect. Same streams either way.
    public enum Container: String, CaseIterable, Identifiable, Sendable { case mov, mp4; public var id: String { rawValue } }

    public var mode: Mode = .compressed
    public var size: Size = .document
    public var fps: Double?                  // nil = the document's rate
    public var codec: Codec = .h264
    public var tier: Tier = .high            // H.264 only: AVFoundation offers no bit-rate control through its presets, so the tiers are the presets' own
    public var proRes: ProRes = .p422
    public var onlyRange = true
    /// Advanced, compressed mode only; nil = the system preset decides. Any of them set sends the export through `CompressedWriter` (reader + AVAssetWriter), which applies them.
    public var videoMbps: Double?            // average video bit rate, megabits/s (0.5…200)
    public var keyframeSeconds: Double?      // maximum distance between key frames, seconds (0.1…10)
    public var audioKbps: Int?               // AAC bit rate, kilobits/s (64…320)
    /// Constant-quality rate control (AVVideoQualityKey, 0.2…1): measured to be honoured by both H.264 and HEVC on Apple silicon (monotonic size and SSIM), so the file size follows the CONTENT.
    public var quality: Double? = QualityStep.high.value
    /// Target file size in megabytes (video + sound). Turned into an AVERAGE bit rate (one pass — the encoder cannot do several), so the result is an estimate near the target, never a guarantee.
    public var targetMB: Double?
    public var container: Container = .mov   // compressed mode only (ProRes and copy stay QuickTime)
    public var audioMono = false             // compressed mode only: the mix is written as one channel instead of stereo
    public init() {}

    public static let videoMbpsRange: ClosedRange<Double> = 0.5...200, keyframeRange: ClosedRange<Double> = 0.1...10, audioKbpsRange: ClosedRange<Int> = 64...320
    public static let qualityRange: ClosedRange<Double> = 0.2...1, targetMBRange: ClosedRange<Double> = 1...200_000
    /// Named quality steps measured on screen-recording tutorials (see docs/EXPORT_MEASUREMENTS.md); the numbers are the encoder's own quality scale, not a percentage of anything.
    public enum QualityStep: String, CaseIterable, Identifiable, Sendable {
        case compact, balanced, high, maximum
        public var id: String { rawValue }
        public var value: Double { switch self { case .compact: return Self.compactQ; case .balanced: return Self.balancedQ; case .high: return Self.highQ; case .maximum: return Self.maximumQ } }
        public var title: String { switch self { case .compact: return T("Compactă"); case .balanced: return T("Echilibrată"); case .high: return T("Înaltă"); case .maximum: return T("Maximă") } }
        static let compactQ = 0.6, balancedQ = 0.7, highQ = 0.8, maximumQ = 0.9
    }
    /// Key frames: a screen recording is mostly static, so a key frame every second spends most of the file on pictures that did not change (measured: 51–71 % of the bytes of
    /// a system-preset export). The default distance keeps seeking fast enough for an editor and for players.
    public static let defaultKeyframeSeconds = 5.0
    /// Old stored presets carry only `tier` (system presets). The system presets are no longer used for compressed video (the 'medium' one wrote 568×320 whatever was announced), so the tier maps to a quality.
    public var legacyQuality: Double { tier == .high ? QualityStep.maximum.value : QualityStep.balanced.value }
    /// What the video encoder is asked for. An explicit bit rate or a size target (average bit rate) wins over a quality; nothing set = the default quality for the tier.
    public enum VideoRate: Equatable, Sendable { case quality(Double), bitrate(Double) }
    public func videoRate(duration: Double) -> VideoRate {
        if let m = clampedMbps { return .bitrate(m) }
        if let b = targetBitrateMbps(duration: duration) { return .bitrate(b) }
        return .quality(clampedQuality ?? legacyQuality)
    }
    /// Size target → average video bit rate: the budget (bytes × 8 / seconds) minus the sound and ~1.5 % container overhead, clamped to what the encoder accepts. nil = no target.
    public func targetBitrateMbps(duration: Double) -> Double? {
        guard let t = targetMB.map({ min(Self.targetMBRange.upperBound, max(Self.targetMBRange.lowerBound, $0)) }), duration > 0 else { return nil }
        let audio = Double(clampedAudioKbps ?? 128) * 1000
        return min(Self.videoMbpsRange.upperBound, max(Self.videoMbpsRange.lowerBound, (t * 1_000_000 * 8 / duration * 0.985 - audio) / 1_000_000))
    }
    var clampedQuality: Double? { quality.map { min(Self.qualityRange.upperBound, max(Self.qualityRange.lowerBound, $0)) } }
    /// Compressed video always goes through the explicit writer: what the sheet announces (size, rate control, key frames) is exactly what is written.
    public var usesAdvancedWriter: Bool { mode == .compressed }
    var clampedMbps: Double? { videoMbps.map { min(Self.videoMbpsRange.upperBound, max(Self.videoMbpsRange.lowerBound, $0)) } }
    var clampedKeyframe: Double? { keyframeSeconds.map { min(Self.keyframeRange.upperBound, max(Self.keyframeRange.lowerBound, $0)) } }
    var clampedAudioKbps: Int? { audioKbps.map { min(Self.audioKbpsRange.upperBound, max(Self.audioKbpsRange.lowerBound, $0)) } }

    static func even(_ v: Double) -> Int { max(2, Int((v / 2).rounded()) * 2) }
    /// Output size for a document of `doc` pixels. `longSide` keeps the document's proportions (it may be larger than the document: that is an enlargement);
    /// `custom` is taken as typed (even, within 16…8192) — a different aspect puts the whole picture inside the frame with margins.
    public func outputSize(document doc: CGSize) -> (w: Int, h: Int) {
        switch size {
        case .document: return (Self.even(Double(doc.width)), Self.even(Double(doc.height)))
        case .longSide(let l):
            let k = Double(l) / Double(max(doc.width, doc.height, 1))
            return doc.width >= doc.height ? (Self.even(Double(l)), Self.even(Double(doc.height) * k)) : (Self.even(Double(doc.width) * k), Self.even(Double(l)))
        case .custom(let w, let h): return (max(16, min(8192, w)) & ~1, max(16, min(8192, h)) & ~1)
        }
    }
    public func outputFPS(document: Double) -> Double { max(1, min(120, fps ?? document)) }
    /// The project as it is exported: only its canvas differs (nil canvas stays nil when nothing is overridden). The document itself is never modified.
    public func outputProject(_ p: SadrogProject, documentSize: CGSize, documentFPS: Double) -> SadrogProject {
        guard size != .document || fps != nil else { return p }
        var q = p; let s = outputSize(document: documentSize)
        q.canvas = DocumentFormat(width: s.w, height: s.h, fps: outputFPS(document: documentFPS)); return q
    }
}
