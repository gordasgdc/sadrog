// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Key-command display: labels (typing is never kept), collection (injected, nothing real is read), persistence, editor state, rendering (synthetic only).
final class KeyTrackTests: XCTestCase {
    let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/"
    func tmp(_ name: String) throws -> URL { let d = URL(fileURLWithPath: root + "temp/keys-\(name)-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); return d }
    func lbl(_ k: String, c: Bool = false, ctl: Bool = false, o: Bool = false, s: Bool = false) -> String? { KeyTrack.label(key: k, command: c, control: ctl, option: o, shift: s) }

    func testOnlyCommandsGetALabelAndTypingNeverDoes() {
        XCTAssertEqual(lbl("k", c: true), "⌘K"); XCTAssertEqual(lbl("f", o: true, s: true), "⌥⇧F"); XCTAssertEqual(lbl("s", c: true, ctl: true), "⌃⌘S")
        XCTAssertEqual(lbl("space", c: true), "⌘␣"); XCTAssertEqual(lbl("f5"), "F5"); XCTAssertEqual(lbl("left", o: true), "⌥←")
        for typed in ["a", "p", "7", "space", "return", "left", "delete", "A"] { XCTAssertNil(lbl(typed), "plain \(typed) is typing/navigation, not a command") }
        XCTAssertNil(lbl("p", s: true), "shift alone is still typing"); XCTAssertNil(lbl("", c: true)); XCTAssertNil(lbl("hello", c: true), "a word is never a key")
    }
    func testKeyCodesMapToSpecialNames() {
        XCTAssertEqual(KeyTrack.specialName(keyCode: 49), "space"); XCTAssertEqual(KeyTrack.specialName(keyCode: 122), "f1"); XCTAssertNil(KeyTrack.specialName(keyCode: 40))
    }
    func testRecorderRecordsOnlyWhileRunningAndIgnoresPauses() {
        var clock = 50.0
        let r = KeyRecorder(now: { clock })
        r.record(label: "⌘A"); XCTAssertEqual(r.stop().strokes.count, 0, "nothing recorded before start")
        r.start(); clock = 50.5; r.record(label: "⌘K")
        r.pause(); clock = 60; r.record(label: "⌘X"); r.resume(); clock = 60.5; r.record(label: "⌥F")
        let t = r.stop()
        XCTAssertEqual(t.strokes.map(\.label), ["⌘K", "⌥F"], "a paused recorder drops what arrives")
        XCTAssertEqual(t.strokes[1].t, 1.0, accuracy: 1e-6, "the 9.5 paused seconds are not in the track")
        r.record(label: "⌘Z"); XCTAssertEqual(r.stop().strokes.count, 0, "a stopped recorder records nothing")
    }
    func testVisibleWindowFadeAndCap() {
        let t = KeyTrack(strokes: [KeyStroke(t: 1, label: "⌘A"), KeyStroke(t: 1.1, label: "⌘B"), KeyStroke(t: 1.2, label: "⌘C"), KeyStroke(t: 1.3, label: "⌘D")])
        XCTAssertTrue(t.visible(at: 0.9).isEmpty, "not before the press")
        XCTAssertEqual(t.visible(at: 1.5).map(\.label), ["⌘B", "⌘C", "⌘D"], "at most three, newest kept")
        XCTAssertEqual(t.visible(at: 1.0 + 1.39).map(\.label), ["⌘B", "⌘C", "⌘D"], "all three still within the hold")
        XCTAssertEqual(t.visible(at: 1.1 + 1.45).map(\.label), ["⌘C", "⌘D"], "the oldest expire first")
        XCTAssertTrue(t.visible(at: 3).isEmpty, "gone after the hold time")
        XCTAssertEqual(t.visible(at: 1.7).first { $0.label == "⌘D" }!.age, 0.4 / KeyTrack.holdSeconds, accuracy: 1e-9)
        let shifted = KeyTrack(strokes: [KeyStroke(t: 1, label: "⌘A")], syncOffset: 0.5)
        XCTAssertTrue(shifted.visible(at: 1.2).isEmpty); XCTAssertEqual(shifted.visible(at: 1.6).count, 1)
    }
    func testFileRoundTripHasNoTypedTextFields() throws {
        let d = try tmp("file"); defer { try? FileManager.default.removeItem(at: d) }
        let t = KeyTrack(strokes: [KeyStroke(t: 0.5, label: "⌘K")], syntheticFixture: true)
        try t.save(to: d); XCTAssertEqual(KeyTrack.load(besideMedia: d.appendingPathComponent("clip.mov").path), t)
        let json = String(data: try Data(contentsOf: d.appendingPathComponent("keys.json")), encoding: .utf8)!
        for bad in ["char", "text", "window", "app", "title", "code"] { XCTAssertFalse(json.lowercased().contains(bad), bad) }
        XCTAssertNil(KeyTrack.load(besideMedia: "/nonexistent/clip.mov"))
    }
    func testDisplayIsOffByDefaultAndSurvivesSaveAndUndo() throws {
        let c = Clip(media: "/x/a.mov", sourceStart: 0, duration: 2)
        XCTAssertNil(c.keyFX, "off by default"); XCTAssertFalse(SadrogProject(name: "p", clips: [c]).needsCompositing)
        let ed = ProjectEditor(project: SadrogProject(name: "p", clips: [c])); let id = ed.project.clips[0].id
        ed.setKeyFX(clip: id, KeyFX(show: true))
        XCTAssertEqual(ed.project.clips[0].keyFX, KeyFX(show: true)); XCTAssertTrue(ed.project.needsCompositing)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(ed.project)); XCTAssertEqual(back.clips[0].keyFX, KeyFX(show: true))
        ed.undo(); XCTAssertNil(ed.project.clips[0].keyFX, "one undo step")
        ed.setKeyFX(clip: id, KeyFX(show: true)); ed.setKeyFX(clip: id, KeyFX(show: false)); XCTAssertNil(ed.project.clips[0].keyFX, "off stores nothing")
        XCTAssertFalse(String(data: try JSONEncoder().encode(ed.project), encoding: .utf8)!.contains("keyFX"))
    }
    func testKeycapsAreRenderedAndGoAway() async throws {
        let d = try tmp("render"); defer { try? FileManager.default.removeItem(at: d) }
        let media = d.appendingPathComponent("red.mov"); try FileManager.default.copyItem(at: URL(fileURLWithPath: root + "synthetic/testcolors/red.mov"), to: media)
        try KeyTrack(strokes: [KeyStroke(t: 0.5, label: "⌘K")], syntheticFixture: true).save(to: d)         // SYNTHETIC command; the source is pure red
        let ed = ProjectEditor(project: SadrogProject(name: "k", clips: [Clip(media: media.path, sourceStart: 0, duration: 3)]))
        ed.setKeyFX(clip: ed.project.clips[0].id, KeyFX(show: true))
        let out = URL(fileURLWithPath: root + "temp/keys-\(UUID().uuidString).mov")
        try await ProjectExporter.export(ed.project, to: out, mode: .reencode(preset: AVAssetExportPresetHighestQuality)); defer { try? FileManager.default.removeItem(at: out) }
        let w = 1280, h = 720
        func darkest(_ t: Double) async throws -> Int {      // scan the bottom-centre band for the keycap's dark fill
            var m = 255
            for dx in stride(from: -60, through: 60, by: 6) { for y in stride(from: h - Int(0.075 * Double(h)) - 36, through: h - Int(0.075 * Double(h)) - 4, by: 6) { m = min(m, try await pixel(out, at: t, x: w / 2 + dx, y: y).r) } }
            return m
        }
        let during = try await darkest(0.8), before = try await darkest(0.2), after = try await darkest(2.5)
        XCTAssertLessThan(during, 130, "keycap visible while the command is on screen (\(during))")
        XCTAssertGreaterThan(before, 200, "nothing before the press (\(before))"); XCTAssertGreaterThan(after, 200, "gone after the hold time (\(after))")
    }
    func testKeycapsStayVisibleOnAZoomedClip() async throws {
        let d = try tmp("zoom"); defer { try? FileManager.default.removeItem(at: d) }
        let media = d.appendingPathComponent("red.mov"); try FileManager.default.copyItem(at: URL(fileURLWithPath: root + "synthetic/testcolors/red.mov"), to: media)
        try KeyTrack(strokes: [KeyStroke(t: 0.5, label: "⌘K")], syntheticFixture: true).save(to: d)
        var c = Clip(media: media.path, sourceStart: 0, duration: 3); c.transform = Transform(x: 0, y: 0, scale: 1.5)       // the picture is zoomed: its bottom edge is cut off
        let ed = ProjectEditor(project: SadrogProject(name: "z", clips: [c])); ed.setKeyFX(clip: ed.project.clips[0].id, KeyFX(show: true))
        let out = URL(fileURLWithPath: root + "temp/keys-\(UUID().uuidString).mov")
        try await ProjectExporter.export(ed.project, to: out, mode: .reencode(preset: AVAssetExportPresetHighestQuality)); defer { try? FileManager.default.removeItem(at: out) }
        let w = 1280, h = 720; var m = 255
        for dx in stride(from: -60, through: 60, by: 6) { for y in stride(from: h - Int(0.075 * Double(h)) - 36, through: h - Int(0.075 * Double(h)) - 4, by: 6) { m = min(m, try await pixel(out, at: 0.8, x: w / 2 + dx, y: y).r) } }
        XCTAssertLessThan(m, 130, "the keycap is drawn on the screen, not on the zoomed picture (\(m))")
    }
    func testArchiveCarriesTheKeyTrack() throws {
        let d = try tmp("arch"), out = try tmp("archout"); defer { try? FileManager.default.removeItem(at: d); try? FileManager.default.removeItem(at: out) }
        let media = d.appendingPathComponent("red.mov"); try FileManager.default.copyItem(at: URL(fileURLWithPath: root + "synthetic/testcolors/red.mov"), to: media)
        let tr = KeyTrack(strokes: [KeyStroke(t: 0.2, label: "⌘K")], syntheticFixture: true); try tr.save(to: d)
        let r = try ProjectArchive.create(SadrogProject(name: "a", clips: [Clip(media: media.path, sourceStart: 0, duration: 2)]), in: out)
        XCTAssertEqual(KeyTrack.load(besideMedia: r.folder.appendingPathComponent("Media/01/red.mov").path), tr)
    }
    func pixel(_ url: URL, at t: Double, x: Int, y: Int) async throws -> (r: Int, g: Int, b: Int) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -x, y: -(img.height - 1 - y), width: img.width, height: img.height)); return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
}

