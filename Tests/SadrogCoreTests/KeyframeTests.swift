// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Video keyframes: per-segment interpolation (linear / hold / eased), property-wise editing, and continuity across cut, trim and speed change.
final class KeyframeTests: XCTestCase {
    let a = Transform(x: 0, y: 0, scale: 1, opacity: 1, rotation: 0)
    let k1 = Transform(x: 0.4, y: 0.2, scale: 2, opacity: 0.5, rotation: 30), k2 = Transform(x: -0.2, y: 0, scale: 1.5, opacity: 1, rotation: -10)

    func clipEditor(speed: Double = 1) -> (ProjectEditor, UUID) {
        let c = Clip(media: "/v.mov", sourceStart: 0, duration: 8)
        return (ProjectEditor(project: SadrogProject(name: "k", clips: [c])), c.id)
    }
    func motion(_ e: ProjectEditor) -> Motion? { e.project.clips[0].motion }

    func testHoldKeepsTheValueUntilTheNextKey() {
        let m = Motion(keys: [MotionKey(t: 2, transform: k1, easing: .hold), MotionKey(t: 4, transform: k2)], easing: .linear)
        let v = { (t: Double) in m.placement(start: self.a, end: nil, elapsed: t, duration: 8) }
        XCTAssertEqual(v(1).x, 0.2, accuracy: 1e-9)                        // linear from start to key 1
        XCTAssertEqual(v(3.999).x, 0.4, accuracy: 1e-9)                    // held after key 1 …
        XCTAssertEqual(v(4).x, -0.2, accuracy: 1e-9)                       // … and jumps at key 2
        XCTAssertEqual(v(6).x, -0.2, accuracy: 1e-9)                       // last key holds (no end state)
    }
    func testPerKeyEasingOverridesTheMotionDefault() {
        let m = Motion(keys: [MotionKey(t: 2, transform: k1, easing: .easeIn), MotionKey(t: 4, transform: k2)], easing: .linear)
        let mid = m.placement(start: a, end: nil, elapsed: 3, duration: 8).x
        XCTAssertGreaterThan(mid, (0.4 + -0.2) / 2, "ease-in leaves the first key slowly: still closer to it than the straight line at the middle")
        XCTAssertEqual(m.placement(start: a, end: nil, elapsed: 1, duration: 8).x, 0.2, accuracy: 1e-9, "the first segment keeps the default")
    }
    func testCutKeepsPerSegmentInterpolation() {
        for ease in Easing.allCases {
            var mo = Motion(keys: [MotionKey(t: 2, transform: k1, easing: ease), MotionKey(t: 5, transform: k2, easing: .hold)], easing: .linear); mo.startEasing = .easeOut
            let an = Animation(a: a, b: nil, motion: mo)
            for off in [0.7, 2.0, 2.9, 3.5, 4.9, 5.0, 6.5] {
                let (x, y) = an.partition(duration: 8, at: off)
                for i in 0...40 {
                    let e1 = off * Double(i) / 40, e2 = (8 - off) * Double(i) / 40
                    XCTAssertEqual(x.state(elapsed: e1, duration: off).x, an.state(elapsed: e1, duration: 8).x, accuracy: 1e-9, "\(ease) cut \(off) first @\(e1)")
                    XCTAssertEqual(y.state(elapsed: e2, duration: 8 - off).x, an.state(elapsed: off + e2, duration: 8).x, accuracy: 1e-9, "\(ease) cut \(off) second @\(e2)")
                }
            }
        }
    }
    func testSplitOnTheEditorKeepsKeysAndEasingOnBothPieces() {
        let (e, id) = clipEditor()
        e.setKey(id, at: 2, k1); e.setKey(id, at: 6, k2); e.setKeyEasing(id, index: 0, .hold)
        let before = e.project.clips[0].animation
        e.split(at: 4)
        XCTAssertEqual(e.project.clips.count, 2)
        let (c1, c2) = (e.project.clips[0], e.project.clips[1])
        for t in stride(from: 0.0, to: 3.99, by: 0.25) { XCTAssertEqual(c1.animation.state(elapsed: t, duration: c1.duration).x, before.state(elapsed: t, duration: 8).x, accuracy: 1e-9) }
        for t in stride(from: 0.0, to: 3.99, by: 0.25) { XCTAssertEqual(c2.animation.state(elapsed: t, duration: c2.duration).x, before.state(elapsed: 4 + t, duration: 8).x, accuracy: 1e-9) }
        XCTAssertEqual(c1.motion?.keys.first?.easing, .hold, "the first piece keeps the key and its interpolation")
        XCTAssertEqual(c2.motion?.startEasing, .hold == c1.motion?.keys.first?.easing ? Easing.hold : nil, "the second piece starts mid-segment of the held key")
    }
    func testSettingOnePropertyLeavesTheOthersAlone() {
        let (e, id) = clipEditor()
        e.setKey(id, at: 2, k1)
        e.setKeyProperty(id, index: 0, .opacity, 0.1)
        var t = motion(e)!.keys[0].transform
        XCTAssertEqual(t.opacity, 0.1); XCTAssertEqual(t.x, k1.x); XCTAssertEqual(t.y, k1.y); XCTAssertEqual(t.scale, k1.scale); XCTAssertEqual(t.rotation, k1.rotation, accuracy: 1e-9)
        e.setKeyProperty(id, index: 0, .rotation, -45)
        t = motion(e)!.keys[0].transform
        XCTAssertEqual(t.rotation, -45, accuracy: 1e-9); XCTAssertEqual(t.opacity, 0.1); XCTAssertEqual(t.scale, k1.scale)
        // a property edit at a time without a key creates one from the evaluated state, so nothing else jumps
        e.setProperty(id, at: 5, .scale, 3)
        let k = motion(e)!.keys.first { abs($0.t - 5) < 0.01 }!.transform
        let held = Transform(x: k1.x, y: k1.y, scale: 3, opacity: 0.1, rotation: -45)
        XCTAssertEqual(k.scale, 3); XCTAssertEqual(k.x, held.x, accuracy: 1e-9); XCTAssertEqual(k.opacity, held.opacity, accuracy: 1e-9)
        XCTAssertEqual(e.project.clips[0].motion?.keys.count, 2)
    }
    func testMoveNavigateAndRemoveKeys() {
        let (e, id) = clipEditor()
        e.setKey(id, at: 2, k1); e.setKey(id, at: 5, k2); e.setKeyEasing(id, index: 0, .hold)
        XCTAssertEqual(e.nextKey(id, after: 0), 0); XCTAssertEqual(e.nextKey(id, after: 2), 1); XCTAssertNil(e.nextKey(id, after: 5))
        XCTAssertEqual(e.previousKey(id, before: 5), 0); XCTAssertNil(e.previousKey(id, before: 2))
        e.moveKey(id, index: 0, to: 3)
        XCTAssertEqual(motion(e)!.keys.map(\.t), [3, 5]); XCTAssertEqual(motion(e)!.keys[0].easing, .hold, "moving keeps the interpolation")
        e.moveKey(id, index: 0, to: 99)                                         // clamped inside the item, a key already there is replaced
        XCTAssertEqual(motion(e)!.keys.count, 2); XCTAssertLessThan(motion(e)!.keys.last!.t, 8)
        e.removeKey(id, at: 0)
        XCTAssertEqual(motion(e)!.keys.count, 1)
        XCTAssertTrue(e.undo()); XCTAssertEqual(motion(e)!.keys.count, 2, "one undo step per gesture")
    }
    func testSpeedChangeKeepsTheAnimationShapeAndInterpolation() {
        let (e, id) = clipEditor()
        e.setKey(id, at: 2, k1); e.setKey(id, at: 6, k2); e.setKeyEasing(id, index: 1, .hold)
        let p0 = e.project.clips[0], before = p0.animation
        e.setSpeed(clip: id, 2)
        let c = e.project.clips[0]
        XCTAssertEqual(c.duration, 4, accuracy: 1e-9)
        XCTAssertEqual(c.motion!.keys.map(\.t), [1, 3]); XCTAssertEqual(c.motion!.keys[1].easing, .hold)
        for f in stride(from: 0.0, through: 0.99, by: 0.05) {                    // the same fraction of the clip shows the same look
            XCTAssertEqual(c.animation.state(elapsed: f * c.duration, duration: c.duration).x, before.state(elapsed: f * 8, duration: 8).x, accuracy: 1e-9, "f=\(f)")
        }
    }
    func testTrimDoesNotLoseKeysSilently() {
        let (e, id) = clipEditor()
        e.setKey(id, at: 2, k1); e.setKey(id, at: 6, k2)
        let before = e.project.clips[0].animation
        e.trimStart(clip: id, by: 3)
        let c = e.project.clips[0]
        XCTAssertEqual(c.duration, 5, accuracy: 1e-9)
        for t in stride(from: 0.0, to: 4.99, by: 0.25) { XCTAssertEqual(c.animation.state(elapsed: t, duration: c.duration).x, before.state(elapsed: 3 + t, duration: 8).x, accuracy: 1e-9, "t=\(t)") }
    }
    func testOldProjectsDecodeWithoutNewFields() throws {
        let json = #"{"keys":[{"t":1,"transform":{"x":0.1}}],"easing":"smooth","fadeIn":0,"fadeOut":0}"#.data(using: .utf8)!
        let m = try JSONDecoder().decode(Motion.self, from: json)
        XCTAssertNil(m.startEasing); XCTAssertNil(m.keys[0].easing)
        let back = try JSONDecoder().decode(Motion.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(back, m)
        XCTAssertFalse(String(data: try JSONEncoder().encode(m), encoding: .utf8)!.contains("startEasing"), "new fields are not written when unused")
    }
}
