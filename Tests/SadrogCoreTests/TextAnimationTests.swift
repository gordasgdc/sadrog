// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Title underline/outline (rendered pixels) and entrance/exit presets (keyframes, cuts, moves, undo, file).
final class TextAnimationTests: XCTestCase {
    let rest = Transform(x: 0.1, y: 0.2, scale: 1, opacity: 1)
    func editor(_ d: Double = 4) -> (ProjectEditor, UUID) {
        let t = TextOverlay(text: "Titlu", start: 1, duration: d, transform: rest)
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/x/y.mov", sourceStart: 0, duration: 8)], texts: [t])); return (ed, t.id)
    }
    func at(_ t: TextOverlay, _ e: Double) -> Transform { t.animation.state(elapsed: e, duration: t.duration) }
    func testEntranceAndExitShapes() {
        let (ed, id) = editor(); ed.setTextAnimation(id, TextAnimation(appear: .slide, disappear: .shrink, seconds: 0.5))
        let t = ed.project.texts[0]
        XCTAssertEqual(at(t, 0).opacity, 0, accuracy: 1e-9); XCTAssertEqual(at(t, 0).y, 0.26, accuracy: 1e-9, "starts lower")
        XCTAssertEqual(at(t, 0.5).y, 0.2, accuracy: 1e-9); XCTAssertEqual(at(t, 0.5).opacity, 1, accuracy: 1e-9)
        XCTAssertEqual(at(t, 2).x, 0.1, accuracy: 1e-9, "rests where it was placed"); XCTAssertEqual(at(t, 2).scale, 1, accuracy: 1e-9)
        XCTAssertEqual(at(t, 3.5).scale, 1, accuracy: 1e-9); XCTAssertEqual(at(t, 4).scale, 0.7, accuracy: 1e-9); XCTAssertEqual(at(t, 4).opacity, 0, accuracy: 1e-9)
        ed.setTextAnimation(id, TextAnimation(appear: .pop, disappear: .none)); XCTAssertEqual(at(ed.project.texts[0], 0).scale, 0.7, accuracy: 1e-9); XCTAssertEqual(at(ed.project.texts[0], 4).scale, 1, accuracy: 1e-9)
        ed.setTextAnimation(id, TextAnimation()); XCTAssertNil(ed.project.texts[0].motion); XCTAssertNil(ed.project.texts[0].anim); XCTAssertEqual(ed.project.texts[0].transform, rest, "back to the resting placement")
        XCTAssertTrue(ed.undo()); XCTAssertEqual(ed.project.texts[0].anim?.appear, .pop)
    }
    func testMovingATitleMovesItsRestingPlace() {
        let (ed, id) = editor(); ed.setTextAnimation(id, TextAnimation(appear: .fade, disappear: .fade))
        ed.setTransform(id, Transform(x: -0.3, y: 0.4)); let t = ed.project.texts[0]
        XCTAssertEqual(at(t, 2).x, -0.3, accuracy: 1e-9); XCTAssertEqual(at(t, 2).y, 0.4, accuracy: 1e-9); XCTAssertNotNil(t.anim)
    }
    func testCuttingKeepsThePicture() {
        for cut in [1.5, 2.5, 4.5, 4.8] {      // title runs 1…5 s: before the entrance ends, in the middle, inside the exit
            let (ed, id) = editor(); ed.setTextAnimation(id, TextAnimation(appear: .slide, disappear: .slide, seconds: 1)); let orig = ed.project.texts[0]
            ed.splitText(at: cut); XCTAssertEqual(ed.project.texts.count, 2); let (a, b) = (ed.project.texts[0], ed.project.texts[1])
            for i in 0...20 {
                let e1 = a.duration * Double(i) / 20, e2 = b.duration * Double(i) / 20
                for (p, q, m) in [(at(a, e1), at(orig, e1), "first"), (at(b, e2), at(orig, a.duration + e2), "second")] {
                    XCTAssertEqual(p.y, q.y, accuracy: 1e-9, "cut \(cut) \(m) y"); XCTAssertEqual(p.opacity, q.opacity, accuracy: 1e-9, "cut \(cut) \(m) opacity"); XCTAssertEqual(p.scale, q.scale, accuracy: 1e-9)
                }
            }
            if cut == 2.5 { XCTAssertEqual(a.anim?.appear, .slide); XCTAssertEqual(a.anim?.disappear, TextOut.none); XCTAssertEqual(b.anim?.disappear, .slide); XCTAssertEqual(b.anim?.appear, TextIn.none) }
            else { XCTAssertNil(a.anim); XCTAssertNil(b.anim, "a cut inside a ramp leaves ordinary keyframes") }
        }
    }
    func testSavedAndReopened() throws {
        var (ed, id) = editor(); ed.setTextAnimation(id, TextAnimation(appear: .pop, disappear: .shrink, seconds: 0.8))
        var t = ed.project.texts[0]; t.underline = true; t.outline = TextColor(r: 0, g: 0, b: 0, a: 1)
        let back = try JSONDecoder().decode(TextOverlay.self, from: JSONEncoder().encode(t)); XCTAssertEqual(back, t)
        let plain = String(data: try JSONEncoder().encode(TextOverlay(text: "x", start: 0)), encoding: .utf8)!
        for k in ["underline", "outline", "anim"] { XCTAssertFalse(plain.contains(k), "plain titles carry no \(k)") }
        _ = ed; ed = editor().0
    }
    /// Rendered pixels of the title image itself (what preview and export both draw).
    func testUnderlineAndOutlineAreDrawn() throws {
        let r = CGSize(width: 1280, height: 720)
        func ink(_ t: TextOverlay) throws -> (all: Int, bottomRow: Int) {
            let img = try XCTUnwrap(TextRenderer.image(t, render: r)); let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            var all = 0, row = 0
            for y in 0..<h { var n = 0; for x in 0..<w where px[(y * w + x) * 4 + 3] > 40 { n += 1 }; all += n; if n > Int(Double(w) * 0.5) { row += 1 } }
            return (all, row)
        }
        var t = TextOverlay(text: "Iluminat", start: 0, color: .white); let base = try ink(t)
        t.underline = true; let u = try ink(t); XCTAssertGreaterThan(u.all, base.all, "underline adds ink"); XCTAssertGreaterThan(u.bottomRow, base.bottomRow, "a long horizontal line appears")
        t.underline = false; t.outline = TextColor(r: 0, g: 0, b: 0, a: 1); let o = try ink(t); XCTAssertGreaterThan(o.all, base.all, "outline adds ink around the letters")
    }
}
