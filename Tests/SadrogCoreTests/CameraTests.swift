// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Camera as a separate, synchronised source: writer (synthetic frames, no camera), validation, manifest, and the project a recording
/// opens with (camera on V2 at the measured offset, as a presenter circle). No camera is started here.
final class CameraTests: XCTestCase {
    static let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG"
    let work = URL(fileURLWithPath: "\(root)/temp/camera-\(UUID().uuidString)")
    override func setUp() async throws { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    func frame(_ t: CMTime, w: Int = 640, h: Int = 360) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &pb)
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fd)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: t, decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fd!, sampleTiming: &timing, sampleBufferOut: &sb)
        return sb!
    }

    func testWriterKeepsItsOwnFileFirstFrameTimeAndOrder() async throws {
        let url = work.appendingPathComponent("camera.mov"), w = CameraWriter(url: url)
        let t0 = CMTime(seconds: 1000.25, preferredTimescale: 600_000)        // host clock, like a real camera
        for i in 0..<30 { w.append(frame(t0 + CMTime(value: CMTimeValue(i), timescale: 30))); usleep(25_000) }      // real-time pace, like a camera
        w.append(frame(t0 + CMTime(value: 5, timescale: 30)))                 // out of order: dropped
        XCTAssertEqual(w.frames, 30); XCTAssertEqual(w.dropped, 1)
        XCTAssertEqual(w.firstPTS.seconds, 1000.25, accuracy: 1e-6)
        XCTAssertEqual(w.durationSeconds, 1.0, accuracy: 0.001)
        let ok = try await w.finish(); XCTAssertTrue(ok)
        let a = AVURLAsset(url: url), tracks = try await a.loadTracks(withMediaType: .video), v = try XCTUnwrap(tracks.first)
        let size = try await v.load(.naturalSize), dur = try await a.load(.duration).seconds
        XCTAssertEqual(size, CGSize(width: 640, height: 360)); XCTAssertEqual(dur, 1.0, accuracy: 0.05)
        let empty = CameraWriter(url: work.appendingPathComponent("none.mov"))
        let wrote = try await empty.finish(); XCTAssertFalse(wrote); XCTAssertFalse(FileManager.default.fileExists(atPath: work.appendingPathComponent("none.mov").path))
    }

    func testValidatorNeverSubstitutesACamera() {
        let src = [SourceInfo(id: 1, kind: .display, title: "M", width: 100, height: 100, pointsWidth: 100, pointsHeight: 100, scale: 1)]
        var c = CaptureConfig(video: VideoSourceSpec(mode: .display, sourceID: 1, title: "M"))
        XCTAssertTrue(CaptureValidator.check(c, sources: src, devices: []).isEmpty, "no camera chosen: nothing to check")
        c.cameras = [CameraSpec(uid: "cam-a", name: "Camera A")]
        XCTAssertEqual(CaptureValidator.check(c, sources: src, devices: [], cameras: ["cam-b"]), [.cameraMissing(name: "Camera A")])
        XCTAssertEqual(CaptureValidator.check(c, sources: src, devices: [], cameras: ["cam-a"], cameraAllowed: false), [.cameraNotAllowed])
        XCTAssertTrue(CaptureValidator.check(c, sources: src, devices: [], cameras: ["cam-a"]).isEmpty)
    }

    func manifest(offset: Double, duration: Double, file: String = "camera.mov") -> SourcesManifest {
        SourcesManifest(video: VideoSourceSpec(mode: .display, sourceID: 1, title: "M"), sourcePixels: [1280, 720], outputPixels: [1280, 720], scale: 1, audioTracks: [],
                        camera: .init(uid: "cam", name: "Camera", file: file, width: 1280, height: 720, frames: Int(duration * 30), firstFrameOffsetSeconds: offset, durationSeconds: duration))
    }
    func session(_ m: SourcesManifest?, copyCamera: Bool = true) throws -> (String, SessionJournal) {
        let f = work.appendingPathComponent("SADROG-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "\(Self.root)/synthetic/capture.mov", toPath: f.appendingPathComponent("capture.mov").path)
        if copyCamera { try FileManager.default.copyItem(atPath: "\(Self.root)/synthetic/presenter/prezentator_sintetic_12s.mov", toPath: f.appendingPathComponent("camera.mov").path) }
        try m?.write(to: f)
        let j = SessionJournal(id: "t", state: .finished, startedAt: Date(), mediaFile: "capture.mov", fragmentSeconds: 10, width: 1280, height: 720, fps: 30, note: "")
        return (f.appendingPathComponent("capture.mov").path, j)
    }

    func testManifestRoundTripAndOldManifests() throws {
        let m = manifest(offset: 0.42, duration: 9)
        let f = work.appendingPathComponent("m"); try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        try m.write(to: f); XCTAssertEqual(try SourcesManifest.read(from: f), m)
        let old = #"{"version":1,"video":{"mode":"display","sourceID":1,"title":"M"},"sourcePixels":[1,1],"outputPixels":[1,1],"scale":1,"audioTracks":[]}"#
        try Data(old.utf8).write(to: f.appendingPathComponent(SourcesManifest.fileName))
        XCTAssertNil(try SourcesManifest.read(from: f).camera)
    }

    func testRecordingOpensWithTheCameraAsASeparateSyncedPresenter() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(Self.root)/synthetic/presenter/prezentator_sintetic_12s.mov"), "synthetic presenter missing")
        // camera started 0.5 s after the first screen frame
        let (media, j) = try session(manifest(offset: 0.5, duration: 12))
        let p = SadrogProject.forRecording(name: "r", media: media, duration: 10, journal: j)
        XCTAssertEqual(p.clips.count, 1); XCTAssertEqual(p.clips[0].media, media, "the screen stays the main clip, untouched")
        let l = try XCTUnwrap(p.layers.first)
        XCTAssertEqual(l.kind, .video); XCTAssertTrue(l.media.hasSuffix("/camera.mov"))
        XCTAssertEqual(l.start, 0.5, accuracy: 1e-9); XCTAssertEqual(l.sourceStart, 0, accuracy: 1e-9)
        XCTAssertEqual(l.duration, 9.5, accuracy: 1e-9, "ends with the screen")
        XCTAssertEqual(l.crop, PresenterPlacement.defaultCrop)
        XCTAssertEqual(l.transform, PresenterPlacement.transform(Transform(scale: PresenterPlacement.scale), corner: .bottomRight, render: CGSize(width: 1280, height: 720)))
        XCTAssertEqual(p.library.count, 2)
        // camera started 0.3 s BEFORE the screen: its first 0.3 s are skipped, so both start together
        let (m2, j2) = try session(manifest(offset: -0.3, duration: 6))
        let l2 = try XCTUnwrap(SadrogProject.forRecording(name: "r", media: m2, duration: 10, journal: j2).layers.first)
        XCTAssertEqual(l2.start, 0, accuracy: 1e-9); XCTAssertEqual(l2.sourceStart, 0.3, accuracy: 1e-9); XCTAssertEqual(l2.duration, 5.7, accuracy: 1e-9)
        // no camera / camera file missing: the recording opens as before
        let (m3, j3) = try session(nil, copyCamera: false); XCTAssertTrue(SadrogProject.forRecording(name: "r", media: m3, duration: 10, journal: j3).layers.isEmpty)
        let (m4, j4) = try session(manifest(offset: 0, duration: 5), copyCamera: false); XCTAssertTrue(SadrogProject.forRecording(name: "r", media: m4, duration: 10, journal: j4).layers.isEmpty)
    }

    func testPresenterCornersKeepTheMargin() {
        let R = CGSize(width: 1920, height: 1080), t = Transform(scale: 0.3)
        let D = 1080 * 0.3, mg = 0.04 * 1080
        let tl = PresenterPlacement.transform(t, corner: .topLeft, render: R)
        XCTAssertEqual(1920 / 2 + tl.x * 1920 - D / 2, mg, accuracy: 1e-9); XCTAssertEqual(1080 / 2 + tl.y * 1080 - D / 2, mg, accuracy: 1e-9)
        let br = PresenterPlacement.transform(t, corner: .bottomRight, render: R)
        XCTAssertEqual(1920 - (1920 / 2 + br.x * 1920 + D / 2), mg, accuracy: 1e-9)
    }
}

