// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Speed, volume automation, fade/crossfade shapes and key interpolation survive copy, paste, duplicate, split of a selection, save/reopen and undo.
final class LotCompatibilityTests: XCTestCase {
    let k1 = Transform(x: 0.3, y: 0.1, scale: 1.4, opacity: 0.8, rotation: 12)
    func rich() -> (ProjectEditor, UUID, UUID) {
        var c = Clip(media: "/v.mov", sourceStart: 2, duration: 6); c.speed = 2; c.speedMute = false
        var e = AudioEdit(); e.points = [VolumeKey(t: 1, db: -6), VolumeKey(t: 4, db: VolumeKey.silenceDB)]; e.fadeInCurve = FadeCurve(shape: .sCurve, bend: 0.7); e.fadeIn = 0.5; c.audio = e
        c.motion = Motion(keys: [MotionKey(t: 2, transform: k1, easing: .hold)], easing: .linear)
        var l = Layer(kind: .audio, media: "/a.m4a", start: 1, duration: 4); l.speed = 0.5
        var le = AudioEdit(); le.points = [VolumeKey(t: 2, db: 3)]; l.audio = le
        let ed = ProjectEditor(project: SadrogProject(name: "c", clips: [c], layers: [l]))
        return (ed, c.id, l.id)
    }
    func testDuplicateAndPasteKeepEverything() {
        let (e, cid, lid) = rich()
        let ids = e.duplicate(items: [cid, lid])
        XCTAssertEqual(ids.count, 2)
        let c2 = e.project.clips.first { $0.id != cid }!, l2 = e.project.layers.first { $0.id != lid }!
        XCTAssertEqual(c2.speed, 2); XCTAssertEqual(c2.audio?.points, e.project.clips[0].audio?.points); XCTAssertEqual(c2.audio?.fadeInCurve, FadeCurve(shape: .sCurve, bend: 0.7))
        XCTAssertEqual(c2.motion?.keys.first?.easing, .hold)
        XCTAssertEqual(l2.speed, 0.5); XCTAssertEqual(l2.audio?.points, [VolumeKey(t: 2, db: 3)])
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.clips.count, 1); XCTAssertEqual(e.project.layers.count, 1, "one undo step for the whole paste")
    }
    func testSplitOfASelectionCutsPointsAndKeysConsistently() {
        let (e, cid, _) = rich()
        let before = e.project.clips[0]
        _ = e.splitSelection([cid], at: 2)          // 2 s into the clip (timeline seconds): duration is local, so the cut is local too
        XCTAssertEqual(e.project.clips.count, 2)
        let (a, b) = (e.project.clips[0], e.project.clips[1])
        XCTAssertEqual(a.duration + b.duration, before.duration, accuracy: 1e-9)
        XCTAssertEqual(b.sourceStart, before.sourceStart + a.duration * 2, accuracy: 1e-9, "second piece continues the source at speed 2")
        let env0 = before.audio!.envelope(duration: before.duration), env1 = a.audio!.envelope(duration: a.duration), env2 = b.audio!.envelope(duration: b.duration)
        for t in stride(from: 0.0, to: a.duration - 0.01, by: 0.2) { XCTAssertEqual(env1.automation(at: t), env0.automation(at: t), accuracy: 1e-9, "first piece @\(t)") }
        for t in stride(from: 0.0, to: b.duration - 0.01, by: 0.2) { XCTAssertEqual(env2.automation(at: t), env0.automation(at: a.duration + t), accuracy: 1e-9, "second piece @\(t)") }
    }
    func testSaveReopenKeepsAllNewFields() throws {
        let (e, _, lid) = rich()
        var p = e.project
        var le = p.layers[0].audio!; le.crossfade = CrossfadeLink(outgoing: UUID(), shape: CrossfadeShape(mode: .equalPower, curve: FadeCurve(shape: .easeOut, bend: 0.3))); p.layers[0].audio = le
        p.clips[0].dissolveShape = CrossfadeShape(mode: .equalPower)
        var m = p.clips[0].motion!; m.startEasing = .easeIn; p.clips[0].motion = m
        let dir = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/lot-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectStore.save(p, to: dir)
        let q = try ProjectStore.load(from: dir)
        XCTAssertEqual(q.clips[0], p.clips[0]); XCTAssertEqual(q.layers[0], p.layers[0]); XCTAssertEqual(q.layers[0].id, lid)
        XCTAssertEqual(q.clips[0].motion?.startEasing, .easeIn); XCTAssertEqual(q.layers[0].audio?.crossfade?.shape.mode, .equalPower)
    }
    func testLockedTrackBlocksEditsOfAutomationAndSpeed() {
        let (e, cid, lid) = rich()
        e.setLock(.a2, true)
        let before = e.project.layers[0]
        e.addVolumePoint(lid, at: 1); e.setSpeed(layer: lid, 2)
        XCTAssertEqual(e.project.layers[0], before, "a locked sound lane cannot be changed")
        e.setLock(.a2, false); e.setLock(.v1, true)
        let c0 = e.project.clips[0]
        e.setSpeed(clip: cid, 4)
        XCTAssertEqual(e.project.clips[0], c0, "a locked main track cannot be retimed")
    }
}
