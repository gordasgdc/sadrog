// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// „Încadrează imaginea în cerc”: the picture moves/scales under a fixed circle; the window never leaves the source (no gaps).
final class CircleFramingTests: XCTestCase {
    let n = CGSize(width: 1920, height: 1080)

    func testPanMovesPictureOppositeToWindowAndKeepsCircleAndZoom() {
        var c = CircleCrop(); c.zoom = 2
        let w0 = c.window(in: n)
        c.pan(imageBy: CGSize(width: 100, height: -40), in: n)
        let w1 = c.window(in: n)
        XCTAssertEqual(w1.minX, w0.minX - 100, accuracy: 0.6); XCTAssertEqual(w1.minY, w0.minY + 40, accuracy: 0.6)
        XCTAssertEqual(w1.width, w0.width, accuracy: 0.001); XCTAssertEqual(c.zoom, 2)
    }
    func testPanIsClampedInsideSource() {
        var c = CircleCrop(); c.zoom = 2
        c.pan(imageBy: CGSize(width: 99999, height: 99999), in: n)
        var w = c.window(in: n); XCTAssertGreaterThanOrEqual(w.minX, -0.5); XCTAssertGreaterThanOrEqual(w.minY, -0.5)
        c.pan(imageBy: CGSize(width: -99999, height: -99999), in: n)
        w = c.window(in: n); XCTAssertLessThanOrEqual(w.maxX, n.width + 0.5); XCTAssertLessThanOrEqual(w.maxY, n.height + 0.5)
    }
    func testZoomKeepsCentrePointWhenRoomAndNeverLeavesSource() {
        var c = CircleCrop(); c.zoom = 1.5; c.pan(imageBy: CGSize(width: 60, height: 0), in: n)
        let m0 = c.window(in: n); let centre = CGPoint(x: m0.midX, y: m0.midY)
        c.setZoom(2.5, keepingCentreIn: n)
        let m1 = c.window(in: n)
        XCTAssertEqual(m1.midX, centre.x, accuracy: 1); XCTAssertEqual(m1.midY, centre.y, accuracy: 1)
        XCTAssertEqual(m1.width, 1080 / 2.5, accuracy: 0.01)
        c.setZoom(4, keepingCentreIn: n); let m2 = c.window(in: n)
        XCTAssertTrue(CGRect(origin: .zero, size: n).insetBy(dx: -0.6, dy: -0.6).contains(m2))
    }
    func testZoomClampedToRange() {
        var c = CircleCrop(); c.setZoom(99, keepingCentreIn: n); XCTAssertEqual(c.zoom, 4)
        c.setZoom(0.1, keepingCentreIn: n); XCTAssertEqual(c.zoom, 1)
    }
    func testRecentreKeepsZoomAndBorder() {
        var c = CircleCrop(); c.zoom = 2; c.pan(imageBy: CGSize(width: 200, height: 50), in: n)
        c.recentre(); XCTAssertEqual(c.offsetX, 0); XCTAssertEqual(c.offsetY, 0); XCTAssertEqual(c.zoom, 2)
    }
    func testFramingIsCodableRoundTripAndGestureIsDeterministic() throws {
        // one gesture = pan from the SAME start state with the final translation → same result whatever the intermediate steps
        var base = CircleCrop(); base.zoom = 2
        var a = base; a.pan(imageBy: CGSize(width: 70, height: 30), in: n)
        var b = base; for _ in 0..<7 { var t = base; t.pan(imageBy: CGSize(width: 70, height: 30), in: n); b = t }
        XCTAssertEqual(a, b)
        let d = try JSONEncoder().encode(a); XCTAssertEqual(try JSONDecoder().decode(CircleCrop.self, from: d), a)
    }
}
