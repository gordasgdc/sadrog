// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import CoreImage
@testable import SadrogCore

/// Line and arrow annotations: geometry in the box, the rasterised mask, persistence.
final class StrokeAnnotationTests: XCTestCase {
    func value(_ img: CIImage, _ x: Int, _ y: Int) -> Double {      // (x,y) in top-left coordinates
        var px = [UInt8](repeating: 0, count: 4); let h = Int(img.extent.height)
        CIContext(options: [.workingColorSpace: NSNull()]).render(img, toBitmap: &px, rowBytes: 4, bounds: CGRect(x: x, y: h - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return Double(px[0]) / 255
    }
    func testBoxAndPointsOfAHorizontalLine() {
        var c = Callout(start: 0); c.setStroke(.line, from: CalloutPoint(x: 0.2, y: 0.5), to: CalloutPoint(x: 0.6, y: 0.5))
        XCTAssertEqual(c.dim, 0); XCTAssertEqual(c.x, 0.2, accuracy: 1e-9); XCTAssertEqual(c.w, 0.4, accuracy: 1e-9); XCTAssertGreaterThanOrEqual(c.h, Callout.minSide)
        XCTAssertEqual(c.points[0].y, 0.5, accuracy: 1e-9); XCTAssertEqual(c.points[0].x, 0, accuracy: 1e-9); XCTAssertEqual(c.points[1].x, 1, accuracy: 1e-9)
    }
    func testMaskPaintsOnlyTheStroke() {
        var c = Callout(start: 0); c.setStroke(.line, from: CalloutPoint(x: 0.1, y: 0.5), to: CalloutPoint(x: 0.9, y: 0.5)); c.lineWidth = 1
        let m = CalloutMask.make(c, render: CGSize(width: 400, height: 200))
        XCTAssertGreaterThan(value(m, 200, 100), 0.9, "on the line"); XCTAssertLessThan(value(m, 200, 60), 0.05, "away from it"); XCTAssertLessThan(value(m, 10, 100), 0.05, "before its start")
    }
    func testArrowHeadIsWiderThanTheShaft() {
        var c = Callout(start: 0); c.setStroke(.arrow, from: CalloutPoint(x: 0.1, y: 0.5), to: CalloutPoint(x: 0.9, y: 0.5)); c.lineWidth = 1
        let m = CalloutMask.make(c, render: CGSize(width: 400, height: 200))
        XCTAssertLessThan(value(m, 150, 100 - 7), 0.2, "shaft is thin"); XCTAssertGreaterThan(value(m, 340, 100 - 7), 0.8, "head is wide near the base")
        XCTAssertGreaterThan(value(m, 352, 100), 0.8, "tip")
    }
    func testPersistsAndOlderCalloutsKeepTheirLook() throws {
        var c = Callout(start: 1); c.setStroke(.arrow, from: CalloutPoint(x: 0.1, y: 0.2), to: CalloutPoint(x: 0.7, y: 0.9)); c.lineWidth = 0.8
        let back = try JSONDecoder().decode(Callout.self, from: JSONEncoder().encode(c)); XCTAssertEqual(back, c)
        let old = try JSONDecoder().decode(Callout.self, from: JSONEncoder().encode(Callout(start: 1))); XCTAssertEqual(old.shape, .rect); XCTAssertEqual(old.lineWidth, 0.4)
    }
}

/// The rectangular annotation: a frame only (no darkening of anything), visible outline, editable back and forth, persisted.
final class FrameAnnotationTests: XCTestCase {
    func px(_ img: CIImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {
        var p = [UInt8](repeating: 0, count: 4); let h = Int(img.extent.height)
        CIContext(options: [.workingColorSpace: NSNull()]).render(img, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: h - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
    }
    func testFrameOnlyPaintsARingAndLeavesEverythingElseUntouched() {
        let R = CGSize(width: 400, height: 200), base = CIImage(color: CIColor(red: 0.4, green: 0.4, blue: 0.4)).cropped(to: CGRect(origin: .zero, size: R))
        var c = Callout(start: 0, x: 0.25, y: 0.25, w: 0.5, h: 0.5); c.corner = 0; c.outlineColor = TextColor(r: 1, g: 0, b: 0)
        XCTAssertFalse(c.isFrameOnly, "a default region is a spotlight")
        c.makeFrameOnly(); XCTAssertTrue(c.isFrameOnly); XCTAssertEqual(c.dim, 0); XCTAssertGreaterThan(c.outline, 0)
        let out = SadrogCompositor.apply(c, mask: CalloutMask.make(c, render: R), to: base, size: R)
        let inside = px(out, 200, 100), far = px(out, 10, 10), ring = px(out, 98, 100)   // box = x 100…300, y 50…150; the ring grows just outside it
        XCTAssertEqual(inside.r, 0.4, accuracy: 0.02, "the interior is not darkened"); XCTAssertEqual(far.r, 0.4, accuracy: 0.02, "nothing outside is darkened")
        XCTAssertGreaterThan(ring.r, 0.9, "the frame is painted in the outline colour"); XCTAssertLessThan(ring.g, 0.1)
    }
    func testSwitchingBackToSpotlightDarkensOutsideAndPersists() throws {
        var c = Callout(start: 0); c.makeFrameOnly(); c.outline = 0.5; c.makeSpotlight()
        XCTAssertFalse(c.isFrameOnly); XCTAssertEqual(c.dim, 0.6, accuracy: 1e-9); XCTAssertEqual(c.outline, 0.5, "the chosen thickness is kept")
        var f = Callout(start: 1); f.makeFrameOnly(); XCTAssertEqual(try JSONDecoder().decode(Callout.self, from: JSONEncoder().encode(f)).isFrameOnly, true)
    }
}
