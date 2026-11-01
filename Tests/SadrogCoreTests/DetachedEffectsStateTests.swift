import AudioToolbox
import XCTest
@testable import SadrogCore

/// State preservation of a recording's effect chain (parameters, bypass, order) and of the detached sound through every montage action.
final class DetachedEffectsStateTests: XCTestCase {
    private func fx(_ n: String, _ bytes: [UInt8], bypassed: Bool = false) -> AudioEffect {
        AudioEffect(component: AUComponentID(type: kAudioUnitType_Effect, subtype: 0x6C706173, manufacturer: 0x6170706C), name: n, manufacturerName: "Apple", componentVersion: 1, state: Data(bytes), bypassed: bypassed)
    }
    private func setup() -> (ProjectEditor, [AudioEffect], UUID) {
        let a = Clip(media: "/a.mov", sourceStart: 0, duration: 10)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [a]))
        let chain = [fx("A", [1, 2, 3]), fx("B", [9, 8], bypassed: true)]
        e.setEffects(0, chain, media: "/a.mov")
        return (e, chain, a.id)
    }
    private func chain(_ p: SadrogProject) -> [AudioEffect] { p.recording("/a.mov").effects[0] ?? [] }

    func testChainSurvivesDetachCutMoveRowReorderUndoRedoAndReopen() throws {
        let (e, original, cid) = setup()
        let lid = try XCTUnwrap(e.detachAudio(of: cid))
        XCTAssertEqual(chain(e.project), original, "detach does not copy or drop the chain")
        e.splitLayer(kind: .audio, at: 4)
        XCTAssertEqual(e.project.layers.count, 2)
        XCTAssertTrue(e.project.layers.allSatisfy { $0.keepsSource && $0.media == "/a.mov" }, "both pieces keep the source identity")
        XCTAssertEqual(chain(e.project), original, "the cut does not duplicate the chain (no double processing)")
        let second = try XCTUnwrap(e.project.layers.first { $0.id != lid })
        XCTAssertTrue(e.placeLayer(second.id, start: 6, row: 1))
        XCTAssertEqual(e.project.rowCount(.a2), 2)
        XCTAssertTrue(e.moveRow(.a2, from: 1, to: 0))
        let moved = try XCTUnwrap(e.project.layers.first { $0.id == second.id })
        XCTAssertEqual(moved.row, 0); XCTAssertEqual(moved.start, 6, accuracy: 1e-9); XCTAssertTrue(moved.keepsSource)
        XCTAssertEqual(chain(e.project), original)
        let f = URL(fileURLWithPath: "\(TestRoot.path)/temp/dfx-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f)
        let back = try ProjectStore.load(from: f)
        XCTAssertEqual(chain(back), original); XCTAssertEqual(back.layers, e.project.layers)
        XCTAssertEqual(back.layers.filter(\.keepsSource).count, 2)
        // each action is one coherent undo step; the chain never changes
        for _ in 0..<3 { XCTAssertTrue(e.undo()); XCTAssertEqual(chain(e.project), original) }
        XCTAssertEqual(e.project.layers.count, 1)
        for _ in 0..<3 { XCTAssertTrue(e.redo()); XCTAssertEqual(chain(e.project), original) }
        XCTAssertEqual(e.project.layers.first { $0.id == second.id }?.row, 0)
    }

    func testRowReorderKeepsIdentityNameAndContentOfEveryTrack() throws {
        let (e, _, cid) = setup()
        let lid = try XCTUnwrap(e.detachAudio(of: cid))
        XCTAssertTrue(e.addRow(.a2)); XCTAssertTrue(e.addRow(.a2))
        let l2 = Layer(kind: .audio, media: "/b.wav", start: 20, duration: 3); XCTAssertTrue(e.addLayer(l2))
        XCTAssertTrue(e.placeLayer(l2.id, start: 0, row: 2))
        e.setTrackName(.a2, 0, "Voce"); e.setTrackName(.a2, 2, "Muzică")
        XCTAssertTrue(e.moveRow(.a2, from: 2, to: 0))
        XCTAssertEqual(e.project.layers.first { $0.id == l2.id }?.row, 0)
        XCTAssertEqual(e.project.layers.first { $0.id == lid }?.row, 1)
        XCTAssertEqual(e.project.trackNames[SadrogProject.rowKey(.a2, 0)], "Muzică")
        XCTAssertEqual(e.project.trackNames[SadrogProject.rowKey(.a2, 1)], "Voce")
        XCTAssertTrue(e.undo())
        XCTAssertEqual(e.project.trackNames[SadrogProject.rowKey(.a2, 2)], "Muzică")
        XCTAssertEqual(e.project.layers.first { $0.id == l2.id }?.row, 2)
    }
}
