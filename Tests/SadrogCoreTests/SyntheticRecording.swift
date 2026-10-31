// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// A synthetic recording for identity tests: a dark picture and N mono audio tracks, each a constant tone of its own amplitude
/// (so the track order of a file can be told apart by measuring). Written under the external test area (storage policy), removed by the caller.
enum SyntheticRecording {
    static let root = "\(TestRoot.path)/temp"
    static func make(amplitudes: [Float], duration: Double = 3) async throws -> URL {
        guard FileManager.default.fileExists(atPath: TestRoot.path) else { throw XCTSkip("external storage") }
        let url = URL(fileURLWithPath: "\(root)/idsyn-\(UUID().uuidString).mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
        let ais = amplitudes.map { _ in AVAssetWriterInput(mediaType: .audio, outputSettings: settings) }
        w.add(vi); ais.forEach { w.add($0) }
        guard w.startWriting() else { throw XCTSkip("cannot write synthetic media") }
        w.startSession(atSourceTime: .zero)
        let n = Int(duration * 48000)
        for (i, ai) in ais.enumerated() {
            var pcm = [Int16](repeating: 0, count: n); let a = amplitudes[i]
            for j in 0..<n { pcm[j] = Int16(Float(20000) * a * sinf(Float(j) * 2 * .pi * (220 + Float(i) * 110) / 48000)) }
            var blk: CMBlockBuffer?; let bytes = pcm.withUnsafeBytes { Data($0) }
            bytes.withUnsafeBytes { CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blk); CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blk!, offsetIntoDestination: 0, dataLength: bytes.count) }
            var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
            var fmt: CMAudioFormatDescription?; CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
            var sb: CMSampleBuffer?; CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blk!, formatDescription: fmt!, sampleCount: n, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
            while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            ai.append(sb!); ai.markAsFinished()
        }
        for f in 0..<Int(duration * 30) {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?; CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, []); memset(CVPixelBufferGetBaseAddress(pb!), 20, CVPixelBufferGetDataSize(pb!)); CVPixelBufferUnlockBaseAddress(pb!, [])
            ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        vi.markAsFinished()
        await w.finishWriting()
        guard w.status == .completed else { throw XCTSkip("synthetic media not written: \(String(describing: w.error))") }
        return url
    }
    /// Volume the audio mix applies to a composition track at `t` seconds (1 when the track has no parameters).
    static func volume(_ mix: AVAudioMix?, track: CMPersistentTrackID, at t: Double) -> Float {
        for ip in mix?.inputParameters ?? [] where ip.trackID == track {
            var v: Float = 1, e: Float = 1; var r = CMTimeRange()
            if ip.getVolumeRamp(for: CMTime(seconds: t, preferredTimescale: 6000), startVolume: &v, endVolume: &e, timeRange: &r) { return v }
        }
        return 1
    }
}
