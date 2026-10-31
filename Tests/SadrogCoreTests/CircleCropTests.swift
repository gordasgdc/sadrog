// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
import AppKit
@testable import SadrogCore

/// „Prezentator în cerc”: framing maths (never distorted), model (format 12, undo, split, old projects) and exported pixels
/// (circle edge, outline, framing, back to the rectangle). Synthetic clips only.
final class CircleCropTests: XCTestCase {
    static let root = "\(TestRoot.path)"
    static let halves = root + "/synthetic/presenter/halves_1280x720.mov"      // left half green, right half yellow
    static let blue = root + "/synthetic/testcolors/blue.mov"

    func testWindowIsASquareThatNeverDistorts() {
        let n = CGSize(width: 1280, height: 720)
        XCTAssertEqual(CircleCrop().window(in: n), CGRect(x: 280, y: 0, width: 720, height: 720))
        XCTAssertEqual(CircleCrop(offsetX: 1).window(in: n), CGRect(x: 560, y: 0, width: 720, height: 720))
        XCTAssertEqual(CircleCrop(offsetX: -1).window(in: n), CGRect(x: 0, y: 0, width: 720, height: 720))
        XCTAssertEqual(CircleCrop(zoom: 2).window(in: n), CGRect(x: 460, y: 180, width: 360, height: 360))
        XCTAssertEqual(CircleCrop(zoom: 2, offsetY: 1).window(in: n).minY, 360)
        let portrait = CircleCrop().window(in: CGSize(width: 720, height: 1280))
        XCTAssertEqual(portrait.width, portrait.height); XCTAssertEqual(portrait.width, 720)
        var c = CircleCrop(zoom: 9, offsetX: 3, offsetY: -5, border: CircleBorder(width: 1, opacity: 2)); c.normalize()
        XCTAssertEqual(c.zoom, 4); XCTAssertEqual(c.offsetX, 1); XCTAssertEqual(c.offsetY, -1)
        XCTAssertEqual(c.border?.width, CircleBorder.widthRange.upperBound); XCTAssertEqual(c.border?.opacity, 1)
    }

