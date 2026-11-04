import XCTest
import AVFoundation
import CoreMedia
@testable import SadrogCore

/// The advanced export parameters, measured on the WRITTEN file. Source: a labelled SYNTHETIC 12 s clip of blocky noise (high entropy, so the encoder really is rate-limited)
/// with a white flash (5.0–5.2 s) and a 1 kHz tone pulse (5.0–5.1 s) at the same instant — the In/Out and sound-sync checks look for exactly those two events.
/// Tolerances: the encoder runs variable rate, so the AVERAGE rate is accepted within ±30 % of the request (measured spread is far smaller); key-frame distance within one frame
/// of the request; audio AAC rate within ±25 % (AAC encoders quantise to their own steps); events within 70 ms (flash width / AAC priming).
final class ExportAdvancedVerificationTests: XCTestCase {
    static let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG"
    var src: String { Self.root + "/synthetic/export_probe/probe12s.mov" }
    private func out(_ n: String) -> URL { URL(fileURLWithPath: Self.root + "/temp/advx-\(n)-\(UUID().uuidString).mov") }
    private let doc = CGSize(width: 1280, height: 720)
    private func project(_ a: Double = 0, _ d: Double = 12) -> SadrogProject { SadrogProject(name: "t", clips: [Clip(media: src, sourceStart: a, duration: d)]) }
    override func setUpWithError() throws { try XCTSkipUnless(FileManager.default.fileExists(atPath: src), "synthetic export probe") }

