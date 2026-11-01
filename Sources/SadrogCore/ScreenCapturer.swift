// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import ScreenCaptureKit
import CoreMedia
import AppKit

public enum CaptureSource: Sendable {
    case display(CGDirectDisplayID)
    case window(CGWindowID)
}

public struct SourceInfo: Identifiable, Sendable, Hashable {
    public enum Kind: Sendable { case display, window }
    public let id: UInt32
    public let kind: Kind
    public let title: String
    public let width: Int, height: Int
    /// Display: logical size in points and backing scale (pixels = points × scale); frame = global logical rect. Windows: scale of the owning display when known.
    public var pointsWidth: Double = 0, pointsHeight: Double = 0, scale: Double = 1
    public var frame: CGRect = .zero
    /// Physical panel resolution (native display mode) — can be smaller than the backing store of a scaled mode; 0 = unknown.
    public var panelWidth = 0, panelHeight = 0
    public init(id: UInt32, kind: Kind, title: String, width: Int, height: Int, pointsWidth: Double = 0, pointsHeight: Double = 0, scale: Double = 1, frame: CGRect = .zero) {
        self.id = id; self.kind = kind; self.title = title; self.width = width; self.height = height
        self.pointsWidth = pointsWidth; self.pointsHeight = pointsHeight; self.scale = scale; self.frame = frame
    }
    /// Native pixel size of the source.
    public var pixels: (w: Int, h: Int) { kind == .display ? (Int((pointsWidth * scale).rounded()), Int((pointsHeight * scale).rounded())) : (Int((Double(width) * scale).rounded()), Int((Double(height) * scale).rounded())) }
}

public enum CaptureError: Error { case sourceNotFound, noPermission }