    func testModelUndoSplitPersistenceAndOldProjects() throws {
        let old = #"{"formatVersion":11,"name":"o","clips":[{"id":"8D3C6A2E-3D7B-4D52-9E2A-1B0C2D3E4F50","media":"/a","sourceStart":0,"duration":4}],"layers":[{"id":"9D3C6A2E-3D7B-4D52-9E2A-1B0C2D3E4F51","kind":"video","media":"/b","start":0,"sourceStart":0,"duration":4,"transform":{"x":0,"y":0,"scale":1,"opacity":1,"rotation":0}}]}"#
        let p0 = try JSONDecoder().decode(SadrogProject.self, from: Data(old.utf8))
        XCTAssertNil(p0.clips[0].crop); XCTAssertNil(p0.layers[0].crop)
        let e = ProjectEditor(project: p0)
        let lid = p0.layers[0].id
        e.setCrop(lid, CircleCrop(zoom: 1.5, border: CircleBorder(style: .simple, color: .presenterRed)))
        XCTAssertEqual(e.project.layers[0].crop?.zoom, 1.5)
        XCTAssertTrue(e.project.needsCompositing)
        let f = URL(fileURLWithPath: "\(Self.root)/temp/circle-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f)
        let back = try ProjectStore.load(from: f)
        XCTAssertEqual(back.layers[0].crop, e.project.layers[0].crop); XCTAssertEqual(back.formatVersion, SadrogProject.currentFormat, "saved by this build: current format")
        e.setCrop(p0.clips[0].id, CircleCrop()); XCTAssertNotNil(e.project.clips[0].crop)
        e.splitLayer(kind: .video, at: 2)
        XCTAssertEqual(e.project.layers.count, 2); XCTAssertTrue(e.project.layers.allSatisfy { $0.crop?.zoom == 1.5 }, "both halves stay circles")
        e.undo(); e.undo(); XCTAssertNil(e.project.clips[0].crop)
        e.setCrop(lid, nil); XCTAssertNil(e.project.layers[0].crop, "back to the rectangle")
        e.undo(); XCTAssertNotNil(e.project.layers[0].crop)
        XCTAssertEqual(e.project.layers[0].media, "/b", "the source is never touched")
    }

    // pixels ------------------------------------------------------------------
    func frame(_ p: SadrogProject, at t: Double) async throws -> NSBitmapImageRep {
        let out = URL(fileURLWithPath: "\(Self.root)/temp/circle-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(p, to: out)
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: out)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        return NSBitmapImageRep(cgImage: try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image)
    }
    func rgb(_ r: NSBitmapImageRep, _ x: Int, _ y: Int) -> (Double, Double, Double) {
        let c = r.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!; return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
    func isBlue(_ c: (Double, Double, Double)) -> Bool { c.2 > 0.5 && c.0 < 0.35 && c.1 < 0.35 }
    func isGreen(_ c: (Double, Double, Double)) -> Bool { c.1 > 0.5 && c.0 < 0.35 && c.2 < 0.5 }
    func isYellow(_ c: (Double, Double, Double)) -> Bool { c.0 > 0.75 && c.1 > 0.6 && c.2 < 0.35 }
    func isWhite(_ c: (Double, Double, Double)) -> Bool { c.0 > 0.8 && c.1 > 0.8 && c.2 > 0.8 }

    /// Overlay of the green|yellow clip as a circle (scale 0.5 → diameter 360 px, centred) over a blue clip.
    func project(_ crop: CircleCrop?) -> SadrogProject {
        var l = Layer(kind: .video, media: Self.halves, start: 0, duration: 4, transform: Transform(scale: 0.5)); l.crop = crop
        var p = SadrogProject(name: "c", clips: [Clip(media: Self.blue, sourceStart: 0, duration: 4)]); p.layers = [l]
        return p
    }
    func testCircleOutlineFramingAndBackToRectangleInTheExport() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.halves) && FileManager.default.fileExists(atPath: Self.blue), "synthetic clips missing")
        // circle, white simple outline 4% of the diameter (14.4 px)
        let a = try await frame(project(CircleCrop(border: CircleBorder(style: .simple, width: 0.04, color: .white))), at: 1)
        XCTAssertEqual(a.pixelsWide, 1280)
        XCTAssertTrue(isGreen(rgb(a, 640 - 90, 360)), "left of centre: green half")
        XCTAssertTrue(isYellow(rgb(a, 640 + 90, 360)), "right of centre: yellow half")
        XCTAssertTrue(isWhite(rgb(a, 640 + 173, 360)), "outline just inside the edge")
        XCTAssertTrue(isWhite(rgb(a, 640, 360 - 173)), "outline top: same width all round (a circle, not an ellipse)")
        XCTAssertTrue(isBlue(rgb(a, 640 + 140, 360 + 140)), "inside the square box but outside the circle: background")
        XCTAssertTrue(isBlue(rgb(a, 640 + 186, 360)), "just outside the circle: background")
        // framing moves the PICTURE, not the circle: window at the left edge → the whole circle shows the green half
        let b = try await frame(project(CircleCrop(offsetX: -1)), at: 1)
        XCTAssertTrue(isGreen(rgb(b, 640 + 90, 360))); XCTAssertTrue(isBlue(rgb(b, 640 + 186, 360)), "circle did not move")
        // back to the rectangle (640×360 centred): the corner area is the overlay again
        let c = try await frame(project(nil), at: 1)
        XCTAssertTrue(isYellow(rgb(c, 640 + 140, 360 + 140)))
    }
    func testGlossyOutlineIsLighterOnTopAndStaysThin() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.halves) && FileManager.default.fileExists(atPath: Self.blue), "synthetic clips missing")
        let red = CircleBorder(style: .glossy, width: 0.04, color: .presenterRed)
        let g = try await frame(project(CircleCrop(border: red)), at: 1)
        let top = rgb(g, 640, 360 - 176), bottom = rgb(g, 640, 360 + 176)
        XCTAssertGreaterThan(top.0 + top.1 + top.2, bottom.0 + bottom.1 + bottom.2 + 0.25, "lit from above")
        XCTAssertGreaterThan(bottom.0, 0.45, "bottom stays red, not black"); XCTAssertLessThan(bottom.1, 0.3)
        XCTAssertTrue(isGreen(rgb(g, 640 - 120, 360)), "the picture inside is untouched by the gloss")
    }
}
