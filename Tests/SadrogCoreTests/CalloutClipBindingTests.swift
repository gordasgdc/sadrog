// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// A callout bound to a clip follows it: moves with it, is cut with it, shortened by trims, removed with it. Independent (older) callouts never change.
final class CalloutClipBindingTests: XCTestCase {
    func fixture() -> (ProjectEditor, UUID, UUID, Callout.ID) {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 4), b = Clip(media: "/b.mov", sourceStart: 0, duration: 4)
        var p = SadrogProject(name: "t", clips: [a, b])
        let c = Callout(start: 5, duration: 2, clipID: b.id); p.callouts = [c]
        return (ProjectEditor(project: p), a.id, b.id, c.id)
    }
    func callout(_ e: ProjectEditor, _ id: Callout.ID) -> Callout? { e.project.callouts.first { $0.id == id } }

    func testMovesWithItsClipWhenAnEarlierClipIsTrimmed() {
        let (e, a, _, id) = fixture()
        e.trimEnd(clip: a, by: 1)                                    // clip A is 3 s now: B starts at 3
        XCTAssertEqual(callout(e, id)?.start ?? -1, 4, accuracy: 1e-6)
        e.undo(); XCTAssertEqual(callout(e, id)?.start ?? -1, 5, accuracy: 1e-6)
    }
    func testMovesWithItsClipWhenClipsAreReordered() {
        let (e, a, b, id) = fixture()
        e.move(clip: b, toIndex: 0)                                  // B first: its callout 1…3
        XCTAssertEqual(callout(e, id)?.start ?? -1, 1, accuracy: 1e-6); XCTAssertEqual(callout(e, id)?.clipID, b)
        _ = a
    }
    func testDeletingTheClipDeletesItsCallout() {
        let (e, a, b, id) = fixture()
        e.delete(clip: a); XCTAssertEqual(callout(e, id)?.start ?? -1, 1, accuracy: 1e-6)    // follows B after the ripple
        e.delete(clip: b); XCTAssertNil(callout(e, id))
    }
    func testSplitInsideTheCalloutKeepsItInTheClipItStartsIn_andTrimShortensIt() {
        let (e, _, b, id) = fixture()
        e.split(at: 6)                                               // B → 4…6 | 6…8; the callout 5…7 starts in the first piece
        let c = callout(e, id)!; XCTAssertEqual(c.clipID, b); XCTAssertEqual(c.start, 5, accuracy: 1e-6); XCTAssertEqual(c.end, 6, accuracy: 1e-6, "cut to the piece it lies in")
        e.trimEnd(clip: b, by: 0.8)                                  // the piece ends at 5.2
        XCTAssertEqual(callout(e, id)?.end ?? -1, 5.2, accuracy: 1e-6)
        e.trimEnd(clip: b, by: 1.15)                                 // the piece shrinks to 0.05 s: the callout starting at 5 is no longer on it
        XCTAssertNil(callout(e, id))
    }
    func testIndependentCalloutsAreNeverTouchedAndOldProjectsDecodeUnbound() throws {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 4)])
        p.callouts = [Callout(start: 1, duration: 2)]
        let e = ProjectEditor(project: p); e.trimEnd(clip: p.clips[0].id, by: 3.5)
        XCTAssertEqual(e.project.callouts[0].start, 1); XCTAssertEqual(e.project.callouts[0].duration, 2); XCTAssertNil(e.project.callouts[0].clipID)
        let j = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","start":1,"duration":2,"x":0.1,"y":0.1,"w":0.3,"h":0.3,"dim":0.5,"blur":0,"corner":0.1}"#
        XCTAssertNil(try JSONDecoder().decode(Callout.self, from: Data(j.utf8)).clipID)
    }
}

/// Duplicating / pasting a clip copies its bound callouts and binds them to the copy (K08).
final class ClipDuplicateTests: XCTestCase {
    func fixture() -> (ProjectEditor, UUID, UUID, UUID) {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 4), b = Clip(media: "/b.mov", sourceStart: 0, duration: 4)
        var p = SadrogProject(name: "t", clips: [a, b])
        let ca = Callout(start: 1, duration: 2, clipID: a.id), cb = Callout(start: 5, duration: 2, clipID: b.id); p.callouts = [ca, cb]
        return (ProjectEditor(project: p), a.id, b.id, cb.id)
    }
    func testDuplicateCopiesBoundCalloutAndShiftsLaterOnes() {
        let (e, a, b, cb) = fixture()
        let n = e.duplicate(clip: a)!
        XCTAssertEqual(e.project.clips.map(\.id).count, 3); XCTAssertEqual(e.project.clips[1].id, n); XCTAssertEqual(e.project.clips[2].id, b)
        let copy = e.project.callouts.first { $0.clipID == n }!
        XCTAssertEqual(copy.start, 5, accuracy: 1e-6); XCTAssertEqual(copy.duration, 2, accuracy: 1e-6)          // 4 + (1 - 0)
        XCTAssertEqual(e.project.callouts.filter { $0.clipID == a }.count, 1)                                     // original keeps its own
        XCTAssertEqual(e.project.callouts.first { $0.id == cb }!.start, 9, accuracy: 1e-6)                        // B moved by 4 s
        XCTAssertEqual(Set(e.project.callouts.map(\.id)).count, 3)
        e.undo(); XCTAssertEqual(e.project.clips.count, 2); XCTAssertEqual(e.project.callouts.count, 2)
    }
    func testCopyPasteAtEndAndRoundTrip() throws {
        let (e, _, b, _) = fixture()
        let s = e.snapshot(clip: b)!; let n = e.paste(s, atIndex: 99)!
        XCTAssertEqual(e.project.clips.last?.id, n); XCTAssertEqual(e.project.callouts.first { $0.clipID == n }!.start, 9, accuracy: 1e-6)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project))
        XCTAssertEqual(back.callouts.filter { $0.clipID == n }.count, 1)
    }
}