/// Wraps SCStream and feeds a RecordingWriter. Capture frames with status != .complete (idle/blank) are skipped.
public final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let queue = DispatchQueue(label: "sadrog.capture")
    private var stream: SCStream?
    public private(set) var writer: RecordingWriter?
    public var onStop: (@Sendable (Error?) -> Void)?

    /// Frame rate of every screen capture file (also what the capture panel states).
    public static let defaultFPS = 60
    public static func hasPermission() -> Bool { CGPreflightScreenCaptureAccess() }
    @discardableResult public static func requestPermission() -> Bool { CGRequestScreenCaptureAccess() }

    public static func listSources() async throws -> [SourceInfo] {
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let displays = c.displays.map { d -> SourceInfo in
            let f = SCContentFilter(display: d, excludingWindows: [])
            let sc = Double(SCShareableContent.info(for: f).pointPixelScale)
            var si = SourceInfo(id: d.displayID, kind: .display, title: displayName(d.displayID), width: d.width, height: d.height, pointsWidth: Double(d.width), pointsHeight: Double(d.height), scale: sc, frame: d.frame)
            (si.panelWidth, si.panelHeight) = panelPixels(d.displayID); return si
        }
        let me = Bundle.main.bundleIdentifier
        let windows = c.windows.filter { $0.isOnScreen && $0.frame.width >= 200 && $0.frame.height >= 120 && $0.owningApplication?.bundleIdentifier != me && ($0.title?.isEmpty == false) }
            .map { w -> SourceInfo in
                // global frame: the identification frame is drawn on the window itself. Scale = the scale of the display holding the window's
                // centre (the capturer uses the same pointPixelScale), so the size shown before recording is the size of the file.
                let mid = CGPoint(x: w.frame.midX, y: w.frame.midY)
                let sc = displays.first { $0.frame.contains(mid) }?.scale ?? 1
                return SourceInfo(id: w.windowID, kind: .window, title: "\(w.owningApplication?.applicationName ?? "?") — \(w.title ?? "")", width: Int(w.frame.width), height: Int(w.frame.height), scale: sc, frame: w.frame)
            }
        return displays + windows
    }

    /// Native (physical) mode of a display, from the mode list's native flag; (0, 0) if not reported.
    public static func panelPixels(_ id: CGDirectDisplayID) -> (Int, Int) {
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode] else { return (0, 0) }
        let native = modes.filter { $0.ioFlags & 0x02000000 != 0 }
        guard let m = native.max(by: { $0.pixelWidth < $1.pixelWidth }) else { return (0, 0) }
        return (m.pixelWidth, m.pixelHeight)
    }

    /// Monitor name as macOS shows it (NSScreen.localizedName); falls back to the display id.
    public static func displayName(_ id: CGDirectDisplayID) -> String {
        for sc in NSScreen.screens where (sc.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id { return sc.localizedName }
        return "Display \(id)"
    }

    public struct Started: Sendable { public var sourcePixels: (w: Int, h: Int); public var outputPixels: (w: Int, h: Int); public var scale: Double }
    public var onLevel: (@Sendable (String, Float) -> Void)?
    public var onTrackLost: (@Sendable (String, String) -> Void)?
    public private(set) var manifest: SourcesManifest?
    private var finalizer: SessionFinalizer?
    private var inputs: [AudioInputCapture] = []
    private var systemTrack: String?
    /// The session clock shared by every file (common start + pauses).
    public private(set) var timeline = CaptureTimeline()
    private var extras: [ExtraScreen] = []
    private var cams: [(spec: CameraSpec, cap: CameraCapture, writer: VideoFileWriter)] = []
    private var prepared: [String: CameraCapture] = [:]
    private let lostLock = NSLock()
    private var lostVideo: [String: String] = [:]
    private func markLost(_ id: String, _ why: String) { lostLock.withLock { lostVideo[id] = why } }

    // MARK: camera preparation (before the countdown; stopped on cancel; never at launch)
    /// Starts the chosen cameras and waits until each delivers frames with exposure and white balance settled. nil = ready;
    /// otherwise the reason, and the cameras are stopped again (a recording never starts with a camera silently missing).
    public func prepareCameras(_ specs: [CameraSpec], timeout: Double = 8) async -> String? {
        releasePreparedCameras()
        for spec in specs {
            do { let c = try CameraCapture(spec: spec); c.start(); prepared[spec.uid] = c }
            catch { releasePreparedCameras(); return L10n.f("Camera „%@”: %@.", "\(spec.name)", "\(error.localizedDescription)") }
        }
        let t0 = Date()
        while Date().timeIntervalSince(t0) < timeout {
            if prepared.values.allSatisfy(\.isReady) { return nil }
            try? await Task.sleep(nanoseconds: 100_000_000)
            if Task.isCancelled { releasePreparedCameras(); return T("Pregătirea camerelor a fost anulată.") }
        }
        let bad = specs.filter { !(prepared[$0.uid]?.isReady ?? false) }.map(\.name)
        releasePreparedCameras()
        return L10n.f("Camera „%@” nu s-a stabilizat în %@ s (fără cadre sau expunere încă în reglaj). Înregistrarea nu a pornit.", "\(bad.joined(separator: "”, „"))", "\(Int(timeout))")
    }
    public func releasePreparedCameras() { prepared.values.forEach { $0.stop() }; prepared = [:] }
    public var preparedCameraCount: Int { prepared.count }

    /// Filter + configuration of one screen source (display / window / region), without audio.
    static func streamParts(_ v: VideoSourceSpec, content c: SCShareableContent, sources: [SourceInfo], fps: Int) throws -> (filter: SCContentFilter, cfg: SCStreamConfiguration, srcPx: (w: Int, h: Int), scale: Double) {
        let me = c.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }     // SADROG's own windows (panel, frames) never in a capture
        let filter: SCContentFilter
        var srcPx: (w: Int, h: Int), scale = 1.0
        var sourceRect: CGRect?
        switch v.mode {
        case .display, .region:
            guard let d = c.displays.first(where: { $0.displayID == v.sourceID }), let info = sources.first(where: { $0.id == v.sourceID && $0.kind == .display }) else { throw CaptureError.sourceNotFound }
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            scale = info.scale
            let pts = CGSize(width: info.pointsWidth, height: info.pointsHeight)
            if v.mode == .region {
                guard let r = v.region, r.isValid else { throw CaptureError.sourceNotFound }
                let rect = RegionMath.sourceRect(r, displayPoints: pts); sourceRect = rect
                let px = RegionMath.pixels(points: rect.size, scale: scale); srcPx = (px.w, px.h)
            } else { let px = RegionMath.pixels(points: pts, scale: scale); srcPx = (px.w, px.h) }
        case .window:
            guard let w = c.windows.first(where: { $0.windowID == v.sourceID }) else { throw CaptureError.sourceNotFound }
            filter = SCContentFilter(desktopIndependentWindow: w)
            scale = Double(SCShareableContent.info(for: filter).pointPixelScale)
            let px = RegionMath.pixels(points: w.frame.size, scale: scale); srcPx = (px.w, px.h)
        }
        let out = RegionMath.output(source: srcPx, maxLongSide: v.maxLongSide)
        let cfg = SCStreamConfiguration()
        cfg.width = out.w & ~1; cfg.height = out.h & ~1
        if let r = sourceRect { cfg.sourceRect = r }
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        cfg.queueDepth = 8; cfg.showsCursor = true
        return (filter, cfg, srcPx, scale)
    }

    /// Starts every source of the session: the primary screen (capture.mov, with system audio and every input as separate tracks), each
    /// additional screen and each camera into its own file. All share one clock; the first frame of the primary screen is the common start.
    /// Every source is validated by the caller; nothing is substituted here — a source that cannot start aborts the whole start.
    public func start(config: CaptureConfig, sources: [SourceInfo], destination: Destination, fps: Int = ScreenCapturer.defaultFPS) async throws -> Started {
        guard let v = config.video else { throw CaptureError.sourceNotFound }
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let primary = try Self.streamParts(v, content: c, sources: sources, fps: fps)
        let cfg = primary.cfg
        let sys = config.activeAudio.first { $0.kind == .system }
        let ins = config.activeAudio.filter { $0.kind == .input }
        cfg.capturesAudio = sys != nil; cfg.sampleRate = 48000; cfg.channelCount = 2
        cfg.excludesCurrentProcessAudio = true
        let tracks = (sys.map { [AudioTrackFormat(id: $0.id, channels: 2)] } ?? []) + ins.map { AudioTrackFormat(id: $0.id, channels: $0.trackChannels) }
        timeline = CaptureTimeline(); lostLock.withLock { lostVideo = [:] }
        let w = try RecordingWriter(destination: destination, settings: RecordingSettings(width: cfg.width, height: cfg.height, fps: fps, withAudio: false, audioTracks: tracks), timeline: timeline)
        writer = w; systemTrack = sys?.id
        func abort() async {
            inputs.forEach { $0.stop() }; inputs = []
            for x in extras { try? await x.stream?.stopCapture(); _ = try? await x.writer.finish() }; extras = []
            for k in cams { k.cap.stop(); _ = try? await k.writer.finish() }; cams = []
            releasePreparedCameras(); try? await w.finish(); writer = nil
        }
        // input devices first (so their clocks run before the first video frame); a missing device aborts instead of falling back
        do {
            for spec in ins {
                let cap = try AudioInputCapture(spec: spec)
                cap.onBuffer = { [weak w, queue] sb in queue.async { w?.appendAudio(sb, track: spec.id) } }   // the writer is single-queue: serialise all inputs with SCK
                cap.onLevel = { [weak self] p in self?.onLevel?(spec.id, p) }
                cap.onLost = { [weak self] why in self?.onTrackLost?(spec.id, why) }
                try cap.start(); inputs.append(cap)
            }
            // cameras: the ones prepared during the countdown are already running (their early frames are not recorded)
            for (k, spec) in config.cameras.enumerated() {
                let cap: CameraCapture
                if let p = prepared.removeValue(forKey: spec.uid) { cap = p } else { cap = try CameraCapture(spec: spec); cap.start() }
                let cw = VideoFileWriter(url: w.folder.appendingPathComponent("camera-\(k + 1).mov"), timeline: timeline)
                cap.onFrame = { [cw] sb in cw.append(sb) }                                   // camera queue only
                cap.onLost = { [weak self] why in self?.markLost(spec.uid, why); self?.onTrackLost?("camera:" + spec.uid, why) }
                cams.append((spec, cap, cw))
            }
            releasePreparedCameras()                                                         // prepared but no longer chosen
            // additional screens before the primary one, so their frames are already flowing at the common start
            for (k, ev) in config.extraVideos.enumerated() {
                let parts = try Self.streamParts(ev, content: c, sources: sources, fps: fps)
                let x = ExtraScreen(id: ev.id, name: ev.title, writer: VideoFileWriter(url: w.folder.appendingPathComponent("screen-\(k + 2).mov"), fps: fps, timeline: timeline))
                x.onLost = { [weak self] why in self?.markLost(ev.id, why); self?.onTrackLost?("screen:" + ev.id, why) }
                let s = SCStream(filter: parts.filter, configuration: parts.cfg, delegate: x)
                try s.addStreamOutput(x, type: .screen, sampleHandlerQueue: x.queue)
                try await s.startCapture(); x.stream = s; extras.append(x)
            }
        } catch { await abort(); throw error }
        let s = SCStream(filter: primary.filter, configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if sys != nil { try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue) }
        stream = s
        do { try await s.startCapture() } catch { stream = nil; await abort(); throw error }
        finalizer = SessionFinalizer(session: w.journal.id, folder: w.folder)
        SessionEventLog.append(SessionEvent(session: w.journal.id, event: "recording_started"), to: w.folder)
        manifest = SourcesManifest(video: v, sourcePixels: [primary.srcPx.w, primary.srcPx.h], outputPixels: [cfg.width, cfg.height], scale: primary.scale, audioTracks: [])
        let order = tracks.map(\.id)
        let specs = (sys.map { [$0] } ?? []) + ins
        manifest?.audioTracks = specs.enumerated().map { .init(index: order.firstIndex(of: $1.id) ?? $0, id: $1.id, kind: $1.kind, deviceName: $1.deviceName, deviceUID: $1.deviceUID, channels: $1.channels, firstSampleOffsetSeconds: nil) }
        return Started(sourcePixels: primary.srcPx, outputPixels: (cfg.width, cfg.height), scale: primary.scale)
    }

    /// Pause / resume EVERY source at the same moment of the shared clock (there is no per-source pause).
    public func pause() { timeline.pause() }
    public func resume() { timeline.resume() }
    public var isPaused: Bool { timeline.isPaused }

    /// Ends the session for any cause through the single finalizer (files + sources.json + `finalized` event), once.
    public func stop(cause: StopCause = .button, request: String? = nil) async throws {
        let s = stream; stream = nil
        try? await s?.stopCapture()
        inputs.forEach { $0.stop() }; inputs = []
        await finalize(cause: cause, request: request)
    }
    private func finalize(cause: StopCause, request: String?) async {
        for k in cams { k.cap.stop() }                                                      // drained: no frame after this
        for x in extras { try? await x.stream?.stopCapture(); x.stream = nil }
        guard let w = queue.sync(execute: { writer }), let f = finalizer else { return }
        let xs = extras, cs = cams; extras = []; cams = []
        await f.finalize(cause: cause, request: request, finish: {
            try await w.finish()
            // the other files never make the primary recording fail; a problem is written in the manifest instead
            let end = w.lastEndTime
            for x in xs { do { _ = try await x.writer.finish(holdUntil: end) } catch { self.markLost(x.id, L10n.f("fișierul nu s-a închis: %@", "\(error.localizedDescription)")) } }
            for k in cs { do { _ = try await k.writer.finish(holdUntil: end) } catch { self.markLost(k.spec.uid, L10n.f("fișierul nu s-a închis: %@", "\(error.localizedDescription)")) } }
        }, writeManifest: {
            // offsets are known only after the last sample; fill them in before the manifest is written
            guard var m = self.manifest else { return }
            for k in m.audioTracks.indices { m.audioTracks[k].firstSampleOffsetSeconds = w.firstAudioOffset[m.audioTracks[k].id] }
            let start = w.sessionStartTime, lost = self.lostLock.withLock { self.lostVideo }
            var files: [SourcesManifest.VideoFile] = []
            if start.isValid {
                for x in xs where x.writer.frames > 0 {
                    files.append(.init(id: x.id, kind: .screen, name: x.name, file: x.writer.url.lastPathComponent, width: x.writer.size.w, height: x.writer.size.h, frames: x.writer.frames,
                                       firstFrameOffsetSeconds: (x.writer.firstPTS - start).seconds, durationSeconds: x.writer.durationSeconds, lost: lost[x.id]))
                }
                for k in cs where k.writer.frames > 0 {
                    files.append(.init(id: k.spec.uid, kind: .camera, name: k.spec.name, file: k.writer.url.lastPathComponent, width: k.writer.size.w, height: k.writer.size.h, frames: k.writer.frames,
                                       firstFrameOffsetSeconds: (k.writer.firstPTS - start).seconds, durationSeconds: k.writer.durationSeconds, lost: lost[k.spec.uid]))
                }
            }
            m.videoFiles = files
            try m.write(to: w.folder); self.manifest = m
        })
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid, let w = writer else { return }
        if type == .screen {
            let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
            guard let raw = att?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
            w.appendVideo(sb)
        } else if type == .audio {
            if let t = systemTrack { w.appendAudio(sb, track: t); onLevel?(t, ChannelExtractor.peak(sb)) }
        }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        // the source ended on its own (window closed, display gone): the same finalizer as every other stop (sources.json included)
        Task {
            self.inputs.forEach { $0.stop() }; self.inputs = []
            await self.finalize(cause: .sourceLost, request: nil)
            self.onStop?(error)
        }
    }
}


