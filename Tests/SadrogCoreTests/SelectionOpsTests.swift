// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Operations on a rectangle-selected set: common move keeps distances and sync, common cut touches only the selected items, locked lanes refuse whole.
final class SelectionOpsTests: XCTestCase {
    private func setup() -> (ProjectEditor, UUID, UUID, UUID, UUID, UUID) {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 10)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [a]))
        let aud = e.detachAudio(of: a.id)!
        XCTAssertTrue(e.addLayer(Layer(kind: .video, media: "/cam.mov", start: 2, duration: 6, transform: Transform(x: 0.2, y: 0.1, scale: 0.4))))
        let cam = e.project.layers.first { $0.kind == .video }!.id
        let t = TextOverlay(text: "Titlu", start: 3, duration: 4); XCTAssertTrue(e.addText(t))
        return (e, a.id, aud, cam, t.id, UUID())
    }
    func testGroupMoveKeepsDistancesAndIdentityInOneUndoStep() throws {
        let (e, _, aud, cam, txt, _) = setup(); let before = e.project
        let r = e.moveGroup([aud, cam, txt], by: 1.5)
        XCTAssertEqual(r, .moved(dx: 1.5, mainStayed: false))
        let L = e.project.layers
        XCTAssertEqual(L.first { $0.id == aud }!.start, 1.5, accuracy: 1e-9); XCTAssertEqual(L.first { $0.id == cam }!.start, 3.5, accuracy: 1e-9)
        XCTAssertEqual(e.project.texts[0].start, 4.5, accuracy: 1e-9); XCTAssertEqual(e.project.texts[0].id, txt)
        XCTAssertEqual(L.first { $0.id == cam }!.transform, before.layers.first { $0.id == cam }!.transform, "transform untouched")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project, before, "one undo step restores everything")
    }
    func testGroupMoveRefusedWhenALaneIsLocked() throws {
        let (e, _, aud, cam, txt, _) = setup(); e.setLock(.t, true); let before = e.project
        XCTAssertEqual(e.moveGroup([aud, cam, txt], by: 1), .refused(.locked)); XCTAssertEqual(e.project, before)
    }
    func testSplitSelectionCutsOnlySelectedCrossingItems() throws {
        let (e, clip, aud, cam, txt, _) = setup()
        let outsider = e.project.layers.first { $0.id == cam }!    // camera NOT selected: must stay whole
        let r = e.splitSelection([clip, aud, txt], at: 5)
        XCTAssertEqual(r, .split(3))
        XCTAssertEqual(e.project.clips.count, 2); XCTAssertEqual(e.project.texts.count, 2)
        XCTAssertEqual(e.project.layers.filter { $0.kind == .audio }.count, 2)
        XCTAssertEqual(e.project.layers.first { $0.id == cam }, outsider, "unselected camera untouched")
        XCTAssertEqual(e.project.clips[0].duration, 5, accuracy: 1e-9); XCTAssertEqual(e.project.texts[0].duration + e.project.texts[1].duration, 4, accuracy: 1e-9)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.clips.count, 1); XCTAssertEqual(e.project.texts.count, 1); XCTAssertEqual(e.project.layers.filter { $0.kind == .audio }.count, 1)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.project.clips.count, 2)
    }
    /// The Blade tool and the menu command share this one operation: V1, camera (V2), detached sound and title cut at EXACTLY the same instant, one undo step.
    func testSplitSelectionAllLanesAtTheSameInstant() throws {
        let (e, clip, aud, cam, txt, _) = setup(); let t = 5.0
        XCTAssertEqual(e.splitSelection([clip, aud, cam, txt], at: t), .split(4))
        let ends = e.project.clips.map { $0.duration } + e.project.layers.map { $0.start }
        XCTAssertEqual(e.project.clips[0].duration, t, accuracy: 1e-12)
        for l in e.project.layers where l.start < t { XCTAssertEqual(l.start + l.duration, t, accuracy: 1e-9, "layer piece ends at the cut") }
        XCTAssertEqual(e.project.layers.filter { $0.start == t }.count, 2, "camera and sound second halves start at the cut")
        XCTAssertEqual(e.project.texts.first { $0.start < t }!.start + e.project.texts.first { $0.start < t }!.duration, t, accuracy: 1e-9)
        XCTAssertEqual(e.project.texts.filter { $0.start == t }.count, 1); _ = ends
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.clips.count, 1); XCTAssertEqual(e.project.layers.count, 2); XCTAssertEqual(e.project.texts.count, 1)
    }
    func testSplitSelectionIgnoresItemsNotCrossedAndRefusesLockedWhole() throws {
        let (e, clip, aud, _, txt, _) = setup()
        XCTAssertEqual(e.splitSelection([txt], at: 9), .nothing)            // title ends at 7
        e.setLock(.t, true); let before = e.project
        XCTAssertEqual(e.splitSelection([clip, aud, txt], at: 5), .locked); XCTAssertEqual(e.project, before, "no partial cut")
    }
    func testSplitSelectionSaveReopen() throws {
        let (e, clip, aud, _, txt, _) = setup(); XCTAssertEqual(e.splitSelection([clip, aud, txt], at: 5), .split(3))
        let f = URL(fileURLWithPath: "\(TestRoot.path)/temp/sel-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f); XCTAssertEqual(try ProjectStore.load(from: f), e.project)
    }
}
