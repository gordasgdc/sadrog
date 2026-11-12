// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// A recording whose picture and sound say what time of the SOURCE they belong to: grey level = 10 + 20 × whole seconds, a 440 Hz tone.
enum RampRecording {
    static func make(duration: Double = 12, tone: Float = 440) async throws -> URL {
        guard FileManager.default.fileExists(atPath: "/Volumes/CristiGordas/TESTE") else { throw XCTSkip("external storage") }
        let url = URL(fileURLWithPath: "\(SyntheticRecording.root)/ramp-\(UUID().uuidString).mov")
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let vi = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 90])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: vi, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 90])
        let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
        w.add(vi); w.add(ai)
        guard w.startWriting() else { throw XCTSkip("cannot write synthetic media") }
        w.startSession(atSourceTime: .zero)
        let n = Int(duration * 48000)
        var pcm = [Int16](repeating: 0, count: n)
        for j in 0..<n { pcm[j] = Int16(12000 * sinf(Float(j) * 2 * .pi * tone / 48000)) }
        var blk: CMBlockBuffer?; let bytes = pcm.withUnsafeBytes { Data($0) }
        bytes.withUnsafeBytes { CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes.count, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: 0, blockBufferOut: &blk); CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: blk!, offsetIntoDestination: 0, dataLength: bytes.count) }
        var asbd = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked, mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var fmt: CMAudioFormatDescription?; CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fmt)
        var sb: CMSampleBuffer?; CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: blk!, formatDescription: fmt!, sampleCount: n, presentationTimeStamp: .zero, packetDescriptions: nil, sampleBufferOut: &sb)
        while !ai.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
        ai.append(sb!); ai.markAsFinished()
        for f in 0..<Int(duration * 30) {
            while !vi.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 1_000_000) }
            var pb: CVPixelBuffer?; CVPixelBufferCreate(nil, 160, 90, kCVPixelFormatType_32BGRA, nil, &pb)
            CVPixelBufferLockBaseAddress(pb!, [])
            memset(CVPixelBufferGetBaseAddress(pb!), Int32(10 + 20 * (f / 30)), CVPixelBufferGetDataSize(pb!))
            CVPixelBufferUnlockBaseAddress(pb!, [])
            ad.append(pb!, withPresentationTime: CMTime(value: CMTimeValue(f), timescale: 30))
        }
        vi.markAsFinished(); await w.finishWriting()
        guard w.status == .completed else { throw XCTSkip("synthetic media not written: \(String(describing: w.error))") }
        return url
    }
    /// Grey level (0…255) of the middle of the picture at `t`.
    static func grey(_ url: URL, at t: Double) async throws -> Double {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -Double(img.width) / 2, y: -Double(img.height) / 2, width: Double(img.width), height: Double(img.height)))
        return Double(px[1])
    }
    /// Mono float samples of the audio of `url` between `from` and `to` seconds (48 kHz).
    static func samples(_ url: URL, from: Double, to: Double) async throws -> [Float] {
        let asset = AVURLAsset(url: url); guard let t = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let r = try AVAssetReader(asset: asset)
        r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 48000), end: CMTime(seconds: to, preferredTimescale: 48000))
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000])
        r.add(o); r.startReading(); var out: [Float] = []
        while let b = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(b) {
            let n = CMBlockBufferGetDataLength(bb); var a = [Float](repeating: 0, count: n / 4)
            a.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: $0.baseAddress!) }; out += a
        }
        return out
    }
    /// Frequency (Hz) estimated from rising zero crossings.
    static func frequency(_ s: [Float]) -> Double {
        guard s.count > 4800 else { return 0 }
        var c = 0; for i in 1..<s.count where s[i - 1] < 0 && s[i] >= 0 { c += 1 }
        return Double(c) / (Double(s.count) / 48000)
    }
}

final class RetimeTests: XCTestCase {
    func clip(_ d: Double, src: Double = 0, media: String = "/x.mov") -> Clip { Clip(media: media, sourceStart: src, duration: d) }

