import XCTest
@testable import SadrogCore

final class TimelineLayoutTests: XCTestCase {
    func testDefaultAndPartialOrderAreCompleted() {
        var l = TimelineLayout(); XCTAssertTrue(l.isDefault); XCTAssertEqual(l.displayOrder, TimelineLayout.defaultOrder)
        l.order = ["a1", "bogus", "t"]; XCTAssertEqual(l.displayOrder, [.a1, .t, .c, .v2, .v1, .a2])
    }
    func testHeightClampsAndResets() {
        var l = TimelineLayout(); l.setHeight(.a1, 5); XCTAssertEqual(l.height(.a1), 18); l.setHeight(.a1, 9999); XCTAssertEqual(l.height(.a1), 420)
        l.setHeight(.a1, 120.4); XCTAssertEqual(l.height(.a1), 120); l.resetHeight(.a1); XCTAssertNil(l.height(.a1)); XCTAssertTrue(l.isDefault)
    }
    func testMoveKeepsEveryLaneOnceAndHeightsFollowTheLane() {
        var l = TimelineLayout(); l.setHeight(.a1, 200)
        XCTAssertTrue(l.move(.a1, to: 0)); XCTAssertEqual(l.displayOrder, [.a1, .t, .c, .v2, .v1, .a2]); XCTAssertEqual(l.height(.a1), 200)
        XCTAssertFalse(l.move(.a1, to: 0)); XCTAssertTrue(l.move(.t, to: 99)); XCTAssertEqual(l.displayOrder.last, .t); XCTAssertEqual(Set(l.displayOrder).count, 6)
    }
    func testEditorOneUndoPerOperationAndOnlyPresentationChanges() {
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/x.mov", sourceStart: 0, duration: 5)]))
        let before = ed.project; let content = (before.clips, before.layers, before.sourceGains, before.mutedSources, before.lockedLanes, before.hiddenLanes, before.mutedLanes, before.trackNames)
        ed.setLaneHeight(.a1, 160); ed.moveLane(.a1, to: 1); ed.moveLane(.v2, to: 5)
        let a = ed.project; XCTAssertEqual(a.layout.height(.a1), 160); XCTAssertEqual(a.layout.displayOrder, [.t, .a1, .c, .v1, .a2, .v2])
        XCTAssertTrue(a.clips == before.clips && a.layers == before.layers && a.sourceGains == before.sourceGains && a.mutedSources == before.mutedSources && a.lockedLanes == before.lockedLanes && a.hiddenLanes == before.hiddenLanes && a.mutedLanes == before.mutedLanes && a.trackNames == before.trackNames)
        _ = content
        ed.undo(); XCTAssertEqual(ed.project.layout.displayOrder, [.t, .a1, .c, .v2, .v1, .a2]); ed.undo(); XCTAssertEqual(ed.project.layout.displayOrder, TimelineLayout.defaultOrder)
        ed.undo(); XCTAssertTrue(ed.project.layout.isDefault); ed.redo(); XCTAssertEqual(ed.project.layout.height(.a1), 160)
        ed.resetLayout(); XCTAssertTrue(ed.project.layout.isDefault)
    }
    func testSavedAndReopenedKeepsLayoutAndOldFilesDecodeToDefault() throws {
        var p = SadrogProject(name: "t"); p.layout.setHeight(.a1, 150); p.layout.move(.c, to: 5)
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("lay-\(UUID().uuidString).sadrogproj")
        try ProjectStore.save(p, to: d); let q = try ProjectStore.load(from: d); XCTAssertEqual(q.layout, p.layout)
        let old = try JSONSerialization.jsonObject(with: JSONEncoder().encode(SadrogProject(name: "o"))) as! [String: Any]
        var o = old; o["layout"] = nil; let r = try JSONDecoder().decode(SadrogProject.self, from: JSONSerialization.data(withJSONObject: o)); XCTAssertTrue(r.layout.isDefault)
    }
}

/// Row-level reorder inside V2 / A2: items, names follow the track; others shift by one; one undo; stacking meaning of V2 kept.
final class RowMoveTests: XCTestCase {
    private func layer(_ row: Int, _ kind: LayerKind, start: Double) -> Layer {
        var l = Layer(kind: kind, media: "/m\(row).mov", start: start, duration: 2); l.track = row == 0 ? nil : row; return l
    }
    func testMoveRowShiftsTheOthersAndNamesFollow() {
        var p = SadrogProject(name: "t")
        p.layers = [layer(0, .video, start: 0), layer(1, .video, start: 0), layer(2, .video, start: 0)]
        p.trackNames["v2.0"] = "zero"; p.trackNames["v2.2"] = "doi"
        let ed = ProjectEditor(project: p)
        XCTAssertTrue(ed.moveRow(.v2, from: 0, to: 2))
        XCTAssertEqual(ed.project.layers.map(\.row), [2, 0, 1], "moved track at the new place, the two others shifted down")
        XCTAssertEqual(ed.project.trackNames["v2.2"], "zero"); XCTAssertEqual(ed.project.trackNames["v2.1"], "doi")
        ed.undo(); XCTAssertEqual(ed.project.layers.map(\.row), [0, 1, 2]); XCTAssertEqual(ed.project.trackNames["v2.0"], "zero")
        ed.redo(); XCTAssertEqual(ed.project.layers.map(\.row), [2, 0, 1])
        XCTAssertFalse(ed.moveRow(.v2, from: 1, to: 1)); XCTAssertFalse(ed.moveRow(.v2, from: 0, to: 9))
    }
}

