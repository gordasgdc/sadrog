// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import AVFoundation

/// One capture mode a camera really offers: frame size and a frame rate that fits one of that size's supported ranges.
public struct CameraFormatOption: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var width: Int, height: Int, fps: Int
    public var id: String { "\(width)x\(height)@\(fps)" }
    public var label: String { "\(width)×\(height) · \(fps) \(T("cadre/s"))" }
    public init(width: Int, height: Int, fps: Int) { self.width = width; self.height = height; self.fps = fps }
}

/// What a device format advertises: size and the frame-rate ranges it supports (read from the device, never invented).
public struct CameraFormatInfo: Equatable, Sendable {
    public var width: Int, height: Int, ranges: [ClosedRange<Double>]
    public init(width: Int, height: Int, ranges: [ClosedRange<Double>]) { self.width = width; self.height = height; self.ranges = ranges }
}

public enum CameraFormats {
    static let usual: [Int] = [24, 25, 30, 50, 60, 120]
    /// Choosable modes: for each size, the usual rates that some supported range covers, plus the range maximum when it is not a usual one.
    /// Largest first, then fastest. The same mode offered by several device formats appears once.
    public static func options(from formats: [CameraFormatInfo]) -> [CameraFormatOption] {
        var out = Set<CameraFormatOption>()
        for f in formats where f.width > 0 && f.height > 0 {
            for r in f.ranges {
                for u in usual where Double(u) >= r.lowerBound - 0.01 && Double(u) <= r.upperBound + 0.01 { out.insert(CameraFormatOption(width: f.width, height: f.height, fps: u)) }
                let top = Int(r.upperBound.rounded(.down)); if top >= 1, !usual.contains(top) { out.insert(CameraFormatOption(width: f.width, height: f.height, fps: top)) }
            }
        }
        return out.sorted { ($0.width * $0.height, $0.fps) > ($1.width * $1.height, $1.fps) }
    }
    /// Index of the device format that supports `choice`; nil when the camera does not offer it (the caller says so — it never picks another mode silently).
    public static func index(of choice: CameraFormatOption, in formats: [CameraFormatInfo]) -> Int? {
        formats.firstIndex { $0.width == choice.width && $0.height == choice.height && $0.ranges.contains { Double(choice.fps) >= $0.lowerBound - 0.01 && Double(choice.fps) <= $0.upperBound + 0.01 } }
    }
    public static func infos(of device: AVCaptureDevice) -> [CameraFormatInfo] {
        device.formats.map { f in
            let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
            return CameraFormatInfo(width: Int(d.width), height: Int(d.height), ranges: f.videoSupportedFrameRateRanges.map { $0.minFrameRate...$0.maxFrameRate })
        }
    }
    /// Modes of the camera with this id, read from the device without starting it (no access request, no capture).
    public static func options(forDeviceID uid: String) -> [CameraFormatOption] {
        guard let d = AVCaptureDevice(uniqueID: uid) else { return [] }
        return options(from: infos(of: d))
    }
}
