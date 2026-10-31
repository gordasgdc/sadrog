// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreGraphics

/// Region of a display, normalised 0…1 of the display (independent of scale factor and monitor).
public struct RegionSpec: Codable, Equatable, Sendable {
    public var x, y, w, h: Double
    public init(x: Double, y: Double, w: Double, h: Double) { self.x = x; self.y = y; self.w = w; self.h = h }
    public var isValid: Bool { w > 0 && h > 0 && x >= 0 && y >= 0 && x + w <= 1.000001 && y + h <= 1.000001 }
}

/// Logical points (macOS) ↔ capture pixels ↔ normalised region. Pure functions, no hardware.
public enum RegionMath {
    /// `SCStreamConfiguration.sourceRect`: display-local logical points, origin top-left.
    public static func sourceRect(_ r: RegionSpec, displayPoints: CGSize) -> CGRect {
        CGRect(x: r.x * displayPoints.width, y: r.y * displayPoints.height, width: r.w * displayPoints.width, height: r.h * displayPoints.height)
    }
    /// Capture size in pixels: points × scale, rounded and made even (HEVC), never below 2.
    public static func pixels(points: CGSize, scale: Double) -> (w: Int, h: Int) {
        (max(2, Int((points.width * scale).rounded()) & ~1), max(2, Int((points.height * scale).rounded()) & ~1))
    }
    /// Normalises a rectangle drawn in logical points; nil if it falls outside the display.
    public static func region(rect: CGRect, displayPoints: CGSize) -> RegionSpec? {
        guard displayPoints.width > 0, displayPoints.height > 0 else { return nil }
        let r = RegionSpec(x: rect.minX / displayPoints.width, y: rect.minY / displayPoints.height, w: rect.width / displayPoints.width, h: rect.height / displayPoints.height)
        return r.isValid ? r : nil
    }
    /// Output size when the long side is capped (nil = 1:1 with the source); aspect kept, even dimensions.
    public static func output(source: (w: Int, h: Int), maxLongSide: Int?) -> (w: Int, h: Int) {
        guard let m = maxLongSide, max(source.w, source.h) > m else { return source }
        let k = Double(m) / Double(max(source.w, source.h))
        return (max(2, Int((Double(source.w) * k).rounded()) & ~1), max(2, Int((Double(source.h) * k).rounded()) & ~1))
    }
}

public enum VideoMode: String, Codable, Sendable, CaseIterable { case display, window, region }
public enum AudioSourceKind: String, Codable, Sendable { case system, input }

public struct VideoSourceSpec: Codable, Equatable, Sendable, Identifiable {
    /// Stable identity of the source row (kept in sources.json); older configurations get one when read.
    public var id: String = UUID().uuidString
    public var mode: VideoMode
    /// CGDirectDisplayID (display, region) or CGWindowID (window).
    public var sourceID: UInt32
    public var title: String
    public var region: RegionSpec?
    public var maxLongSide: Int?
    public init(id: String = UUID().uuidString, mode: VideoMode, sourceID: UInt32, title: String, region: RegionSpec? = nil, maxLongSide: Int? = nil) {
        self.id = id; self.mode = mode; self.sourceID = sourceID; self.title = title; self.region = region; self.maxLongSide = maxLongSide
    }
    enum CodingKeys: String, CodingKey { case id, mode, sourceID, title, region, maxLongSide }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        mode = try c.decode(VideoMode.self, forKey: .mode); sourceID = try c.decode(UInt32.self, forKey: .sourceID); title = try c.decode(String.self, forKey: .title)
        region = try c.decodeIfPresent(RegionSpec.self, forKey: .region); maxLongSide = try c.decodeIfPresent(Int.self, forKey: .maxLongSide)
    }
}

public struct AudioSourceSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var kind: AudioSourceKind
    /// CoreAudio device UID for `.input`; nil for the system mix.
    public var deviceUID: String?
    public var deviceName: String
    /// 1-based channels of the device mapped to this track (empty = all for system).
    public var channels: [Int]
    public var enabled: Bool
    public init(id: String = UUID().uuidString, kind: AudioSourceKind, deviceUID: String? = nil, deviceName: String, channels: [Int] = [], enabled: Bool = true) {
        self.id = id; self.kind = kind; self.deviceUID = deviceUID; self.deviceName = deviceName; self.channels = channels; self.enabled = enabled
    }
    public var trackChannels: Int { kind == .system ? 2 : max(1, channels.count) }
}

/// A camera recorded as its OWN video file (camera.mov) next to the screen recording, on the same clock — never burnt into the screen.
public struct CameraSpec: Codable, Equatable, Sendable, Identifiable {
    public var id: String { uid }
    public var uid: String
    public var name: String
    /// A mode chosen by the user (size + frame rate); nil = the camera's own current mode. A chosen mode the camera cannot give stops the camera with a message.
    public var format: CameraFormatOption?
    public init(uid: String, name: String, format: CameraFormatOption? = nil) { self.uid = uid; self.name = name; self.format = format }
}

