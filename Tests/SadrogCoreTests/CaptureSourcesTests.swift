import XCTest
import AVFoundation
import CoreMedia
@testable import SadrogCore

final class CaptureSourcesTests: XCTestCase {
    func testRegionMathLogicalPointsPixelsAndScales() {
        // BenQ 4K shown as 3840x2160 points @1x, laptop 1512x982 points @2x (pixels differ for the same normalised region)
        let r = RegionSpec(x: 0.25, y: 0.5, w: 0.5, h: 0.25)
        let benq = RegionMath.sourceRect(r, displayPoints: CGSize(width: 3840, height: 2160))
        XCTAssertEqual(benq, CGRect(x: 960, y: 1080, width: 1920, height: 540))
        let lap = RegionMath.sourceRect(r, displayPoints: CGSize(width: 1512, height: 982))
        XCTAssertEqual(lap.width, 756, accuracy: 1e-9)
        let px = RegionMath.pixels(points: lap.size, scale: 2)
        XCTAssertEqual(px.w, 1512); XCTAssertEqual(px.h % 2, 0)
        XCTAssertEqual(RegionMath.pixels(points: CGSize(width: 101, height: 51), scale: 1.5).w % 2, 0)
        XCTAssertEqual(RegionMath.region(rect: benq, displayPoints: CGSize(width: 3840, height: 2160)), r)
        XCTAssertNil(RegionMath.region(rect: CGRect(x: 3000, y: 0, width: 1200, height: 100), displayPoints: CGSize(width: 3840, height: 2160)))
        let o = RegionMath.output(source: (3840, 2160), maxLongSide: 1920)
        XCTAssertEqual(o.w, 1920); XCTAssertEqual(o.h, 1080)
        XCTAssertEqual(RegionMath.output(source: (1280, 720), maxLongSide: 1920).w, 1280)
    }

    func testValidatorNeverSubstitutes() {
        let srcs = [SourceInfo(id: 7, kind: .display, title: "BenQ", width: 3840, height: 2160)]
        let devs = [AvailableDevice(uid: "mix", name: "MixPre", inputChannels: 8)]
        var c = CaptureConfig()
        XCTAssertEqual(CaptureValidator.check(c, sources: srcs, devices: devs), [.noVideoSource])
        c.video = VideoSourceSpec(mode: .display, sourceID: 7, title: "BenQ")
        XCTAssertTrue(CaptureValidator.check(c, sources: srcs, devices: devs).isEmpty)
        c.video = VideoSourceSpec(mode: .display, sourceID: 9, title: "Altul")
        XCTAssertEqual(CaptureValidator.check(c, sources: srcs, devices: devs), [.videoSourceMissing("Altul")])
        c.video = VideoSourceSpec(mode: .region, sourceID: 7, title: "BenQ")
        XCTAssertEqual(CaptureValidator.check(c, sources: srcs, devices: devs), [.regionMissing])
        c.video = VideoSourceSpec(mode: .window, sourceID: 7, title: "w")   // an id of a display is not a window
        XCTAssertEqual(CaptureValidator.check(c, sources: srcs, devices: devs), [.videoSourceMissing("w")])
        c.video = VideoSourceSpec(mode: .display, sourceID: 7, title: "BenQ")
        c.audio = [AudioSourceSpec(kind: .input, deviceUID: "gone", deviceName: "Mic", channels: [1]),
                   AudioSourceSpec(kind: .input, deviceUID: "mix", deviceName: "MixPre", channels: []),
                   AudioSourceSpec(kind: .input, deviceUID: "mix", deviceName: "MixPre", channels: [9]),
                   AudioSourceSpec(kind: .input, deviceUID: "mix", deviceName: "MixPre", channels: [1, 2]),
                   AudioSourceSpec(kind: .input, deviceUID: "mix", deviceName: "MixPre", channels: [2, 1]),
                   AudioSourceSpec(kind: .system, deviceName: "Calculator"), AudioSourceSpec(kind: .system, deviceName: "Calculator")]
        let issues = CaptureValidator.check(c, sources: srcs, devices: devs)
        XCTAssertTrue(issues.contains(.audioDeviceMissing(name: "Mic")))
        XCTAssertTrue(issues.contains(.noChannelsChosen(name: "MixPre")))
        XCTAssertTrue(issues.contains(.channelOutOfRange(name: "MixPre", channel: 9, available: 8)))
        XCTAssertTrue(issues.contains(.duplicateDeviceChannels(name: "MixPre")))
        XCTAssertTrue(issues.contains(.moreThanOneSystemAudio))
        c.audio[0].enabled = false   // disabled rows are not validated
        XCTAssertFalse(CaptureValidator.check(c, sources: srcs, devices: devs).contains(.audioDeviceMissing(name: "Mic")))
    }

