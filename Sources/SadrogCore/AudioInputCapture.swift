// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import AVFoundation
import CoreMedia

public enum AudioInputError: Error, Equatable, LocalizedError {
    case deviceMissing(String), permissionDenied, notDetermined, cannotOpen(String)
    public var errorDescription: String? {
        switch self {
        case .deviceMissing(let n): return L10n.f("Dispozitivul „%@” nu este disponibil.", "\(n)")
        case .permissionDenied: return T("Permisiunea pentru microfon este refuzată (Setări de sistem → Confidențialitate → Microfon).")
        case .notDetermined: return T("Permisiunea pentru microfon nu a fost încă acordată.")
        case .cannotOpen(let m): return L10n.f("Nu pot deschide intrarea audio: %@", "\(m)")
        }
    }
}

/// One AVCaptureSession per input row. Output goes ONLY to the sample-buffer delegate (no playback → no feedback).
/// Used both for the level meter (no recording) and for recording; buffers are reduced to the row's chosen channels.
public final class AudioInputCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public let spec: AudioSourceSpec
    public var onBuffer: (@Sendable (CMSampleBuffer) -> Void)?
    public var onLevel: (@Sendable (Float) -> Void)?
    public var onLost: (@Sendable (String) -> Void)?
    private let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "sadrog.audioin")
    private let device: AVCaptureDevice
    private var observers: [NSObjectProtocol] = []

    public static var authorization: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }
    public static func requestAccess() async -> Bool { await AVCaptureDevice.requestAccess(for: .audio) }

    public init(spec: AudioSourceSpec) throws {
        self.spec = spec
        guard let uid = spec.deviceUID, let d = AVCaptureDevice(uniqueID: uid) else { throw AudioInputError.deviceMissing(spec.deviceName) }
        switch Self.authorization { case .denied, .restricted: throw AudioInputError.permissionDenied; case .notDetermined: throw AudioInputError.notDetermined; default: break }
        device = d
        super.init()
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: d) } catch { throw AudioInputError.cannotOpen(error.localizedDescription) }
        guard session.canAddInput(input) else { throw AudioInputError.cannotOpen(T("intrarea nu poate fi adăugată")) }
        session.addInput(input)
        let out = AVCaptureAudioDataOutput()
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw AudioInputError.cannotOpen(T("ieșirea nu poate fi adăugată")) }
        session.addOutput(out)
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: d, queue: nil) { [weak self] _ in self?.onLost?("dispozitivul a fost deconectat") })
        observers.append(NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
            self?.onLost?((n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? T("eroare de captură")) })
    }

    public func start() throws { queue.async { [session] in session.startRunning() } }
    public func stop() { observers.forEach(NotificationCenter.default.removeObserver); observers = []; let s = session; queue.async { s.stopRunning() } }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sb: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard sb.isValid else { return }
        let picked: CMSampleBuffer
        if spec.channels.isEmpty { picked = sb } else if let x = ChannelExtractor.extract(sb, channels: spec.channels) { picked = x } else { return }   // unsupported format → nothing, never a wrong channel
        onLevel?(ChannelExtractor.peak(picked))
        onBuffer?(picked)
    }
}
