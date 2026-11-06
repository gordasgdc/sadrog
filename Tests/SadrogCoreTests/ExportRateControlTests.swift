import XCTest
import AVFoundation
import CoreMedia
@testable import SadrogCore

/// Rate control of the compressed export (constant quality, average rate, size target), key frames, colour tags and the repaired 'medium' tier — all measured on the WRITTEN file.
/// The pure rules (priority between controls, size-target arithmetic, old presets) need no media.
final class ExportRateControlTests: XCTestCase {
    static let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG"
    var probe: String { Self.root + "/synthetic/export_probe/probe12s.mov" }
    var hd: String { Self.root + "/synthetic/preset/hd.mov" }
    private func out(_ n: String) -> URL { URL(fileURLWithPath: Self.root + "/temp/rc-\(n)-\(UUID().uuidString).mov") }
    private func project(_ media: String, _ d: Double = 12) -> SadrogProject { SadrogProject(name: "t", clips: [Clip(media: media, sourceStart: 0, duration: d)]) }
    private let doc = CGSize(width: 1280, height: 720)

    // MARK: pure rules
    func testRatePriorityAndLegacyMapping() {
        var s = ExportSettings()
        XCTAssertEqual(s.videoRate(duration: 60), .quality(ExportSettings.QualityStep.high.value), "a new export is constant quality")
        s.quality = nil; s.tier = .high; XCTAssertEqual(s.videoRate(duration: 60), .quality(ExportSettings.QualityStep.maximum.value), "an old 'high' preset keeps a high quality")
        s.tier = .medium; XCTAssertEqual(s.videoRate(duration: 60), .quality(ExportSettings.QualityStep.balanced.value))
        s.quality = 0.01; XCTAssertEqual(s.videoRate(duration: 60), .quality(0.2), "clamped to the encoder's useful range")
        s.targetMB = 100; if case .bitrate = s.videoRate(duration: 60) {} else { XCTFail("a size target wins over a quality") }
        s.videoMbps = 6; XCTAssertEqual(s.videoRate(duration: 60), .bitrate(6), "an explicit rate wins over everything")
    }
    func testSizeTargetArithmeticAccountsForSoundAndOverhead() {
        var s = ExportSettings(); s.targetMB = 120; s.audioKbps = 128
        let mbps = s.targetBitrateMbps(duration: 600)!          // 120 MB over 10 minutes
        let total = (mbps * 1e6 + 128_000) / 8 * 600           // what the encoder + sound would write, in bytes
        XCTAssertEqual(total / 1e6, 120 * 0.985, accuracy: 0.5, "the budget leaves ~1.5 % for the container")
        s.targetMB = 1; XCTAssertEqual(s.targetBitrateMbps(duration: 6000)!, ExportSettings.videoMbpsRange.lowerBound, "an unreachable target is clamped, and the plan says so")
        XCTAssertNil(ExportSettings().targetBitrateMbps(duration: 60))
    }
    func testOldPresetsWithoutRateControlStillDecode() throws {
        let json = #"{"presets":[{"id":"user-1","name":"Vechi","mode":"compressed","codec":"h264","tier":"medium","proRes":"p422","longSide":1280,"builtIn":false}],"defaultID":"user-1"}"#
        let u = URL(fileURLWithPath: Self.root + "/temp/rc-old-\(UUID().uuidString).json"); try Data(json.utf8).write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        let st = ExportPresetStore(url: u), s = st.defaultSettings
        XCTAssertNil(s.quality); XCTAssertNil(s.targetMB); XCTAssertEqual(s.size, .longSide(1280))
        XCTAssertEqual(s.videoRate(duration: 60), .quality(ExportSettings.QualityStep.balanced.value))
    }
    func testBuiltInIdsAreStableAndTutorialIsFirst() {
        let ids = ExportPreset.builtIns.map(\.id)
        for old in ["web1080", "compact720", "document", "master", "fast"] { XCTAssertTrue(ids.contains(old), "the id \(old) may be stored as a default") }
        XCTAssertEqual(ids.first, "tutorial")
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    // MARK: on the written file
    private struct Written { var w: Int, h: Int, codec: String, mbps: Double, syncGaps: [Double], primaries: String?, matrix: String?, transfer: String? }
    private func read(_ u: URL) async throws -> Written {
        let a = AVURLAsset(url: u), v = try await a.loadTracks(withMediaType: .video)[0]
        let fd = try await v.load(.formatDescriptions)[0], sub = CMFormatDescriptionGetMediaSubType(fd), size = try await v.load(.naturalSize)
        func ext(_ k: CFString) -> String? { CMFormatDescriptionGetExtension(fd, extensionKey: k) as? String }
        let r = try AVAssetReader(asset: a), o = AVAssetReaderTrackOutput(track: v, outputSettings: nil); r.add(o); r.startReading()
        var syncs: [Double] = [], bytes = 0
        while let b = o.copyNextSampleBuffer() {
            bytes += CMSampleBufferGetTotalSampleSize(b)
            let at = (CMSampleBufferGetSampleAttachmentsArray(b, createIfNecessary: false) as? [[CFString: Any]])?.first
            if at?[kCMSampleAttachmentKey_NotSync] as? Bool != true { syncs.append(CMSampleBufferGetPresentationTimeStamp(b).seconds) }
        }
        let dur = try await v.load(.timeRange).duration.seconds
        return Written(w: Int(size.width), h: Int(size.height), codec: sub == kCMVideoCodecType_HEVC ? "hevc" : (sub == kCMVideoCodecType_H264 ? "h264" : "other"),
                       mbps: Double(bytes) * 8 / max(dur, 0.001) / 1e6, syncGaps: zip(syncs.dropFirst(), syncs).map { $0 - $1 },
                       primaries: ext(kCMFormatDescriptionExtension_ColorPrimaries), matrix: ext(kCMFormatDescriptionExtension_YCbCrMatrix), transfer: ext(kCMFormatDescriptionExtension_TransferFunction))
    }
    private func export(_ media: String, _ s: ExportSettings, doc: CGSize, dur: Double = 12) async throws -> Written {
        let u = out("x"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(project(media, dur), to: u, settings: s, documentSize: doc, documentFPS: 30)
        return try await read(u)
    }

    func testConstantQualityIsHonouredByBothCodecs() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: probe), "synthetic export probe")
        for codec in ExportSettings.Codec.allCases {
            var lo = ExportSettings(); lo.codec = codec; lo.quality = 0.55
            var hi = lo; hi.quality = 0.85
            let l = try await export(probe, lo, doc: doc), h = try await export(probe, hi, doc: doc)
            XCTAssertEqual(l.codec, codec.rawValue)
            XCTAssertGreaterThan(h.mbps, l.mbps * 1.3, "\(codec): a higher quality writes a clearly larger file (the key is not ignored)")
        }
    }
    func testSizeTargetLandsNearTheTarget() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: probe), "synthetic export probe")
        var s = ExportSettings(); s.targetMB = 6; s.audioKbps = 64         // 12 s → about 4 Mb/s in total; noise content, so the encoder is rate-limited
        let u = out("t"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(project(probe), to: u, settings: s, documentSize: doc, documentFPS: 30)
        let bytes = (try FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        XCTAssertEqual(Double(bytes) / 1e6, 6, accuracy: 6 * 0.3, "a one-pass average rate lands near the target (estimate, not a guarantee)")
    }
    func testDefaultKeyFramesAreFarApartAndColourIsTaggedRec709() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: probe), "synthetic export probe")
        let w = try await export(probe, ExportSettings(), doc: doc)
        // the encoder may add key frames at scene cuts (the probe has a white flash), so compare with an explicit 1 s distance instead of counting
        var every = ExportSettings(); every.keyframeSeconds = 1
        let one = try await export(probe, every, doc: doc)
        XCTAssertLessThan(w.syncGaps.count, one.syncGaps.count - 3, "far fewer key frames than one per second")
        XCTAssertLessThanOrEqual(w.syncGaps.max() ?? 0, ExportSettings.defaultKeyframeSeconds + 0.2)
        XCTAssertEqual(w.primaries, kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String); XCTAssertEqual(w.matrix, kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String)
        XCTAssertEqual(w.transfer, kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String)
    }
    func testMediumTierNoLongerWritesAnotherSizeThanAnnounced() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: hd), "synthetic clips")
        var s = ExportSettings(); s.quality = nil; s.tier = .medium; s.size = .longSide(1280)
        let w = try await export(hd, s, doc: CGSize(width: 1920, height: 1080), dur: 1.5)
        let plan = ExportPlan.video(project(hd, 1.5), documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: true)
        XCTAssertEqual(w.w, plan.width); XCTAssertEqual(w.h, plan.height); XCTAssertEqual(plan.width, 1280)
    }
}
