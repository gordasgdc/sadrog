// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Rectangle selection on a timeline larger than the visible area: the autoscroll step and the pointer → content coordinate conversion, with no test hook in the product.
final class MarqueeAutoscrollTests: XCTestCase {
    private func step(_ p: CGPoint, zoom: Double = 4, ox: CGFloat = 400, oy: CGFloat = 50, contentH: CGFloat = 900) -> MarqueeAutoscroll.Step {
        MarqueeAutoscroll.step(pointer: p, viewW: 1000, contentW: 4000, viewportH: 500, contentH: contentH, rulerH: 24, zoom: zoom, offsetX: ox, offsetY: oy)
    }
    func testPointerInTheMiddleDoesNotScrollAndCornerIsInContentCoordinates() {
        let s = step(CGPoint(x: 500, y: 250)); XCTAssertEqual(s.offsetX, 400); XCTAssertEqual(s.offsetY, 50); XCTAssertEqual(s.corner, CGPoint(x: 900, y: 300))
    }
    func testRightAndLeftEdgesScrollHorizontallyAndStayClamped() {
        XCTAssertGreaterThan(step(CGPoint(x: 990, y: 250)).offsetX, 400)
        XCTAssertLessThan(step(CGPoint(x: 3, y: 250)).offsetX, 400)
        XCTAssertEqual(step(CGPoint(x: 3, y: 250), ox: 0).offsetX, 0, "never before the start")
        XCTAssertEqual(step(CGPoint(x: 999, y: 250), ox: 3000).offsetX, 3000, "never past the end (content 4000 − view 1000)")
    }
    func testBottomAndTopEdgesScrollVerticallyWithinContent() {
        XCTAssertGreaterThan(step(CGPoint(x: 500, y: 495)).offsetY, 50)
        XCTAssertLessThan(step(CGPoint(x: 500, y: 30)).offsetY, 50)       // inside the ruler + edge band
        XCTAssertEqual(step(CGPoint(x: 500, y: 495), oy: 400).offsetY, 400, "content 900 − viewport 500")
        XCTAssertEqual(step(CGPoint(x: 500, y: 495), contentH: 480).offsetY, 50, "everything fits: no vertical scroll")
    }
    func testNoHorizontalScrollWhenTheTimelineIsNotZoomed() {
        XCTAssertEqual(step(CGPoint(x: 995, y: 250), zoom: 1).offsetX, 400)
    }
    func testSpeedGrowsTowardTheEdgeAndHasAMinimum() {
        let near = step(CGPoint(x: 975, y: 250)).offsetX - 400, far = step(CGPoint(x: 1000, y: 250)).offsetX - 400
        XCTAssertGreaterThanOrEqual(near, 4); XCTAssertGreaterThan(far, near)
    }
    func testCornerFollowsTheScrolledOffsets() {
        let s = step(CGPoint(x: 995, y: 495)); XCTAssertEqual(s.corner.x, 995 + s.offsetX); XCTAssertEqual(s.corner.y, 495 + s.offsetY)
    }
}