/// What one session records. The FIRST screen source is the primary file (capture.mov, with every audio track); each additional screen and each
/// camera gets its own file next to it, on the same session clock. Nothing is composited at capture time: every source stays separate.
public struct CaptureConfig: Codable, Equatable, Sendable {
    public var video: VideoSourceSpec?
    public var extraVideos: [VideoSourceSpec]
    public var audio: [AudioSourceSpec]
    public var cameras: [CameraSpec]
    public init(video: VideoSourceSpec? = nil, extraVideos: [VideoSourceSpec] = [], audio: [AudioSourceSpec] = [], cameras: [CameraSpec] = []) {
        self.video = video; self.extraVideos = extraVideos; self.audio = audio; self.cameras = cameras
    }
    enum CodingKeys: String, CodingKey { case video, extraVideos, audio, cameras, camera }
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        video = try c.decodeIfPresent(VideoSourceSpec.self, forKey: .video)
        extraVideos = try c.decodeIfPresent([VideoSourceSpec].self, forKey: .extraVideos) ?? []
        audio = try c.decodeIfPresent([AudioSourceSpec].self, forKey: .audio) ?? []
        cameras = try c.decodeIfPresent([CameraSpec].self, forKey: .cameras) ?? (try c.decodeIfPresent(CameraSpec.self, forKey: .camera)).map { [$0] } ?? []
    }
    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(video, forKey: .video); try c.encode(extraVideos, forKey: .extraVideos); try c.encode(audio, forKey: .audio); try c.encode(cameras, forKey: .cameras)
    }
    /// Every screen source, primary first.
    public var videos: [VideoSourceSpec] { (video.map { [$0] } ?? []) + extraVideos }
    public var activeAudio: [AudioSourceSpec] { audio.filter(\.enabled) }
}

public enum CaptureIssue: Equatable, Sendable {
    case noVideoSource
    case videoSourceMissing(String)
    case regionMissing, regionOutsideDisplay
    case audioDeviceMissing(name: String)
    case noChannelsChosen(name: String)
    case channelOutOfRange(name: String, channel: Int, available: Int)
    case duplicateDeviceChannels(name: String)
    case moreThanOneSystemAudio
    case cameraMissing(name: String)
    case cameraNotAllowed
    case duplicateVideo(String)
    case duplicateCamera(String)
    public var text: String {
        switch self {
        case .noVideoSource: return T("Alege ce se înregistrează (monitor, fereastră sau regiune).")
        case .videoSourceMissing(let t): return L10n.f("Sursa video „%@” nu mai este disponibilă. Alege din nou; nu se trece la altă sursă.", "\(t)")
        case .regionMissing: return T("Trasează regiunea de înregistrat.")
        case .regionOutsideDisplay: return T("Regiunea iese din monitor.")
        case .audioDeviceMissing(let n): return L10n.f("Dispozitivul audio „%@” nu este disponibil. Nu se folosește alt dispozitiv în loc.", "\(n)")
        case .noChannelsChosen(let n): return L10n.f("„%@”: alege cel puțin un canal.", "\(n)")
        case .channelOutOfRange(let n, let c, let a): return L10n.f("„%@”: canalul %@ nu există (disponibile: %@).", "\(n)", "\(c)", "\(a)")
        case .duplicateDeviceChannels(let n): return L10n.f("„%@”: aceleași canale sunt alese de două ori.", "\(n)")
        case .moreThanOneSystemAudio: return T("Sunetul calculatorului poate fi adăugat o singură dată.")
        case .cameraMissing(let n): return L10n.f("Camera „%@” nu este disponibilă. Nu se folosește altă cameră în loc.", "\(n)")
        case .duplicateVideo(let t): return L10n.f("„%@” e adăugată de două ori. Fiecare sursă se înregistrează o singură dată.", "\(t)")
        case .duplicateCamera(let n): return L10n.f("Camera „%@” e adăugată de două ori.", "\(n)")
        case .cameraNotAllowed: return T("SADROG nu are acces la cameră. Permite-l în Setări → Confidențialitate → Cameră sau alege „Fără cameră”.")
        }
    }
}

public struct AvailableDevice: Equatable, Sendable { public var uid: String; public var name: String; public var inputChannels: Int
    public init(uid: String, name: String, inputChannels: Int) { self.uid = uid; self.name = name; self.inputChannels = inputChannels } }