/// Where a raw key event is classified: only a command label survives; Secure Input drops everything.
final class KeyCaptureTests: XCTestCase {
    func cap(_ code: UInt16, _ ch: String?, c: Bool = false, o: Bool = false, ctl: Bool = false, s: Bool = false, secure: Bool = false) -> String? {
        KeyCapture.label(keyCode: code, characters: ch, command: c, control: ctl, option: o, shift: s, secureInput: secure)
    }
    func testTypedTextNeverBecomesALabel() {
        let typed: [(UInt16, String)] = [(0, "p"), (1, "a"), (2, "s"), (3, "s"), (18, "1"), (49, " "), (36, "\r"), (51, "\u{7f}")]
        for (k, c) in typed { XCTAssertNil(cap(k, c), "typing \(c.debugDescription)") }
        XCTAssertNil(cap(0, "P", s: true), "shifted letter is still typing")
    }
    func testCommandsAndFunctionKeysSurviveWithTheirLabelOnly() {
        XCTAssertEqual(cap(40, "k", c: true), "⌘K"); XCTAssertEqual(cap(122, nil), "F1"); XCTAssertEqual(cap(49, " ", c: true), "⌘␣"); XCTAssertEqual(cap(123, nil, o: true), "⌥←")
    }
    func testSecureInputDropsEverythingEvenCommands() {
        XCTAssertNil(cap(40, "k", c: true, secure: true)); XCTAssertNil(cap(122, nil, secure: true))
    }
    func testRecorderOnlyEverHoldsLabelsFromTheFilter() {
        var clock = 0.0; let r = KeyRecorder(now: { clock }); r.start()
        for (k, ch, c) in [(UInt16(0), "s", false), (UInt16(1), "e", false), (UInt16(40), "k", true)] {
            clock += 0.1; if let l = cap(k, ch, c: c) { r.record(label: l) }
        }
        let t = r.stop(); XCTAssertEqual(t.strokes.map(\.label), ["⌘K"])
        let json = String(data: try! JSONEncoder().encode(t), encoding: .utf8)!; XCTAssertFalse(json.contains("\"s\"") || json.contains("\"e\""))
    }
}
