// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation
import Foundation

/// Writes one VIDEO source into its own file (a camera, or an additional screen): H.264 at the source's own size, fragmented like the
/// screen recording. With a `timeline` (a real session) every frame is placed on the session clock: frames before the common start or inside a
/// pause are dropped and later ones are shifted back by the paused time, exactly like the other files — so the editor places the file by
/// `firstPTS − origin` without any invented offset. Without a timeline (tests) host times are used as they are. Fed from one queue.
public final class VideoFileWriter {
    public let url: URL
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    /// First / last written frame, in session time (host time when there is no timeline).
    public private(set) var firstPTS = CMTime.invalid
    public private(set) var lastPTS = CMTime.invalid
    public private(set) var frames = 0
    public private(set) var dropped = 0
    public private(set) var size = (w: 0, h: 0)
    private var lastFrame: CMSampleBuffer?
    private let fps: Int
    private let timeline: CaptureTimeline?
    public init(url: URL, fps: Int = 30, timeline: CaptureTimeline? = nil) { self.url = url; self.fps = fps; self.timeline = timeline }

    public func append(_ raw: CMSampleBuffer) {
        guard raw.isValid, let fd = CMSampleBufferGetFormatDescription(raw) else { dropped += 1; return }
        let host = CMSampleBufferGetPresentationTimeStamp(raw)
        var sb = raw, pts = host
        if let timeline {
            guard let t = timeline.map(host) else { return }                         // before the start or paused: not a drop, just not recorded
            if t != host { guard let s = raw.shifted(by: host - t) else { dropped += 1; return }; sb = s }
            pts = t
        }
        if writer == nil {
            let d = CMVideoFormatDescriptionGetDimensions(fd)
            guard d.width > 0, d.height > 0, let w = try? AVAssetWriter(url: url, fileType: .mov) else { dropped += 1; return }
            w.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
            let i = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: Int(d.width), AVVideoHeightKey: Int(d.height),
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(Int(d.width) * Int(d.height) * 4, 60_000_000), AVVideoExpectedSourceFrameRateKey: fps, AVVideoMaxKeyFrameIntervalKey: fps * 2]])
            i.expectsMediaDataInRealTime = true
            guard w.canAdd(i) else { dropped += 1; return }
            w.add(i)
            guard w.startWriting() else { dropped += 1; return }
            w.startSession(atSourceTime: pts)
            writer = w; input = i; firstPTS = pts; size = (Int(d.width), Int(d.height))
        }
        guard let i = input, i.isReadyForMoreMediaData else { dropped += 1; return }
        if lastPTS.isValid, CMTimeCompare(pts, lastPTS) <= 0 { dropped += 1; return }            // times must increase
        if i.append(sb) { frames += 1; lastPTS = pts; lastFrame = sb } else { dropped += 1 }
    }

    /// Duration covered: from the first frame to the end of the last one.
    public var durationSeconds: Double { frames == 0 ? 0 : (lastPTS - firstPTS).seconds + 1 / Double(max(fps, 1)) }

    /// A screen that does not change sends no frames: repeat the last frame at `end` (session time) so the file lasts as long as the session.
    func holdLastFrame(until end: CMTime) {
        guard let lf = lastFrame, let i = input, end.isValid, CMTimeCompare(end - lastPTS, CMTime(value: 1, timescale: 4)) > 0 else { return }
        guard let c = lf.shifted(by: lastPTS - end) else { return }
        var tries = 0
        while !i.isReadyForMoreMediaData && tries < 200 { Thread.sleep(forTimeInterval: 0.005); tries += 1 }
        if i.isReadyForMoreMediaData, i.append(c) { lastPTS = end; frames += 1 }
    }

    /// Closes the file (optionally holding the last frame until `holdUntil`). No frame at all → no file (removed), returns false.
    @discardableResult public func finish(holdUntil: CMTime? = nil) async throws -> Bool {
        guard let w = writer, let i = input else { try? FileManager.default.removeItem(at: url); return false }
        if let h = holdUntil { holdLastFrame(until: h) }
        i.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed else { throw w.error ?? CocoaError(.fileWriteUnknown) }
        return true
    }
}
public typealias CameraWriter = VideoFileWriter

