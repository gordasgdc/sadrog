// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// A named, storable `ExportSettings`. Only what `ExportSettings` already holds — a preset never adds a capability the exporter does not have.
public struct ExportPreset: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var mode: String, codec: String, tier: String, proRes: String
    public var longSide: Int?                // nil = like the document; custom sizes are not stored in presets
    public var fps: Double?
    public var videoMbps: Double?, keyframeSeconds: Double?, audioKbps: Int?   // advanced; absent in presets saved before they existed
    public var quality: Double?, targetMB: Double?                            // rate control added in 1.6.0; absent in older presets (their tier then decides the quality)
    public var container: String?, audioMono: Bool?                           // added in 1.7.0; absent = QuickTime, stereo (what older presets wrote)
    public var builtIn = false
    public init(id: String, name: String, settings s: ExportSettings, builtIn: Bool = false) {
        self.id = id; self.name = name; mode = s.mode.rawValue; codec = s.codec.rawValue; tier = s.tier.rawValue; proRes = s.proRes.rawValue
        if case .longSide(let l) = s.size { longSide = l } else if case .custom(let w, let h) = s.size { longSide = max(w, h) } else { longSide = nil }
        fps = s.fps; videoMbps = s.videoMbps; keyframeSeconds = s.keyframeSeconds; audioKbps = s.audioKbps; quality = s.quality; targetMB = s.targetMB; self.builtIn = builtIn
        container = s.container == .mov ? nil : s.container.rawValue; audioMono = s.audioMono ? true : nil
    }
    /// The settings this preset stands for; `onlyRange` is a per-export choice and is kept from `base`.
    public func settings(keeping base: ExportSettings = ExportSettings()) -> ExportSettings {
        var s = base
        s.mode = ExportSettings.Mode(rawValue: mode) ?? .compressed; s.codec = ExportSettings.Codec(rawValue: codec) ?? .h264
        s.tier = ExportSettings.Tier(rawValue: tier) ?? .high; s.proRes = ExportSettings.ProRes(rawValue: proRes) ?? .p422
        s.size = longSide.map { .longSide($0) } ?? .document; s.fps = fps
        s.videoMbps = videoMbps; s.keyframeSeconds = keyframeSeconds; s.audioKbps = audioKbps; s.quality = quality; s.targetMB = targetMB
        s.container = container.flatMap(ExportSettings.Container.init(rawValue:)) ?? .mov; s.audioMono = audioMono ?? false
        return s
    }
    public static var builtIns: [ExportPreset] {
        func mk(_ id: String, _ n: String, _ f: (inout ExportSettings) -> Void) -> ExportPreset { var s = ExportSettings(); f(&s); return ExportPreset(id: id, name: n, settings: s, builtIn: true) }
        return [
            mk("tutorial", T("Tutorial / captură de ecran (recomandat)")) { $0.mode = .compressed; $0.container = .mp4; $0.quality = ExportSettings.QualityStep.high.value },
            mk("web1080", T("Web 1080p")) { $0.mode = .compressed; $0.container = .mp4; $0.size = .longSide(1920); $0.quality = ExportSettings.QualityStep.high.value },
            mk("compact720", T("Compact 720p")) { $0.mode = .compressed; $0.container = .mp4; $0.size = .longSide(1280); $0.quality = ExportSettings.QualityStep.balanced.value },
            mk("hevc-compact", T("HEVC compact (fișier mic)")) { $0.mode = .compressed; $0.container = .mp4; $0.codec = .hevc; $0.quality = ExportSettings.QualityStep.balanced.value },
            mk("document", T("Calitate maximă (ca documentul)")) { $0.mode = .compressed; $0.quality = ExportSettings.QualityStep.maximum.value },
            mk("master", T("Master ProRes")) { $0.mode = .master },
            mk("fast", T("Rapid, fără re-codificare")) { $0.mode = .copy },
        ]
    }
}

/// Personal presets + the default, in a JSON file (injectable for tests). A corrupt or missing file simply means "no personal presets".
public struct ExportPresetStore {
    struct Disk: Codable { var presets: [ExportPreset] = []; var defaultID: String? }
    let url: URL
    public init(url: URL) { self.url = url }
    private var disk: Disk { (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(Disk.self, from: $0) } ?? Disk() }
    private func write(_ d: Disk) { try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true); try? JSONEncoder().encode(d).write(to: url, options: .atomic) }
    public var personal: [ExportPreset] { disk.presets }
    public var all: [ExportPreset] { ExportPreset.builtIns + personal }
    public var defaultID: String? { disk.defaultID }
    /// Saves under `name` (same name replaces it); the name must not be empty or equal a built-in name.
    @discardableResult public mutating func save(name: String, settings: ExportSettings) -> ExportPreset? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !ExportPreset.builtIns.contains(where: { $0.name == n }) else { return nil }
        var d = disk; let id = d.presets.first { $0.name == n }?.id ?? "user-" + UUID().uuidString.prefix(8)
        let p = ExportPreset(id: id, name: n, settings: settings); d.presets.removeAll { $0.id == id }; d.presets.append(p); write(d); return p
    }
    public mutating func delete(id: String) { var d = disk; d.presets.removeAll { $0.id == id }; if d.defaultID == id { d.defaultID = nil }; write(d) }
    public mutating func setDefault(_ id: String?) { var d = disk; d.defaultID = id; write(d) }
    /// No personal default = the recommended built-in (Tutorial: H.264, constant quality, MP4).
    public var defaultSettings: ExportSettings { (all.first { $0.id == defaultID }?.settings()) ?? ExportPreset.builtIns[0].settings() }
    /// The preset whose values equal `s` (range choice ignored), to show which one is active.
    public func matching(_ s: ExportSettings) -> ExportPreset? { (personal + ExportPreset.builtIns).first { $0.settings(keeping: s) == s } }
}

