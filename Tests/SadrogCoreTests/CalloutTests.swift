// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Callout (local highlight): model rules (clamping, overlap, undo, persistence) and pixels of the exported frames.
final class CalloutTests: XCTestCase {
    let helper = CompositionTests()
    let dir = CompositionTests.dir
    var haveColours: Bool { FileManager.default.fileExists(atPath: dir + "/blue.mov") && FileManager.default.fileExists(atPath: dir + "/red.mov") }

    func testRegionIsClampedToTheFrameAndEditingIsOneUndoStep() throws {
        var c = Callout(start: 1, duration: 2, x: 0.9, y: -0.2, w: 0.5, h: 5, dim: 3, blur: -1, corner: 9)
        XCTAssertEqual(c.x, 0.5, accuracy: 1e-12); XCTAssertEqual(c.y, 0, accuracy: 1e-12); XCTAssertEqual(c.h, 1, accuracy: 1e-12)
        XCTAssertEqual(c.dim, 1); XCTAssertEqual(c.blur, 0); XCTAssertEqual(c.corner, 0.5)
        c.w = 0; c.normalize(); XCTAssertEqual(c.w, Callout.minSide, accuracy: 1e-12)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a", sourceStart: 0, duration: 10)]))
        let a = Callout(start: 1, duration: 2), b = Callout(start: 5, duration: 2)
        XCTAssertTrue(e.addCallout(a)); XCTAssertTrue(e.addCallout(b))
        XCTAssertTrue(e.addCallout(Callout(start: 2, duration: 2)))                                 // overlapping effects are allowed (own targets); rows keep them readable
        XCTAssertTrue(e.moveCallout(b.id, to: 2))                                                    // moving over another effect is allowed too
        XCTAssertTrue(e.updateCallout(a.id) { $0.x = 0.1; $0.y = 0.2; $0.w = 0.3; $0.h = 0.25; $0.dim = 0.8; $0.blur = 0.5 })
        XCTAssertEqual(e.project.callouts[0].w, 0.3, accuracy: 1e-12)
        e.undo(); XCTAssertEqual(e.project.callouts[0].w, 0.4, accuracy: 1e-12)
        e.redo()
        e.trimCalloutEnd(a.id, by: 1); XCTAssertEqual(e.project.callouts[0].duration, 1, accuracy: 1e-9)
        e.trimCalloutStart(a.id, by: 0.5); XCTAssertEqual(e.project.callouts[0].start, 1.5, accuracy: 1e-9)
        let f = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/callout-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f)
        XCTAssertEqual(try ProjectStore.load(from: f), e.project)
        var p = SadrogProject(name: "x"); p.callouts = [Callout(start: 0, duration: 4)]
        XCTAssertTrue(p.needsCompositing); XCTAssertEqual(p.timelineEnd, 4, accuracy: 1e-9)
    }

    func testOutsideIsDarkenedInsideUntouchedOnlyWhileTheCalloutLastsAndLaneSwitchHidesIt() async throws {
        try XCTSkipUnless(haveColours, "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: dir + "/red.mov", sourceStart: 0, duration: 3)])
        p.callouts = [Callout(start: 1, duration: 1, x: 0.25, y: 0.25, w: 0.5, h: 0.5, dim: 0.6, blur: 0, corner: 0)]
        var url = try await helper.export(p); defer { try? FileManager.default.removeItem(at: url) }
        let inside = try await helper.pixel(url, at: 1.5, x: 0.5, y: 0.5), outside = try await helper.pixel(url, at: 1.5, x: 0.1, y: 0.1)
        let before = try await helper.pixel(url, at: 0.5, x: 0.1, y: 0.1), after = try await helper.pixel(url, at: 2.5, x: 0.1, y: 0.1)
        let top = try await helper.pixel(url, at: 1.5, x: 0.5, y: 0.1)                               // y down: above the region
        XCTAssertGreaterThan(inside.0, 200)
        XCTAssertEqual(outside.0, 255 * 0.4, accuracy: 12); XCTAssertEqual(top.0, 255 * 0.4, accuracy: 12)
        XCTAssertGreaterThan(before.0, 200); XCTAssertGreaterThan(after.0, 200)
        let d = try await AVURLAsset(url: url).load(.duration).seconds; XCTAssertEqual(d, 3, accuracy: 0.1)
        p.hiddenLanes = [.c]; try? FileManager.default.removeItem(at: url); url = try await helper.export(p)
        let hidden = try await helper.pixel(url, at: 1.5, x: 0.1, y: 0.1); XCTAssertGreaterThan(hidden.0, 200)
    }

    func testBlurSpreadsOnlyOutsideTheRegion() async throws {
        try XCTSkipUnless(haveColours, "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: dir + "/blue.mov", sourceStart: 0, duration: 2)])
        p.layers = [Layer(kind: .video, media: dir + "/red.mov", start: 0, duration: 2, transform: Transform(x: 0.25, scale: 0.3))]   // red box right of centre
        let plain = try await helper.export(p); defer { try? FileManager.default.removeItem(at: plain) }
        p.callouts = [Callout(start: 0, duration: 2, x: 0.0, y: 0.0, w: 0.5, h: 1, dim: 0, blur: 1, corner: 0)]                      // left half sharp, right half blurred
        let blurred = try await helper.export(p); defer { try? FileManager.default.removeItem(at: blurred) }
        // a point just outside the red box (its edge is at x≈0.9): untouched when plain, picks up red when blurred
        let a = try await helper.pixel(plain, at: 1, x: 0.915, y: 0.5), b = try await helper.pixel(blurred, at: 1, x: 0.915, y: 0.5)
        XCTAssertGreaterThan(b.0, a.0 + 5)
        let l0 = try await helper.pixel(plain, at: 1, x: 0.2, y: 0.5), l1 = try await helper.pixel(blurred, at: 1, x: 0.2, y: 0.5)
        XCTAssertEqual(l0.2, l1.2, accuracy: 3)                                                       // sharp half identical
    }

    // MARK: shapes, invert, feather, freehand

    func testOldProjectsWithoutShapeKeysDecodeAsRectangles() throws {
        let c = Callout(start: 1, duration: 2)
        var obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(c)) as! [String: Any]
        for k in ["shape", "points", "invert", "feather"] { obj.removeValue(forKey: k) }
        let old = try JSONDecoder().decode(Callout.self, from: JSONSerialization.data(withJSONObject: obj))
        XCTAssertEqual(old.shape, .rect); XCTAssertFalse(old.invert); XCTAssertEqual(old.feather, 0); XCTAssertTrue(old.points.isEmpty)
        XCTAssertEqual(old, c)
    }

    func testFreehandBoxFollowsThePointsAndStaysRelative() {
        var c = Callout(start: 0)
        c.setFreehand(frame: [CalloutPoint(x: 0.2, y: 0.2), CalloutPoint(x: 0.6, y: 0.2), CalloutPoint(x: 0.4, y: 0.8)])
        XCTAssertEqual(c.shape, .freehand); XCTAssertEqual(c.x, 0.2, accuracy: 1e-12); XCTAssertEqual(c.w, 0.4, accuracy: 1e-12); XCTAssertEqual(c.h, 0.6, accuracy: 1e-12)
        XCTAssertEqual(c.points[2].x, 0.5, accuracy: 1e-12); XCTAssertEqual(c.points[2].y, 1, accuracy: 1e-12)
        var d = Callout(start: 0); d.setFreehand(frame: [CalloutPoint(x: 0, y: 0), CalloutPoint(x: 1, y: 1)])    // too few points: unchanged
        XCTAssertEqual(d.shape, .rect)
    }

    /// Exports `p` and returns the red channel at frame fractions (x, y) at time `t`.
    private func reds(_ p: SadrogProject, at t: Double, _ pts: [(Double, Double)]) async throws -> [Double] {
        let url = try await helper.export(p); defer { try? FileManager.default.removeItem(at: url) }
        var out: [Double] = []; for q in pts { out.append(try await helper.pixel(url, at: t, x: q.0, y: q.1).0) }; return out
    }

    func testEllipseFreehandInvertAndFeatherSelectTheRightPixels() async throws {
        try XCTSkipUnless(haveColours, "synthetic colour clips not available")
        let base = SadrogProject(name: "t", clips: [Clip(media: dir + "/red.mov", sourceStart: 0, duration: 2)])
        let dark = 255 * 0.4
        // ellipse in the box (0.2…0.8): centre kept, box corner (outside the ellipse) darkened
        var p = base; p.callouts = [Callout(start: 0, duration: 2, x: 0.2, y: 0.2, w: 0.6, h: 0.6, dim: 0.6, shape: .ellipse)]
        var r = try await reds(p, at: 1, [(0.5, 0.5), (0.22, 0.22), (0.05, 0.05)])
        XCTAssertGreaterThan(r[0], 200); XCTAssertEqual(r[1], dark, accuracy: 14); XCTAssertEqual(r[2], dark, accuracy: 14)
        // triangle (apex top): point inside kept, point beside it darkened
        var f = Callout(start: 0, duration: 2, dim: 0.6); f.setFreehand(frame: [CalloutPoint(x: 0.5, y: 0.1), CalloutPoint(x: 0.9, y: 0.9), CalloutPoint(x: 0.1, y: 0.9)])
        p = base; p.callouts = [f]
        r = try await reds(p, at: 1, [(0.5, 0.7), (0.15, 0.3)])
        XCTAssertGreaterThan(r[0], 200); XCTAssertEqual(r[1], dark, accuracy: 14)
        // inverted: the effect goes INSIDE, the outside stays
        p = base; p.callouts = [Callout(start: 0, duration: 2, x: 0.25, y: 0.25, w: 0.5, h: 0.5, dim: 0.6, corner: 0, shape: .rect, invert: true)]
        r = try await reds(p, at: 1, [(0.5, 0.5), (0.1, 0.1)])
        XCTAssertEqual(r[0], dark, accuracy: 14); XCTAssertGreaterThan(r[1], 200)
        // feather: right on the edge the value is between kept and darkened, and the box centre is still kept
        p = base; p.callouts = [Callout(start: 0, duration: 2, x: 0.25, y: 0.25, w: 0.5, h: 0.5, dim: 0.6, corner: 0, feather: 0.6)]
        r = try await reds(p, at: 1, [(0.5, 0.5), (0.25, 0.5), (0.02, 0.02)])
        XCTAssertGreaterThan(r[0], 240); XCTAssertGreaterThan(r[1], dark + 20); XCTAssertLessThan(r[1], 255 - 20); XCTAssertEqual(r[2], dark, accuracy: 14)
    }

    /// Demo frames for the report: dark outside (rectangle, circle, freehand) and blurred inside, on the demo project's own material.
    func testWritesDemoFramesForTheShapes() async throws {
        let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG"
        let f = URL(fileURLWithPath: root + "/ui_screens/dest_editor/SADROG-5A1D0C11-2B7E-4C55-9A31-0E5D7F2A6B90/project.sadrogproj")
        var p = try ProjectStore.load(from: f)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: p.clips[0].media), "demo media not available")
        var c = p.clips[0]; c.duration = 4; c.transform = Transform(); c.endTransform = nil
        p.clips = [c]; p.layers = []; p.texts = []; p.hiddenLanes = []; p.mutedLanes = []
        var tri = Callout(start: 2, duration: 1, dim: 0.65); tri.setFreehand(frame: [CalloutPoint(x: 0.3, y: 0.2), CalloutPoint(x: 0.75, y: 0.3), CalloutPoint(x: 0.6, y: 0.85), CalloutPoint(x: 0.35, y: 0.7)])
        p.callouts = [
            Callout(start: 0, duration: 1, x: 0.3, y: 0.25, w: 0.4, h: 0.45, dim: 0.65, corner: 0.08),
            Callout(start: 1, duration: 1, x: 0.5 - 0.225 * 720 / 1280, y: 0.275, w: 0.45 * 720 / 1280, h: 0.45, dim: 0.65, shape: .ellipse, feather: 0.3),   // circle: equal pixel width and height
            tri,
            Callout(start: 3, duration: 1, x: 0.25, y: 0.3, w: 0.5, h: 0.25, dim: 0, blur: 1, corner: 0.1, invert: true)]
        let out = URL(fileURLWithPath: root + "/ui_screens/callout_v9/demo_shapes.mov"); try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true); try? FileManager.default.removeItem(at: out)
        try await ProjectExporter.export(p, to: out)
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        for (i, t) in [0.5, 1.5, 2.5, 3.5].enumerated() {
            let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
            try NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: root + "/ui_screens/callout_v9/shape_\(i).png"))
        }
    }

    // MARK: magnification, outline, shadow
    func testMagnifyOutlineAndShadowAffectOnlyTheirPixels() async throws {
        try XCTSkipUnless(haveColours, "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: dir + "/blue.mov", sourceStart: 0, duration: 2)])
        p.layers = [Layer(kind: .video, media: dir + "/red.mov", start: 0, duration: 2, transform: Transform(x: 0.25, scale: 0.3))]   // red box ≈ x 0.6…0.9
        let plain = try await helper.export(p); defer { try? FileManager.default.removeItem(at: plain) }
        // magnification ×2 about the box centre (0.75, 0.5): the red box grows to ≈ 0.45…1.05, so x=0.97 turns red INSIDE the box only
        p.callouts = [Callout(start: 0, duration: 2, x: 0.5, y: 0.2, w: 0.5, h: 0.6, dim: 0, blur: 0, corner: 0, magnify: 1)]
        let mag = try await helper.export(p); defer { try? FileManager.default.removeItem(at: mag) }
        let a = try await helper.pixel(plain, at: 1, x: 0.97, y: 0.5), b = try await helper.pixel(mag, at: 1, x: 0.97, y: 0.5)
        XCTAssertLessThan(a.0, 60); XCTAssertGreaterThan(b.0, 200, "the magnified red box reaches x=0.97")
        let o0 = try await helper.pixel(plain, at: 1, x: 0.3, y: 0.5), o1 = try await helper.pixel(mag, at: 1, x: 0.3, y: 0.5)
        XCTAssertEqual(o0.0, o1.0, accuracy: 2); XCTAssertEqual(o0.2, o1.2, accuracy: 2)             // outside the box: untouched
        // outline: a yellow ring just outside the left edge (x=0.5), nothing far away
        p.callouts = [Callout(start: 0, duration: 2, x: 0.5, y: 0.2, w: 0.4, h: 0.6, dim: 0, blur: 0, corner: 0, outline: 0.5, outlineColor: TextColor(r: 1, g: 1, b: 0))]
        let ol = try await helper.export(p); defer { try? FileManager.default.removeItem(at: ol) }
        let ring = try await helper.pixel(ol, at: 1, x: 0.497, y: 0.5), far = try await helper.pixel(ol, at: 1, x: 0.3, y: 0.5)
        XCTAssertGreaterThan(ring.0, 200); XCTAssertGreaterThan(ring.1, 200); XCTAssertLessThan(ring.2, 60)
        XCTAssertEqual(far.2, o0.2, accuracy: 2)
        // shadow: darkens the area just outside the box, not the inside
        p.callouts = [Callout(start: 0, duration: 2, x: 0.5, y: 0.2, w: 0.4, h: 0.6, dim: 0, blur: 0, corner: 0, shadow: 1)]
        let sh = try await helper.export(p); defer { try? FileManager.default.removeItem(at: sh) }
        let near = try await helper.pixel(sh, at: 1, x: 0.49, y: 0.5), inside = try await helper.pixel(sh, at: 1, x: 0.55, y: 0.5)
        XCTAssertLessThan(near.2, o0.2 - 20); XCTAssertEqual(inside.2, o0.2, accuracy: 3)
    }
    func testOldCalloutsDecodeWithoutMagnifyOutlineShadow() throws {
        let j = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":1,"duration":2,"x":0.1,"y":0.1,"w":0.3,"h":0.3,"dim":0.5,"blur":0,"corner":0.1}"#
        let c = try JSONDecoder().decode(Callout.self, from: Data(j.utf8))
        XCTAssertEqual(c.magnify, 0); XCTAssertEqual(c.outline, 0); XCTAssertEqual(c.shadow, 0)
    }

    // MARK: rectangular crop
    func testRectCropIsNonDestructiveAndChangesTheShownPicture() async throws {
        try XCTSkipUnless(haveColours, "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: dir + "/blue.mov", sourceStart: 0, duration: 2)])
        p.layers = [Layer(kind: .video, media: dir + "/red.mov", start: 0, duration: 2, transform: Transform(x: 0.25, scale: 0.3))]   // red box ≈ x 0.6…0.9
        let plain = try await helper.export(p); defer { try? FileManager.default.removeItem(at: plain) }
        p.layers[0].rectCrop = RectCrop(left: 0.5)
        let cut = try await helper.export(p); defer { try? FileManager.default.removeItem(at: cut) }
        let a = try await helper.pixel(plain, at: 1, x: 0.62, y: 0.5), b = try await helper.pixel(cut, at: 1, x: 0.62, y: 0.5)
        XCTAssertGreaterThan(a.0, 200); XCTAssertLessThan(b.0, 60, "half the picture is cut: the box is narrower")
        let c = try await helper.pixel(cut, at: 1, x: 0.75, y: 0.5); XCTAssertGreaterThan(c.0, 200)
        // model: sides clamp, never collapse; round-trips; old clips have none
        var r = RectCrop(left: 0.9, right: 0.9, top: -1, bottom: .nan); r.normalize()
        XCTAssertLessThanOrEqual(r.left + r.right, 0.9501); XCTAssertEqual(r.top, 0); XCTAssertEqual(r.bottom, 0)
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode({ var k = Clip(media: "/x", sourceStart: 0, duration: 1); k.rectCrop = RectCrop(top: 0.1); return k }()))
        XCTAssertEqual(back.rectCrop?.top, 0.1)
        XCTAssertNil(try JSONDecoder().decode(Clip.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","media":"/x","sourceStart":0,"duration":1}"#.utf8)).rectCrop)
    }
}
