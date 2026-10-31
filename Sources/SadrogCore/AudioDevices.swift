// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CoreAudio
import CoreMedia
import AudioToolbox

/// Read-only CoreAudio enumeration. Never changes defaults or device settings.
public enum AudioDevices {
    private static func string(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String? {
        var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var v: Unmanaged<CFString>?; var sz = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, &v) == 0, let r = v else { return nil }
        return r.takeRetainedValue() as String
    }
    private static func inputChannels(_ id: AudioObjectID) -> Int {
        var a = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: kAudioObjectPropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &a, 0, nil, &sz) == 0, sz > 0 else { return 0 }
        let p = UnsafeMutableRawPointer.allocate(byteCount: Int(sz), alignment: 16); defer { p.deallocate() }
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &sz, p) == 0 else { return 0 }
        return UnsafeMutableAudioBufferListPointer(p.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
    /// Devices with at least one input channel.
    public static func inputs() -> [AvailableDevice] {
        var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var sz: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz) == 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(sz) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids) == 0 else { return [] }
        return ids.compactMap { id in
            let n = inputChannels(id); guard n > 0, let uid = string(id, kAudioDevicePropertyDeviceUID) else { return nil }
            return AvailableDevice(uid: uid, name: string(id, kAudioObjectPropertyName) ?? uid, inputChannels: n)
        }
    }
}

/// Picks channels out of an interleaved or planar Float32 LPCM buffer and builds a new buffer (same timing).
public enum ChannelExtractor {
    public static func extract(_ sb: CMSampleBuffer, channels: [Int]) -> CMSampleBuffer? {
        guard !channels.isEmpty, let fd = CMSampleBufferGetFormatDescription(sb),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM, asbd.mBitsPerChannel == 32, asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return nil }
        let n = CMSampleBufferGetNumSamples(sb); let total = Int(asbd.mChannelsPerFrame)
        guard n > 0, channels.allSatisfy({ $0 >= 1 && $0 <= total }) else { return nil }
        let planar = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16); defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self)
        var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == 0 else { return nil }
        let list = UnsafeMutableAudioBufferListPointer(abl)
        var out = [Float](repeating: 0, count: n * channels.count)
        for (k, c) in channels.enumerated() {
            for i in 0..<n {
                if planar { out[i * channels.count + k] = list[c - 1].mData!.assumingMemoryBound(to: Float.self)[i] }
                else { out[i * channels.count + k] = list[0].mData!.assumingMemoryBound(to: Float.self)[i * total + (c - 1)] }
            }
        }
        var d = AudioStreamBasicDescription(mSampleRate: asbd.mSampleRate, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels.count), mFramesPerPacket: 1, mBytesPerFrame: UInt32(4 * channels.count), mChannelsPerFrame: UInt32(channels.count), mBitsPerChannel: 32, mReserved: 0)
        var nfd: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: nil, asbd: &d, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &nfd) == 0, let nfd else { return nil }
        let bytes = out.count * 4
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb) == 0, let bb else { return nil }
        guard out.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb, offsetIntoDestination: 0, dataLength: bytes) }) == 0 else { return nil }
        var t = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sb), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sb), decodeTimeStamp: .invalid)
        var res: CMSampleBuffer?
        var cnt = CMItemCount(n)
        guard CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: nfd, sampleCount: cnt, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &res) == 0 else { return nil }
        _ = cnt; cnt = 0
        return res
    }
    /// Peak (0…1) of all samples in an LPCM float buffer — the real signal behind the level meter.
    public static func peak(_ sb: CMSampleBuffer) -> Float {
        guard let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, asbd.mBitsPerChannel == 32 else { return 0 }
        var size = 0
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: &size, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
        let raw = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16); defer { raw.deallocate() }
        let abl = raw.assumingMemoryBound(to: AudioBufferList.self); var block: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sb, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == 0 else { return 0 }
        var p: Float = 0
        for b in UnsafeMutableAudioBufferListPointer(abl) { let c = Int(b.mDataByteSize) / 4; guard let d = b.mData?.assumingMemoryBound(to: Float.self) else { continue }; for i in 0..<c { p = max(p, abs(d[i])) } }
        return min(p, 1)
    }
}
