// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

final class DocumentFormatTests: XCTestCase {
    func testPresetsAreRealSizesAndValuesAreSanitised() {
        XCTAssertEqual(DocumentFormat(width: 1921, height: 1081, fps: 500), DocumentFormat(width: 1920, height: 1080, fps: 120))
        XCTAssertEqual(DocumentFormat(width: 1920, height: 1080).preset?.name, "1080p HD")
        XCTAssertNil(DocumentFormat(width: 1000, height: 1000).preset)
        XCTAssertEqual(DocumentFormat(width: 1080, height: 1920).aspect, "9:16")
        XCTAssertEqual(DocumentFormat(width: 3840, height: 2160).aspect, "16:9")
        XCTAssertEqual(DocumentFormat(width: 2328, height: 1080).aspect, "2,16:1")
        XCTAssertEqual(DocumentFormat(width: 1080, height: 2328).aspect, "1:2,16")
    }
    func testOldProjectsHaveNoCanvasAndNewOnesRoundTrip() throws {
        let old = try JSONDecoder().decode(SadrogProject.self, from: Data(#"{"formatVersion":6,"name":"o","clips":[]}"#.utf8))
        XCTAssertNil(old.canvas)
        var p = old; p.canvas = DocumentFormat(width: 1280, height: 720, fps: 25)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.canvas, DocumentFormat(width: 1280, height: 720, fps: 25))
        let e = ProjectEditor(project: old); e.setCanvas(DocumentFormat(width: 1920, height: 1080, fps: 30))
        XCTAssertEqual(e.project.canvas?.width, 1920); e.undo(); XCTAssertNil(e.project.canvas)
    }
    /// The document size and frame rate are really applied: the exported file has them, whatever the source size.
    func testExportUsesTheDocumentSizeAndFrameRate() async throws {
        let blue = CompositionTests.dir + "/blue.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 2)])
        p.canvas = DocumentFormat(width: 640, height: 640, fps: 25)
        let b = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(b.renderSize, CGSize(width: 640, height: 640)); XCTAssertNotNil(b.videoComposition(for: p))
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/doc-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(p, to: out)
        let vts = try await AVURLAsset(url: out).loadTracks(withMediaType: .video); let v = try XCTUnwrap(vts.first)
        let size = try await v.load(.naturalSize), rate = try await v.load(.nominalFrameRate)
        XCTAssertEqual(size, CGSize(width: 640, height: 640)); XCTAssertEqual(Double(rate), 25, accuracy: 0.5)
    }
    func testCanvasAlignSnapsOnlyWithinThresholdAndReportsRealGuides() {
        let canvas = CGSize(width: 1920, height: 1080)
        // centre 3 px off the canvas centre → snaps, one vertical guide at 960
        let r = CanvasAlign.snap(moving: CGRect(x: 763, y: 100, width: 400, height: 200), others: [], canvas: canvas, threshold: 8)
        XCTAssertEqual(r.dx, -3, accuracy: 1e-9); XCTAssertEqual(r.guidesX, [960]); XCTAssertEqual(r.dy, 0); XCTAssertEqual(r.guidesY, [])
        // far from everything: no snap, no guide
        let far = CanvasAlign.snap(moving: CGRect(x: 300, y: 300, width: 100, height: 100), others: [], canvas: canvas, threshold: 8)
        XCTAssertEqual(far, .init(dx: 0, dy: 0, guidesX: [], guidesY: []))
        // left edge 5 px right of another item's right edge, top aligned with its top
        let other = CGRect(x: 100, y: 200, width: 300, height: 300)
        let o = CanvasAlign.snap(moving: CGRect(x: 405, y: 203, width: 200, height: 100), others: [other], canvas: canvas, threshold: 8)
        XCTAssertEqual(o.dx, -5); XCTAssertEqual(o.guidesX, [400]); XCTAssertEqual(o.dy, -3); XCTAssertEqual(o.guidesY, [200])
    }
}

/// Frame-rate rule for documents made from SADROG recordings (decision 2026-10-29).
final class RecordingDocumentRateTests: XCTestCase {
    static let c5 = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/evidence/capture_probes/C5/SADROG-6C7145EC-CD59-44A8-875E-758B8E931335"
    func testNewDocumentUsesConfiguredCaptureRateAndKeepsRealTiming() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.c5 + "/session.json"), "C5 not available")
        let j = try SessionJournal.read(from: URL(fileURLWithPath: Self.c5))
        XCTAssertEqual(j.fps, 60)
        let media = Self.c5 + "/capture.mov", asset = AVURLAsset(url: URL(fileURLWithPath: media))
        let d = try await asset.load(.duration).seconds
        let vt = try await asset.loadTracks(withMediaType: .video); let nominal = try await vt[0].load(.nominalFrameRate)
        XCTAssertLessThan(nominal, 30)                                        // the file's nominal rate is NOT what the document gets
        let p = SadrogProject.forRecording(name: "t", media: media, duration: d, journal: j)
        XCTAssertEqual(p.canvas, DocumentFormat(width: 3840, height: 2160, fps: 60))
        XCTAssertEqual(p.clips.first?.duration ?? 0, d, accuracy: 1e-9)         // no speed or duration change
        let b = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(b.composition.duration.seconds, d, accuracy: 0.002)
        for (k, t) in b.mainAudio { let seg = try XCTUnwrap(t.segments.first { !$0.isEmpty }); XCTAssertEqual(seg.timeMapping.source.duration.seconds, seg.timeMapping.target.duration.seconds, accuracy: 1e-6, "audio \(k) rescaled") }
        XCTAssertEqual(b.videoComposition(for: p)?.frameDuration, CMTime(value: 1, timescale: 60))
    }
    func testExistingProjectsAreNotMigrated() throws {
        // a project saved before this rule (no canvas) stays "same as source" when loaded and saved again
        let dir = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/legacy-\(UUID().uuidString)"); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let json = #"{"formatVersion":6,"name":"vechi","clips":[]}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent(ProjectStore.fileName))
        let p = try ProjectStore.load(from: dir); XCTAssertNil(p.canvas)
        try ProjectStore.save(p, to: dir); XCTAssertNil(try ProjectStore.load(from: dir).canvas)
    }
}
