// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Cross-dissolve: the model rules (overlap, ripple, limits, undo, file), and the pictures/sound the exporter really writes (synthetic red/blue sources).
final class DissolveTests: XCTestCase {
    let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/synthetic/"
    var red: String { dir + "testcolors/red.mov" }
    var blue: String { dir + "testcolors/blue.mov" }
    var beep: String { dir + "inout/colors_beep.mov" }
    func editor(_ lens: [Double] = [2, 2]) -> ProjectEditor {
        ProjectEditor(project: SadrogProject(name: "d", clips: lens.enumerated().map { Clip(media: $0.offset % 2 == 0 ? red : blue, sourceStart: 0, duration: $0.element) }))
    }
    func testDissolveOverlapsAndShortensTheTimeline() {
        let ed = editor(); let id = ed.project.clips[1].id
        XCTAssertEqual(ed.maxDissolve(forClip: ed.project.clips[0].id), 0, "the first clip has nothing before it")
        ed.setDissolve(clip: id, seconds: 1)
        XCTAssertEqual(ed.project.duration, 3, accuracy: 1e-9)
        XCTAssertEqual(ed.project.clipSpans.map(\.start), [0, 1]); XCTAssertEqual(ed.project.clipSpans.map(\.end), [2, 3])
        XCTAssertEqual(ed.project.clipLanes, [0, 1])
        ed.setDissolve(clip: id, seconds: 99); XCTAssertEqual(ed.project.clips[1].dissolve, 2 - ProjectEditor.minClip, accuracy: 1e-9, "never more than the material allows")
        ed.setDissolve(clip: id, seconds: 0); XCTAssertEqual(ed.project.duration, 4); XCTAssertEqual(ed.project.clipLanes, [0, 0])
        XCTAssertTrue(ed.undo()); XCTAssertEqual(ed.project.clips[1].dissolve, 2 - ProjectEditor.minClip, accuracy: 1e-9)
    }
    func testNothingMovesSilently() {
        var p = SadrogProject(name: "d", clips: [Clip(media: red, sourceStart: 0, duration: 2), Clip(media: blue, sourceStart: 0, duration: 2), Clip(media: red, sourceStart: 0, duration: 2)])
        let cb = Callout(start: 4.5, duration: 1, clipID: p.clips[2].id); p.callouts = [cb]
        let ed = ProjectEditor(project: p)
        ed.setDissolve(clip: p.clips[1].id, seconds: 1)
        XCTAssertEqual(ed.project.callouts[0].start, 3.5, accuracy: 1e-9, "a clip-bound callout moves with its clip")
        XCTAssertEqual(ed.project.start(ofClip: p.clips[2].id)!, 3, accuracy: 1e-9)
        ed.setDissolve(clip: p.clips[2].id, seconds: 1.5)       // the clip's two dissolves can never meet: 1 + 1.5 > 2 − min
        XCTAssertLessThanOrEqual(ed.project.clips[1].dissolve + ed.project.clips[2].dissolve, 2 - ProjectEditor.minClip + 1e-9)
        XCTAssertGreaterThan(ed.project.clips[2].dissolve, 0)
    }
    func testEditsKeepDissolvesPossible() {
        let ed = editor([3, 3]); let id = ed.project.clips[1].id; ed.setDissolve(clip: id, seconds: 2)
        ed.split(at: 2)                                         // spans 0–3 and 1–4: two clips are on screen at 2 s → refused
        XCTAssertEqual(ed.project.clips.count, 2, "no cut inside a dissolve")
        ed.split(at: 3.5); XCTAssertEqual(ed.project.clips.count, 3)
        XCTAssertEqual(ed.project.clips[1].dissolve, 2); XCTAssertEqual(ed.project.clips[2].dissolve, 0, "the new piece starts with a plain cut")
        ed.trimEnd(clip: ed.project.clips[0].id, by: 2.2)       // the previous clip is trimmed: the dissolve shrinks to what is left
        for i in ed.project.clips.indices { XCTAssertLessThanOrEqual(ed.project.overlap(into: i), (i > 0 ? ed.project.clips[i - 1].duration : 0)) }
        XCTAssertLessThan(ed.project.clips[1].dissolve, 0.8)
        ed.delete(clip: ed.project.clips[0].id); XCTAssertEqual(ed.project.clips[0].dissolve, 0, "none on the first clip")
        let d = ed.duplicate(clip: ed.project.clips[1].id); XCTAssertEqual(ed.project.clips.first { $0.id == d }?.dissolve, 0)
    }
    func testSavedAndReopened() throws {
        let ed = editor(); ed.setDissolve(clip: ed.project.clips[1].id, seconds: 0.8)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(ed.project))
        XCTAssertEqual(back.clips[1].dissolve, 0.8); XCTAssertEqual(back, ed.project)
        XCTAssertFalse(String(data: try JSONEncoder().encode(editor().project), encoding: .utf8)!.contains("dissolve"), "older/plain projects carry no new key")
    }
    func pixel(_ url: URL, at t: Double) async throws -> (r: Int, g: Int, b: Int) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -100, y: -(img.height - 1 - 100), width: img.width, height: img.height)); return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
    func testExportedPictureBlendsRedIntoBlue() async throws {
        let ed = editor(); ed.setDissolve(clip: ed.project.clips[1].id, seconds: 1)
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/dissolve-\(UUID().uuidString).mov")
        try await ProjectExporter.export(ed.project, to: out, mode: .reencode(preset: AVAssetExportPresetHighestQuality)); defer { try? FileManager.default.removeItem(at: out) }
        let d = try await AVURLAsset(url: out).load(.duration).seconds; XCTAssertEqual(d, 3, accuracy: 0.1)
        var p = try await pixel(out, at: 0.5); XCTAssertGreaterThan(p.r, 200, "before: red \(p)"); XCTAssertLessThan(p.b, 60)
        p = try await pixel(out, at: 1.5); XCTAssertTrue(p.r > 70 && p.r < 190 && p.b > 70 && p.b < 190, "middle of the dissolve is a mix \(p)")
        let q = try await pixel(out, at: 1.25), r = try await pixel(out, at: 1.75); XCTAssertGreaterThan(q.r, r.r, "red fades out"); XCTAssertLessThan(q.b, r.b, "blue fades in")
        p = try await pixel(out, at: 2.5); XCTAssertGreaterThan(p.b, 200, "after: blue \(p)"); XCTAssertLessThan(p.r, 60)
    }
    func testSoundCrossfadesOverTheSameSpan() async throws {
        var p = SadrogProject(name: "d", clips: [Clip(media: beep, sourceStart: 0, duration: 2), Clip(media: beep, sourceStart: 0, duration: 2)])
        let ed = ProjectEditor(project: p); ed.setDissolve(clip: ed.project.clips[1].id, seconds: 1); p = ed.project
        let b = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(b.composition.duration.seconds, 3, accuracy: 0.01, "audio and picture end together")
        XCTAssertGreaterThanOrEqual(b.composition.tracks(withMediaType: .audio).count, 2, "the incoming clip has its own audio track")
        let mix = try XCTUnwrap(b.audioMix(for: p)); XCTAssertEqual(mix.inputParameters.count, b.composition.tracks(withMediaType: .audio).count)
        for ip in mix.inputParameters {   // every track has a ramp across 1…2 s: the outgoing one down, the incoming one up
            var start: Float = 0, end: Float = 0; var range = CMTimeRange.zero; var found = false
            var t = 0.0; while t < 3 { if ip.getVolumeRamp(for: CMTime(seconds: t, preferredTimescale: 600), startVolume: &start, endVolume: &end, timeRange: &range), range.duration.seconds > 0.5 { found = true; break }; t += 0.25 }
            XCTAssertTrue(found, "ramp present"); XCTAssertEqual(range.duration.seconds, 1, accuracy: 0.01)
        }
    }
}
