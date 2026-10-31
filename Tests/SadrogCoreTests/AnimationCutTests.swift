// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// A cut or a trim never changes what is shown: every piece, sampled over its own time, equals the ORIGINAL animation at the matching time.
final class AnimationCutTests: XCTestCase {
    let a = Transform(x: -0.3, y: 0.1, scale: 1, opacity: 1), b = Transform(x: 0.4, y: -0.2, scale: 1.5, opacity: 0.8)
    let k1 = Transform(x: 0.1, y: 0.3, scale: 0.7, opacity: 1), k2 = Transform(x: -0.5, y: 0, scale: 2, opacity: 0.5)

    func close(_ p: Transform, _ q: Transform, _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        for (n, u, v) in [("x", p.x, q.x), ("y", p.y, q.y), ("scale", p.scale, q.scale), ("opacity", p.opacity, q.opacity)] {
            XCTAssertEqual(u, v, accuracy: 1e-9, "\(msg) \(n)", file: file, line: line)
        }
    }
    /// Compares the pieces of `orig` cut at `off` with the original, 41 samples each, and returns them for further cuts.
    @discardableResult func check(_ orig: Animation, _ D: Double, _ off: Double, _ msg: String) -> (Animation, Animation) {
        let (x, y) = orig.partition(duration: D, at: off)
        for i in 0...40 {
            let e1 = off * Double(i) / 40, e2 = (D - off) * Double(i) / 40
            close(x.state(elapsed: e1, duration: off), orig.state(elapsed: e1, duration: D), "\(msg) first @\(e1)")
            close(y.state(elapsed: e2, duration: D - off), orig.state(elapsed: off + e2, duration: D), "\(msg) second @\(e2)")
        }
        return (x, y)
    }
    var cases: [(String, Animation)] {
        var out: [(String, Animation)] = []
        for e in Easing.allCases {
            out.append(("two-state \(e)", Animation(a: a, b: b, motion: Motion(easing: e))))
            out.append(("keys \(e)", Animation(a: a, b: b, motion: Motion(keys: [MotionKey(t: 1.2, transform: k1), MotionKey(t: 3, transform: k2)], easing: e))))
            out.append(("keys, no end \(e)", Animation(a: a, b: nil, motion: Motion(keys: [MotionKey(t: 1.2, transform: k1), MotionKey(t: 3, transform: k2)], easing: e))))
            out.append(("keys+fades \(e)", Animation(a: a, b: b, motion: Motion(keys: [MotionKey(t: 2, transform: k1)], easing: e, fadeIn: 1, fadeOut: 1.5))))
        }
        out.append(("plain two-state", Animation(a: a, b: b, motion: nil)))
        out.append(("fades only", Animation(a: a, b: nil, motion: Motion(fadeIn: 1, fadeOut: 1))))
        out.append(("static", Animation(a: a, b: nil, motion: nil)))
        return out
    }
    let D = 4.0
    func testEveryCutKeepsThePicture() {
        for (n, an) in cases { for off in [0.3, 1.0, 1.2, 2.0, 2.5, 3.0, 3.4, 3.9] { check(an, D, off, "\(n) cut \(off)") } }
    }
    func testCutsOfCutsKeepThePicture() {
        for (n, an) in cases {
            let (x, y) = check(an, D, 1.7, n)
            let (y1, y2) = check(y, D - 1.7, 1.1, n + " 2nd of 2nd")
            let (x1, _) = check(x, 1.7, 0.6, n + " 1st of 1st")
            for i in 0...20 {   // the three pieces replay the original
                let e = 0.5 * Double(i) / 20
                close(x1.state(elapsed: e, duration: 0.6), an.state(elapsed: e, duration: D), n + " p1")
                close(y1.state(elapsed: e, duration: 1.1), an.state(elapsed: 1.7 + e, duration: D), n + " p2")
                close(y2.state(elapsed: e, duration: D - 2.8), an.state(elapsed: 2.8 + e, duration: D), n + " p3")
            }
        }
    }
    func testNoJumpAtTheCut() {
        for (n, an) in cases { for off in [0.5, 1.2, 2.2] {
            let (x, y) = an.partition(duration: D, at: off)
            close(x.state(elapsed: off, duration: off), y.state(elapsed: 0, duration: D - off), "\(n) seam \(off)")
        } }
    }
    func testTrimsKeepWhatStays() {
        for (n, an) in cases {
            var c = Clip(media: "m", sourceStart: 0, duration: D, transform: an.a, endTransform: an.b); c.motion = an.motion
            var f = c; f.trimmedFront(by: 1.3, duration: D)
            var t = c; t.trimmedBack(by: 1.1, duration: D)
            for i in 0...30 {
                let e = (D - 1.3) * Double(i) / 30
                close(f.animation.state(elapsed: e, duration: D - 1.3), an.state(elapsed: 1.3 + e, duration: D), n + " front")
                let e2 = (D - 1.1) * Double(i) / 30
                close(t.animation.state(elapsed: e2, duration: D - 1.1), an.state(elapsed: e2, duration: D), n + " back")
            }
        }
    }
    func testEditorSplitFreezeUndoAndSave() throws {
        var c = Clip(media: "m", sourceStart: 0, duration: D, transform: a, endTransform: b)
        c.motion = Motion(keys: [MotionKey(t: 2, transform: k1)], easing: .easeIn, fadeIn: 0.5, fadeOut: 0.5)
        let an = c.animation
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [c]))
        ed.split(at: 1.5)
        let (c1, c2) = (ed.project.clips[0], ed.project.clips[1])
        close(c1.animation.state(elapsed: 1.5, duration: 1.5), c2.animation.state(elapsed: 0, duration: 2.5), "editor seam")
        close(c2.animation.state(elapsed: 1.0, duration: 2.5), an.state(elapsed: 2.5, duration: D), "editor second")
        // freeze at 2.5 s: the held frame shows exactly what the original showed there, then the clip goes on without a jump
        let id = ed.freezeFrame(at: 2.5, length: 1)
        let held = try XCTUnwrap(ed.project.clips.first { $0.id == id })
        XCTAssertNil(held.endTransform); XCTAssertNil(held.motion)
        close(held.transform, an.state(elapsed: 2.5, duration: D), "freeze")
        let after = ed.project.clips[ed.project.clips.firstIndex { $0.id == id }! + 1]
        close(after.animation.state(elapsed: 0, duration: after.duration), an.state(elapsed: 2.5, duration: D), "after freeze")
        // undo restores the single clip; save/reopen keeps the sliced animation
        XCTAssertTrue(ed.undo()); XCTAssertTrue(ed.undo()); XCTAssertEqual(ed.project.clips.count, 1)
        ed.redo()
        let data = try JSONEncoder().encode(ed.project), back = try JSONDecoder().decode(SadrogProject.self, from: data)
        XCTAssertEqual(back.clips, ed.project.clips)
    }
}
