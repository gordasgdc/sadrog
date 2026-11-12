// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import VideoToolbox

/// Whether this Mac has a HARDWARE encoder for a codec at a picture size — asked from VideoToolbox by actually opening a session that
/// requires one (nothing is encoded). The export then requires the hardware encoder exactly when this says yes, so the label in the export
/// sheet is what is used, never a hope. Results are cached per codec and size.
public enum HardwareEncoder {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: Bool] = [:]
    public static func available(_ codec: ExportSettings.Codec, width: Int, height: Int) -> Bool {
        let key = "\(codec.rawValue)-\(width)x\(height)"
        lock.lock(); if let v = cache[key] { lock.unlock(); return v }; lock.unlock()
        var session: VTCompressionSession?
        let spec = [kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: kCFBooleanTrue] as CFDictionary
        let st = VTCompressionSessionCreate(allocator: nil, width: Int32(width), height: Int32(height), codecType: codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264,
                                            encoderSpecification: spec, imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session)
        if let session { VTCompressionSessionInvalidate(session) }
        let ok = st == noErr && session != nil
        lock.lock(); cache[key] = ok; lock.unlock()
        return ok
    }
}