    struct M { var codec: String, w: Int, h: Int, fps: Double, vMbps: Double, aKbps: Double?, aRate: Double?, aCh: Int?, dur: Double, vDur: Double, aDur: Double?, syncGaps: [Double], firstSync: Double }
    private func measure(_ u: URL) async throws -> M {
        let a = AVURLAsset(url: u), v = try await a.loadTracks(withMediaType: .video)[0], au = try await a.loadTracks(withMediaType: .audio).first
        let fd = try await v.load(.formatDescriptions)[0], st = CMFormatDescriptionGetMediaSubType(fd)
        let size = try await v.load(.naturalSize)
        var aRate: Double?, aCh: Int?, aKbps: Double?, aDur: Double?
        if let au {
            let af = try await au.load(.formatDescriptions)[0]; let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(af)?.pointee
            aRate = asbd?.mSampleRate; aCh = asbd.map { Int($0.mChannelsPerFrame) }; aDur = try await au.load(.timeRange).duration.seconds
            aKbps = Double(try await Self.payloadBytes(a, au)) * 8 / max(0.001, aDur ?? 1) / 1000
        }
        // key frames: read the compressed samples and take the sync ones
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: v, outputSettings: nil); r.add(o); r.startReading()
        var syncs: [Double] = []
        while let b = o.copyNextSampleBuffer() {
            let at = (CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[CFString: Any]])?.first
            if at?[kCMSampleAttachmentKey_NotSync] as? Bool != true { syncs.append(CMSampleBufferGetPresentationTimeStamp(b).seconds) }
        }
        let vBytes = try await Self.payloadBytes(a, v), vd = try await v.load(.timeRange).duration.seconds
        let gaps = zip(syncs.dropFirst(), syncs).map { $0 - $1 }
        return M(codec: st == kCMVideoCodecType_HEVC ? "hevc" : (st == kCMVideoCodecType_H264 ? "h264" : "other"), w: Int(size.width), h: Int(size.height), fps: Double(try await v.load(.nominalFrameRate)),
                 vMbps: Double(vBytes) * 8 / max(0.001, vd) / 1e6, aKbps: aKbps, aRate: aRate, aCh: aCh, dur: try await a.load(.duration).seconds, vDur: try await v.load(.timeRange).duration.seconds, aDur: aDur,
                 syncGaps: gaps, firstSync: syncs.first ?? -1)
    }
    /// Bytes of the COMPRESSED samples of a track: the real size of its stream in the file (estimatedDataRate is only the container's guess).
    static func payloadBytes(_ a: AVAsset, _ t: AVAssetTrack) async throws -> Int {
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: nil); r.add(o); r.startReading()
        var n = 0; while let b = o.copyNextSampleBuffer() { n += CMSampleBufferGetTotalSampleSize(b) }; return n
    }
    private func meanLuma(_ u: URL, at t: Double) async throws -> Double {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: u)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero; g.maximumSize = CGSize(width: 160, height: 90)
        let img = try g.copyCGImage(at: CMTime(seconds: t, preferredTimescale: 600), actualTime: nil)
        guard let data = img.dataProvider?.data, let p = CFDataGetBytePtr(data) else { return -1 }
        let n = CFDataGetLength(data); var s = 0.0; var c = 0; for i in stride(from: 0, to: n - 3, by: 4) { s += Double(p[i]) * 0.3 + Double(p[i + 1]) * 0.59 + Double(p[i + 2]) * 0.11; c += 1 }
        return s / Double(max(1, c))
    }
    /// First time the exported sound goes above 0.1 (the 1 kHz pulse), read as decoded PCM.
    private func firstTone(_ u: URL) async throws -> Double {
        let a = AVURLAsset(url: u), t = try await a.loadTracks(withMediaType: .audio)[0]
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000])
        r.add(o); r.startReading()
        while let b = o.copyNextSampleBuffer() {
            let t0 = CMSampleBufferGetPresentationTimeStamp(b).seconds; guard let bb = CMSampleBufferGetDataBuffer(b) else { continue }
            var len = 0; var ptr: UnsafeMutablePointer<Int8>?; CMBlockBufferGetDataPointer(bb, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &len, dataPointerOut: &ptr)
            guard let p = ptr else { continue }
            let f = UnsafeRawPointer(p).assumingMemoryBound(to: Float.self)
            for i in stride(from: 0, to: len / 4, by: 2) where abs(f[i]) > 0.1 { return t0 + Double(i / 2) / 48000 }
        }
        return -1
    }
    private func export(_ p: SadrogProject, _ s: ExportSettings, range: ClosedRange<Double>? = nil, name: String = "x") async throws -> URL {
        let u = out(name); try await ProjectExporter.export(p, to: u, settings: s, documentSize: doc, documentFPS: 30, range: range); return u
    }

    func testBitrateRespectedWithinToleranceAcrossRequests() async throws {
        for req in [2.0, 6.0] {
            var s = ExportSettings(); s.videoMbps = req; s.keyframeSeconds = 1; s.audioKbps = 128
            let u = try await export(project(), s, name: "br"); defer { try? FileManager.default.removeItem(at: u) }
            let m = try await measure(u)
            XCTAssertEqual(m.vMbps, req, accuracy: req * 0.30, "requested \(req) Mb/s, measured \(m.vMbps)")
            print("ADVX bitrate request \(req) → measured \(m.vMbps) Mb/s")
        }
    }
    func testEffectiveParametersOnTheFile() async throws {
        var s = ExportSettings(); s.codec = .h264; s.videoMbps = 4; s.keyframeSeconds = 1; s.audioKbps = 96; s.size = .longSide(960); s.fps = 24
        let u = try await export(project(), s, name: "eff"); defer { try? FileManager.default.removeItem(at: u) }
        let m = try await measure(u)
        XCTAssertEqual(m.codec, "h264"); XCTAssertEqual(m.w, 960); XCTAssertEqual(m.h, 540); XCTAssertEqual(m.fps, 24, accuracy: 0.5)
        XCTAssertEqual(m.aRate, 48000); XCTAssertEqual(m.aCh, 2); XCTAssertEqual(m.aKbps ?? 0, 96, accuracy: 96 * 0.25, "AAC rate \(m.aKbps ?? -1)")
        XCTAssertEqual(m.dur, 12, accuracy: 0.15)
        XCTAssertFalse(m.syncGaps.isEmpty); XCTAssertLessThanOrEqual(m.syncGaps.max() ?? 99, 1.0 + 1.0 / 24 + 0.001, "key-frame interval ≤ 1 s (+1 frame): \(m.syncGaps.max() ?? -1)")
        print("ADVX effective: gaps max \(m.syncGaps.max() ?? -1) min \(m.syncGaps.min() ?? -1) aKbps \(m.aKbps ?? -1) vMbps \(m.vMbps)")
        var h = ExportSettings(); h.codec = .hevc; h.videoMbps = 4; h.keyframeSeconds = 2
        let uh = try await export(project(0, 6), h, name: "hevc"); defer { try? FileManager.default.removeItem(at: uh) }
        let mh = try await measure(uh); XCTAssertEqual(mh.codec, "hevc"); XCTAssertLessThanOrEqual(mh.syncGaps.max() ?? 99, 2.0 + 1.0 / 30 + 0.001)
    }
    func testInOutWithNonZeroStartKeepsEventsAndSoundInSync() async throws {
        var s = ExportSettings(); s.videoMbps = 6; s.keyframeSeconds = 1; s.audioKbps = 128
        let u = try await export(project(), s, range: 2...8, name: "io"); defer { try? FileManager.default.removeItem(at: u) }
        let m = try await measure(u)
        XCTAssertEqual(m.dur, 6, accuracy: 0.15); XCTAssertEqual(m.vDur, m.aDur ?? -9, accuracy: 0.1, "video and sound last the same")
        // the flash and the tone were at 5.0 s in the source → 3.0 s in the file
        let before = try await meanLuma(u, at: 2.93), inside = try await meanLuma(u, at: 3.07), inside2 = try await meanLuma(u, at: 3.13), after = try await meanLuma(u, at: 3.27)
        XCTAssertLessThan(before, 200); XCTAssertGreaterThan(inside, 235); XCTAssertGreaterThan(inside2, 235); XCTAssertLessThan(after, 200)
        let tone = try await firstTone(u); XCTAssertEqual(tone, 3.0, accuracy: 0.07, "tone at \(tone) s")
        print("ADVX in/out: tone at \(tone) s, luma \(before) \(inside) \(inside2) \(after)")
    }
    func testSourceWithoutSoundStillExportsWithAudioSettings() async throws {
        let v = Self.root + "/synthetic/video.mp4"; try XCTSkipUnless(FileManager.default.fileExists(atPath: v), "silent clip")
        let a = AVURLAsset(url: URL(fileURLWithPath: v)); let hasAudio = !(try await a.loadTracks(withMediaType: .audio)).isEmpty; try XCTSkipIf(hasAudio, "clip has sound")
        var s = ExportSettings(); s.audioKbps = 192; s.videoMbps = 2
        let u = out("silent"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(SadrogProject(name: "t", clips: [Clip(media: v, sourceStart: 0, duration: 1)]), to: u, settings: s, documentSize: doc, documentFPS: 30)
        let outAudio = try await AVURLAsset(url: u).loadTracks(withMediaType: .audio)
        XCTAssertTrue(outAudio.isEmpty, "no invented sound")
    }
}
