import XCTest
@testable import SadrogCore

final class DropPlanTests: XCTestCase {
    private let v = DropMaterial(path: "/v.mov", duration: 4, hasVideo: true, hasAudio: true)
    private let w = DropMaterial(path: "/w.mov", duration: 2, hasVideo: true, hasAudio: false)
    private let a = DropMaterial(path: "/a.wav", duration: 3, hasVideo: false, hasAudio: true)
    private func base() -> SadrogProject {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/m.mov", sourceStart: 0, duration: 10)])
        p.layers = [Layer(kind: .video, media: "/o.mov", start: 2, duration: 3)]; return p
    }
    func testOverlayDropKeepsOrderAndDistancesAndIsOneUndoStep() throws {
        let e = ProjectEditor(project: base()), before = e.project
        let plan = DropPlanner.plan(e.project, materials: [v, w], destination: .overlay(row: 1), at: 1)
        XCTAssertTrue(plan.isValid); XCTAssertTrue(plan.createsTrack, "row one past the last = new track")
        XCTAssertEqual(plan.placements.map(\.start), [1, 5]); XCTAssertEqual(plan.end, 7)
        let ids = try XCTUnwrap(e.perform(plan)); XCTAssertEqual(ids.count, 2)
        XCTAssertEqual(e.project.rowCount(.v2), 2); XCTAssertEqual(e.project.layers.filter { $0.row == 1 }.count, 2)
        e.undo(); XCTAssertEqual(e.project, before, "track creation + insertion = one undo")
    }
    func testIncompatibleLockedAndOverlapAreRefusedBeforeDropAndChangeNothing() {
        let e = ProjectEditor(project: base()), before = e.project
        XCTAssertEqual(DropPlanner.plan(e.project, materials: [a], destination: .overlay(row: 0), at: 0).refusal, .incompatible)
        XCTAssertEqual(DropPlanner.plan(e.project, materials: [w], destination: .audio(row: 0), at: 0).refusal, .incompatible)
        XCTAssertEqual(DropPlanner.plan(e.project, materials: [v], destination: .overlay(row: 0), at: 1).refusal, .overlap)
        var locked = base(); locked.lockedLanes = [.a2]
        XCTAssertEqual(DropPlanner.plan(locked, materials: [a], destination: .audio(row: 0), at: 0).refusal, .locked)
        XCTAssertNil(e.perform(DropPlanner.plan(e.project, materials: [v], destination: .overlay(row: 0), at: 1))); XCTAssertEqual(e.project, before)
    }
    func testMainDropAppendsAndAudioSnapsToTheEdge() throws {
        let e = ProjectEditor(project: base())
        let m = DropPlanner.plan(e.project, materials: [v], destination: .main, at: 3); XCTAssertEqual(m.start, 10)
        e.perform(m); XCTAssertEqual(e.project.clips.count, 2)
        let s = DropPlanner.plan(e.project, materials: [a], destination: .audio(row: 0), at: 4.95, snapPoints: Snapping.points(of: e.project, playhead: 0), threshold: 0.2)
        XCTAssertEqual(s.start, 5, accuracy: 1e-9); XCTAssertEqual(s.guide, 5)
    }
    func testTrackLimitAndUnreadable() {
        var p = base(); p.reservedRows["v2"] = 12
        XCTAssertEqual(DropPlanner.plan(p, materials: [v], destination: .overlay(row: 12), at: 0).refusal, .tooManyTracks)
        XCTAssertEqual(DropPlanner.plan(p, materials: [DropMaterial(path: "/z", duration: 0, hasVideo: true, hasAudio: true)], destination: .main, at: 0).refusal, .unreadable)
    }
    func testEffectDroppedOnAClipOrOverlayRetargetsItInOneUndoStep() throws {
        var p = base(); p.clips.append(Clip(media: "/n.mov", sourceStart: 0, duration: 6))
        let e = ProjectEditor(project: p), ov = e.project.layers[0].id, c2 = e.project.clips[1].id
        var co = Callout(start: 1, duration: 3); co.normalize(); e.addCallout(co); let id = e.project.callouts[0].id, before = e.project
        XCTAssertTrue(e.retargetCallout(id, toClip: c2, toLayer: nil, at: 12))
        var c = e.project.callouts[0]; XCTAssertEqual(c.clipID, c2); XCTAssertNil(c.layerID); XCTAssertGreaterThanOrEqual(c.start, 10); XCTAssertLessThanOrEqual(c.start + c.duration, 16 + 1e-9)
        XCTAssertTrue(e.retargetCallout(id, toClip: nil, toLayer: ov, at: 2.5)); c = e.project.callouts[0]; XCTAssertEqual(c.layerID, ov); XCTAssertNil(c.clipID); XCTAssertGreaterThanOrEqual(c.start, 2)
        XCTAssertFalse(e.retargetCallout(id, toClip: UUID(), toLayer: nil, at: 0))
        e.undo(); e.undo(); XCTAssertEqual(e.project, before)
    }
}
