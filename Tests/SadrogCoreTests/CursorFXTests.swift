// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
import CoreImage
import ImageIO
@testable import SadrogCore

/// Per-clip pointer look (1.7.0): styles, colour, size, opacity; typed clicks (left / right / double); compatibility with projects and tracks saved before;
/// and the SAME place in the preview path and in the exported file after trim, crop and zoom. Synthetic pointer tracks only.
final class CursorFXTests: XCTestCase {
    let n = CGSize(width: 640, height: 360)
    var base: Double { 0.035 * 360 }
    /// Renders the effect over black and returns RGB (0…255) at a pixel given from the TOP-LEFT.
    func px(_ track: MouseTrack, _ fx: MouseFX, at t: Double, x: Double, y: Double) -> (r: Int, g: Int, b: Int) {
        let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: n))
        let img = SadrogCompositor.drawPointer(track, fx: fx, at: t, on: black, size: n)
        var b = [UInt8](repeating: 0, count: 4)
        CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()]).render(img, toBitmap: &b, rowBytes: 4, bounds: CGRect(x: x.rounded(), y: (360 - 1 - y).rounded(), width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Int(b[0]), Int(b[1]), Int(b[2]))
    }
    func still(_ x: Double = 0.5, _ y: Double = 0.5, presses: [(Double, Double)] = [], rights: [(Double, Double)] = []) -> MouseTrack {
        var s = [MouseSample(t: 0, x: x, y: y)]
        var times = Set<Double>([0, 10]); for (a, b) in presses + rights { times.insert(a); times.insert(b) }
        s = times.sorted().map { t in MouseSample(t: t, x: x, y: y, down: presses.contains { t >= $0.0 && t < $0.1 }, right: rights.contains { t >= $0.0 && t < $0.1 }) }
        var tr = MouseTrack(samples: s, syntheticFixture: true); if !rights.isEmpty { tr.rightTracked = true }; return tr
    }

    func testOldProjectsKeepTheirLookAndAreSavedUnchanged() throws {
        let old = try JSONDecoder().decode(MouseFX.self, from: Data(#"{"highlight":true,"clickRing":true}"#.utf8))
        XCTAssertEqual(old.style, .disc); XCTAssertEqual(old.color, MouseFX.legacyColor); XCTAssertEqual(old.opacity, 0.35); XCTAssertEqual(old.clickSeconds, 0.5)
        let json = String(decoding: try JSONEncoder().encode(old), as: UTF8.self)
        for k in ["style", "color", "size", "opacity", "stroke", "clickColor", "clickSeconds", "clickStrength"] { XCTAssertFalse(json.contains(k), k) }
        var f = MouseFX.modern; f.color = TextColor(r: 0, g: 1, b: 1); f.size = 2; f.clickSeconds = 1.2; f.clickStrength = 0.4
        XCTAssertEqual(try JSONDecoder().decode(MouseFX.self, from: JSONEncoder().encode(f)), f)
        let wild = try JSONDecoder().decode(MouseFX.self, from: Data(#"{"highlight":true,"clickRing":true,"size":99,"opacity":-1,"style":"nope"}"#.utf8))
        XCTAssertEqual(wild.size, 3); XCTAssertEqual(wild.opacity, 0.05); XCTAssertEqual(wild.style, .disc)
        // an old pointer track (no secondary button) still loads and says so
        let tr = try JSONDecoder().decode(MouseTrack.self, from: Data(#"{"schema":1,"syntheticFixture":true,"syncOffset":0,"samples":[{"t":0,"x":0.5,"y":0.5,"down":false}]}"#.utf8))
        XCTAssertNil(tr.rightTracked); XCTAssertNil(tr.samples[0].right)
    }
    func testResetUndoRedo() {
        let e = ProjectEditor(project: SadrogProject(name: "c", clips: [Clip(media: "/x.mov", sourceStart: 0, duration: 5)])); let id = e.project.clips[0].id
        var f = MouseFX.modern; f.color = TextColor(r: 1, g: 0, b: 0); f.size = 2
        e.setMouseFX(clip: id, f); XCTAssertEqual(e.project.clips[0].mouseFX, f); XCTAssertFalse(f.lookIsDefault)
        var r = f; r.resetLook(); XCTAssertTrue(r.lookIsDefault); XCTAssertEqual(r.highlight, f.highlight)
        e.setMouseFX(clip: id, r); XCTAssertEqual(e.project.clips[0].mouseFX, r)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.clips[0].mouseFX, f)
        XCTAssertTrue(e.undo()); XCTAssertNil(e.project.clips[0].mouseFX)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.project.clips[0].mouseFX, f)
    }
    func testStylesColourSizeAndOpacity() {
        let tr = still(); let cx = 320.0, cy = 180.0
        var f = MouseFX.modern; f.clickRing = false; f.color = TextColor(r: 0, g: 1, b: 0); f.opacity = 1
        // outline: nothing at the centre, colour on the circle
        var p = px(tr, f, at: 1, x: cx, y: cy); XCTAssertLessThan(p.g, 10, "ring centre is empty \(p)")
        p = px(tr, f, at: 1, x: cx + base - 1, y: cy); XCTAssertGreaterThan(p.g, 180, "ring line \(p)"); XCTAssertLessThan(p.r, 30)
        f.size = 2; p = px(tr, f, at: 1, x: cx + 2 * base - 1.5, y: cy); XCTAssertGreaterThan(p.g, 180, "twice the radius \(p)")
        p = px(tr, f, at: 1, x: cx + base - 1, y: cy); XCTAssertLessThan(p.g, 10, "the old radius is empty at size 2 \(p)")
        // halo: brightest at the centre, fading, nothing far away
        f.size = 1; f.style = .halo
        let c0 = px(tr, f, at: 1, x: cx, y: cy).g, c1 = px(tr, f, at: 1, x: cx + base, y: cy).g, c2 = px(tr, f, at: 1, x: cx + base * 2.2, y: cy).g
        XCTAssertGreaterThan(c0, c1); XCTAssertGreaterThan(c1, c2); XCTAssertLessThan(c2, 6)
        // disc with opacity: a flat fill at that opacity
        f.style = .disc; f.opacity = 0.5; p = px(tr, f, at: 1, x: cx, y: cy); XCTAssertEqual(Double(p.g), 127, accuracy: 6)
        f.highlight = false; p = px(tr, f, at: 1, x: cx, y: cy); XCTAssertLessThan(p.g, 3, "switched off")
    }
    func testClickKindsFromTheTrack() {
        // left at 1.0; double at 3.0 + 3.25 (same place); right at 5.0; a second left far in time
        let tr = still(presses: [(1.0, 1.1), (3.0, 3.08), (3.25, 3.33), (7.0, 7.1)], rights: [(5.0, 5.1)])
        let ev = tr.clickEvents
        XCTAssertEqual(ev.map(\.kind), [.left, .double, .right, .left]); XCTAssertEqual(ev[1].t, 3.0, accuracy: 1e-9); XCTAssertEqual(ev[1].gap, 0.25, accuracy: 1e-9)
        XCTAssertEqual(tr.activeClicks(at: 3.6, duration: 0.5).map(\.kind), [.double]); XCTAssertTrue(tr.activeClicks(at: 3.8, duration: 0.5).isEmpty)
        // two presses close in time but apart on screen are two clicks
        let apart = MouseTrack(samples: [MouseSample(t: 0, x: 0.2, y: 0.2), MouseSample(t: 1, x: 0.2, y: 0.2, down: true), MouseSample(t: 1.05, x: 0.2, y: 0.2), MouseSample(t: 1.2, x: 0.6, y: 0.6, down: true), MouseSample(t: 1.3, x: 0.6, y: 0.6)])
        XCTAssertEqual(apart.clickEvents.map(\.kind), [.left, .left])
        // an old track (no secondary button) never yields a right click
        XCTAssertFalse(still(presses: [(1, 1.1)]).clickEvents.contains { $0.kind == .right })
    }
    func testRecorderReadsTheSecondaryButton() {
        var clock = 0.0, left = false, right = false
        let rec = MouseRecorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100), interval: 0, now: { clock }, readRight: { right }, read: { (CGPoint(x: 50, y: 50), left) })
        rec.start(); rec.tick(); clock = 1; right = true; rec.tick(); clock = 1.1; right = false; rec.tick(); clock = 2; left = true; rec.tick()
        let t = rec.stop()
        XCTAssertEqual(t.rightTracked, true); XCTAssertEqual(t.clickEvents.map(\.kind), [.right, .left])
        let old = MouseRecorder(frame: CGRect(x: 0, y: 0, width: 100, height: 100), interval: 0, now: { clock }, read: { (CGPoint(x: 50, y: 50), false) }); old.start(); old.tick()
        XCTAssertNil(old.stop().rightTracked)
    }
    func testClickEffectsDifferAndNeverStack() {
        var f = MouseFX.modern; f.highlight = false; f.clickColor = TextColor(r: 1, g: 1, b: 1); f.clickStrength = 1
        let cx = 320.0, cy = 180.0
        func ringR(_ age: Double) -> Double { base * (0.6 + 1.6 * age / 0.5) }
        // left: a ring line, an empty inside
        let l = still(presses: [(1, 1.1)])
        XCTAssertGreaterThan(px(l, f, at: 1.2, x: cx + ringR(0.2) - 1.5, y: cy).g, 90); XCTAssertLessThan(px(l, f, at: 1.2, x: cx, y: cy).g, 6)
        // right: a tinted inside as well
        let r = still(rights: [(1, 1.1)])
        XCTAssertGreaterThan(px(r, f, at: 1.2, x: cx, y: cy).g, 20, "right click fills its inside"); XCTAssertGreaterThan(px(r, f, at: 1.2, x: cx + ringR(0.2) - 1, y: cy).g, 60)
        // double: at 0.4 s after the first press there are TWO rings (first aged 0.4, second aged 0.15), and the inside stays empty
        let d = still(presses: [(1, 1.08), (1.25, 1.33)])
        XCTAssertGreaterThan(px(d, f, at: 1.4, x: cx + ringR(0.4) - 1.5, y: cy).g, 25, "first ring"); XCTAssertGreaterThan(px(d, f, at: 1.4, x: cx + ringR(0.15) - 1.5, y: cy).g, 120, "second ring")
        XCTAssertLessThan(px(d, f, at: 1.4, x: cx, y: cy).g, 6)
        // between the two presses only ONE ring exists (no separate simple marker): the place where a fresh second ring would start is empty
        XCTAssertLessThan(px(d, f, at: 1.2, x: cx + ringR(0.0) - 1.5, y: cy).g, 6)
        // duration and strength
        f.clickSeconds = 1.0; XCTAssertGreaterThan(px(l, f, at: 1.8, x: cx + base * (0.6 + 1.6 * 0.8) - 1.5, y: cy).g, 20, "still alive at 0.8 s when it lasts 1 s")
        f.clickSeconds = 0.5; XCTAssertLessThan(px(l, f, at: 1.8, x: cx + base * (0.6 + 1.6 * 0.8) - 1.5, y: cy).g, 6)
        f.clickRing = false; XCTAssertLessThan(px(l, f, at: 1.2, x: cx + ringR(0.2) - 1.5, y: cy).g, 6)
    }
    /// Trim + crop + zoom: the mark is at the same pixel in the preview path (composition through an image generator) and in the exported file, at the same timeline moment.
    func testSamePlaceInPreviewAndExportAfterTrimCropAndZoom() async throws {
        let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: root + "synthetic/testcolors/red.mov"), "synthetic colour clips not available")
        let d = URL(fileURLWithPath: root + "temp/cursorfx-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: d) }
        let media = d.appendingPathComponent("red.mov"); try FileManager.default.copyItem(at: URL(fileURLWithPath: root + "synthetic/testcolors/red.mov"), to: media)
        // the pointer moves: (0.3,0.4) until 1 s, then (0.7,0.6) from 1.5 s on — the clip is trimmed to start at 1.5 s, so only the second place may show
        try MouseTrack(samples: [MouseSample(t: 0, x: 0.3, y: 0.4), MouseSample(t: 1, x: 0.3, y: 0.4), MouseSample(t: 1.5, x: 0.7, y: 0.6), MouseSample(t: 3, x: 0.7, y: 0.6)], syntheticFixture: true).save(to: d)
        var c = Clip(media: media.path, sourceStart: 1.5, duration: 1.2); c.rectCrop = RectCrop(left: 0.2, right: 0, top: 0.1, bottom: 0); c.transform = Transform(x: 0.05, y: -0.04, scale: 1.3)
        var f = MouseFX.modern; f.style = .disc; f.opacity = 1; f.color = TextColor(r: 0, g: 1, b: 0); f.clickRing = false; c.mouseFX = f
        let p = SadrogProject(name: "align", clips: [c])
        let built = try await CompositionBuilder.buildFull(p); let vc = try XCTUnwrap(built.videoComposition(for: p))
        func greenCentre(_ asset: AVAsset, _ comp: AVVideoComposition?) async throws -> (x: Double, y: Double, n: Int) {
            let g = AVAssetImageGenerator(asset: asset); g.videoComposition = comp; g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            let cg = try await g.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image; let w = cg.width, h = cg.height
            var b = [UInt8](repeating: 0, count: w * h * 4)
            CGContext(data: &b, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sx = 0.0, sy = 0.0, k = 0
            for y in 0..<h { for x in 0..<w { let o = (y * w + x) * 4; if b[o + 1] > 150 && b[o] < 110 { sx += Double(x); sy += Double(y); k += 1 } } }
            return (k > 0 ? sx / Double(k) / Double(w) : -1, k > 0 ? sy / Double(k) / Double(h) : -1, k)
        }
        let pre = try await greenCentre(built.composition, vc)
        let out = d.appendingPathComponent("out.mp4"); var s = ExportPreset.builtIns[0].settings(); s.onlyRange = false
        try await ProjectExporter.export(p, to: out, settings: s, documentSize: built.renderSize, documentFPS: 30)
        let exp = try await greenCentre(AVURLAsset(url: out), nil)
        print("CURSOR align preview \(pre) export \(exp)")
        XCTAssertGreaterThan(pre.n, 50, "the mark is drawn"); XCTAssertGreaterThan(exp.n, 50)
        XCTAssertEqual(exp.x, pre.x, accuracy: 0.004); XCTAssertEqual(exp.y, pre.y, accuracy: 0.004)
        // expected place: the pointer's position inside the CROPPED picture, then the clip transform (fit, scale about the centre, offset)
        let ux = (0.7 - 0.2) / 0.8, uy = (0.6 - 0.1) / 0.9                      // fraction of the cropped picture
        let rw = Double(built.renderSize.width), rh = Double(built.renderSize.height), cw = rw * 0.8, chh = rh * 0.9, fit = min(rw / cw, rh / chh) * 1.3
        let ex = (rw / 2 + 0.05 * rw + (ux - 0.5) * cw * fit) / rw, ey = (rh / 2 - 0.04 * rh + (uy - 0.5) * chh * fit) / rh
        XCTAssertEqual(pre.x, ex, accuracy: 0.01, "x after trim+crop+zoom"); XCTAssertEqual(pre.y, ey, accuracy: 0.01, "y after trim+crop+zoom")
    }
    /// Evidence probe (runs only when asked): SADROG_CURSOR_PROBE=<project folder> SADROG_CURSOR_OUT=<folder>. Exports the project as MP4 (Tutorial preset) and saves, for the
    /// left / right / double click moments given in SADROG_CURSOR_TIMES (seconds, comma separated), the preview-path frame and the exported frame, with their mean difference.
    func testProbePreviewVersusExportFrames() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let folder = env["SADROG_CURSOR_PROBE"], let outDir = env["SADROG_CURSOR_OUT"] else { throw XCTSkip("SADROG_CURSOR_PROBE / SADROG_CURSOR_OUT not set") }
        let times = (env["SADROG_CURSOR_TIMES"] ?? "2.2,4.7,7.33").split(separator: ",").compactMap { Double($0) }
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let p = try ProjectStore.load(from: URL(fileURLWithPath: folder).appendingPathComponent("project.sadrogproj"))
        let built = try await CompositionBuilder.buildFull(p); let vc = try XCTUnwrap(built.videoComposition(for: p))
        let out = URL(fileURLWithPath: outDir).appendingPathComponent("proba_cursor.mp4"); try? FileManager.default.removeItem(at: out)
        var s = ExportPreset.builtIns[0].settings(); s.onlyRange = false
        let t0 = Date(); try await ProjectExporter.export(p, to: out, settings: s, documentSize: built.renderSize, documentFPS: 30)
        print("CURSORPROBE export \(out.path) in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s")
        func grab(_ asset: AVAsset, _ comp: AVVideoComposition?, _ t: Double) async throws -> CGImage {
            let g = AVAssetImageGenerator(asset: asset); g.videoComposition = comp; g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
            return try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        }
        func bytes(_ cg: CGImage) -> [UInt8] { var b = [UInt8](repeating: 0, count: cg.width * cg.height * 4); CGContext(data: &b, width: cg.width, height: cg.height, bitsPerComponent: 8, bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height)); return b }
        func save(_ cg: CGImage, _ name: String) { let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: outDir).appendingPathComponent(name) as CFURL, "public.png" as CFString, 1, nil)!; CGImageDestinationAddImage(d, cg, nil); CGImageDestinationFinalize(d) }
        for t in times {
            let a = try await grab(built.composition, vc, t), b = try await grab(AVURLAsset(url: out), nil, t)
            save(a, String(format: "viewer_%.2f.png", t)); save(b, String(format: "mp4_%.2f.png", t))
            let x = bytes(a), y = bytes(b); XCTAssertEqual(x.count, y.count)
            var d = 0.0; for i in stride(from: 0, to: min(x.count, y.count), by: 4) { d += abs(Double(x[i]) - Double(y[i])) + abs(Double(x[i + 1]) - Double(y[i + 1])) + abs(Double(x[i + 2]) - Double(y[i + 2])) }
            let mean = d / Double(x.count / 4 * 3)
            print(String(format: "CURSORPROBE t=%.2f s mean abs difference viewer vs mp4: %.2f / 255", t, mean))
            XCTAssertLessThan(mean, 4, "viewer and exported frame differ at \(t) s")
        }
    }
}