public enum CameraError: Error, LocalizedError {
    case notFound(String), notAllowed, cannotOpen(String)
    public var errorDescription: String? {
        switch self {
        case .notFound(let n): return L10n.f("Camera „%@” nu este disponibilă", "\(n)")
        case .notAllowed: return T("SADROG nu are acces la cameră")
        case .cannotOpen(let w): return L10n.f("Camera nu poate fi pornită: %@", "\(w)")
        }
    }
}

/// Reads the CHOSEN camera only (by its unique id; never another one) and hands every frame to `onFrame`, on one queue.
/// Starts only when a recording starts with a camera chosen; nothing here runs when the app opens.
public final class CameraCapture: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    public static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .video) }
    public static func list() -> [CameraSpec] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera], mediaType: .video, position: .unspecified)
            .devices.map { CameraSpec(uid: $0.uniqueID, name: $0.localizedName) }
    }

    private let session = AVCaptureSession()
    public let queue = DispatchQueue(label: "sadrog.camera")
    public var onFrame: ((CMSampleBuffer) -> Void)?
    public var onLost: ((String) -> Void)?
    private var observers: [NSObjectProtocol] = []
    private let device: AVCaptureDevice

    public init(spec: CameraSpec) throws {
        guard Self.authorization == .authorized else { throw CameraError.notAllowed }
        guard let d = AVCaptureDevice(uniqueID: spec.uid) else { throw CameraError.notFound(spec.name) }
        device = d
        super.init()
        session.beginConfiguration()
        session.sessionPreset = .high
        if let want = spec.format {
            // an explicit mode: take it from the device's own list or fail loudly — never record in a mode the user did not choose
            guard let i = CameraFormats.index(of: want, in: CameraFormats.infos(of: d)) else { throw CameraError.cannotOpen(L10n.f("modul %@ nu este oferit de această cameră", want.label)) }
            do {
                try d.lockForConfiguration()
                d.activeFormat = d.formats[i]
                let dur = CMTime(value: 1, timescale: CMTimeScale(want.fps))
                d.activeVideoMinFrameDuration = dur; d.activeVideoMaxFrameDuration = dur
                d.unlockForConfiguration()
            } catch { throw CameraError.cannotOpen(error.localizedDescription) }
            // macOS has no input-priority preset; whether the session keeps this format on a real camera is NOT verified here (no camera was opened)
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: d) } catch { throw CameraError.cannotOpen(error.localizedDescription) }
        guard session.canAddInput(input) else { throw CameraError.cannotOpen(T("intrarea nu poate fi adăugată")) }
        session.addInput(input)
        let out = AVCaptureVideoDataOutput()
        out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw CameraError.cannotOpen(T("ieșirea nu poate fi adăugată")) }
        session.addOutput(out)
        session.commitConfiguration()
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: d, queue: nil) { [weak self] _ in self?.onLost?(T("camera a fost deconectată")) })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            self?.onLost?((n.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? T("eroare de cameră")) })
    }
    public func start() { queue.async { [session] in session.startRunning() } }
    /// Stops the camera; returns after the last frame was delivered (the queue is drained).
    public func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers = []; let s = session; queue.sync { s.stopRunning() } }
    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        readyLock.withLock { seen += 1 }
        onFrame?(sb)
    }
    private let readyLock = NSLock()
    private var seen = 0
    /// Frames are arriving (≥ 10) AND the camera has finished adjusting exposure and white balance. Starting the camera alone does not
    /// guarantee a stable picture; this is checked, not assumed.
    public var isReady: Bool {
        let n = readyLock.withLock { seen }
        return n >= 10 && !device.isAdjustingExposure && !device.isAdjustingWhiteBalance
    }
}
