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
    public var builtIn = false
    public init(id: String, name: String, settings s: ExportSettings, builtIn: Bool = false) {
        self.id = id; self.name = name; mode = s.mode.rawValue; codec = s.codec.rawValue; tier = s.tier.rawValue; proRes = s.proRes.rawValue
        if case .longSide(let l) = s.size { longSide = l } else if case .custom(let w, let h) = s.size { longSide = max(w, h) } else { longSide = nil }
        fps = s.fps; videoMbps = s.videoMbps; keyframeSeconds = s.keyframeSeconds; audioKbps = s.audioKbps; self.builtIn = builtIn
    }
    /// The settings this preset stands for; `onlyRange` is a per-export choice and is kept from `base`.
    public func settings(keeping base: ExportSettings = ExportSettings()) -> ExportSettings {
        var s = base
        s.mode = ExportSettings.Mode(rawValue: mode) ?? .compressed; s.codec = ExportSettings.Codec(rawValue: codec) ?? .h264
        s.tier = ExportSettings.Tier(rawValue: tier) ?? .high; s.proRes = ExportSettings.ProRes(rawValue: proRes) ?? .p422
        s.size = longSide.map { .longSide($0) } ?? .document; s.fps = fps
        s.videoMbps = videoMbps; s.keyframeSeconds = keyframeSeconds; s.audioKbps = audioKbps
        return s
    }
    public static var builtIns: [ExportPreset] {
        func mk(_ id: String, _ n: String, _ f: (inout ExportSettings) -> Void) -> ExportPreset { var s = ExportSettings(); f(&s); return ExportPreset(id: id, name: n, settings: s, builtIn: true) }
        return [
            mk("web1080", T("Web 1080p")) { $0.mode = .compressed; $0.size = .longSide(1920) },
            mk("compact720", T("Compact 720p")) { $0.mode = .compressed; $0.tier = .medium; $0.size = .longSide(1280) },
            mk("document", T("Calitate maximă (ca documentul)")) { $0.mode = .compressed },
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
    public var defaultSettings: ExportSettings { (all.first { $0.id == defaultID }?.settings()) ?? ExportSettings() }
    /// The preset whose values equal `s` (range choice ignored), to show which one is active.
    public func matching(_ s: ExportSettings) -> ExportPreset? { (personal + ExportPreset.builtIns).first { $0.settings(keeping: s) == s } }
}

/// A rough size for the chosen settings — always an ESTIMATE: the exporter's real bit rate is the system's (AVFoundation presets), and the real file depends on the picture.
public enum ExportEstimate {
    public static func bytes(_ pl: ExportPlan, settings s: ExportSettings) -> Int64? {
        guard pl.delivery == .reencode, pl.duration > 0 else { return nil }
        let px = Double(pl.width * pl.height) * pl.fps
        let bits: Double
        switch s.mode {
        case .compressed:
            let audio = Double(s.clampedAudioKbps ?? 128) * 1000
            bits = s.clampedMbps.map { $0 * 1_000_000 + audio } ?? px * (s.codec == .hevc ? 0.045 : (s.tier == .high ? 0.075 : 0.045)) + 128_000
        case .master: bits = px * (s.proRes == .p422 ? 2.4 : 3.6) + 1_536_000
        case .copy, .lossless: return nil
        }
        return Int64(bits / 8 * pl.duration)
    }
}