    func testManifestRoundTrip() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-m-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: f) }
        let m = SourcesManifest(video: VideoSourceSpec(mode: .region, sourceID: 1, title: "BenQ", region: RegionSpec(x: 0, y: 0, w: 0.5, h: 0.5)), sourcePixels: [1920, 1080], outputPixels: [1920, 1080], scale: 1,
                                audioTracks: [.init(index: 0, id: "system", kind: .system, deviceName: "Calculator", deviceUID: nil, channels: [], firstSampleOffsetSeconds: 0.02)])
        try m.write(to: f); XCTAssertEqual(try SourcesManifest.read(from: f), m)
    }

    static func audioBuffer(frames: Int, channels: Int, planar: Bool, pts: Double = 0, value: (Int, Int) -> Float) -> CMSampleBuffer {
        var flags: AudioFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        if planar { flags |= kAudioFormatFlagIsNonInterleaved }
        var d = AudioStreamBasicDescription(mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: flags, mBytesPerPacket: planar ? 4 : UInt32(4 * channels), mFramesPerPacket: 1,
                                            mBytesPerFrame: planar ? 4 : UInt32(4 * channels), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
        var fd: CMAudioFormatDescription?; CMAudioFormatDescriptionCreate(allocator: nil, asbd: &d, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
        var data = [Float](repeating: 0, count: frames * channels)
        for c in 0..<channels { for i in 0..<frames { data[planar ? c * frames + i : i * channels + c] = value(c, i) } }
        let bytes = data.count * 4; var bb: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: bytes, flags: 0, blockBufferOut: &bb)
        data.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: bb!, offsetIntoDestination: 0, dataLength: bytes) }
        var t = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48000), presentationTimeStamp: CMTime(seconds: pts, preferredTimescale: 48000), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        if planar {
            // planar buffers need per-channel descriptors; create via CMSampleBufferCreate with the whole block (each channel contiguous)
            CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        } else {
            CMSampleBufferCreate(allocator: nil, dataBuffer: bb, dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: fd, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sb)
        }
        return sb!
    }

    func testChannelExtractInterleavedAndPeak() throws {
        let sb = Self.audioBuffer(frames: 480, channels: 8, planar: false) { c, i in Float(c + 1) / 10 + Float(i) / 1_000_000 }
        let out = try XCTUnwrap(ChannelExtractor.extract(sb, channels: [3, 5]))
        XCTAssertEqual(CMSampleBufferGetNumSamples(out), 480)
        XCTAssertEqual(CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(out)!)!.pointee.mChannelsPerFrame, 2)
        var bb: CMBlockBuffer?; var abl = AudioBufferList()
        CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(out, bufferListSizeNeededOut: nil, bufferListOut: &abl, bufferListSize: MemoryLayout<AudioBufferList>.size, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &bb)
        let f = abl.mBuffers.mData!.assumingMemoryBound(to: Float.self)
        XCTAssertEqual(f[0], 0.3, accuracy: 1e-6); XCTAssertEqual(f[1], 0.5, accuracy: 1e-6)   // channels 3 and 5
        XCTAssertEqual(f[2 * 100], 0.3 + 100e-6, accuracy: 1e-6)
        XCTAssertNil(ChannelExtractor.extract(sb, channels: [9]))
        XCTAssertEqual(ChannelExtractor.peak(sb), 0.8, accuracy: 1e-3)
        let silent = Self.audioBuffer(frames: 480, channels: 2, planar: false) { _, _ in 0 }
        XCTAssertEqual(ChannelExtractor.peak(silent), 0)
    }

    func testWriterTwoSeparateAudioTracks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-2a-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let w = try RecordingWriter(destination: Destination(url: root), settings: RecordingSettings(width: 320, height: 180, fps: 30, audioTracks: [.init(id: "system", channels: 2), .init(id: "mix", channels: 1)]))
        XCTAssertEqual(w.audioOrder, ["system", "mix"])
        let helper = RecordingWriterTests()
        for i in 0..<90 {
            let before = w.counters.videoWritten; var tries = 0
            while w.counters.videoWritten == before && tries < 2000 { w.appendVideo(helper.makeFrame(i, w: 320, h: 180)); tries += 1; if w.counters.videoWritten == before { try await Task.sleep(nanoseconds: 2_000_000) } }
            let t = Double(i) / 30
            for (k, id) in ["system", "mix"].enumerated() {
                let sb = Self.audioBuffer(frames: 1600, channels: k == 0 ? 2 : 1, planar: false, pts: t) { _, j in sinf(Float(j) * (k == 0 ? 0.05 : 0.2)) * 0.3 }
                w.appendAudio(sb, track: id)
            }
        }
        try await w.finish()
        XCTAssertGreaterThan(w.counters.audioWrittenByTrack["system", default: 0], 60)
        XCTAssertGreaterThan(w.counters.audioWrittenByTrack["mix", default: 0], 60)
        let a = AVURLAsset(url: w.mediaURL)
        let at = try await a.loadTracks(withMediaType: .audio)
        XCTAssertEqual(at.count, 2)
    }

    func testStillScreenKeepsVideoAsLongAsAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-still-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let w = try RecordingWriter(destination: Destination(url: root), settings: RecordingSettings(width: 320, height: 180, fps: 30, audioTracks: [.init(id: "system", channels: 2)]))
        let helper = RecordingWriterTests()
        w.appendVideo(helper.makeFrame(0, w: 320, h: 180, duration: 10))   // SCK-style frame lasting until the next one (never came)
        for i in 0..<300 { w.appendAudio(Self.audioBuffer(frames: 480, channels: 2, planar: false, pts: Double(i) * 0.01) { _, j in sinf(Float(j) * 0.05) * 0.3 }, track: "system") }
        try await w.finish()
        let a = AVURLAsset(url: w.mediaURL)
        let v = try await a.loadTracks(withMediaType: .video)[0].load(.timeRange).duration.seconds
        let au = try await a.loadTracks(withMediaType: .audio)[0].load(.timeRange).duration.seconds
        XCTAssertGreaterThan(au, 2.5)
        XCTAssertEqual(v, au, accuracy: 0.2)
    }
}

final class WindowSizeTests: XCTestCase {
    /// A window on a 2× display: the size shown before recording (pixels) equals the capture-file size, not its points.
    func testWindowPixelsUseDisplayScale() {
        let w = SourceInfo(id: 1, kind: .window, title: "w", width: 700, height: 448, scale: 2)
        XCTAssertEqual(w.pixels.w, 1400); XCTAssertEqual(w.pixels.h, 896)
        XCTAssertEqual(RegionMath.output(source: w.pixels, maxLongSide: nil).w, 1400)
    }
}