/// Several screens and cameras in one session: configuration (old forms still read), validation (duplicates, never a substitute),
/// manifest, and the project a recording opens with (one V2 row per file, by its measured offset).
final class MultiSourceTests: XCTestCase {
    let ct = CameraTests()
    override func setUp() async throws { try await ct.setUp() }
    override func tearDown() async throws { try await ct.tearDown() }

    func testConfigReadsOldFormsAndKeepsSourcesSeparate() throws {
        let old = #"{"video":{"mode":"display","sourceID":1,"title":"M"},"audio":[],"camera":{"uid":"c1","name":"Cam"}}"#
        let c = try JSONDecoder().decode(CaptureConfig.self, from: Data(old.utf8))
        XCTAssertEqual(c.cameras.map(\.uid), ["c1"]); XCTAssertTrue(c.extraVideos.isEmpty); XCTAssertFalse(c.video!.id.isEmpty)
        var n = CaptureConfig(video: VideoSourceSpec(mode: .display, sourceID: 1, title: "M"), extraVideos: [VideoSourceSpec(mode: .window, sourceID: 9, title: "W")], cameras: [CameraSpec(uid: "a", name: "A"), CameraSpec(uid: "b", name: "B")])
        let back = try JSONDecoder().decode(CaptureConfig.self, from: JSONEncoder().encode(n))
        XCTAssertEqual(back, n); XCTAssertEqual(back.videos.count, 2)
        let src = [SourceInfo(id: 1, kind: .display, title: "M", width: 10, height: 10), SourceInfo(id: 9, kind: .window, title: "W", width: 10, height: 10)]
        XCTAssertTrue(CaptureValidator.check(n, sources: src, devices: [], cameras: ["a", "b"]).isEmpty)
        n.extraVideos.append(VideoSourceSpec(mode: .display, sourceID: 1, title: "M"))
        n.cameras.append(CameraSpec(uid: "a", name: "A"))
        let issues = CaptureValidator.check(n, sources: src, devices: [], cameras: ["a"])
        XCTAssertTrue(issues.contains(.duplicateVideo("M"))); XCTAssertTrue(issues.contains(.duplicateCamera("A"))); XCTAssertTrue(issues.contains(.cameraMissing(name: "B")))
    }