/// Each editable row (a track of V2 / A2 / effects) has its own height, tied to the TRACK: it follows reorder, removal of another track and reopening.
final class RowHeightTests: XCTestCase {
    private func layer(_ row: Int, _ kind: LayerKind) -> Layer { var l = Layer(kind: kind, media: "/m\(row).m4a", start: 0, duration: 2); l.track = row == 0 ? nil : row; return l }
    private func project() -> SadrogProject {
        var p = SadrogProject(name: "t"); p.layers = [layer(0, .audio), layer(1, .audio), layer(2, .audio)]; return p
    }
    func testOneRowIsResizedWithoutTouchingTheOthersOrTheLane() {
        let ed = ProjectEditor(project: project()); ed.setRowHeight(.a2, 1, 140)
        XCTAssertEqual(ed.project.layout.rowHeight(.a2, 1), 140); XCTAssertNil(ed.project.layout.rowHeight(.a2, 0)); XCTAssertNil(ed.project.layout.rowHeight(.a2, 2)); XCTAssertNil(ed.project.layout.height(.a2))
        ed.setRowHeight(.a2, 1, 9999); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 1), TimelineLayout.heightRange.upperBound, "clamped")
        ed.undo(); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 1), 140); ed.setRowHeight(.a2, 1, nil); XCTAssertNil(ed.project.layout.rowHeight(.a2, 1))
    }
    func testHeightFollowsTheTrackOnMoveSwapAndRemove() {
        let ed = ProjectEditor(project: project()); ed.setRowHeight(.a2, 0, 200); ed.setRowHeight(.a2, 2, 60)
        XCTAssertTrue(ed.moveRow(.a2, from: 0, to: 2))     // track 0 goes to the top (row 2); the others shift down
        XCTAssertEqual(ed.project.layout.rowHeight(.a2, 2), 200); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 1), 60); XCTAssertNil(ed.project.layout.rowHeight(.a2, 0))
        ed.undo(); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 0), 200); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 2), 60)
        XCTAssertTrue(ed.swapRows(.a2, 0, 2)); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 2), 200); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 0), 60)
    }
    func testRemovingAnEmptyTrackShiftsHeightsAndDropsItsOwn() {
        var p = project(); p.layers.remove(at: 1)     // row 1 is empty, rows 0 and 2 hold items
        let ed = ProjectEditor(project: p); ed.setRowHeight(.a2, 2, 90); ed.setRowHeight(.a2, 1, 120)
        XCTAssertTrue(ed.removeRow(.a2, 1)); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 1), 90, "the track above moved down with its height"); XCTAssertNil(ed.project.layout.rowHeight(.a2, 2))
    }
    func testPersistenceAndOldFilesWithoutTheKey() throws {
        let ed = ProjectEditor(project: project()); ed.setRowHeight(.a2, 1, 77)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(ed.project))
        XCTAssertEqual(back.layout.rowHeight(.a2, 1), 77)
        // a layout written by the previous build has only heights/order
        let old = try JSONDecoder().decode(TimelineLayout.self, from: Data(#"{"heights":{"a2":120},"order":[]}"#.utf8))
        XCTAssertEqual(old.height(.a2), 120); XCTAssertTrue(old.rowHeights.isEmpty)
    }
    func testResizingTheWholeLaneStartsFromAutomaticRows() {
        let ed = ProjectEditor(project: project()); ed.setRowHeight(.a2, 1, 140); ed.setLaneHeight(.a2, 200)
        XCTAssertNil(ed.project.layout.rowHeight(.a2, 1), "an explicit lane height replaces the row heights of that lane"); XCTAssertEqual(ed.project.layout.height(.a2), 200)
    }
    func testDeletingTheLastItemOfARowDropsItsHeightKeyAndUndoRedoKeepIt() {
        let p = project(); let ed = ProjectEditor(project: p); ed.setRowHeight(.a2, 2, 150); ed.setRowHeight(.a2, 0, 90)
        ed.deleteLayer(p.layers[2].id)                        // the top row has no items left: its key must not survive
        XCTAssertNil(ed.project.layout.rowHeight(.a2, 2)); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 0), 90)
        ed.undo(); XCTAssertEqual(ed.project.layout.rowHeight(.a2, 2), 150, "undo restores the height with the track")
        ed.redo(); XCTAssertNil(ed.project.layout.rowHeight(.a2, 2))
        // a new track created afterwards starts automatic, it does not inherit the stale value
        var nl = Layer(kind: .audio, media: "/n.m4a", start: 0, duration: 1); nl.track = 2; ed.addLayer(nl)
        XCTAssertNil(ed.project.layout.rowHeight(.a2, 2))
    }
}
