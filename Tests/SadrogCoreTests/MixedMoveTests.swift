import XCTest
@testable import SadrogCore

/// Moving a selection that includes main-track (V1) clips: the clips travel as one block to the nearest boundary between other clips and every other
/// selected item (camera, title, detached sound, effect) shifts by the SAME effective delta, so the relations between them are unchanged.
final class MixedMoveTests: XCTestCase {
    struct F { let e: ProjectEditor; let a, b, c: Clip; let cam: Layer; let title: TextOverlay; let sound: Layer; let fx: Callout; let other: Layer }
    func fixture() -> F {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 4), b = Clip(media: "/b.mov", sourceStart: 0, duration: 4), c = Clip(media: "/c.mov", sourceStart: 0, duration: 4)
        let cam = Layer(kind: .video, media: "/cam.mov", start: 4.5, duration: 2)
        let title = TextOverlay(text: "T", start: 5, duration: 1)
        var sound = Layer(kind: .audio, media: "/b.mov", start: 4, duration: 4); sound.linkedClip = b.id
        let fx = Callout(start: 6, duration: 1, clipID: b.id)
        let other = Layer(kind: .video, media: "/o.mov", start: 0.5, duration: 1)           // over clip A, not selected
        var p = SadrogProject(name: "t", clips: [a, b, c], layers: [cam, sound, other]); p.texts = [title]; p.callouts = [fx]
        return F(e: ProjectEditor(project: p), a: a, b: b, c: c, cam: cam, title: title, sound: sound, fx: fx, other: other)
    }
    func sel(_ f: F) -> [UUID] { [f.b.id, f.cam.id, f.title.id, f.sound.id, f.fx.id] }

    func testSegmentCameraTitleSoundAndEffectMoveLaterKeepingEveryRelation() {
        let f = fixture(); let e = f.e
        func rel(_ p: SadrogProject) -> [Double] {
            let bs = p.clipSpans.first { $0.id == f.b.id }!.start
            return [p.layers.first { $0.id == f.cam.id }!.start - bs, p.texts[0].start - bs, p.layers.first { $0.id == f.sound.id }!.start - bs, p.callouts[0].start - bs]
        }
        let before = rel(e.project)
        let r = e.moveGroup(sel(f), by: 3.4)                                                  // nearest boundary is +4 s (after clip C)
        XCTAssertEqual(r, .moved(dx: 4, mainStayed: false))
        XCTAssertEqual(e.project.clips.map(\.id), [f.a.id, f.c.id, f.b.id])
        XCTAssertEqual(e.project.clipSpans.last!.start, 8, accuracy: 1e-9)
        for (x, y) in zip(before, rel(e.project)) { XCTAssertEqual(x, y, accuracy: 1e-9) }     // identical temporal relations
        XCTAssertEqual(e.project.layers.first { $0.id == f.other.id }!.start, 0.5)            // unselected item untouched
        XCTAssertEqual(e.project.callouts[0].clipID, f.b.id)
    }
    func testLinkedSoundIsCarriedEvenWhenNotSelected() {
        let f = fixture(); let e = f.e
        _ = e.moveGroup([f.b.id, f.cam.id], by: 4)
        XCTAssertEqual(e.project.layers.first { $0.id == f.sound.id }!.start, 8, accuracy: 1e-9)   // linked to B: stays in sync
    }
    func testOneUndoStepRestoresEverything() {
        let f = fixture(); let e = f.e; let before = e.project
        _ = e.moveGroup(sel(f), by: 4)
        XCTAssertNotEqual(e.project, before)
        e.undo(); XCTAssertEqual(e.project, before); XCTAssertFalse(e.canUndo)
    }
    func testMovesEarlierToTheFront() {
        let f = fixture(); var p = f.e.project; p.layers[2].start = 10; let e = ProjectEditor(project: p)       // the unselected overlay no longer sits where the camera lands
        XCTAssertEqual(e.moveGroup(sel(f), by: -9), .moved(dx: -4, mainStayed: false))                         // boundary 0 → d = -4; every item stays ≥ 0
        XCTAssertEqual(e.project.clips.first?.id, f.b.id); XCTAssertEqual(e.project.layers.first { $0.id == f.cam.id }!.start, 0.5, accuracy: 1e-9)
    }
    func testLandingOnAnUnselectedItemOfTheSameRowIsRefusedWholeAndNothingChanges() {
        let f = fixture(); let before = f.e.project                                                           // the camera would land on `other` (0.5…1.5)
        XCTAssertEqual(f.e.moveGroup(sel(f), by: -9), .refused(.overlap)); XCTAssertEqual(f.e.project, before)
    }
    func testWhenTheItemsWouldGoBelowZeroTheNearestAllowedBoundaryIsUsed() {
        var f = fixture(); var p = f.e.project; p.layers[0].start = 3                          // camera at 3: a −4 move would put it at −1
        f = F(e: ProjectEditor(project: p), a: f.a, b: f.b, c: f.c, cam: p.layers[0], title: f.title, sound: f.sound, fx: f.fx, other: f.other)
        XCTAssertEqual(f.e.moveGroup(sel(f), by: -9), .refused(.nothing))                      // no earlier boundary keeps everything ≥ 0 → nothing moves
        XCTAssertEqual(f.e.project, p)
    }
    func testNonAdjacentClipsLockedV1AndDissolveAreRefusedWholeWithNoChange() {
        let f = fixture(); let before = f.e.project
        XCTAssertEqual(f.e.moveGroup([f.a.id, f.c.id, f.cam.id], by: 4), .refused(.notAdjacent)); XCTAssertEqual(f.e.project, before)
        f.e.setLock(.v1, true); let locked = f.e.project
        XCTAssertEqual(f.e.moveGroup(sel(f), by: 4), .refused(.locked)); XCTAssertEqual(f.e.project, locked); f.e.setLock(.v1, false)
        var p = f.e.project; p.clips[2].dissolve = 0.5; let d = ProjectEditor(project: p)
        XCTAssertEqual(d.moveGroup(sel(f), by: 4), .refused(.dissolve)); XCTAssertEqual(d.project, p)
    }
    func testLockedOverlayLaneRefusesTheWholeMove() {
        let f = fixture(); f.e.setLock(.v2, true); let before = f.e.project
        XCTAssertEqual(f.e.moveGroup(sel(f), by: 4), .refused(.locked)); XCTAssertEqual(f.e.project, before)
    }
    func testSurvivesSaveAndReopen() throws {
        let f = fixture(); _ = f.e.moveGroup(sel(f), by: 4)
        let dir = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/mixed-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectStore.save(f.e.project, to: dir)
        let back = try ProjectStore.load(from: dir)
        XCTAssertEqual(back.clips.map(\.id), [f.a.id, f.c.id, f.b.id]); XCTAssertEqual(back.texts[0].start, 9, accuracy: 1e-9)
    }
}