    func testRecordingOpensEverySourceOnItsOwnRow() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "\(CameraTests.root)/synthetic/presenter/prezentator_sintetic_12s.mov"))
        var m = ct.manifest(offset: 0, duration: 6, file: "camera-1.mov")
        m.camera = nil
        m.videoFiles = [
            .init(id: "s2", kind: .screen, name: "Monitor 2", file: "screen-2.mov", width: 1280, height: 720, frames: 300, firstFrameOffsetSeconds: 0.01, durationSeconds: 9),
            .init(id: "c1", kind: .camera, name: "Cam 1", file: "camera-1.mov", width: 1280, height: 720, frames: 180, firstFrameOffsetSeconds: 0.03, durationSeconds: 6),
            .init(id: "c2", kind: .camera, name: "Cam 2", file: "camera-2.mov", width: 1280, height: 720, frames: 180, firstFrameOffsetSeconds: 0.02, durationSeconds: 6)]
        let (media, j) = try ct.session(m)
        let folder = URL(fileURLWithPath: media).deletingLastPathComponent()
        for f in ["screen-2.mov", "camera-1.mov", "camera-2.mov"] where !FileManager.default.fileExists(atPath: folder.appendingPathComponent(f).path) {
            try FileManager.default.copyItem(atPath: "\(CameraTests.root)/synthetic/presenter/prezentator_sintetic_12s.mov", toPath: folder.appendingPathComponent(f).path)
        }
        let p = SadrogProject.forRecording(name: "r", media: media, duration: 10, journal: j)
        XCTAssertEqual(p.layers.count, 3)
        XCTAssertEqual(p.layers.map(\.row), [0, 1, 2], "one row each: they play at the same time")
        XCTAssertNil(p.layers[0].crop, "an extra screen opens as a full overlay"); XCTAssertNotNil(p.layers[1].crop); XCTAssertNotNil(p.layers[2].crop)
        XCTAssertEqual(p.layers[1].start, 0.03, accuracy: 1e-9)
        XCTAssertNotEqual(p.layers[1].transform.y, p.layers[2].transform.y, "two presenter circles are not stacked on the same spot")
        // the editor rule: items overlap only on different rows
        let e = ProjectEditor(project: p)
        XCTAssertFalse(e.setLayerRow(p.layers[2].id, 1), "row 1 is busy at that time")
        XCTAssertTrue(e.setLayerRow(p.layers[2].id, 3))
    }
}

/// Camera modes: what the device offers is listed from its own formats; a mode the camera lacks is refused, not replaced. Synthetic format lists.
final class CameraFormatTests: XCTestCase {
    private let formats = [CameraFormatInfo(width: 1920, height: 1080, ranges: [1...30]),
                           CameraFormatInfo(width: 1280, height: 720, ranges: [1...60]),
                           CameraFormatInfo(width: 3840, height: 2160, ranges: [1...24, 1...29.97])]
    func testOptionsComeFromTheRangesLargestFirstWithoutDuplicates() {
        let o = CameraFormats.options(from: formats)
        XCTAssertEqual(o.first, CameraFormatOption(width: 3840, height: 2160, fps: 29))
        XCTAssertTrue(o.contains(CameraFormatOption(width: 1280, height: 720, fps: 60))); XCTAssertTrue(o.contains(CameraFormatOption(width: 1920, height: 1080, fps: 25)))
        XCTAssertFalse(o.contains(CameraFormatOption(width: 1920, height: 1080, fps: 60)), "1080p tops out at 30")
        XCTAssertEqual(o.count, Set(o).count)
    }
    func testIndexFindsTheDeviceFormatOrRefusesNeverSubstitutes() {
        XCTAssertEqual(CameraFormats.index(of: CameraFormatOption(width: 1280, height: 720, fps: 50), in: formats), 1)
        XCTAssertNil(CameraFormats.index(of: CameraFormatOption(width: 1920, height: 1080, fps: 60), in: formats))
        XCTAssertNil(CameraFormats.index(of: CameraFormatOption(width: 640, height: 480, fps: 30), in: formats))
    }
    func testChosenModeSurvivesTheConfigFileAndOldFilesHaveNone() throws {
        let spec = CameraSpec(uid: "u", name: "C", format: CameraFormatOption(width: 1280, height: 720, fps: 30))
        XCTAssertEqual(try JSONDecoder().decode(CameraSpec.self, from: JSONEncoder().encode(spec)), spec)
        XCTAssertNil(try JSONDecoder().decode(CameraSpec.self, from: Data(#"{"uid":"u","name":"C"}"#.utf8)).format)
    }
}