/// Multi-item clipboard, lane locks, names (L1).
final class ClipboardLockTests: XCTestCase {
    func fixture() -> (ProjectEditor, Clip, Clip, Layer, Layer) {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 4), b = Clip(media: "/b.mov", sourceStart: 0, duration: 4)
        let l1 = Layer(kind: .video, media: "/c.mov", start: 1, duration: 3), l2 = Layer(kind: .audio, media: "/m.m4a", start: 0, duration: 2)
        var p = SadrogProject(name: "t", clips: [a, b], layers: [l1, l2])
        p.callouts = [Callout(start: 5, duration: 2, clipID: b.id)]
        p.texts = [TextOverlay(text: "T", start: 0, duration: 1)]
        return (ProjectEditor(project: p), a, b, l1, l2)
    }
    func testMultiDuplicateIsOneUndoStepAndKeepsOriginals() {
        let (e, a, b, l1, _) = fixture()
        let ids = e.duplicate(items: [a.id, b.id, l1.id])
        XCTAssertEqual(ids.count, 3); XCTAssertEqual(e.project.clips.count, 4); XCTAssertEqual(e.project.layers.count, 3)
        XCTAssertEqual(e.project.clips.map(\.media), ["/a.mov", "/b.mov", "/a.mov", "/b.mov"])
        let copyB = e.project.clips[3].id
        let k = e.project.callouts.filter { $0.clipID == copyB }; XCTAssertEqual(k.count, 1); XCTAssertEqual(k[0].start, 13, accuracy: 1e-6)
        XCTAssertEqual(e.project.callouts.filter { $0.clipID == b.id }.first?.start ?? -1, 5, accuracy: 1e-6)
        let newLayer = e.project.layers.first { ids.contains($0.id) }!; XCTAssertEqual(newLayer.start, 4, accuracy: 1e-6)
        e.undo(); XCTAssertEqual(e.project.clips.count, 2); XCTAssertEqual(e.project.layers.count, 2); XCTAssertEqual(e.project.callouts.count, 1)
    }
    func testPasteLayerOverlappingGoesToNextRow() {
        let (e, _, _, l1, _) = fixture()
        let items = e.clipboardItems(for: [l1.id])
        let ids = e.paste(items, clipIndex: 0, at: 2)                 // overlaps the original (1…4) on row 0 → row 1
        XCTAssertEqual(ids.count, 1); XCTAssertEqual(e.project.layers.first { $0.id == ids[0] }?.row, 1)
    }
    func testPasteTitleSlidesToFreeSlot() {
        let (e, _, _, _, _) = fixture()
        let t = e.project.texts[0]; let ids = e.paste(e.clipboardItems(for: [t.id]), clipIndex: 0, at: 0.5)
        XCTAssertEqual(e.project.texts.first { $0.id == ids[0] }?.start ?? -1, 1, accuracy: 1e-6)
    }
    func testLockedLaneRefusesEditsButFollowUpsStillWork() {
        let (e, a, b, l1, _) = fixture()
        e.setLock(.v2, true)
        e.delete(items: [l1.id]); XCTAssertEqual(e.project.layers.count, 2)                          // refused
        e.paste(e.clipboardItems(for: [l1.id]), clipIndex: 0, at: 9); XCTAssertEqual(e.project.layers.count, 2)
        e.trimEnd(clip: a.id, by: 1); XCTAssertEqual(e.project.clips[0].duration, 3, accuracy: 1e-6)  // other lanes free; the callout of B follows (reanchor)
        XCTAssertEqual(e.project.callouts[0].start, 4, accuracy: 1e-6)
        e.setLock(.v1, true); e.delete(clip: b.id); XCTAssertEqual(e.project.clips.count, 2)
        e.setLock(.v2, false); e.delete(items: [l1.id]); XCTAssertEqual(e.project.layers.count, 1)
        e.undo(); XCTAssertEqual(e.project.layers.count, 2)
    }
    func testRenameAndRoundTrip() throws {
        let (e, a, _, l1, _) = fixture()
        e.rename(a.id, to: "  Intro "); e.rename(l1.id, to: "Cameră"); e.setLock(.t, true)
        XCTAssertEqual(e.project.clips[0].label, "Intro")
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project))
        XCTAssertEqual(back.clips[0].label, "Intro"); XCTAssertEqual(back.layers[0].label, "Cameră"); XCTAssertEqual(back.lockedLanes, [.t])
        e.rename(a.id, to: ""); XCTAssertNil(e.project.clips[0].label)
        let old = try JSONDecoder().decode(SadrogProject.self, from: Data(#"{"formatVersion":6,"name":"o","clips":[]}"#.utf8))
        XCTAssertTrue(old.lockedLanes.isEmpty)
    }
}

