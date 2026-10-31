// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Operations on an effect that belongs to a clip: the target and the relative time survive every edit.
final class CalloutOperationsTests: XCTestCase {
    private func fixture() -> (ProjectEditor, Clip.ID, Callout.ID) {
        let clip = Clip(media: "/x.mov", sourceStart: 0, duration: 10)
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [clip]))
        var c = Callout(start: 2, duration: 3, x: 0.1, y: 0.1, w: 0.3, h: 0.3, clipID: clip.id); c.normalize(); ed.addCallout(c)
        return (ed, clip.id, ed.project.callouts[0].id)
    }
    func testDeletingTheBandKeepsTheClip() {
        let (ed, clip, cid) = fixture()
        ed.delete(items: [cid])
        XCTAssertTrue(ed.project.callouts.isEmpty); XCTAssertEqual(ed.project.clips.map(\.id), [clip])
        ed.undo(); XCTAssertEqual(ed.project.callouts.count, 1); ed.redo(); XCTAssertTrue(ed.project.callouts.isEmpty)
    }
    func testDuplicatedBandStaysOnItsTargetInsideTheClipAndNeverShiftsOthers() {
        let (ed, clip, cid) = fixture()
        var other = Callout(start: 5, duration: 2, x: 0, y: 0, w: 0.3, h: 0.3, clipID: clip); other.normalize(); ed.addCallout(other)
        let oid = ed.project.callouts.last!.id
        let made = ed.duplicate(items: [cid])
        XCTAssertEqual(made.count, 1)
        let d = ed.project.callouts.first { $0.id == made[0] }!
        XCTAssertEqual(d.clipID, clip)
        XCTAssertGreaterThanOrEqual(d.start, 0); XCTAssertLessThanOrEqual(d.end, 10 + 1e-6)
        let o = ed.project.callouts.first { $0.id == oid }!
        XCTAssertEqual(o.start, 5, accuracy: 1e-9)                       // the neighbour was not pushed
    }
    func testDuplicateAtTheEndOfTheClipStillFitsAndStaysAttached() {
        let clip = Clip(media: "/x.mov", sourceStart: 0, duration: 10)
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [clip]))
        var c = Callout(start: 7, duration: 3, x: 0, y: 0, w: 0.3, h: 0.3, clipID: clip.id); c.normalize(); ed.addCallout(c)
        let made = ed.duplicate(items: [ed.project.callouts[0].id])
        let d = ed.project.callouts.first { $0.id == made[0] }!
        XCTAssertEqual(d.clipID, clip.id); XCTAssertLessThanOrEqual(d.end, 10 + 1e-6); XCTAssertGreaterThanOrEqual(d.duration, SadrogProject.minCalloutLength)
    }
    func testCuttingTheClipMovesTheBandToThePieceItStartsIn() {
        let (ed, clip, cid) = fixture()
        ed.split(at: 3.5)                                                   // inside the band 2…5
        let c = ed.project.callouts.first { $0.id == cid }!
        XCTAssertEqual(c.clipID, clip); XCTAssertEqual(c.start, 2, accuracy: 1e-9); XCTAssertLessThanOrEqual(c.end, 3.5 + 1e-6)
    }
    func testTrimmingTheClipStartShiftsTheBandKeepingItsPlaceInTheClip() {
        let (ed, clip, cid) = fixture()
        ed.trimStart(clip: clip, by: 1)
        let c = ed.project.callouts.first { $0.id == cid }!
        XCTAssertEqual(c.clipID, clip); XCTAssertEqual(c.start, 1, accuracy: 1e-9); XCTAssertEqual(c.duration, 3, accuracy: 1e-9)
    }
    func testTrimmingTheClipEndShortensTheBand() {
        let (ed, clip, cid) = fixture()
        ed.trimEnd(clip: clip, by: 6)                                       // clip 0…4
        let c = ed.project.callouts.first { $0.id == cid }!
        XCTAssertEqual(c.clipID, clip); XCTAssertEqual(c.end, 4, accuracy: 1e-9)
    }
    func testSaveAndReopenKeepTargetAndInterval() throws {
        let (ed, clip, cid) = fixture()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("band-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectStore.save(ed.project, to: dir.appendingPathComponent("project.sadrogproj"))
        let back = try ProjectStore.load(from: dir.appendingPathComponent("project.sadrogproj"))
        let c = back.callouts.first { $0.id == cid }!
        XCTAssertEqual(c.clipID, clip); XCTAssertEqual(c.start, 2, accuracy: 1e-9); XCTAssertEqual(c.duration, 3, accuracy: 1e-9)
    }
}
