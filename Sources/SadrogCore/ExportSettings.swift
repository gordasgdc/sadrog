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
    public init() {}

    public static let videoMbpsRange: ClosedRange<Double> = 0.5...200, keyframeRange: ClosedRange<Double> = 0.1...10, audioKbpsRange: ClosedRange<Int> = 64...320
    /// True when the chosen controls need the explicit writer (the presets cannot express them). Only the compressed mode has such controls.
    public var usesAdvancedWriter: Bool { mode == .compressed && (videoMbps != nil || keyframeSeconds != nil || audioKbps != nil) }
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
