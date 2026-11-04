import XCTest
@testable import SadrogCore

final class CalloutTargetsTests: XCTestCase {
    private func twoClips() -> (ProjectEditor, UUID, UUID) {
        let a = Clip(media: "/a", sourceStart: 0, duration: 10), b = Clip(media: "/b", sourceStart: 0, duration: 10)
        return (ProjectEditor(project: SadrogProject(name: "t", clips: [a, b])), a.id, b.id)
    }

    func testEffectsOnDifferentTargetsCoexistAndKeepTheirRequestedStart() {
        let (e, a, b) = twoClips()
        var c1 = Callout(start: 2, duration: 3); c1.clipID = a
        var c2 = Callout(start: 3, duration: 3); c2.clipID = a            // same target, overlapping interval: still accepted, never pushed
        var c3 = Callout(start: 12, duration: 3); c3.clipID = b
        XCTAssertTrue(e.addCallout(c1)); XCTAssertTrue(e.addCallout(c2)); XCTAssertTrue(e.addCallout(c3))
        XCTAssertEqual(e.project.callouts.map(\.start), [2, 3, 12])
        let rows = e.project.calloutRows()
        XCTAssertEqual(rows[c1.id], 0); XCTAssertEqual(rows[c2.id], 1); XCTAssertEqual(rows[c3.id], 0)
    }

    func testOverlappingEffectsKeepArrayOrderAcrossSaveAndReload() throws {
        let (e, a, _) = twoClips()
        var ids: [UUID] = []
        for s in [4.0, 1.0, 2.5] { var c = Callout(start: s, duration: 3); c.clipID = a; ids.append(c.id); XCTAssertTrue(e.addCallout(c)) }
        let f = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/co-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f)
        XCTAssertEqual(try ProjectStore.load(from: f).callouts.map(\.id), ids)       // composition order = array order, stable
    }

    func testTwoDiscreteStyleEditsAreTwoUndoSteps() {
        let (e, a, _) = twoClips()
        var c = Callout(start: 1, duration: 3); c.clipID = a
        XCTAssertTrue(e.addCallout(c))
        XCTAssertTrue(e.updateCallout(c.id) { $0.w = 0.3 })
        XCTAssertTrue(e.updateCallout(c.id) { $0.h = 0.2 })
        e.undo(); XCTAssertEqual(e.project.callouts[0].w, 0.3, accuracy: 1e-12); XCTAssertNotEqual(e.project.callouts[0].h, 0.2)
        e.undo(); XCTAssertNotEqual(e.project.callouts[0].w, 0.3)
    }
}
