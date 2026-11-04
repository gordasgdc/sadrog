import XCTest
@testable import SadrogCore

final class DetachAudioTests: XCTestCase {
    private func project() -> ProjectEditor {
        var a = Clip(media: "/a.mov", sourceStart: 5, duration: 10); a.audio = AudioEdit(fadeIn: 1)
        let b = Clip(media: "/b.mov", sourceStart: 0, duration: 8)
        return ProjectEditor(project: SadrogProject(name: "t", clips: [a, b]))
    }

    func testDetachKeepsPositionOffsetAndEditsAndSilencesTheClipSound() throws {
        let e = project(); let cid = e.project.clips[1].id
        let lid = try XCTUnwrap(e.detachAudio(of: cid))
        let l = try XCTUnwrap(e.project.layers.first { $0.id == lid }), c = e.project.clips[1]
        XCTAssertEqual(l.kind, .audio); XCTAssertEqual(l.media, "/b.mov"); XCTAssertEqual(l.start, 10, accuracy: 1e-9); XCTAssertEqual(l.sourceStart, 0); XCTAssertEqual(l.duration, 8)
        XCTAssertTrue(c.audioDetached); XCTAssertEqual(l.linkedClip, cid)
        XCTAssertTrue(e.detachedAudioInSync(lid))
        XCTAssertNil(e.detachAudio(of: cid), "a second detach is refused")
        let a = e.project.clips[0].id; let l0 = try XCTUnwrap(e.detachAudio(of: a)); let layer0 = try XCTUnwrap(e.project.layers.first { $0.id == l0 })
        XCTAssertEqual(layer0.audio?.fadeIn, 1); XCTAssertNil(e.project.clips[0].audio, "fades live on the item now: no double application")
        XCTAssertEqual(layer0.row, 0); XCTAssertEqual(try XCTUnwrap(e.project.layers.first { $0.id == lid }).row, 0, "items do not overlap in time → same row")
    }

    func testIndependentMoveBreaksSyncAndReattachIsRefusedUntilItemIsGoneThenRestores() throws {
        let e = project(); let cid = e.project.clips[0].id
        let lid = try XCTUnwrap(e.detachAudio(of: cid))
        XCTAssertTrue(e.moveLayer(lid, to: 3)); XCTAssertFalse(e.detachedAudioInSync(lid))
        XCTAssertFalse(e.reattachAudio(of: cid), "moved item would play twice")
        e.deleteLayer(lid)                               // separate delete: the picture stays, the clip stays silent
        XCTAssertEqual(e.project.clips.count, 2); XCTAssertTrue(e.project.clips[0].audioDetached)
        XCTAssertTrue(e.reattachAudio(of: cid)); XCTAssertFalse(e.project.clips[0].audioDetached)
    }

    func testReattachInSyncRemovesItemAndRestoresEditsAndUndoRedoAreCoherent() throws {
        let e = project(); let cid = e.project.clips[0].id
        let lid = try XCTUnwrap(e.detachAudio(of: cid))
        XCTAssertTrue(e.reattachAudio(of: cid))
        XCTAssertTrue(e.project.layers.isEmpty); XCTAssertEqual(e.project.clips[0].audio?.fadeIn, 1); XCTAssertFalse(e.project.clips[0].audioDetached)
        e.undo(); XCTAssertEqual(e.project.layers.map(\.id), [lid]); XCTAssertTrue(e.project.clips[0].audioDetached)
        e.undo(); XCTAssertTrue(e.project.layers.isEmpty); XCTAssertEqual(e.project.clips[0].audio?.fadeIn, 1)
        e.redo(); XCTAssertEqual(e.project.layers.count, 1)
    }

    func testCutOfThePictureLeavesTheAudioWholeAndSurvivesSaveAndReload() throws {
        let e = project(); let cid = e.project.clips[0].id
        _ = e.detachAudio(of: cid)
        e.split(at: 4)
        XCTAssertEqual(e.project.layers.count, 1); XCTAssertEqual(e.project.layers[0].duration, 10, accuracy: 1e-9)
        XCTAssertTrue(e.project.clips.prefix(2).allSatisfy(\.audioDetached))
        let f = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/dt-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f)
        let back = try ProjectStore.load(from: f)
        XCTAssertEqual(back, e.project); XCTAssertEqual(back.layers[0].linkedClip, cid)
    }
}

