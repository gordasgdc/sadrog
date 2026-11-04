// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// A cut V1 segment lifted onto a V2 row: properties and sound links kept, V1 closed up, everything after it in sync, one undo step, saved and reopened.
final class MoveToOverlayTests: XCTestCase {
    private func setup() -> (ProjectEditor, [Clip]) {
        var a = Clip(media: "/a.mov", sourceStart: 0, duration: 4)
        var b = Clip(media: "/a.mov", sourceStart: 4, duration: 3, transform: Transform(x: 0.1, y: 0.2, scale: 0.5), endTransform: Transform(x: 0, y: 0, scale: 0.7))
        b.crop = CircleCrop(); b.label = "Mijloc"
        var c = Clip(media: "/a.mov", sourceStart: 7, duration: 5)
        a.audio = nil; c.audio = nil
        let p = SadrogProject(name: "t", clips: [a, b, c])
        let e = ProjectEditor(project: p)
        return (e, [a, b, c])
    }
    func testMoveKeepsPropertiesLinksAndClosesV1() throws {
        let (e, cl) = setup()
        e.addText(TextOverlay(text: "după", start: 8, duration: 2))
        let lid = try XCTUnwrap(e.moveClipToOverlay(cl[1].id))
        XCTAssertEqual(lid, cl[1].id)
        XCTAssertEqual(e.project.clips.map(\.id), [cl[0].id, cl[2].id])
        let l = try XCTUnwrap(e.project.layers.first { $0.id == lid })
        XCTAssertEqual(l.kind, .video); XCTAssertEqual(l.start, 4, accuracy: 1e-9); XCTAssertEqual(l.duration, 3)
        XCTAssertEqual(l.sourceStart, 4); XCTAssertEqual(l.transform, cl[1].transform); XCTAssertEqual(l.endTransform, cl[1].endTransform)
        XCTAssertNotNil(l.crop); XCTAssertEqual(l.label, "Mijloc")
        let audio = try XCTUnwrap(e.project.layers.first { $0.kind == .audio })
        XCTAssertEqual(audio.linkedClip, cl[1].id); XCTAssertEqual(audio.start, 4, accuracy: 1e-9); XCTAssertTrue(audio.keepsSource)
        XCTAssertEqual(e.project.texts[0].start, 5, accuracy: 1e-9, "items after the clip move earlier by its length")
        XCTAssertEqual(e.project.clipSpans[1].start, 4, accuracy: 1e-9)
    }
    func testOneUndoStepRedoSaveReopen() throws {
        let (e, cl) = setup(); let before = e.project
        XCTAssertNotNil(e.moveClipToOverlay(cl[1].id)); let after = e.project
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project, before)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.project, after)
        let f = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/mto-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f); XCTAssertEqual(try ProjectStore.load(from: f), e.project)
    }
    func testBlockersAndLastClip() throws {
        var (e, cl) = setup()
        e.setDissolve(clip: cl[1].id, seconds: 0.5)
        XCTAssertEqual(e.overlayMoveBlocker(of: cl[1].id), "dissolve"); XCTAssertNil(e.moveClipToOverlay(cl[1].id))
        e.setDissolve(clip: cl[1].id, seconds: 0)
        XCTAssertNotNil(e.moveClipToOverlay(cl[1].id)); XCTAssertNotNil(e.moveClipToOverlay(cl[0].id))
        XCTAssertNil(e.moveClipToOverlay(cl[2].id), "the last clip stays")
        e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 4)]))
        XCTAssertNil(e.moveClipToOverlay(e.project.clips[0].id))
    }
    func testOccupiedRowRefused() throws {
        let (e, cl) = setup()
        let l = Layer(kind: .video, media: "/b.mov", start: 4, duration: 3); XCTAssertTrue(e.addLayer(l))
        XCTAssertNil(e.moveClipToOverlay(cl[1].id, row: 0), "row 0 is taken at that time")
        let id = try XCTUnwrap(e.moveClipToOverlay(cl[1].id))
        XCTAssertEqual(e.project.layers.first { $0.id == id }?.row, 1, "default: first free row")
    }
}