extension ScreenCapturer {
    /// One still image of a source for the "eye" preview. Not a recording: nothing is written and no stream stays open.
    public static func snapshot(source: SourceInfo, region: RegionSpec? = nil, maxWidth: Int = 640) async -> CGImage? {
        guard let c = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true) else { return nil }
        let filter: SCContentFilter
        let cfg = SCStreamConfiguration(); cfg.showsCursor = true
        var aspect = Double(max(source.width, 1)) / Double(max(source.height, 1))
        switch source.kind {
        case .display:
            guard let d = c.displays.first(where: { $0.displayID == source.id }) else { return nil }
            let me = c.applications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier }
            filter = SCContentFilter(display: d, excludingApplications: me, exceptingWindows: [])
            if let r = region, r.isValid { cfg.sourceRect = RegionMath.sourceRect(r, displayPoints: CGSize(width: source.pointsWidth, height: source.pointsHeight)); aspect = cfg.sourceRect.width / cfg.sourceRect.height }
        case .window:
            guard let w = c.windows.first(where: { $0.windowID == source.id }) else { return nil }
            filter = SCContentFilter(desktopIndependentWindow: w)
        }
        cfg.width = maxWidth; cfg.height = max(2, Int(Double(maxWidth) / aspect))
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
    }
}