public enum CaptureValidator {
    /// Pure check against what is currently available. Never substitutes another device/source.
    public static func check(_ c: CaptureConfig, sources: [SourceInfo], devices: [AvailableDevice], cameras: [String] = [], cameraAllowed: Bool = true) -> [CaptureIssue] {
        var out: [CaptureIssue] = []
        if c.video == nil { out.append(.noVideoSource) }
        var seenVideo = Set<String>()
        for v in c.videos {
            let kind: SourceInfo.Kind = v.mode == .window ? .window : .display
            if !sources.contains(where: { $0.id == v.sourceID && $0.kind == kind }) { out.append(.videoSourceMissing(v.title)) }
            if v.mode == .region { if let r = v.region { if !r.isValid { out.append(.regionOutsideDisplay) } } else { out.append(.regionMissing) } }
            let key = "\(v.mode.rawValue)#\(v.sourceID)#\(v.region.map { "\($0)" } ?? "")"
            if !seenVideo.insert(key).inserted { out.append(.duplicateVideo(v.title)) }
        }
        if c.activeAudio.filter({ $0.kind == .system }).count > 1 { out.append(.moreThanOneSystemAudio) }
        var used = Set<String>()
        for a in c.activeAudio where a.kind == .input {
            guard let d = devices.first(where: { $0.uid == a.deviceUID }) else { out.append(.audioDeviceMissing(name: a.deviceName)); continue }
            if a.channels.isEmpty { out.append(.noChannelsChosen(name: a.deviceName)); continue }
            for ch in a.channels where ch < 1 || ch > d.inputChannels { out.append(.channelOutOfRange(name: a.deviceName, channel: ch, available: d.inputChannels)) }
            let key = "\(d.uid)#\(a.channels.sorted())"
            if !used.insert(key).inserted { out.append(.duplicateDeviceChannels(name: a.deviceName)) }
        }
        var seenCam = Set<String>()
        for cam in c.cameras {
            if !seenCam.insert(cam.uid).inserted { out.append(.duplicateCamera(cam.name)); continue }
            if !cameras.contains(cam.uid) { out.append(.cameraMissing(name: cam.name)) }
        }
        if !c.cameras.isEmpty, !cameraAllowed { out.append(.cameraNotAllowed) }
        return out
    }
}

/// Written next to capture.mov so the editor can tell the tracks apart. Offsets are against the shared session clock.
public struct SourcesManifest: Codable, Equatable, Sendable {
    public struct Track: Codable, Equatable, Sendable {
        public var index: Int            // 0-based audio track in capture.mov
        public var id: String
        public var kind: AudioSourceKind
        public var deviceName: String
        public var deviceUID: String?
        public var channels: [Int]
        public var firstSampleOffsetSeconds: Double?  // measured at stop; nil = unknown
    }
    public var version = 1
    public var video: VideoSourceSpec
    public var sourcePixels: [Int]
    public var outputPixels: [Int]
    public var scale: Double
    public var audioTracks: [Track]
    /// The camera recorded next to the screen (nil = none). Its offset is first camera frame − first screen frame, same host clock.
    public struct Camera: Codable, Equatable, Sendable {
        public var uid: String, name: String
        public var file: String                    // relative to the session folder
        public var width: Int, height: Int
        public var frames: Int
        public var firstFrameOffsetSeconds: Double
        public var durationSeconds: Double
        public var lost: String?                   // set when the camera disappeared during the recording
        public init(uid: String, name: String, file: String, width: Int, height: Int, frames: Int, firstFrameOffsetSeconds: Double, durationSeconds: Double, lost: String? = nil) {
            self.uid = uid; self.name = name; self.file = file; self.width = width; self.height = height; self.frames = frames
            self.firstFrameOffsetSeconds = firstFrameOffsetSeconds; self.durationSeconds = durationSeconds; self.lost = lost
        }
    }
    public var camera: Camera?                     // format of the first camera lot (one camera); still read
    /// Every additional video file of the session (extra screens and cameras), each on the same clock as capture.mov.
    public struct VideoFile: Codable, Equatable, Sendable {
        public enum Kind: String, Codable, Sendable { case screen, camera }
        public var id: String, kind: Kind, name: String, file: String
        public var width: Int, height: Int, frames: Int
        public var firstFrameOffsetSeconds: Double, durationSeconds: Double
        public var lost: String?
        public init(id: String, kind: Kind, name: String, file: String, width: Int, height: Int, frames: Int, firstFrameOffsetSeconds: Double, durationSeconds: Double, lost: String? = nil) {
            self.id = id; self.kind = kind; self.name = name; self.file = file; self.width = width; self.height = height; self.frames = frames
            self.firstFrameOffsetSeconds = firstFrameOffsetSeconds; self.durationSeconds = durationSeconds; self.lost = lost
        }
    }
    public var videoFiles: [VideoFile]?
    /// Additional video files, whatever the manifest format (the single `camera` of older sessions included).
    public var allVideoFiles: [VideoFile] {
        if let v = videoFiles { return v }
        return camera.map { [VideoFile(id: $0.uid, kind: .camera, name: $0.name, file: $0.file, width: $0.width, height: $0.height, frames: $0.frames, firstFrameOffsetSeconds: $0.firstFrameOffsetSeconds, durationSeconds: $0.durationSeconds, lost: $0.lost)] } ?? []
    }
    public static let fileName = "sources.json"
    public func write(to folder: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.prettyPrinted, .sortedKeys]
        try e.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
    public static func read(from folder: URL) throws -> SourcesManifest {
        try JSONDecoder().decode(SourcesManifest.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }
}
