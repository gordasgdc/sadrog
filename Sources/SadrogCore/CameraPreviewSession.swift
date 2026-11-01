// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import AVFoundation

/// A live preview of one camera, opened only on request and closed with `stop()`: it has no outputs and writes nothing, it only feeds a preview layer.
/// It never asks for camera access (the caller does, after the user's click) and never picks a mode the user did not choose.
public final class CameraPreviewSession: @unchecked Sendable {
    public let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sadrog.camera.preview")
    private var observers: [NSObjectProtocol] = []
    private var stopped = false
    /// Called on an arbitrary queue: `.live` when the camera delivers, `.failed`/`.absent` when it stops being available.
    public var onState: (@Sendable (CameraPreviewState) -> Void)?

    public init(uid: String, format: CameraFormatOption?) throws {
        guard CameraCapture.authorization == .authorized else { throw CameraError.notAllowed }
        guard let d = AVCaptureDevice(uniqueID: uid) else { throw CameraError.notFound(uid) }
        session.beginConfiguration()
        if let want = format {
            guard let i = CameraFormats.index(of: want, in: CameraFormats.infos(of: d)) else {
                session.commitConfiguration(); throw CameraError.cannotOpen(L10n.f("modul %@ nu este oferit de această cameră", want.label))
            }
            do {
                try d.lockForConfiguration()
                d.activeFormat = d.formats[i]
                let dur = CMTime(value: 1, timescale: CMTimeScale(want.fps))
                d.activeVideoMinFrameDuration = dur; d.activeVideoMaxFrameDuration = dur
                d.unlockForConfiguration()
            } catch { session.commitConfiguration(); throw CameraError.cannotOpen(error.localizedDescription) }
        }
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: d) } catch { session.commitConfiguration(); throw CameraError.cannotOpen(error.localizedDescription) }
        guard session.canAddInput(input) else { session.commitConfiguration(); throw CameraError.cannotOpen(T("intrarea nu poate fi adăugată")) }
        session.addInput(input)
        session.commitConfiguration()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: AVCaptureSession.didStartRunningNotification, object: session, queue: nil) { [weak self] _ in self?.onState?(.live) })
        observers.append(nc.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: d, queue: nil) { [weak self] _ in self?.onState?(.absent) })
        observers.append(nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            self?.onState?(.failed((n.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? T("eroare de cameră"))) })
        observers.append(nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] _ in
            self?.onState?(.failed(T("camera este folosită de altă aplicație sau a fost întreruptă"))) })
    }
    public func start() { queue.async { [session] in session.startRunning() } }
    /// Stops the camera and releases the device; returns when it is stopped. Safe to call more than once.
    public func stop() {
        guard !stopped else { return }
        stopped = true
        observers.forEach(NotificationCenter.default.removeObserver); observers = []
        let s = session
        queue.sync { s.stopRunning(); for i in s.inputs { s.removeInput(i) } }
    }
    deinit { stop() }
}
