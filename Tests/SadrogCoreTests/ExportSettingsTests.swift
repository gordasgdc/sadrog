import XCTest
import AVFoundation
import ImageIO
@testable import SadrogCore

/// Explicit export settings, checked on the WRITTEN FILE (size, rate, codec, duration), with titles and callouts on the picture. Needs the synthetic clips.
final class ExportSettingsTests: XCTestCase {
    static let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/synthetic"
    let hd = root + "/preset/hd.mov", portrait = root + "/preset/portrait.mov", withAudio = root + "/capture.mov"
    private func out(_ n: String) -> URL { URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/exp-\(n)-\(UUID().uuidString).mov") }
    private func project(_ media: String, dur: Double = 1.5, effects: Bool = true) -> SadrogProject {
        var p = SadrogProject(name: "t", clips: [Clip(media: media, sourceStart: 0, duration: dur)])
        if effects {
            p.texts = [TextOverlay(text: "Titlu", start: 0, duration: dur)]
            let e = ProjectEditor(project: p); e.addCallout(Callout(start: 0.2, duration: 1)); p = e.project
        }
        return p
    }
    struct Info { var w: Int; var h: Int; var fps: Double; var codec: String; var duration: Double; var audio: String? }
    private func info(_ u: URL) async throws -> Info {
        let a = AVURLAsset(url: u), v = try await a.loadTracks(withMediaType: .video)[0]
        let d = try await v.load(.formatDescriptions)[0]
        let au = try await a.loadTracks(withMediaType: .audio).first
        let ac = try await au?.load(.formatDescriptions).first
        let size = try await v.load(.naturalSize), rate = try await v.load(.nominalFrameRate)
        func four(_ c: FourCharCode) -> String { String(bytes: [UInt8(c >> 24 & 255), UInt8(c >> 16 & 255), UInt8(c >> 8 & 255), UInt8(c & 255)], encoding: .macOSRoman) ?? "?" }
        return Info(w: Int(size.width), h: Int(size.height), fps: Double(rate), codec: four(CMFormatDescriptionGetMediaSubType(d)), duration: try await a.load(.duration).seconds, audio: ac.map { four(CMFormatDescriptionGetMediaSubType($0)) })
    }
    private func run(_ p: SadrogProject, _ s: ExportSettings, doc: CGSize, fps: Double = 30, range: ClosedRange<Double>? = nil) async throws -> Info {
        let u = out("x"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(p, to: u, settings: s, documentSize: doc, documentFPS: fps, range: range)
        return try await info(u)
    }
    private func need() throws { try XCTSkipUnless(FileManager.default.fileExists(atPath: hd) && FileManager.default.fileExists(atPath: portrait), "synthetic clips") }

    func testPlanIsPureAndHonest() {
        var s = ExportSettings(); s.size = .longSide(3840)
        let p = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 4)])
        let pl = ExportPlan.video(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: false)
        XCTAssertEqual(pl.width, 3840); XCTAssertEqual(pl.height, 2160); XCTAssertEqual(pl.loss, .lossy); XCTAssertEqual(pl.notes.count, 2, "enlargement noted + the constant-quality note")
        s.mode = .lossless; XCTAssertEqual(ExportPlan.video(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: false).loss, .lossless)
        s.mode = .master; let m = ExportPlan.video(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: false)
        XCTAssertEqual(m.loss, .highQuality, "ProRes is a master, never called lossless"); XCTAssertTrue(m.codec.contains("ProRes"))
        s = ExportSettings(); s.mode = .copy
        XCTAssertEqual(ExportPlan.video(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: false).notes.count, 1, "copy not possible is said")
        s = ExportSettings(); s.size = .custom(1080, 1920); s.fps = 24
        let v = ExportPlan.video(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: false)
        XCTAssertEqual(v.width, 1080); XCTAssertEqual(v.height, 1920); XCTAssertEqual(v.fps, 24); XCTAssertEqual(v.notes.count, 3, "other aspect + other rate + the constant-quality note")
        s = ExportSettings(); s.size = .longSide(1920)
        let pt = ExportPlan.video(p, documentSize: CGSize(width: 1080, height: 1920), documentFPS: 30, settings: s, copyPossible: false); XCTAssertEqual(pt.width, 1080); XCTAssertEqual(pt.height, 1920, "portrait keeps its proportions")
    }
    func testDocumentIsNeverModified() throws {
        var s = ExportSettings(); s.size = .longSide(3840); s.fps = 60
        let p = project("/a.mov"), q = s.outputProject(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30)
        XCTAssertNil(p.canvas); XCTAssertEqual(q.canvas, DocumentFormat(width: 3840, height: 2160, fps: 60))
    }
    func testUpscaleTo4KAndOtherRateWithEffectsOnTheWrittenFile() async throws {
        try need(); var s = ExportSettings(); s.size = .longSide(3840); s.fps = 24
        let i = try await run(project(hd), s, doc: CGSize(width: 1920, height: 1080))
        XCTAssertEqual(i.w, 3840); XCTAssertEqual(i.h, 2160); XCTAssertEqual(i.fps, 24, accuracy: 0.5); XCTAssertEqual(i.duration, 1.5, accuracy: 0.1)
    }
    func testDownscalePortraitAndLandscapeToCustomSizeAndHEVC() async throws {
        try need(); var s = ExportSettings(); s.size = .longSide(1280); s.codec = .hevc
        let a = try await run(project(portrait), s, doc: CGSize(width: 1080, height: 1920)); XCTAssertEqual(a.w, 720); XCTAssertEqual(a.h, 1280); XCTAssertEqual(a.codec, "hvc1")
        s = ExportSettings(); s.size = .custom(1080, 1920)      // landscape source into a portrait frame: whole picture inside, margins
        let b = try await run(project(hd), s, doc: CGSize(width: 1920, height: 1080)); XCTAssertEqual(b.w, 1080); XCTAssertEqual(b.h, 1920); XCTAssertEqual(b.codec, "avc1")
    }
    func testRangeAndMasterAndAudio() async throws {
        try need(); var s = ExportSettings(); s.mode = .master
        let i = try await run(project(hd, dur: 2), s, doc: CGSize(width: 1920, height: 1080), range: 0.5...1.5)
        XCTAssertEqual(i.codec, "apcn"); XCTAssertEqual(i.duration, 1.0, accuracy: 0.1)
        if FileManager.default.fileExists(atPath: withAudio) {
            var c = SadrogProject(name: "t", clips: [Clip(media: withAudio, sourceStart: 0, duration: 1.5)])
            let r = try await run(c, ExportSettings(), doc: CGSize(width: 1280, height: 720)); XCTAssertEqual(r.audio, "aac "); c.name = "x"
        }
    }
    func testCopyNeverTurnsLossyWhenProcessingIsNeeded() async throws {
        try need(); var s = ExportSettings(); s.mode = .copy
        let u = out("c"); defer { try? FileManager.default.removeItem(at: u) }
        do { try await ProjectExporter.export(project(hd), to: u, settings: s, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30); XCTFail("must refuse") }
        catch ExportError.copyNeedsProcessing { XCTAssertFalse(FileManager.default.fileExists(atPath: u.path), "nothing written") }
        let plain = try await run(project(hd, effects: false), s, doc: CGSize(width: 1920, height: 1080)); XCTAssertEqual(plain.w, 1920)
    }
    /// Lossless: every pixel of the written file equals the frame the compositor produced (same size, titles and callout drawn), compared byte for byte.
    func testLosslessIsBitExactAgainstTheProcessedFrames() async throws {
        try need(); var s = ExportSettings(); s.mode = .lossless; s.size = .longSide(1280)
        let p = project(hd, dur: 1)
        let u = out("l").deletingPathExtension(); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(p, to: u, settings: s, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30)
        let files = try FileManager.default.contentsOfDirectory(atPath: u.path).sorted(); XCTAssertTrue(files.contains("frame_000001.png")); XCTAssertEqual(files.filter { $0.hasSuffix(".png") }.count, Int((p.timelineEnd * 30).rounded()), "one PNG per frame of the timeline")
        // reference: the same composition read back through the compositor
        let q = s.outputProject(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30)
        let built = try await CompositionBuilder.buildFull(q, fx: [:]), vcomp = built.videoComposition(for: q) ?? AVMutableVideoComposition(propertiesOf: built.composition)
        func frames(_ make: () async throws -> AVAssetReader, _ out: (AVAssetReader) async throws -> AVAssetReaderOutput) async throws -> [[UInt8]] {
            let r = try await make(), o = try await out(r); r.add(o); r.startReading(); var res: [[UInt8]] = []
            while let b = o.copyNextSampleBuffer(), res.count < 6 {
                guard let px = CMSampleBufferGetImageBuffer(b) else { continue }
                CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
                let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), bpr = CVPixelBufferGetBytesPerRow(px), base = CVPixelBufferGetBaseAddress(px)!.assumingMemoryBound(to: UInt8.self)
                var a = [UInt8](); a.reserveCapacity(w * h * 4); for y in 0..<h { a += UnsafeBufferPointer(start: base + y * bpr, count: w * 4) }; res.append(a)
            }
            return res
        }
        let bgra: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        let ref = try await frames({ try AVAssetReader(asset: built.composition) }, { r in
            let t = try await built.composition.loadTracks(withMediaType: .video); let o = AVAssetReaderVideoCompositionOutput(videoTracks: t, videoSettings: bgra); o.videoComposition = vcomp; return o })
        var got: [[UInt8]] = []
        for k in 1...6 {
            let src = CGImageSourceCreateWithURL(u.appendingPathComponent(String(format: "frame_%06d.png", k)) as CFURL, nil)!, img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
            XCTAssertEqual(img.width, 1280); XCTAssertEqual(img.height, 720)
            var buf = [UInt8](repeating: 0, count: 1280 * 720 * 4)
            let ctx = CGContext(data: &buf, width: 1280, height: 720, bitsPerComponent: 8, bytesPerRow: 1280 * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: 1280, height: 720)); got.append(buf)
        }
        XCTAssertEqual(got.count, ref.count); XCTAssertGreaterThan(ref.count, 3)
        for (k, (a, b)) in zip(ref, got).enumerated() {
            var diff = 0; for i in stride(from: 0, to: a.count, by: 4) where a[i] != b[i] || a[i + 1] != b[i + 1] || a[i + 2] != b[i + 2] { diff += 1 }
            XCTAssertEqual(diff, 0, "frame \(k): pixels differing from the processed frame")
        }
    }

    // MARK: advanced controls — measured on the written file
    private func measured(_ u: URL) async throws -> (mbps: Double, audioKbps: Double?, codec: String, dur: Double) {
        let a = AVURLAsset(url: u), v = try await a.loadTracks(withMediaType: .video)[0]
        let rate = try await v.load(.estimatedDataRate)
        let au = try await a.loadTracks(withMediaType: .audio).first
        let ar = try await au?.load(.estimatedDataRate)
        let d = try await v.load(.formatDescriptions)[0], c = CMFormatDescriptionGetMediaSubType(d)
        return (Double(rate) / 1e6, ar.map { Double($0) / 1000 }, c == kCMVideoCodecType_HEVC ? "hevc" : (c == kCMVideoCodecType_H264 ? "h264" : "other"), try await a.load(.duration).seconds)
    }
    func testAdvancedBitrateIsAppliedAndMonotonic() async throws {
        try need()
        var lo = ExportSettings(); lo.videoMbps = 1; lo.keyframeSeconds = 0.5; lo.audioKbps = 96
        var hi = lo; hi.videoMbps = 12
        let ul = out("lo"), uh = out("hi"); defer { try? FileManager.default.removeItem(at: ul); try? FileManager.default.removeItem(at: uh) }
        XCTAssertTrue(lo.usesAdvancedWriter)
        let doc = CGSize(width: 1920, height: 1080)
        try await ProjectExporter.export(project(hd), to: ul, settings: lo, documentSize: doc, documentFPS: 30)
        try await ProjectExporter.export(project(hd), to: uh, settings: hi, documentSize: doc, documentFPS: 30)
        let l = try await measured(ul), h = try await measured(uh)
        XCTAssertEqual(l.codec, "h264"); XCTAssertEqual(l.dur, 1.5, accuracy: 0.15)
        XCTAssertLessThan(l.mbps, 3, "1 Mb/s requested"); XCTAssertGreaterThan(h.mbps, l.mbps, "higher requested rate gives a higher measured rate")
    }
    func testAdvancedAudioBitrateAndHEVC() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: withAudio), "synthetic clip with sound")
        var s = ExportSettings(); s.codec = .hevc; s.audioKbps = 64; s.videoMbps = 4
        let u = out("aud"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(project(withAudio, effects: false), to: u, settings: s, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30)
        let m = try await measured(u)
        XCTAssertEqual(m.codec, "hevc"); XCTAssertNotNil(m.audioKbps); XCTAssertLessThan(m.audioKbps ?? 999, 110, "64 kb/s AAC requested")
    }
    func testAdvancedLeavesPresetPathAloneAndClampsRanges() {
        var s = ExportSettings(); XCTAssertTrue(s.usesAdvancedWriter, "compressed video always goes through the explicit writer (the system presets announced one size and wrote another)")
        s.mode = .master; s.videoMbps = 5; XCTAssertFalse(s.usesAdvancedWriter, "advanced controls exist only for the compressed mode")
        s = ExportSettings(); s.videoMbps = 9999; s.keyframeSeconds = 0; s.audioKbps = 1
        XCTAssertEqual(s.clampedMbps, 200); XCTAssertEqual(s.clampedKeyframe, 0.1); XCTAssertEqual(s.clampedAudioKbps, 64)
        var st = ExportPresetStore(url: URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/presets-adv-\(UUID().uuidString).json"))
        defer { try? FileManager.default.removeItem(at: st.url) }
        s = ExportSettings(); s.videoMbps = 8; s.audioKbps = 192
        let p = st.save(name: "Avansat", settings: s)
        XCTAssertEqual(p?.settings().videoMbps, 8); XCTAssertEqual(st.personal.first?.settings().audioKbps, 192)
    }
}