    func testAcceptanceDurations() {
        // 60 s of source become 10 s at 6× and 120 s at 0.5×
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [clip(60)]))
        let id = e.project.clips[0].id
        XCTAssertTrue(e.setSpeed(clip: id, 6))
        XCTAssertEqual(e.project.clips[0].duration, 10, accuracy: 1e-9); XCTAssertEqual(e.project.clips[0].sourceSpan, 60, accuracy: 1e-9)
        XCTAssertEqual(e.project.timelineEnd, 10, accuracy: 1e-9)
        XCTAssertTrue(e.setSpeed(clip: id, 0.5))
        XCTAssertEqual(e.project.clips[0].duration, 120, accuracy: 1e-9); XCTAssertEqual(e.project.clips[0].sourceSpan, 60, accuracy: 1e-9)
        XCTAssertTrue(e.setSpeed(clip: id, 1)); XCTAssertEqual(e.project.clips[0].duration, 60, accuracy: 1e-9); XCTAssertEqual(e.project.clips[0].speed, 1)
    }
    func testClampAndNoOp() {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [clip(10)])); let id = e.project.clips[0].id
        XCTAssertFalse(e.setSpeed(clip: id, 1)); XCTAssertFalse(e.canUndo)
        XCTAssertTrue(e.setSpeed(clip: id, 1000)); XCTAssertEqual(e.project.clips[0].speed, 16)
        XCTAssertTrue(e.setSpeed(clip: id, 0)); XCTAssertEqual(e.project.clips[0].speed, 0.1)
        XCTAssertTrue(e.setSpeed(clip: id, .nan) == false || e.project.clips[0].speed == 1)
        XCTAssertEqual(Retime.label(0.25), "0.25×"); XCTAssertEqual(Retime.label(2), "2×"); XCTAssertEqual(Retime.label(1.5), "1.5×")
    }
    func testRippleShiftsFollowingClipsAndUndoIsOneStep() {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [clip(10), clip(10, media: "/y.mov")]))
        let a = e.project.clips[0].id, b = e.project.clips[1].id
        XCTAssertTrue(e.setSpeed(clip: a, 2))
        XCTAssertEqual(e.project.start(ofClip: b), 5); XCTAssertEqual(e.project.duration, 15)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.start(ofClip: b), 10); XCTAssertEqual(e.project.clips[0].speed, 1); XCTAssertFalse(e.canUndo)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.project.start(ofClip: b), 5)
    }
    func testHeldClipCannotBeRetimed() {
        var c = clip(3); c.held = true
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c]))
        XCTAssertEqual(e.retimeBlocker(ofClip: c.id), "held"); XCTAssertFalse(e.setSpeed(clip: c.id, 2))
    }
    func testSplitKeepsSourceContinuity() {
        // 12 s of source from 5 s, played at 4× = 3 s; cut after 1 s of timeline = 4 s of source
        var c = clip(3, src: 5); c.speed = 4
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c]))
        e.split(at: 1)
        let (a, b) = (e.project.clips[0], e.project.clips[1])
        XCTAssertEqual(a.sourceStart, 5); XCTAssertEqual(a.duration, 1, accuracy: 1e-9)
        XCTAssertEqual(b.sourceStart, 9, accuracy: 1e-9); XCTAssertEqual(b.duration, 2, accuracy: 1e-9); XCTAssertEqual(b.speed, 4)
        XCTAssertEqual(a.sourceSpan + b.sourceSpan, 12, accuracy: 1e-9)       // nothing lost, nothing repeated
        XCTAssertEqual(a.sourceStart + a.sourceSpan, b.sourceStart, accuracy: 1e-9)
    }
    func testTrimsUseSourceSeconds() {
        var c = clip(5, src: 10); c.speed = 2          // source 10…20
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c])); let id = c.id
        e.trimStart(clip: id, by: 1)                   // 1 s of timeline = 2 s of source
        XCTAssertEqual(e.project.clips[0].sourceStart, 12, accuracy: 1e-9); XCTAssertEqual(e.project.clips[0].duration, 4, accuracy: 1e-9)
        e.trimStart(clip: id, by: -100)                // cannot reveal material before the file start: 12 s of source = 6 s of timeline
        XCTAssertEqual(e.project.clips[0].sourceStart, 0, accuracy: 1e-9); XCTAssertEqual(e.project.clips[0].duration, 10, accuracy: 1e-9)
        e.trimEnd(clip: id, by: 2)
        XCTAssertEqual(e.project.clips[0].sourceSpan, 16, accuracy: 1e-9)
    }
    func testKeysCalloutsAndDetachedSoundScaleWithTheClip() {
        var c = clip(10, src: 2); c.transform = Transform(scale: 1); c.endTransform = Transform(scale: 2)
        c.motion = Motion(keys: [MotionKey(t: 4, transform: Transform(scale: 1.5))])
        var p = SadrogProject(name: "t", clips: [c])
        var k = Callout(start: 2, duration: 4); k.clipID = c.id; p.callouts = [k]
        let e = ProjectEditor(project: p)
        let layer = e.detachAudio(of: c.id); XCTAssertNotNil(layer)
        XCTAssertTrue(e.setSpeed(clip: c.id, 2))      // 10 s → 5 s
        XCTAssertEqual(e.project.clips[0].motion?.keys.first?.t ?? 0, 2, accuracy: 1e-9)           // the animation still spans the whole clip
        XCTAssertEqual(e.project.callouts[0].start, 1, accuracy: 1e-9); XCTAssertEqual(e.project.callouts[0].duration, 2, accuracy: 1e-9)
        let l = e.project.layers[0]
        XCTAssertEqual(l.speed, 2); XCTAssertEqual(l.duration, 5, accuracy: 1e-9); XCTAssertEqual(l.sourceStart, 2)
        XCTAssertTrue(e.detachedAudioInSync(l.id))     // sound and picture still cover the same source
    }
    func testIndependentLayerRefusesOverlapAndKeepsOthers() {
        var p = SadrogProject(name: "t", clips: [clip(30)])
        p.layers = [Layer(kind: .video, media: "/o.mov", start: 0, duration: 10), Layer(kind: .video, media: "/o2.mov", start: 12, duration: 5)]
        let e = ProjectEditor(project: p); let a = p.layers[0].id
        XCTAssertEqual(e.layerSpeedBlocker(a, speed: 0.5), "overlap")      // 20 s would run into the item at 12 s
        XCTAssertFalse(e.setSpeed(layer: a, 0.5)); XCTAssertEqual(e.project.layers[0].duration, 10)
        XCTAssertTrue(e.setSpeed(layer: a, 2)); XCTAssertEqual(e.project.layers[0].duration, 5); XCTAssertEqual(e.project.layers[1].start, 12)   // nothing else moved
    }
    func testPersistenceAndOldProjects() throws {
        var c = clip(5); c.speed = 3; c.speedMute = true
        var p = SadrogProject(name: "t", clips: [c]); p.keepPitch = false
        var l = Layer(kind: .audio, media: "/a.m4a", start: 0, duration: 4); l.speed = 0.5; p.layers = [l]
        let dir = URL(fileURLWithPath: "\(SyntheticRecording.root)/rt-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectStore.save(p, to: dir)
        let q = try ProjectStore.load(from: dir)
        XCTAssertEqual(q.clips[0].speed, 3); XCTAssertTrue(q.clips[0].speedMute); XCTAssertEqual(q.layers[0].speed, 0.5); XCTAssertFalse(q.keepPitch)
        XCTAssertEqual(q.formatVersion, SadrogProject.currentFormat); XCTAssertEqual(SadrogProject.currentFormat, 19)
        let old = #"{"formatVersion":17,"name":"old","clips":[{"id":"1836A1A2-E44E-455B-BBFF-ACA2019A18CD","media":"/x.mov","sourceStart":0,"duration":5}],"layers":[{"id":"1836A1A2-E44E-455B-BBFF-ACA2019A18CE","kind":"audio","media":"/y.m4a","start":0,"sourceStart":0,"duration":2,"transform":{}}]}"#
        let o = try JSONDecoder().decode(SadrogProject.self, from: Data(old.utf8))
        XCTAssertEqual(o.clips[0].speed, 1); XCTAssertEqual(o.layers[0].speed, 1); XCTAssertTrue(o.keepPitch); XCTAssertFalse(Retime.isRetimed(o))
        // a neutral clip does not write the new keys
        let js = String(data: try JSONEncoder().encode(clip(5)), encoding: .utf8)!
        XCTAssertFalse(js.contains("speed"))
    }
    func testRetimedProjectNeedsCompositing() {
        var c = clip(5); XCTAssertFalse(SadrogProject(name: "t", clips: [c]).needsCompositing)
        c.speed = 2; XCTAssertTrue(SadrogProject(name: "t", clips: [c]).needsCompositing)       // never exported by copying
    }
    func testTimeMaps() {
        XCTAssertEqual(Retime.source(start: 5, speed: 4, local: 1.5), 11); XCTAssertEqual(Retime.local(sourceStart: 5, speed: 4, source: 11), 1.5)
        XCTAssertEqual(Retime.duration(sourceSpan: 60, speed: 6), 10)
    }

    // MARK: export (real composition, synthetic recording)
    func testExportMapsPictureAndSoundOfARetimedClip() async throws {
        let src = try await RampRecording.make(duration: 12); defer { try? FileManager.default.removeItem(at: src) }
        var c = Clip(media: src.path, sourceStart: 0, duration: 12)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c])); c = e.project.clips[0]
        XCTAssertTrue(e.setSpeed(clip: c.id, 2))      // 12 s → 6 s
        let out = URL(fileURLWithPath: "\(SyntheticRecording.root)/rt-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(e.project, to: out)
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(d, 6, accuracy: 0.15)
        // output 1.25 s ↔ source 2.5 s (grey 10+20·2); output 4.25 s ↔ source 8.5 s (grey 10+20·8)
        let g1 = try await RampRecording.grey(out, at: 1.25), g2 = try await RampRecording.grey(out, at: 4.25)
        XCTAssertEqual(g1, 50, accuracy: 14); XCTAssertEqual(g2, 170, accuracy: 14)
        // sound: pitch kept (spectral) → ≈440 Hz; same duration as the picture
        let s = try await RampRecording.samples(out, from: 1, to: 4); XCTAssertEqual(RampRecording.frequency(s), 440, accuracy: 25)
        let ad = try await AVURLAsset(url: out).loadTracks(withMediaType: .audio).first?.load(.timeRange).duration.seconds ?? 0
        XCTAssertEqual(ad, 6, accuracy: 0.2)
    }
    func testExportVarispeedChangesPitchAndSlowMotionHoldsFrames() async throws {
        let src = try await RampRecording.make(duration: 6); defer { try? FileManager.default.removeItem(at: src) }
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: src.path, sourceStart: 0, duration: 6)]))
        let id = e.project.clips[0].id
        XCTAssertTrue(e.setSpeed(clip: id, 0.5)); e.setKeepPitch(false)        // 6 s → 12 s, pitch follows the speed
        let out = URL(fileURLWithPath: "\(SyntheticRecording.root)/rt-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(e.project, to: out)
        let d = try await AVURLAsset(url: out).load(.duration).seconds; XCTAssertEqual(d, 12, accuracy: 0.2)
        let g = try await RampRecording.grey(out, at: 5.0)                      // source 2.5 s → grey 50
        XCTAssertEqual(g, 50, accuracy: 14)
        let s = try await RampRecording.samples(out, from: 2, to: 8); XCTAssertEqual(RampRecording.frequency(s), 220, accuracy: 20)
    }
    func testSpeedMuteSilencesTheClip() async throws {
        let src = try await RampRecording.make(duration: 4); defer { try? FileManager.default.removeItem(at: src) }
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: src.path, sourceStart: 0, duration: 4)]))
        let id = e.project.clips[0].id
        XCTAssertTrue(e.setSpeed(clip: id, 2)); e.setSpeedMute(clip: id, true)
        let built = try await CompositionBuilder.buildFull(e.project)
        XCTAssertTrue(built.composition.tracks(withMediaType: .audio).isEmpty)
    }
}