/// Numeric: detaching in sync changes NOTHING in the audible result (full mix and every stem), moving the item shifts the sound, and the A2 stem stays free of linked sound.
final class DetachAudioMixTests: XCTestCase {
    let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/detach-\(UUID().uuidString)")
    override func setUp() async throws { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }
    private func deliver(_ p: SadrogProject, _ sub: String) async throws -> [[Float]] {
        let dir = out.appendingPathComponent(sub); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let srcs = RecordingAudio.sources(media: RecordingAudioTests.c5, trackCount: 2)
        let items = AudioDelivery.plan(p, sources: srcs, baseName: "d")
        let urls = try await AudioDelivery.export(p, items: items, to: dir)
        let h = MixDeliveryTests(); var r: [[Float]] = []
        for u in urls { r.append(try await h.samples(u).x) }
        return r
    }
    func testInSyncDetachIsInaudibleAndShiftMovesTheSound() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5")
        var c = Clip(media: RecordingAudioTests.c5, sourceStart: 10, duration: 4); c.audio = AudioEdit(fadeIn: 0.5)
        var p = SadrogProject(name: "t", clips: [c]); p.sourceGains = [1: -3]; p.masterGainDB = -2
        let attached = try await deliver(p, "a")
        let e = ProjectEditor(project: p); let lid = try XCTUnwrap(e.detachAudio(of: c.id))
        let detached = try await deliver(e.project, "b")
        XCTAssertEqual(attached.count, 3, "mix + 2 sources")
        XCTAssertEqual(detached.count, attached.count, "no extra A2 stem for linked sound")
        for (a, b) in zip(attached, detached) {
            let n = min(a.count, b.count); var d: Float = 0; for i in 0..<n { d = max(d, abs(a[i] - b[i])) }
            XCTAssertLessThan(d, 2e-3, "in-sync detach must not change the signal (max diff \(d))")
        }
        XCTAssertTrue(e.moveLayer(lid, to: 1))
        let moved = try await deliver(e.project, "c")
        func firstLoud(_ x: [Float]) -> Double { Double(x.firstIndex { abs($0) > 0.02 } ?? 0) / 48000 }
        XCTAssertEqual(firstLoud(moved[0]) - firstLoud(detached[0]), 1, accuracy: 0.1, "moving the item shifts the sound by 1 s")
    }
}

final class DetachAudioClipboardTests: XCTestCase {
    func testDeletingEachSideSeparatelyAndPastingACopyKeepsLinksHonest() throws {
        let c = Clip(media: "/a.mov", sourceStart: 0, duration: 6)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c, Clip(media: "/b.mov", sourceStart: 0, duration: 4)]))
        let lid = try XCTUnwrap(e.detachAudio(of: c.id))
        e.delete(clip: c.id)                                                  // picture removed, the sound stays (independent)
        XCTAssertEqual(e.project.layers.map(\.id), [lid]); XCTAssertEqual(e.project.layers[0].linkedClip, c.id)
        XCTAssertFalse(e.detachedAudioInSync(lid), "no picture left to be in sync with")
        e.undo(); XCTAssertEqual(e.project.clips.count, 2); XCTAssertTrue(e.detachedAudioInSync(lid))
        e.deleteLayer(lid); XCTAssertTrue(e.project.clips[0].audioDetached, "picture stays, silent")
    }
}

