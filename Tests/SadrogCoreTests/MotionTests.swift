// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Several keyframes, easing and visual fades: the maths, the editing, the persistence — and the pictures the exporter really writes (synthetic colour source).
final class MotionTests: XCTestCase {
    let src = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/synthetic/inout/colors_beep.mov"   // SYNTHETIC: 1 s each red, green, blue…
    let a = Transform(x: -0.25), k = Transform(x: 0.25)

    func testThreeStatesNeedAKeyframe() {
        let m = Motion(keys: [MotionKey(t: 1, transform: k)], easing: .linear)
        XCTAssertEqual(m.state(start: a, end: a, elapsed: 0, duration: 2).x, -0.25, accuracy: 1e-9)
        XCTAssertEqual(m.state(start: a, end: a, elapsed: 0.5, duration: 2).x, 0, accuracy: 1e-9)
        XCTAssertEqual(m.state(start: a, end: a, elapsed: 1, duration: 2).x, 0.25, accuracy: 1e-9)
        XCTAssertEqual(m.state(start: a, end: a, elapsed: 1.5, duration: 2).x, 0, accuracy: 1e-9)
        XCTAssertEqual(m.state(start: a, end: a, elapsed: 2, duration: 2).x, -0.25, accuracy: 1e-9)
        XCTAssertEqual(Transform.state(start: a, end: a, elapsed: 1, duration: 2).x, -0.25, accuracy: 1e-9, "without keys the two states alone cannot move")
    }
    func testEasingChangesTheCurveNotTheEnds() {
        let cases: [(Easing, Double)] = [(.linear, 0.0), (.smooth, 0.0), (.easeIn, -0.125), (.easeOut, 0.125)]
        for (e, expect) in cases {
            let m = Motion(keys: [MotionKey(t: 1, transform: k)], easing: e)
            XCTAssertEqual(m.state(start: a, end: nil, elapsed: 0.5, duration: 2).x, expect, accuracy: 1e-9, "\(e)")
            XCTAssertEqual(m.state(start: a, end: nil, elapsed: 1, duration: 2).x, 0.25, accuracy: 1e-9)
        }
        XCTAssertEqual(Motion(keys: [MotionKey(t: 1, transform: k)]).state(start: a, end: nil, elapsed: 1.8, duration: 2).x, 0.25, accuracy: 1e-9, "no end state: the last key holds")
    }
    func testFadesRampTheOpacityAtTheEdges() {
        let m = Motion(fadeIn: 1, fadeOut: 1)
        func o(_ t: Double) -> Double { m.state(start: .identity, end: nil, elapsed: t, duration: 4).opacity }
        XCTAssertEqual(o(0), 0, accuracy: 1e-9); XCTAssertEqual(o(0.5), 0.5, accuracy: 1e-9); XCTAssertEqual(o(2), 1, accuracy: 1e-9); XCTAssertEqual(o(3.5), 0.5, accuracy: 1e-9); XCTAssertEqual(o(4), 0, accuracy: 1e-9)
        XCTAssertEqual(Motion(fadeIn: 1).state(start: Transform(opacity: 0.5), end: nil, elapsed: 2, duration: 4).opacity, 0.5, accuracy: 1e-9, "fades multiply the item's own opacity")
    }
    func testEditingIsUndoableAndASplitKeepsTheRightPieces() {
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: src, sourceStart: 0, duration: 6)]))
        let id = ed.project.clips[0].id
        ed.setKey(id, at: 1, k); ed.setKey(id, at: 4, a); ed.updateMotion(id) { $0.fadeIn = 0.5; $0.fadeOut = 0.5; $0.easing = .easeOut }
        XCTAssertEqual(ed.project.clips[0].motion?.keys.count, 2); ed.setKey(id, at: 1.02, Transform(x: 0.1)); XCTAssertEqual(ed.project.clips[0].motion?.keys.count, 2, "a key within 50 ms is replaced, not doubled")
        ed.split(at: 2.5)
        let c = ed.project.clips; XCTAssertEqual(c.count, 2)
        XCTAssertEqual(c[0].motion?.keys.map { $0.t }, [1.02]); XCTAssertEqual(c[0].motion?.fadeIn, 0.5); XCTAssertEqual(c[0].motion?.fadeOut, 0)
        XCTAssertEqual(c[1].motion?.keys.map { $0.t }, [1.5]); XCTAssertEqual(c[1].motion?.fadeIn, 0); XCTAssertEqual(c[1].motion?.fadeOut, 0.5)
        ed.undo(); XCTAssertEqual(ed.project.clips.count, 1)
        ed.removeKey(id, at: 0); XCTAssertEqual(ed.project.clips[0].motion?.keys.count, 1)
        ed.updateMotion(id) { $0 = Motion() }; XCTAssertNil(ed.project.clips[0].motion, "a neutral motion is removed")
    }
    func testPersistsAndOlderProjectsLookTheSame() throws {
        var c = Clip(media: "/x.mov", sourceStart: 0, duration: 5); c.motion = Motion(keys: [MotionKey(t: 2, transform: k)], easing: .easeIn, fadeIn: 0.4)
        XCTAssertEqual(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(c)), c)
        let plain = Clip(media: "/x.mov", sourceStart: 0, duration: 5); XCTAssertFalse(String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("motion"))
        XCTAssertNil(try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(plain)).motion); XCTAssertTrue(SadrogProject(name: "t", clips: [c]).needsCompositing)
        var t = TextOverlay(text: "x", start: 0); t.motion = Motion(fadeOut: 1); XCTAssertEqual(try JSONDecoder().decode(TextOverlay.self, from: JSONEncoder().encode(t)).motion, t.motion)
    }

    // MARK: what the exporter writes
    func pixel(_ url: URL, at t: Double, x: Int, y: Int) async throws -> (r: Int, g: Int, b: Int) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height)); return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
    func render(_ p: SadrogProject) async throws -> URL {
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/motion-\(UUID().uuidString).mov")
        try await ProjectExporter.export(p, to: out, mode: .reencode(preset: AVAssetExportPresetHighestQuality)); return out
    }
    func testExportedPicturesFollowTheKeyframesAndFades() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src), "synthetic source not available")
        var c = Clip(media: src, sourceStart: 0, duration: 2, transform: a, endTransform: a); c.motion = Motion(keys: [MotionKey(t: 1, transform: k)], easing: .linear)
        let out = try await render(SadrogProject(name: "t", clips: [c])); defer { try? FileManager.default.removeItem(at: out) }
        let dark = { (p: (r: Int, g: Int, b: Int)) in p.r + p.g + p.b < 60 }, lit = { (p: (r: Int, g: Int, b: Int)) in p.r + p.g + p.b > 100 }
        // x = −0.25 at the start: the picture sits left, black bar on the right; x = +0.25 at 1 s: the other way round; back to −0.25 at the end
        var p = try await pixel(out, at: 0.05, x: 310, y: 120); XCTAssertTrue(dark(p), "t=0: right side empty \(p)"); p = try await pixel(out, at: 0.05, x: 10, y: 120); XCTAssertTrue(lit(p), "t=0: left side has the picture \(p)")
        p = try await pixel(out, at: 1.0, x: 10, y: 120); XCTAssertTrue(dark(p), "t=1: left side empty \(p)"); p = try await pixel(out, at: 1.0, x: 310, y: 120); XCTAssertTrue(lit(p), "t=1: right side has the picture \(p)")
        p = try await pixel(out, at: 1.9, x: 310, y: 120); XCTAssertTrue(dark(p), "t≈2: back to the left \(p)")
    }
    func testExportedFadeInIsDarkThenFull() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src), "synthetic source not available")
        var c = Clip(media: src, sourceStart: 0, duration: 3); c.motion = Motion(fadeIn: 1, fadeOut: 1)
        let out = try await render(SadrogProject(name: "t", clips: [c])); defer { try? FileManager.default.removeItem(at: out) }
        let start = try await pixel(out, at: 0.03, x: 160, y: 120), mid = try await pixel(out, at: 1.5, x: 160, y: 120), end = try await pixel(out, at: 2.97, x: 160, y: 120)
        XCTAssertLessThan(start.r + start.g + start.b, 60, "starts dark \(start)"); XCTAssertGreaterThan(mid.g, 100, "fully visible (green second) \(mid)"); XCTAssertLessThan(end.r + end.g + end.b, 120, "ends dark \(end)")
    }
}
