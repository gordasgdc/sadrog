// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

final class CalloutBandsTests: XCTestCase {
    private func project() -> (SadrogProject, UUID, UUID) {
        let a = Clip(media: "/a", sourceStart: 0, duration: 10), b = Clip(media: "/b", sourceStart: 0, duration: 10)
        return (SadrogProject(name: "t", clips: [a, b]), a.id, b.id)
    }
    func testAttachedEffectsStackInsideTheirOwnTargetInStartOrder() {
        var (p, a, b) = project()
        var c1 = Callout(start: 2, duration: 3); c1.clipID = a
        var c2 = Callout(start: 3, duration: 3); c2.clipID = a
        var c3 = Callout(start: 12, duration: 3); c3.clipID = b
        p.callouts = [c2, c1, c3]
        let rows = p.attachedCalloutRows()
        XCTAssertEqual(rows[c1.id], 0); XCTAssertEqual(rows[c2.id], 1); XCTAssertEqual(rows[c3.id], 0)
    }
    func testNonOverlappingEffectsOnTheSameTargetShareARow() {
        var (p, a, _) = project()
        var c1 = Callout(start: 1, duration: 2); c1.clipID = a
        var c2 = Callout(start: 4, duration: 2); c2.clipID = a
        p.callouts = [c1, c2]
        XCTAssertEqual(p.attachedCalloutRows()[c1.id], 0); XCTAssertEqual(p.attachedCalloutRows()[c2.id], 0)
    }
    func testOldGlobalEffectsStayGlobalAndAreNotReassociated() {
        var (p, a, _) = project()
        let old = Callout(start: 1, duration: 2)                       // no clipID, no layerID: an older project's effect
        var bound = Callout(start: 1, duration: 2); bound.clipID = a
        p.callouts = [old, bound]
        XCTAssertFalse(p.isAttached(old)); XCTAssertTrue(p.isAttached(bound))
        XCTAssertEqual(Set(p.globalCalloutRows().keys), [old.id])
        XCTAssertEqual(Set(p.attachedCalloutRows().keys), [bound.id])
        XCTAssertNil(p.callouts.first { $0.id == old.id }?.clipID)
    }
    func testEffectsBoundToAnOverlayAreAttachedToo() {
        var (p, _, _) = project()
        var c = Callout(start: 1, duration: 2); c.layerID = UUID()
        p.callouts = [c]
        XCTAssertTrue(p.isAttached(c)); XCTAssertEqual(p.attachedCalloutRows()[c.id], 0)
    }
}

final class CalloutBandDepthTests: XCTestCase {
    func testDepthCountsStackedRowsPerTargetKind() {
        let clip = Clip(media: "/x.mov", sourceStart: 0, duration: 10)
        var p = SadrogProject(name: "t", clips: [clip])
        XCTAssertEqual(p.attachedRowDepth.clips, 0); XCTAssertEqual(p.attachedRowDepth.layers, 0)
        var a = Callout(start: 1, duration: 4, x: 0, y: 0, w: 0.3, h: 0.3, clipID: clip.id); a.normalize()
        var b = Callout(start: 2, duration: 4, x: 0, y: 0, w: 0.3, h: 0.3, clipID: clip.id); b.normalize()
        var c = Callout(start: 8, duration: 1, x: 0, y: 0, w: 0.3, h: 0.3, clipID: clip.id); c.normalize()
        p.callouts = [a, b, c]
        XCTAssertEqual(p.attachedRowDepth.clips, 2)          // a and b overlap, c reuses row 0
        XCTAssertEqual(p.attachedRowDepth.layers, 0)
    }
}