/// Moving a multiple selection together (L1).
final class GroupMoveTests: XCTestCase {
    func fixture() -> (ProjectEditor, [UUID]) {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 4), b = Clip(media: "/b.mov", sourceStart: 0, duration: 4)
        let l1 = Layer(kind: .video, media: "/c.mov", start: 1, duration: 2), l2 = Layer(kind: .video, media: "/d.mov", start: 5, duration: 2)
        var p = SadrogProject(name: "t", clips: [a, b], layers: [l1, l2])
        let c = Callout(start: 5, duration: 2, clipID: b.id); p.callouts = [c]
        return (ProjectEditor(project: p), [l1.id, l2.id, c.id])
    }
    func testMovesTogetherKeepingDistancesInOneUndoStep() {
        let (e, ids) = fixture()
        let r = e.moveGroup(ids, by: 0.5)
        XCTAssertEqual(r, .moved(dx: 0.5, mainStayed: false))
        XCTAssertEqual(e.project.layers.map(\.start), [1.5, 5.5]); XCTAssertEqual(e.project.callouts[0].start, 5.5, accuracy: 1e-9); XCTAssertEqual(e.project.callouts[0].clipID, e.project.clips[1].id)
        e.undo(); XCTAssertEqual(e.project.layers.map(\.start), [1, 5]); XCTAssertEqual(e.project.callouts[0].start, 5)
    }
    func testStopsAtZero() {
        let (e, ids) = fixture()
        let r = e.moveGroup(ids, by: -3)
        XCTAssertEqual(r, .moved(dx: -1, mainStayed: false))                                // clamped: l1 starts at 1
        XCTAssertEqual(e.project.layers.map(\.start), [0, 4]); XCTAssertEqual(e.project.clips.count, 2)
        XCTAssertEqual(e.project.callouts[0].start, 4, accuracy: 1e-9)
    }
    func testBoundCalloutBecomesIndependentWhenMovedOutOfEveryClip() {
        let (e, ids) = fixture()
        _ = e.moveGroup([ids[2]], by: 6)                                                    // 11…13 is past the 8 s main track
        XCTAssertNil(e.project.callouts[0].clipID)
    }
    func testLockedLaneRefusesTheWholeGroupAndOverlapToo() {
        let (e, ids) = fixture()
        e.setLock(.c, true)
        XCTAssertEqual(e.moveGroup(ids, by: 1), .refused(.locked)); XCTAssertEqual(e.project.layers.map(\.start), [1, 5])    // nothing moved, not even the layers
        e.setLock(.c, false)
        XCTAssertEqual(e.moveGroup([ids[0]], by: 4), .refused(.overlap))                    // 5…7 is taken by the other layer, which does not move
        XCTAssertEqual(e.moveGroup([ids[0], ids[1]], by: 4), .moved(dx: 4, mainStayed: false))   // both move: distances kept, no overlap
    }
    func testMainBlockMove() {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 2), b = Clip(media: "/b.mov", sourceStart: 0, duration: 2), c = Clip(media: "/c.mov", sourceStart: 0, duration: 2), d = Clip(media: "/d.mov", sourceStart: 0, duration: 2)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [a, b, c, d]))
        XCTAssertTrue(e.moveBlock([a.id, b.id], byIndex: 2)); XCTAssertEqual(e.project.clips.map(\.media), ["/c.mov", "/d.mov", "/a.mov", "/b.mov"])
        XCTAssertFalse(e.moveBlock([e.project.clips[0].id, e.project.clips[2].id], byIndex: 1), "not adjacent")
        e.undo(); XCTAssertEqual(e.project.clips.map(\.media), ["/a.mov", "/b.mov", "/c.mov", "/d.mov"])
        e.setLock(.v1, true); XCTAssertFalse(e.moveBlock([a.id], byIndex: 1))
    }
}
