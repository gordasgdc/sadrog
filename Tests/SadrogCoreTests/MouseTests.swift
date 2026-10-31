// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Pointer metadata: collection (injected pointer, no real recording), persistence, editor consumption (follow-zoom), rendering (synthetic fixtures only).
final class MouseTests: XCTestCase {
    let root = "\(TestRoot.path)/"
    func tmp(_ name: String) throws -> URL { let d = URL(fileURLWithPath: root + "temp/mouse-\(name)-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }

    func testCollectionStartsOnlyWhenAskedAndIgnoresPauses() {
        var clock = 100.0, reads = 0
        var pos = CGPoint(x: 150, y: 250), down = false
        let rec = MouseRecorder(frame: CGRect(x: 100, y: 200, width: 200, height: 100), interval: 0, now: { clock }, read: { reads += 1; return (pos, down) })
        XCTAssertFalse(rec.isRunning); XCTAssertEqual(reads, 0, "creating a recorder reads nothing")
        rec.start(); XCTAssertTrue(rec.isRunning)
        let before = reads
        clock = 100.5; pos = CGPoint(x: 200, y: 250); rec.tick()
        rec.pause(); clock = 110; pos = CGPoint(x: 250, y: 220); rec.tick(); XCTAssertEqual(reads, before + 1, "nothing is read while paused")
        rec.resume(); clock = 110.5; down = true; rec.tick()
        let t = rec.stop(); XCTAssertFalse(rec.isRunning)
        let s = t.samples.filter { $0.t > 0.2 }
        XCTAssertEqual(s[0].x, 0.5, accuracy: 1e-9); XCTAssertEqual(s[0].y, 0.5, accuracy: 1e-9); XCTAssertEqual(s[0].t, 0.5, accuracy: 1e-6)
        XCTAssertEqual(s[1].t, 1.0, accuracy: 1e-6, "the 9.5 paused seconds are not in the track"); XCTAssertTrue(s[1].down)
        let after = reads; clock = 120; rec.tick(); XCTAssertEqual(reads, after, "a stopped recorder reads nothing"); XCTAssertEqual(rec.stop().samples.count, 0)
    }
    func testNormalizeClampsToTheCapturedFrame() {
        let f = CGRect(x: -1920, y: 0, width: 1920, height: 1080)
        let a = MouseTrack.normalize(CGPoint(x: -960, y: 540), in: f); XCTAssertEqual(a.x, 0.5, accuracy: 1e-9); XCTAssertEqual(a.y, 0.5, accuracy: 1e-9)
        let b = MouseTrack.normalize(CGPoint(x: 500, y: -40), in: f); XCTAssertEqual(b.x, 1); XCTAssertEqual(b.y, 0)
    }
    func testInterpolationClicksAndSyncOffset() {
        var t = MouseTrack(samples: [MouseSample(t: 0, x: 0, y: 0), MouseSample(t: 2, x: 1, y: 0.5, down: true), MouseSample(t: 3, x: 1, y: 0.5)], syntheticFixture: true)
        XCTAssertEqual(t.position(at: 1)!.x, 0.5, accuracy: 1e-9); XCTAssertEqual(t.position(at: 9)!.x, 1); XCTAssertEqual(t.clicks.count, 1); XCTAssertEqual(t.clicks[0].t, 2)
        t.syncOffset = 0.5; XCTAssertEqual(t.position(at: 1.5)!.x, 0.5, accuracy: 1e-9, "offset moves the track on the media's clock"); XCTAssertEqual(t.clicks[0].t, 2.5)
        XCTAssertEqual(t.sinceClick(at: 2.75)!.age, 0.25, accuracy: 1e-9); XCTAssertNil(t.sinceClick(at: 2.0))
    }
    func testTrackFileRoundTripAndNoPrivateFields() throws {
        let d = try tmp("file"); defer { try? FileManager.default.removeItem(at: d) }
        let t = MouseTrack(samples: [MouseSample(t: 0, x: 0.1, y: 0.2), MouseSample(t: 1, x: 0.3, y: 0.4, down: true)], syntheticFixture: true)
        try t.save(to: d); XCTAssertEqual(MouseTrack.load(besideMedia: d.appendingPathComponent("clip.mov").path), t)
        let json = String(data: try Data(contentsOf: d.appendingPathComponent("mouse.json")), encoding: .utf8)!
        for bad in ["key", "text", "window", "app", "title"] { XCTAssertFalse(json.lowercased().contains(bad), bad) }
        XCTAssertNil(MouseTrack.load(besideMedia: "/nonexistent/clip.mov"))
    }
    func testFollowKeepsThePointerNearCentreAndInsideThePicture() throws {
        // SYNTHETIC path: the pointer crosses the frame left → right over 6 s, then stays
        let samples = (0...60).map { MouseSample(t: Double($0) / 10, x: 0.1 + 0.8 * Double($0) / 60, y: 0.5) }
        let tr = MouseTrack(samples: samples, syntheticFixture: true)
        let plan = try XCTUnwrap(MouseFollow.plan(tr, sourceStart: 0, duration: 6, scale: 2))
        XCTAssertGreaterThan(plan.keys.count, 8)
        let m = Motion(keys: plan.keys, easing: .linear), render = CGSize(width: 1000, height: 500)
        for e in stride(from: 0.0, through: 5.9, by: 0.37) {
            let st = m.state(start: plan.start, end: nil, elapsed: e, duration: 6), p = tr.position(at: e)!
            XCTAssertEqual(st.scale, 2, accuracy: 1e-9)
            let q = CGPoint(x: p.x * 1000, y: p.y * 500).applying(BuiltComposition.matrix(natural: render, render: render, st))
            XCTAssertTrue(q.x >= -1 && q.x <= 1001, "pointer stays on screen at \(e): \(q)")
            if e > 1.5 && e < 4.5 { XCTAssertLessThan(abs(q.x - 500), 120, "and near the centre at \(e): \(q)") }
            // the picture always covers the frame: the corners of the magnified picture are outside the render rect
            let a = CGPoint(x: 0, y: 0).applying(BuiltComposition.matrix(natural: render, render: render, st)), b = CGPoint(x: 1000, y: 500).applying(BuiltComposition.matrix(natural: render, render: render, st))
            XCTAssertLessThanOrEqual(a.x, 0.001); XCTAssertGreaterThanOrEqual(b.x, 999.999)
        }
        let ed = ProjectEditor(project: SadrogProject(name: "m", clips: [Clip(media: root + "synthetic/testcolors/red.mov", sourceStart: 0, duration: 4)]))
        XCTAssertTrue(ed.followMouse(clip: ed.project.clips[0].id, track: tr, scale: 1.8)); XCTAssertTrue(ed.canUndo)
        XCTAssertNotNil(ed.project.clips[0].motion?.keys.first); XCTAssertTrue(ed.undo()); XCTAssertNil(ed.project.clips[0].motion)
        XCTAssertFalse(ed.followMouse(clip: ed.project.clips[0].id, track: MouseTrack(samples: []), scale: 1.8), "no track, no zoom")
    }
    func pixel(_ url: URL, at t: Double, x: Int, y: Int) async throws -> (r: Int, g: Int, b: Int) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height)); return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
    func testHighlightAndClickRingAreRendered() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root + "synthetic/testcolors/red.mov"), "needs synthetic colour clips (not distributed)")
        let d = try tmp("render"); defer { try? FileManager.default.removeItem(at: d) }
        let media = d.appendingPathComponent("red.mov"); try FileManager.default.copyItem(at: URL(fileURLWithPath: root + "synthetic/testcolors/red.mov"), to: media)
        // SYNTHETIC pointer: at (0.25, 0.5) for 3 s with a click at 1 s; the pure-red source has no green at all
        try MouseTrack(samples: [MouseSample(t: 0, x: 0.25, y: 0.5), MouseSample(t: 1, x: 0.25, y: 0.5, down: true), MouseSample(t: 1.1, x: 0.25, y: 0.5), MouseSample(t: 3, x: 0.25, y: 0.5)], syntheticFixture: true).save(to: d)
        let ed = ProjectEditor(project: SadrogProject(name: "m", clips: [Clip(media: media.path, sourceStart: 0, duration: 3)]))
        ed.setMouseFX(clip: ed.project.clips[0].id, MouseFX(highlight: true, clickRing: true))
        let out = URL(fileURLWithPath: root + "temp/mouse-\(UUID().uuidString).mov")
        try await ProjectExporter.export(ed.project, to: out, mode: .reencode(preset: AVAssetExportPresetHighestQuality)); defer { try? FileManager.default.removeItem(at: out) }
        let h = 720, w = 1280
        var p = try await pixel(out, at: 0.4, x: w / 4, y: h / 2); XCTAssertGreaterThan(p.g, 60, "highlight under the pointer \(p)")
        p = try await pixel(out, at: 0.4, x: w * 3 / 4, y: h / 2); XCTAssertLessThan(p.g, 30, "nothing away from it \(p)")
        // click at 1 s: the ring is 0.6×base … 2.2×base (base = 3.5 % of the height) — look just inside its path at 1.25 s, where no highlight reaches
        let base = 0.035 * Double(h), r = base * (0.6 + 1.6 * 0.5)
        p = try await pixel(out, at: 1.25, x: w / 4 + Int(r - 2.5), y: h / 2); XCTAssertGreaterThan(p.g, 100, "ring pixel \(p)")
        p = try await pixel(out, at: 2.5, x: w / 4 + Int(r), y: h / 2); XCTAssertLessThan(p.g, 30, "the ring is gone \(p)")
        // save / reopen keeps the effect
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(ed.project)); XCTAssertEqual(back.clips[0].mouseFX, MouseFX())
    }
    func testArchiveCarriesThePointerTrack() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root + "synthetic/testcolors/red.mov"), "needs synthetic colour clips (not distributed)")
        let d = try tmp("arch"), out = try tmp("archout"); defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: out) }
        let media = d.appendingPathComponent("red.mov"); try FileManager.default.copyItem(at: URL(fileURLWithPath: root + "synthetic/testcolors/red.mov"), to: media)
        let tr = MouseTrack(samples: [MouseSample(t: 0, x: 0.5, y: 0.5)], syntheticFixture: true); try tr.save(to: d)
        let r = try ProjectArchive.create(SadrogProject(name: "a", clips: [Clip(media: media.path, sourceStart: 0, duration: 2)]), in: out)
        let copy = r.folder.appendingPathComponent("Media/01/red.mov").path
        XCTAssertEqual(MouseTrack.load(besideMedia: copy), tr, "the archive keeps the pointer track with its recording")
    }
}