/// A rough size for the chosen settings — always an ESTIMATE. An explicit average rate (or a size target, which becomes one) gives a size that follows from the arithmetic;
/// a constant-quality export follows the CONTENT, so it is a range measured on real 4K recordings (docs/EXPORT_MEASUREMENTS.md): `low` = a mostly static screen recording,
/// `high` = a busy screen recording (scrolling, video panels, a full DaVinci Resolve window), `motion` = camera footage with continuous movement.
public enum ExportEstimate {
    public struct Range: Equatable, Sendable { public var low: Int64, high: Int64, motion: Int64 }
    /// bits per pixel per frame at 3840×2160, H.264, 5 s key frames — measured (A: static tutorial, B: busy tutorial, C: 4K 50p camera clip).
    static let table: [(q: Double, low: Double, high: Double, motion: Double)] = [
        (0.6, 0.00269, 0.00535, 0.0184), (0.7, 0.00354, 0.00828, 0.0297), (0.8, 0.00635, 0.01592, 0.0586), (0.9, 0.0474, 0.0576, 0.2374)]
    /// HEVC needs fewer bits for the same measured quality; the saving differs by content (A 0.90, B 0.68, C 0.62 at q 0.7).
    static let hevcFactor: (low: Double, high: Double, motion: Double) = (0.9, 0.68, 0.62)
    static func bpp(_ q: Double) -> (low: Double, high: Double, motion: Double) {
        let t = table
        let i = max(0, min(t.count - 2, t.lastIndex { $0.q <= q } ?? 0)), a = t[i], b = t[i + 1], u = (q - a.q) / (b.q - a.q)
        func mix(_ x: Double, _ y: Double) -> Double { exp(log(x) + (log(y) - log(x)) * max(-3, min(1.5, u))) }
        return (mix(a.low, b.low), mix(a.high, b.high), mix(a.motion, b.motion))
    }
    /// Fewer pixels cost more bits per pixel (measured ×1.3–1.5 from 4K to Full HD): about (4K pixels / pixels)^0.25.
    static func smallPictureFactor(_ px: Double) -> Double { pow(max(1, 8_294_400 / max(px, 1)), 0.25) }
    public static func qualityRange(_ pl: ExportPlan, settings s: ExportSettings) -> Range? {
        guard s.mode == .compressed, pl.delivery == .reencode, pl.duration > 0, case .quality(let q) = s.videoRate(duration: pl.duration) else { return nil }
        let px = Double(pl.width * pl.height), b = bpp(q), k = smallPictureFactor(px), h = s.codec == .hevc ? hevcFactor : (1, 1, 1)
        let audio = Double(s.clampedAudioKbps ?? 128) * 1000
        func bytes(_ bpp: Double, _ f: Double) -> Int64 { Int64((bpp * f * k * px * pl.fps + audio) / 8 * pl.duration) }
        return Range(low: bytes(b.low, h.0), high: bytes(b.high, h.1), motion: bytes(b.motion, h.2))
    }
    /// One figure: exact arithmetic for a rate or a target, the middle (geometric mean) of the screen-recording range for a quality.
    public static func bytes(_ pl: ExportPlan, settings s: ExportSettings) -> Int64? {
        guard pl.delivery == .reencode, pl.duration > 0 else { return nil }
        let px = Double(pl.width * pl.height) * pl.fps
        let bits: Double
        switch s.mode {
        case .compressed:
            let audio = Double(s.clampedAudioKbps ?? 128) * 1000
            if case .bitrate(let m) = s.videoRate(duration: pl.duration) { bits = m * 1_000_000 + audio }
            else if let r = qualityRange(pl, settings: s) { return Int64(sqrt(Double(r.low) * Double(r.high))) }
            else { return nil }
        case .master: bits = px * (s.proRes == .p422 ? 2.4 : 3.6) + 1_536_000
        case .copy, .lossless: return nil
        }
        return Int64(bits / 8 * pl.duration)
    }
}
