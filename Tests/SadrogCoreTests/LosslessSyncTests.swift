import XCTest
import AVFoundation
import ImageIO
@testable import SadrogCore

/// Lossless PNG+WAV as a complete delivery: non-zero In/Out, frame count and rate, sound start/length, an impulse that must line up with the picture change,
/// the manifest, and no partial result after an error or a cancel. Uses a synthetic clip made here (dark picture, white from T, a one-sample-burst click at T).
final class LosslessSyncTests: XCTestCase {
    static let root = "\(TestRoot.path)/temp"
    let T = 1.5, fps = 30.0, dur = 3.0
    private func makeClip(_ url: URL) async throws {
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        w.add(vi); w.add(ai); XCTAssertTrue(w.startWriting()); w.startSession(atSourceTime: .zero)
        let n = Int(dur * 48000); var pcm = [Int16](repeating: 0, count: n); for i in Int(T * 48000)..<Int(T * 48000) + 480 { pcm[i] = 30000 }
        var blk: CMBlockBuffer?; let bytes = pcm.withUnsafeBytes { Data($0) }
        bytes.withUnsafeBytes { CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blk); CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blk!, offsetIntoDestination: 0, dataLength: bytes.count) }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?; CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var sb: CMSampleBuffer?; CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blk!, formatDescription: fmt!, sampleCount: n, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
        while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        ai.append(sb!); ai.markAsFinished()
        for f in 0..<Int(dur * fps) {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?; CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, []); memset(CVPixelBufferGetBaseAddress(pb!), Double(f) / fps >= T - 1e-9 ? 255 : 20, CVPixelBufferGetDataSize(pb!)); CVPixelBufferUnlockBaseAddress(pb!, [])
            ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        vi.markAsFinished()
        await w.finishWriting(); XCTAssertEqual(w.status, .completed)
    }
    private func brightness(_ u: URL) -> Int {
        let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(u as CFURL, nil)!, 0, nil)!
        var px = [UInt8](repeating: 0, count: 4); let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1, height: 1)); return Int(px[0])
    }
    func testInOutFramesAudioStartImpulseAlignmentManifestAndNoPartialOnFailure() async throws {
        guard FileManager.default.fileExists(atPath: TestRoot.path) else { throw XCTSkip("external storage") }
        let clip = URL(fileURLWithPath: Self.root + "/sync-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: clip) }
        try await makeClip(clip)
        var p = SadrogProject(name: "t", clips: [Clip(media: clip.path, sourceStart: 0, duration: dur)]); p.canvas = DocumentFormat(width: 320, height: 180, fps: 30)
        p.rangeIn = 1.0; p.rangeOut = 2.5
        var s = ExportSettings(); s.mode = .lossless
        let folder = URL(fileURLWithPath: Self.root + "/ll-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: folder) }
        try await ProjectExporter.export(p, to: folder, settings: s, documentSize: CGSize(width: 320, height: 180), documentFPS: 30, range: p.exportRange)
        let m = try JSONDecoder().decode(LosslessManifest.self, from: Data(contentsOf: folder.appendingPathComponent("sequence.json")))
        XCTAssertEqual(m.frameCount, 45); XCTAssertEqual(m.fps, 30, accuracy: 0.01); XCTAssertEqual(m.width, 320); XCTAssertEqual(m.rangeStartSeconds, 1.0, accuracy: 1e-9); XCTAssertEqual(m.rangeEndSeconds, 2.5, accuracy: 1e-9)
        XCTAssertEqual(m.firstFrameTimeSeconds, 0, accuracy: 1e-3, "first exported frame is the frame at In"); XCTAssertEqual(m.lastFrameTimeSeconds, 44.0 / 30, accuracy: 1e-3)
        let pngs = try FileManager.default.contentsOfDirectory(atPath: folder.path).filter { $0.hasSuffix(".png") }; XCTAssertEqual(pngs.count, 45)
        XCTAssertLessThan(brightness(folder.appendingPathComponent("frame_000001.png")), 60, "frame at In = 1.0 s is still dark")
        XCTAssertGreaterThan(brightness(folder.appendingPathComponent("frame_000045.png")), 200, "last frame (2.5 s) is white")
        var firstWhite = 0; for k in 1...45 where brightness(folder.appendingPathComponent(String(format: "frame_%06d.png", k))) > 200 { firstWhite = k - 1; break }
        XCTAssertEqual(firstWhite, 15, "the picture change (1.5 s) sits 0.5 s after In")
        // audio: read the WAV back
        let a = AVURLAsset(url: folder.appendingPathComponent("audio.wav")); let adur = try await a.load(.duration).seconds; XCTAssertEqual(adur, 1.5, accuracy: 0.02)
        let atrack = try await a.loadTracks(withMediaType: .audio)[0]
        let r = try AVAssetReader(asset: a), o = AVAssetReaderTrackOutput(track: atrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000])
        r.add(o); XCTAssertTrue(r.startReading()); var samples: [Float] = []
        while let b = o.copyNextSampleBuffer() { var len = 0; var ptr: UnsafeMutablePointer<Int8>?; let bb = CMSampleBufferGetDataBuffer(b)!; CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            samples += UnsafeBufferPointer(start: UnsafeRawPointer(ptr!).assumingMemoryBound(to: Float.self), count: len / 4) }
        let frames = samples.count / 2; XCTAssertEqual(Double(frames) / 48000, 1.5, accuracy: 0.02); XCTAssertEqual(m.audioFrames.map(Double.init) ?? 0, Double(frames), accuracy: 2)
        let first = (0..<frames).first { abs(samples[$0 * 2]) > 0.3 } ?? -1
        XCTAssertGreaterThan(first, 0); let tA = Double(first) / 48000
        XCTAssertEqual(tA, 0.5, accuracy: 0.01, "impulse 0.5 s after In, not shifted by the In offset"); XCTAssertEqual(tA, Double(firstWhite) / 30, accuracy: 1.0 / 30, "sound and picture change line up within one frame")
        XCTAssertGreaterThan(abs(samples[0]) + abs(samples[1]) + abs(samples[100]), -1)
        // no partial result: an existing destination is refused, and a cancelled export leaves no folder
        do { try await ProjectExporter.export(p, to: folder, settings: s, documentSize: CGSize(width: 320, height: 180), documentFPS: 30, range: p.exportRange); XCTFail("must refuse an existing folder") } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("sequence.json").path), "the refused export did not touch the finished one")
        let f2 = URL(fileURLWithPath: Self.root + "/ll-c-\(UUID().uuidString)")
        let t = Task { try await ProjectExporter.export(p, to: f2, settings: s, documentSize: CGSize(width: 320, height: 180), documentFPS: 30, range: p.exportRange) }
        t.cancel(); _ = try? await t.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: f2.path), "cancel leaves no partial folder")
    }
}
