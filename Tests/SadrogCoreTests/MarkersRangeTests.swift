// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Timeline markers and the In/Out work range: undoable, persisted, and only the export uses the range.
final class MarkersRangeTests: XCTestCase {
    func editor() -> ProjectEditor { ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 10)])) }

    func testMarkersAreSortedClampedUniqueAndUndoable() {
        let e = editor()
        let b = e.addMarker(at: 6, name: "b"), a = e.addMarker(at: 2)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertNil(e.addMarker(at: 2.02), "a second marker at the same spot is not created")
        XCTAssertNotNil(e.addMarker(at: 99)); XCTAssertEqual(e.project.markers.map(\.time), [2, 6, 10])
        e.renameMarker(b!, "Intro"); XCTAssertEqual(e.project.markers[1].name, "Intro")
        e.removeMarker(a!); XCTAssertEqual(e.project.markers.count, 2)
        e.undo(); XCTAssertEqual(e.project.markers.count, 3)
        e.undo(); XCTAssertEqual(e.project.markers[1].name, "b")
    }
    func testRangeKeepsInBeforeOutAndClamps() {
        let e = editor()
        e.setRange(in: 3); XCTAssertEqual(e.project.exportRange, 3...10)
        e.setRange(out: 8); XCTAssertEqual(e.project.exportRange, 3...8)
        e.setRange(in: 9); XCTAssertNil(e.project.rangeOut, "In past Out opens Out"); XCTAssertEqual(e.project.exportRange, 9...10)
        e.setRange(out: 4); XCTAssertNil(e.project.rangeIn, "Out before In opens In"); XCTAssertEqual(e.project.exportRange, 0...4)
        e.clearRange(); XCTAssertNil(e.project.exportRange)
        e.undo(); XCTAssertEqual(e.project.exportRange, 0...4)
    }
    func testPersistsAndOlderFilesHaveNone() throws {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 10)])
        p.markers = [TimelineMarker(time: 1.5, name: "x")]; p.rangeIn = 1; p.rangeOut = 7
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(back.markers, p.markers); XCTAssertEqual(back.exportRange, 1...7)
        let old = #"{"formatVersion":12,"name":"o","clips":[]}"#.data(using: .utf8)!
        let o = try JSONDecoder().decode(SadrogProject.self, from: old); XCTAssertTrue(o.markers.isEmpty); XCTAssertNil(o.exportRange)
    }
}