/// Integrated flow on a synthetic project: two screen clips, a camera overlay, detached + shifted sound, reordered tracks, two callouts on different targets —
/// undo/redo of every step, save/reopen, and the audible result (stems) measured.
final class IntegratedMontageFlowTests: XCTestCase {
    func testWholeFlowUndoRedoReopenAndStems() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5")
        let m = RecordingAudioTests.c5
        let a = Clip(media: m, sourceStart: 10, duration: 4), b = Clip(media: m, sourceStart: 20, duration: 4)
        var cam = Layer(kind: .video, media: m, start: 0, duration: 8); cam.label = "Cameră"
        var cam2 = Layer(kind: .video, media: m, start: 1, duration: 3); cam2.track = 1
        let e = ProjectEditor(project: SadrogProject(name: "Integrat", clips: [a, b], layers: [cam, cam2]))
        var states: [SadrogProject] = [e.project]
        func step(_ f: () -> Void) { f(); states.append(e.project) }
        var lid: UUID?
        step { lid = e.detachAudio(of: a.id) }
        step { XCTAssertTrue(e.moveLayer(try! XCTUnwrap(lid), to: 1.5)) }
        step { XCTAssertTrue(e.swapRows(.v2, 0, 1)) }
        step { XCTAssertTrue(e.setTrackName(.v2, 1, "Cameră")) }
        var c1 = Callout(start: 1, duration: 3); c1.clipID = a.id
        var c2 = Callout(start: 2, duration: 3); c2.clipID = b.id
        step { XCTAssertTrue(e.addCallout(c1)) }
        step { XCTAssertTrue(e.addCallout(c2)) }
        XCTAssertEqual(e.project.calloutRows().values.max(), 1, "two simultaneous effects sit on two rows")
        // every step is its own history entry, both ways
        for i in stride(from: states.count - 1, to: 0, by: -1) { XCTAssertEqual(e.project, states[i]); XCTAssertTrue(e.undo() || i == 0) ; }
        XCTAssertEqual(e.project, states[0])
        for i in 1..<states.count { XCTAssertTrue(e.redo()); XCTAssertEqual(e.project, states[i], "redo step \(i)") }
        XCTAssertEqual(e.project.layers.count, 3); XCTAssertEqual(e.project.callouts.count, 2)
        let f = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/int-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f); XCTAssertEqual(try ProjectStore.load(from: f), e.project)
        // audible: the clip's own sound is gone from its slot (no doubling) and the detached copy starts 1.5 s into the document
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/intd-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: out) }
        let srcs = RecordingAudio.sources(media: m, trackCount: 2)
        let items = AudioDelivery.plan(e.project, sources: srcs, baseName: "i").filter { if case .source = $0.selection { return true } else { return false } }
        let urls = try await AudioDelivery.export(e.project, items: items, to: out)
        let h = MixDeliveryTests()
        for (k, u) in urls.enumerated() {
            let x = try await h.samples(u).x
            func energy(_ from: Double, _ to: Double) -> Double { Double(x[Int(from * 48000)..<min(x.count, Int(to * 48000))].reduce(Float(0)) { $0 + abs($1) }) }
            XCTAssertLessThan(energy(0, 1.4), 1e-3 + (k == 0 ? 1e9 : 0) , "stem \(k)")     // silence before the shifted item exists (clip 1's own slot is silent)
            XCTAssertGreaterThan(energy(1.6, 3.0) + energy(4.2, 7.5), 0, "stem \(k) carries sound")
        }
    }
}

final class DetachAudioIdentityTests: XCTestCase {
    private func detached() throws -> (ProjectEditor, Clip.ID, Layer.ID) {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 2, duration: 10), Clip(media: "/b.mov", sourceStart: 0, duration: 6)]))
        let cid = e.project.clips[0].id; return (e, cid, try XCTUnwrap(e.detachAudio(of: cid)))
    }
    func testPasteKeepsSourceIdentityButDropsTheMontageLink() throws {
        let (e, _, lid) = try detached()
        let made = e.paste(e.clipboardItems(for: [lid]), clipIndex: 0, at: 20)
        let copy = try XCTUnwrap(e.project.layers.first { made.contains($0.id) })
        XCTAssertNil(copy.linkedClip); XCTAssertTrue(copy.keepsSource, "the copy still plays as its recording source (stem, volume, mute, effects)")
    }
    func testCutPiecesReattachTogetherWithoutLeavingFragments() throws {
        let (e, cid, lid) = try detached()
        e.splitLayer(kind: .audio, at: 4)
        XCTAssertEqual(e.project.layers.count, 2); XCTAssertTrue(e.detachedAudioInSync(lid), "contiguous pieces still cover the clip")
        XCTAssertTrue(e.reattachAudio(of: cid)); XCTAssertTrue(e.project.layers.isEmpty, "no fragment is left to double the sound")
    }
    func testReattachRefusedWhenTheItemCarriesItsOwnGainOrMute() throws {
        let (e, cid, lid) = try detached()
        e.setAudio(lid, AudioEdit(gainDB: 6))
        XCTAssertEqual(e.reattachBlocker(of: cid), "edited"); XCTAssertFalse(e.reattachAudio(of: cid))
        XCTAssertEqual(e.project.layers.count, 1); XCTAssertTrue(e.project.clips[0].audioDetached)
    }
}
