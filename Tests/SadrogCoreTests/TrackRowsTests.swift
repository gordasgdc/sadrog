import XCTest
@testable import SadrogCore

final class TrackRowsTests: XCTestCase {
    private func ed() -> (ProjectEditor, Layer, Layer, Layer) {
        let v1 = Layer(kind: .video, media: "/v1", start: 0, duration: 5)
        var v2 = Layer(kind: .video, media: "/v2", start: 2, duration: 5); v2.track = 1
        let a = Layer(kind: .audio, media: "/a", start: 1, duration: 4)
        return (ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/m", sourceStart: 0, duration: 20)], layers: [v1, v2, a])), v1, v2, a)
    }
    func testSwapChangesStackingOrderOfVideoAndKeepsTimes() throws {
        let (e, v1, v2, _) = ed()
        XCTAssertTrue(e.swapRows(.v2, 0, 1))
        XCTAssertEqual(e.project.layers.first { $0.id == v1.id }?.row, 1); XCTAssertEqual(e.project.layers.first { $0.id == v2.id }?.row, 0)
        XCTAssertEqual(e.project.layers.first { $0.id == v1.id }?.start, 0); XCTAssertEqual(e.project.layers.first { $0.id == v2.id }?.start, 2)
        e.undo(); XCTAssertEqual(e.project.layers.first { $0.id == v1.id }?.row, 0)
        XCTAssertFalse(e.swapRows(.v2, 0, 5)); XCTAssertFalse(e.swapRows(.a2, 0, 0))
    }
    func testPlaceMovesTimeAndRowAtomicallyAndRefusesCollisionWithoutLoss() {
        let (e, v1, v2, _) = ed()
        XCTAssertFalse(e.placeLayer(v1.id, start: 2, row: 1), "v2 occupies 2–7 on row 1")
        XCTAssertEqual(e.project.layers.count, 3); XCTAssertEqual(e.project.layers.first { $0.id == v1.id }?.start, 0)
        XCTAssertTrue(e.placeLayer(v1.id, start: 8, row: 1)); XCTAssertEqual(e.project.layers.first { $0.id == v1.id }?.row, 1)
        XCTAssertTrue(e.placeLayer(v2.id, start: 2, row: 2), "one past the last row creates a track")
        XCTAssertEqual(e.project.rowCount(.v2), 3)
    }
    func testCreateRenameRemoveEmptyRowAndReload() throws {
        let (e, _, v2, _) = ed()
        XCTAssertTrue(e.addRow(.v2)); XCTAssertEqual(e.project.rowCount(.v2), 3)
        XCTAssertTrue(e.setTrackName(.v2, 1, "Cameră")); XCTAssertEqual(e.project.trackNames["v2.1"], "Cameră")
        XCTAssertFalse(e.removeRow(.v2, 1), "holds an item")
        XCTAssertTrue(e.removeRow(.v2, 2)); XCTAssertEqual(e.project.rowCount(.v2), 2)
        XCTAssertTrue(e.placeLayer(v2.id, start: 6, row: 0)); XCTAssertTrue(e.removeRow(.v2, 1)); XCTAssertEqual(e.project.rowCount(.v2), 1); XCTAssertNil(e.project.trackNames["v2.1"])
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project)); XCTAssertEqual(back, e.project)
        let old = try JSONDecoder().decode(SadrogProject.self, from: Data(#"{"formatVersion":14,"name":"o","clips":[]}"#.utf8)); XCTAssertEqual(old.rowCount(.a2), 1)
    }
    func testLockedLaneRefusesRowEdits() {
        let (e0x, v1, _, _) = ed(); var pl = e0x.project; pl.lockedLanes = [.v2]; let e = ProjectEditor(project: pl); _ = e0x
        XCTAssertFalse(e.swapRows(.v2, 0, 1)); XCTAssertFalse(e.placeLayer(v1.id, start: 9, row: 0))
    }
}
