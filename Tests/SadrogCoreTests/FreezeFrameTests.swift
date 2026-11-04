// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Freeze frame: a held clip inserted at the playhead; no sound; trims change only its length; exports with the right length.
final class FreezeFrameTests: XCTestCase {
    func testInsertsHeldClipCutsTheSourceAndUndoes() {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 10, duration: 6)]))
        let id = e.freezeFrame(at: 2, length: 3)
        XCTAssertNotNil(id); let c = e.project.clips
        XCTAssertEqual(c.map(\.duration), [2, 3, 4]); XCTAssertEqual(c.map(\.held), [false, true, false])
        XCTAssertEqual(c[1].sourceStart, 12, accuracy: 1e-9, "the held picture is the one under the playhead"); XCTAssertEqual(c[2].sourceStart, 12, accuracy: 1e-9)
        XCTAssertEqual(e.project.duration, 9, accuracy: 1e-9)
        XCTAssertNil(e.freezeFrame(at: 3.5, length: 1), "no freeze of a freeze")
        e.undo(); XCTAssertEqual(e.project.clips.count, 1); XCTAssertEqual(e.project.duration, 6)
    }
    func testAtTheEdgesOfAClipAndTrimsKeepTheFrame() {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 4)]))
        let id = e.freezeFrame(at: 0, length: 1)!; XCTAssertEqual(e.project.clips.map(\.held), [true, false])
        e.trimStart(clip: id, by: -2); XCTAssertEqual(e.project.clips[0].duration, 3, accuracy: 1e-9); XCTAssertEqual(e.project.clips[0].sourceStart, 0, "a trim never moves the held frame")
        e.trimEnd(clip: id, by: 1); XCTAssertEqual(e.project.clips[0].duration, 2, accuracy: 1e-9)
        e.split(at: 1); XCTAssertEqual(e.project.clips.prefix(2).map(\.held), [true, true]); XCTAssertEqual(e.project.clips[1].sourceStart, 0)
    }
    func testPersists() throws {
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 1, duration: 4)])); e.freezeFrame(at: 2, length: 2)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project)); XCTAssertEqual(back.clips.map(\.held), [false, true, false])
    }
    func testExportedLengthAndHeldPicture() async throws {
        let dir = CompositionTests.dir, blue = dir + "/blue.mov", red = dir + "/red.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue) && FileManager.default.fileExists(atPath: red), "synthetic colour clips not available")
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 2), Clip(media: red, sourceStart: 0, duration: 2)]))
        e.freezeFrame(at: 3, length: 2)         // red, held 2 s in the middle of the red clip: 2 blue + 1 red + 2 held + 1 red
        let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/freeze-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(e.project, to: out)
        let a = AVURLAsset(url: out); let d = try await a.load(.duration).seconds
        XCTAssertEqual(d, 6, accuracy: 0.15)
        let g = AVAssetImageGenerator(asset: a); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        for t in [1.0, 3.5, 4.5, 5.5] {
            let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image; var px = [UInt8](repeating: 0, count: 4)
            CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                .draw(img, in: CGRect(x: -Double(img.width) / 2, y: -Double(img.height) / 2, width: Double(img.width), height: Double(img.height)))
            if t < 2 { XCTAssertGreaterThan(Int(px[2]), 150, "blue at \(t)") } else { XCTAssertGreaterThan(Int(px[0]), 150, "red at \(t)") }
        }
    }
}
