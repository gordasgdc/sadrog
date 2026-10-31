// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Size and frame rate of the EDIT DOCUMENT (the canvas that preview and export render), independent of the recorded source,
/// of the application window and of the viewer zoom. nil in a project = legacy behaviour (canvas = first source, its frame rate).
public struct DocumentFormat: Codable, Equatable, Hashable, Sendable {
    public var width: Int, height: Int
    public var fps: Double
    public init(width: Int, height: Int, fps: Double = 30) {
        // even pixel sizes (H.264/HEVC 4:2:0), sane bounds
        func even(_ v: Int) -> Int { let c = max(16, min(8192, v)); return c - c % 2 }
        self.width = even(width); self.height = even(height); self.fps = max(1, min(120, fps))
    }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        self.init(width: try c.decode(Int.self, forKey: .width), height: try c.decode(Int.self, forKey: .height), fps: try c.decodeIfPresent(Double.self, forKey: .fps) ?? 30)
    }
    public var size: CGSize { CGSize(width: width, height: height) }
    /// Reduced aspect ratio, e.g. "16:9", "1:1", "9:16".
    /// Reduced ratio when it is a familiar one (both terms ≤ 32), otherwise the decimal ratio, e.g. "2,16:1" — never "97:45".
    public var aspect: String {
        func g(_ a: Int, _ b: Int) -> Int { b == 0 ? a : g(b, a % b) }; let k = max(1, g(width, height)), a = width / k, b = height / k
        if max(a, b) <= 32 { return "\(a):\(b)" }
        let r = Double(max(width, height)) / Double(min(width, height)), t = String(format: "%.2f", r).replacingOccurrences(of: ".", with: ",")
        return width >= height ? "\(t):1" : "1:\(t)"
    }

    public struct Preset: Identifiable, Sendable, Equatable { public let id: String; public let name: String; public let width: Int; public let height: Int }
    /// Presets apply exactly these pixel sizes; the frame rate is chosen separately.
    public static let presets: [Preset] = [
        .init(id: "uhd", name: "4K UHD", width: 3840, height: 2160),
        .init(id: "1440", name: "1440p", width: 2560, height: 1440),
        .init(id: "1080", name: "1080p HD", width: 1920, height: 1080),
        .init(id: "720", name: "720p HD", width: 1280, height: 720),
        .init(id: "sq1080", name: T("Pătrat 1080"), width: 1080, height: 1080),
        .init(id: "v1080", name: "Vertical 1080×1920", width: 1080, height: 1920),
    ]
    public static let frameRates: [Double] = [24, 25, 30, 50, 60]
    public var preset: Preset? { Self.presets.first { $0.width == width && $0.height == height } }
}

/// Alignment of a moving item on the CANVAS (viewer), separate from the timeline magnet. Works in canvas pixels; the threshold is given
/// in canvas pixels too (the caller converts its on-screen tolerance), so the result does not depend on the viewer zoom.
public enum CanvasAlign {
    public struct Result: Equatable, Sendable { public var dx: Double; public var dy: Double; public var guidesX: [Double]; public var guidesY: [Double] }
    /// `moving`: the item's bounding box; `others`: boxes of the other visible items; the canvas edges and centre are always targets.
    /// Each axis snaps to the closest target within `threshold` among the item's left/centre/right (top/centre/bottom) lines;
    /// the guides returned are exactly the lines that coincide after snapping (nothing is drawn without an actual alignment).
    public static func snap(moving r: CGRect, others: [CGRect], canvas: CGSize, threshold: Double) -> Result {
        let tx: [Double] = [0, Double(canvas.width) / 2, Double(canvas.width)] + others.flatMap { [Double($0.minX), Double($0.midX), Double($0.maxX)] }
        let ty: [Double] = [0, Double(canvas.height) / 2, Double(canvas.height)] + others.flatMap { [Double($0.minY), Double($0.midY), Double($0.maxY)] }
        func axis(_ vals: [Double], _ targets: [Double]) -> (Double, [Double]) {
            var best: Double?
            for v in vals { for t in targets where abs(t - v) <= threshold && (best == nil || abs(t - v) < abs(best!)) { best = t - v } }
            guard let d = best else { return (0, []) }
            let hits = Set(vals.map { $0 + d }.filter { v in targets.contains { abs($0 - v) < 0.5 } }.map { ($0 * 2).rounded() / 2 })
            return (d, hits.sorted())
        }
        let (dx, gx) = axis([Double(r.minX), Double(r.midX), Double(r.maxX)], tx)
        let (dy, gy) = axis([Double(r.minY), Double(r.midY), Double(r.maxY)], ty)
        return Result(dx: dx, dy: dy, guidesX: gx, guidesY: gy)
    }
}

public extension SadrogProject {
    /// First opening of a SADROG recording as a document: the canvas takes the CONFIGURED capture settings from the session journal
    /// (capture-file size, configured frame rate), not the file's nominal rate — a screen-recording file has variable frame timing, so its
    /// nominal rate (e.g. 17 or 25.11) only says how often the picture changed. The clip keeps the file's real duration and timing; a 60 fps
    /// document does not create motion that was not captured (frames are repeated where the source did not change).
    /// Projects already saved keep whatever they have (an explicit canvas, or none = "same as source"); nothing is migrated silently.
    static func forRecording(name: String, media: String, duration: Double, journal: SessionJournal) -> SadrogProject {
        var p = SadrogProject(name: name, clips: [Clip(media: media, sourceStart: 0, duration: duration)])
        if journal.width > 0, journal.height > 0, journal.fps > 0 { p.canvas = DocumentFormat(width: journal.width, height: journal.height, fps: Double(journal.fps)) }
        // every other video file of the session (extra screens, cameras): its own V2 row, placed by the offset measured on the session clock.
        // Cameras open as presenter circles (stacked up from the bottom-right corner), extra screens as full-frame overlays — all editable.
        let folder = URL(fileURLWithPath: media).deletingLastPathComponent()
        let files = (try? SourcesManifest.read(from: folder))?.allVideoFiles ?? []
        let R = CGSize(width: max(1, journal.width), height: max(1, journal.height))
        var row = 0, camIndex = 0
        for f in files where f.frames > 0 {
            let path = folder.appendingPathComponent(f.file).path
            let off = f.firstFrameOffsetSeconds, start = max(0, off), sourceStart = max(0, -off)
            let length = min(f.durationSeconds - sourceStart, duration - start)
            guard FileManager.default.fileExists(atPath: path), length > 0.05 else { continue }
            var l: Layer
            if f.kind == .camera {
                var t = PresenterPlacement.transform(Transform(scale: PresenterPlacement.scale), corner: .bottomRight, render: R)
                t.y -= Double(camIndex) * (PresenterPlacement.scale + PresenterPlacement.margin) * Double(min(R.width, R.height)) / Double(R.height)
                l = Layer(kind: .video, media: path, start: start, sourceStart: sourceStart, duration: length, transform: t)
                l.crop = PresenterPlacement.defaultCrop; camIndex += 1
            } else {
                l = Layer(kind: .video, media: path, start: start, sourceStart: sourceStart, duration: length)
            }
            l.track = row == 0 ? nil : row; row += 1
            p.layers.append(l); p.library.append(path)
        }
        if !p.layers.isEmpty { p.library.insert(media, at: 0) }
        return p
    }
}
