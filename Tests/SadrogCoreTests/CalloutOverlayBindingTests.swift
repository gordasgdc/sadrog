// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// A callout can target a video overlay (V2): it moves with it, is cut with it, goes with it, is copied with it, and acts only inside its picture.
/// V1-bound and independent (older) callouts keep their behaviour.
final class CalloutOverlayBindingTests: XCTestCase {
    let dir = CompositionTests.dir
    func fixture() -> (ProjectEditor, Layer.ID, Callout.ID) {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 12)])
        let l = Layer(kind: .video, media: "/o.mov", start: 2, duration: 6, transform: Transform(x: -0.25, y: 0, scale: 0.5))
        let c = Callout(start: 3, duration: 2, layerID: l.id)
        p.layers = [l]; p.callouts = [c]
        return (ProjectEditor(project: p), l.id, c.id)
    }
    func callout(_ e: ProjectEditor, _ id: Callout.ID) -> Callout? { e.project.callouts.first { $0.id == id } }

    func testFollowsTheOverlayWhenItMoves() {
        let (e, l, id) = fixture()
        XCTAssertTrue(e.moveLayer(l, to: 5))
        XCTAssertEqual(callout(e, id)?.start ?? -1, 6, accuracy: 1e-6); XCTAssertEqual(callout(e, id)?.layerID, l)
        e.undo(); XCTAssertEqual(callout(e, id)?.start ?? -1, 3, accuracy: 1e-6)
    }
    func testIsShortenedByTrimsAndRemovedWhenTrimmedAway() {
        let (e, l, id) = fixture()
        e.trimLayerEnd(l, by: 4.5)                                   // overlay 2…3.5: callout 3…5 → 3…3.5
        XCTAssertEqual(callout(e, id)?.duration ?? -1, 0.5, accuracy: 1e-6)
        e.trimLayerStart(l, by: 1.4)                                 // overlay 3.4…3.5: callout 3.4…3.5
        XCTAssertEqual(callout(e, id)?.start ?? -1, 3.4, accuracy: 1e-6)
        e.trimLayerStart(l, by: 0.04); e.undo(); e.undo(); e.undo()
        XCTAssertEqual(callout(e, id)?.duration ?? -1, 2, accuracy: 1e-6, "undo restores the callout with the overlay")
    }
    func testDeletingTheOverlayDeletesItsCalloutAndUndoBringsBothBack() {
        let (e, l, id) = fixture()
        e.deleteLayer(l); XCTAssertNil(callout(e, id)); e.undo(); XCTAssertNotNil(callout(e, id))
    }
    func testACutGivesTheCalloutToThePieceItStartsIn() {
        let (e, l, id) = fixture()
        e.undo(); _ = l
        var p = e.project; p.callouts[0].start = 6; p.callouts[0].duration = 1
        let e2 = ProjectEditor(project: p)
        e2.splitLayer(kind: .video, at: 5)                           // overlay 2…5 and 5…8; the callout (6…7) lies in the new piece
        let second = e2.project.layers.first { $0.id != l }
        XCTAssertEqual(callout(e2, id)?.layerID, second?.id)
    }
    func testCopyingTheOverlayCopiesItsCalloutBoundToTheCopy() {
        let (e, l, id) = fixture()
        let made = e.duplicate(items: [l])
        XCTAssertEqual(made.count, 1)
        let copy = e.project.callouts.first { $0.id != id }
        XCTAssertEqual(copy?.layerID, made.first); XCTAssertNotEqual(copy?.layerID, l)
        XCTAssertEqual(e.project.callouts.count, 2)
        e.undo(); XCTAssertEqual(e.project.callouts.count, 1)
    }
    /// Ruling 2026-10-31: an effect belongs to its target, so a copy of it stays on that overlay (inside it, without pushing neighbours) instead of becoming a global one.
    func testACalloutPastedAloneStaysOnItsOverlay() {
        let (e, l, id) = fixture()
        let items = e.clipboardItems(for: [id])
        XCTAssertEqual(items.count, 1)
        let new = e.paste(items, clipIndex: 0, at: 20)
        let copy = e.project.callouts.first { $0.id == new.first }
        XCTAssertEqual(copy?.layerID, l); XCTAssertNil(copy?.clipID)
        let span = e.project.layers.first { $0.id == l }!
        XCTAssertGreaterThanOrEqual(copy!.start, span.start - 1e-9); XCTAssertLessThanOrEqual(copy!.end, span.end + 1e-9)
    }
    func testBindAndReleaseAndClipExclusivity() {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 12)])
        let l = Layer(kind: .video, media: "/o.mov", start: 2, duration: 6); p.layers = [l]
        let c = Callout(start: 3, duration: 9, clipID: p.clips[0].id); p.callouts = [c]
        let e = ProjectEditor(project: p)
        XCTAssertTrue(e.bindCallout(c.id, toLayer: l.id))
        XCTAssertEqual(callout(e, c.id)?.layerID, l.id); XCTAssertNil(callout(e, c.id)?.clipID); XCTAssertEqual(callout(e, c.id)?.end ?? 0, 8, accuracy: 1e-6)
        XCTAssertTrue(e.bindCallout(c.id, toLayer: nil)); XCTAssertNil(callout(e, c.id)?.layerID)
        e.undo(); XCTAssertEqual(callout(e, c.id)?.layerID, l.id)
        let audio = Layer(kind: .audio, media: "/m.m4a", start: 0, duration: 9); e.addLayer(audio)
        XCTAssertFalse(e.bindCallout(c.id, toLayer: audio.id), "only video overlays can be targets")
    }
    func testUnknownOverlayReleasesAndOldProjectsDecode() throws {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 12)])
        p.callouts = [Callout(start: 1, duration: 2, layerID: UUID())]
        let e = ProjectEditor(project: p); e.setLock(.t, true); e.setLock(.t, false)
        XCTAssertNil(e.project.callouts[0].layerID, "an id that is not an overlay of this project releases the callout, never deletes it")
        let old = try JSONDecoder().decode(Callout.self, from: Data(#"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":1,"duration":2,"x":0.1,"y":0.1,"w":0.2,"h":0.2,"dim":0.6,"blur":0,"corner":0.1}"#.utf8))
        XCTAssertNil(old.layerID); XCTAssertNil(old.clipID)
        let back = try JSONDecoder().decode(Callout.self, from: JSONEncoder().encode(Callout(start: 1, layerID: old.id)))
        XCTAssertEqual(back.layerID, old.id)
    }

    /// Pixels: the effect is confined to the overlay's picture; the same callout unbound darkens everything below it.
    func testEffectStaysInsideTheOverlayPicture() async throws {
        let blue = dir + "/blue.mov", red = dir + "/red.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue) && FileManager.default.fileExists(atPath: red), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 3)])
        let l = Layer(kind: .video, media: red, start: 0, duration: 3, transform: Transform(x: -0.25, y: 0, scale: 0.5))      // red fills x 0…0.5, y 0.25…0.75
        p.layers = [l]
        var c = Callout(start: 0, duration: 3, x: 0.1, y: 0.4, w: 0.2, h: 0.2, dim: 1, layerID: l.id)
        p.callouts = [c]
        let helper = CompositionTests()
        let bound = try await helper.export(p); defer { try? FileManager.default.removeItem(at: bound) }
        let inBox = try await helper.pixel(bound, at: 1, x: 0.2, y: 0.5), inOverlay = try await helper.pixel(bound, at: 1, x: 0.42, y: 0.3), onV1 = try await helper.pixel(bound, at: 1, x: 0.8, y: 0.5)
        XCTAssertGreaterThan(inBox.0, 200, "inside the selection the overlay keeps its colour")
        XCTAssertLessThan(inOverlay.0 + inOverlay.1 + inOverlay.2, 60, "inside the overlay but outside the selection: darkened")
        XCTAssertGreaterThan(onV1.2, 150, "the main picture outside the overlay is untouched")
        c.layerID = nil; p.callouts = [c]                          // control: independent, it acts on everything below it
        let free = try await helper.export(p); defer { try? FileManager.default.removeItem(at: free) }
        let v1 = try await helper.pixel(free, at: 1, x: 0.8, y: 0.5)
        XCTAssertLessThan(v1.0 + v1.1 + v1.2, 60, "control: an independent callout darkens the main picture too")
    }
}