/// Audio-only SCStream used to show the level of the system mix while no recording runs. Writes nothing.
public final class SystemAudioMonitor: NSObject, SCStreamOutput, @unchecked Sendable {
    private var stream: SCStream?
    private let queue = DispatchQueue(label: "sadrog.sysmeter")
    public var onLevel: (@Sendable (Float) -> Void)?
    public func start() async throws {
        let c = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        guard let d = c.displays.first else { throw CaptureError.sourceNotFound }
        let cfg = SCStreamConfiguration(); cfg.width = 2; cfg.height = 2; cfg.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        cfg.capturesAudio = true; cfg.sampleRate = 48000; cfg.channelCount = 2; cfg.excludesCurrentProcessAudio = true
        let s = SCStream(filter: SCContentFilter(display: d, excludingWindows: []), configuration: cfg, delegate: nil)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        stream = s; try await s.startCapture()
    }
    public func stop() async { let s = stream; stream = nil; try? await s?.stopCapture() }
    public func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio, sb.isValid { onLevel?(ChannelExtractor.peak(sb)) }
    }
}


/// One additional screen source: its own SCStream and file, on the session clock. Losing it does not stop the others.
final class ExtraScreen: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let id: String, name: String
    let writer: VideoFileWriter
    let queue = DispatchQueue(label: "sadrog.screen.extra")
    var stream: SCStream?
    var onLost: ((String) -> Void)?
    init(id: String, name: String, writer: VideoFileWriter) { self.id = id; self.name = name; self.writer = writer }
    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sb.isValid else { return }
        let att = (CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]])?.first
        guard let raw = att?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        writer.append(sb)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { onLost?(error.localizedDescription) }
}
