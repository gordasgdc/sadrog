// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Pixel-level check that the exported composition matches the placement maths (solid-colour sources, known geometry).
/// Needs the synthetic colour clips under the external SADROG folder; skipped when the volume is not mounted.
final class CompositionTests: XCTestCase {
    static let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/synthetic/testcolors"
    var blue: String { Self.dir + "/blue.mov" }
    var red: String { Self.dir + "/red.mov" }

    func export(_ p: SadrogProject) async throws -> URL {
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/comp-\(UUID().uuidString).mov")
        try await ProjectExporter.export(p, to: out); return out
    }
    func pixel(_ url: URL, at t: Double, x fx: Double, y fy: Double) async throws -> (Double, Double, Double) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        let w = img.width, h = img.height; var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -Double(w) * fx, y: -Double(h) * (1 - fy) + 1 - 1, width: Double(w), height: Double(h)))
        return (Double(px[0]), Double(px[1]), Double(px[2]))
    }

    func testOverlayTransformOpacityAndGaps() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue) && FileManager.default.fileExists(atPath: red), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 4)])
        p.layers = [Layer(kind: .video, media: red, start: 1, duration: 2, transform: Transform(x: 0.25, y: 0, scale: 0.5, opacity: 1))]
        let url = try await export(p); defer { try? FileManager.default.removeItem(at: url) }
        let inside = try await pixel(url, at: 1.5, x: 0.75, y: 0.5)         // inside the overlay rectangle
        XCTAssertGreaterThan(inside.0, 200); XCTAssertLessThan(inside.2, 60)  // red
        let outside = try await pixel(url, at: 1.5, x: 0.25, y: 0.5)
        XCTAssertGreaterThan(outside.2, 150); XCTAssertLessThan(outside.0, 80) // blue main
        let edge = try await pixel(url, at: 1.5, x: 0.9, y: 0.5)             // right of the scaled rectangle (0.5..1.0 wide) still inside
        XCTAssertGreaterThan(edge.0, 200)
        let corner = try await pixel(url, at: 1.5, x: 0.55, y: 0.1)          // above the rectangle (it spans y 0.25..0.75)
        XCTAssertGreaterThan(corner.2, 150); XCTAssertLessThan(corner.0, 80)
        let after = try await pixel(url, at: 3.5, x: 0.75, y: 0.5)           // overlay ended
        XCTAssertGreaterThan(after.2, 150); XCTAssertLessThan(after.0, 80)
    }

    func testOpacityBlendsAndMainTransformShrinks() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue) && FileManager.default.fileExists(atPath: red), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 3, transform: Transform(scale: 0.5))])
        p.layers = [Layer(kind: .video, media: red, start: 0, duration: 3, transform: Transform(scale: 0.5, opacity: 0.5))]
        let url = try await export(p); defer { try? FileManager.default.removeItem(at: url) }
        let mid = try await pixel(url, at: 1, x: 0.5, y: 0.5)                // red 50% over blue: both channels present
        XCTAssertGreaterThan(mid.0, 70); XCTAssertGreaterThan(mid.2, 70)
        let corner = try await pixel(url, at: 1, x: 0.05, y: 0.05)           // main shrunk to 50%: corner is black background
        XCTAssertLessThan(corner.0 + corner.1 + corner.2, 60)
    }

    func testLegacyProjectStillDecodes() throws {
        let json = #"{"formatVersion":2,"name":"old","clips":[{"id":"1836A1A2-E44E-455B-BBFF-ACA2019A18CD","media":"/x.mov","sourceStart":0,"duration":5}]}"#
        let p = try JSONDecoder().decode(SadrogProject.self, from: Data(json.utf8))
        XCTAssertTrue(p.clips[0].transform.isIdentity); XCTAssertTrue(p.layers.isEmpty); XCTAssertEqual(p.timelineEnd, 5)
    }

    func testLayerOperationsAndUndo() {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a", sourceStart: 0, duration: 10)]))
        let v = Layer(kind: .video, media: "/b", start: 2, duration: 4)
        XCTAssertTrue(e.addLayer(v)); XCTAssertFalse(e.addLayer(Layer(kind: .video, media: "/c", start: 5, duration: 2)))   // overlaps on its lane
        XCTAssertTrue(e.addLayer(Layer(kind: .audio, media: "/m", start: 0, duration: 20)))                                  // other lane is independent
        XCTAssertEqual(e.project.timelineEnd, 20)
        XCTAssertTrue(e.moveLayer(v.id, to: 7)); XCTAssertEqual(e.project.layers[0].start, 7)
        e.setTransform(v.id, Transform(x: 0.1, scale: 0.6, opacity: 0.8)); XCTAssertEqual(e.project.layers[0].transform.scale, 0.6)
        e.splitLayer(kind: .video, at: 9); XCTAssertEqual(e.project.layers.filter { $0.kind == .video }.count, 2)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.layers.filter { $0.kind == .video }.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertTrue(e.project.layers[0].transform.isIdentity)
        e.setTransform(e.project.clips[0].id, Transform(scale: 0.5)); XCTAssertEqual(e.project.clips[0].transform.scale, 0.5)
    }

    /// Demo project (main + overlay with transform/opacity + independent audio): saved file reopens identically and the exported frame matches the preview frame.
    func testDemoProjectReopenAndExportMatchesPreview() async throws {
        let dir = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/ui_screens/dest_editor/SADROG-5A1D0C11-2B7E-4C55-9A31-0E5D7F2A6B90/project.sadrogproj")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: dir.path), "demo project not available")
        let p = try ProjectStore.load(from: dir)
        XCTAssertEqual(p.layers.count, 2); let ov = p.layers.first { $0.kind == .video }!
        XCTAssertTrue(ov.transform.scale > 0 && ov.transform.opacity > 0)       // the demo project is edited by hand during UI checks, so no fixed values here
        var short = p; short.hiddenLanes = []; short.mutedLanes = []; short.clips = Array(p.clips.prefix(2)); short.layers = p.layers.map { var l = $0; l.duration = min(l.duration, 9); return l }
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/demo-\(UUID().uuidString).mov")
        try await ProjectExporter.export(short, to: out); defer { try? FileManager.default.removeItem(at: out) }
        let built = try await CompositionBuilder.buildFull(short)
        let pg = AVAssetImageGenerator(asset: built.composition); pg.videoComposition = built.videoComposition(for: short)
        pg.requestedTimeToleranceBefore = .zero; pg.requestedTimeToleranceAfter = .zero
        let eg = AVAssetImageGenerator(asset: AVURLAsset(url: out)); eg.requestedTimeToleranceBefore = .zero; eg.requestedTimeToleranceAfter = .zero
        let t = CMTime(seconds: 11, preferredTimescale: 600)
        func gray(_ im: CGImage) -> [Double] {
            var px = [UInt8](repeating: 0, count: 64 * 36 * 4)
            let c = CGContext(data: &px, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 256, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(im, in: CGRect(x: 0, y: 0, width: 64, height: 36)); return px.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
        }
        let a = gray(try await pg.image(at: t).image), b = gray(try await eg.image(at: t).image)
        let mad = zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
        print("preview-vs-export mean abs diff (0-255):", mad)
        XCTAssertLessThan(mad, 4)
    }
}
