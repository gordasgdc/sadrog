// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
import CoreImage
@testable import SadrogCore

/// Colour controls per clip: neutral by default, one undo step, saved with the project, and the SAME picture in the preview path
/// (video composition on an image generator) and in the exported file. Fully synthetic source (a flat colour), written under the external test folder.
final class PictureAdjustTests: XCTestCase {
    static let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp"
    static var source: String { dir + "/flat_colour_320x180.mov" }

    /// 1 s, 30 fps, flat (R 0.60, G 0.40, B 0.20).
    static func makeSource() async throws {
        if FileManager.default.fileExists(atPath: source) { return }
        let url = URL(fileURLWithPath: source)
        let w = try AVAssetWriter(outputURL: url, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180])
        w.add(input); w.startWriting(); w.startSession(atSourceTime: .zero)
        for i in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var pb: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, ad.pixelBufferPool!, &pb)
            let b = pb!; CVPixelBufferLockBaseAddress(b, [])
            let p = CVPixelBufferGetBaseAddress(b)!.assumingMemoryBound(to: UInt8.self), rb = CVPixelBufferGetBytesPerRow(b)
            for y in 0..<180 { for x in 0..<320 { let o = y * rb + x * 4; p[o] = 51; p[o + 1] = 102; p[o + 2] = 153; p[o + 3] = 255 } }
            CVPixelBufferUnlockBaseAddress(b, [])
            ad.append(b, withPresentationTime: CMTime(value: CMTimeValue(i), timescale: 30))
        }
        input.markAsFinished(); await w.finishWriting()
    }
    /// Mean R, G, B (0…1) of a frame.
    static func mean(_ cg: CGImage) -> (r: Double, g: Double, b: Double) {
        let w = cg.width, h = cg.height; var px = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0
        for i in stride(from: 0, to: px.count, by: 4) { r += Double(px[i]); g += Double(px[i + 1]); b += Double(px[i + 2]) }
        let n = Double(w * h) * 255; return (r / n, g / n, b / n)
    }
    static func frame(of asset: AVAsset, composition: AVVideoComposition? = nil) async throws -> (r: Double, g: Double, b: Double) {
        let gen = AVAssetImageGenerator(asset: asset); gen.videoComposition = composition
        gen.requestedTimeToleranceBefore = .zero; gen.requestedTimeToleranceAfter = .zero
        return mean(try await gen.image(at: CMTime(seconds: 0.5, preferredTimescale: 600)).image)
    }
    func project(_ adjust: PictureAdjust?) -> SadrogProject {
        var c = Clip(media: Self.source, sourceStart: 0, duration: 1); c.picture = adjust
        return SadrogProject(name: "colour", clips: [c])
    }

    func testNeutralByDefaultAndNotSaved() throws {
        let a = PictureAdjust(); XCTAssertTrue(a.isNeutral)
        XCTAssertFalse(project(nil).needsCompositing)
        var b = PictureAdjust(); b.saturation = 0; XCTAssertTrue(project(b).needsCompositing)
        let data = try JSONEncoder().encode(project(a).clips[0])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("picture"), "neutral values are not written")
    }
    func testRoundTripAndClamp() throws {
        var a = PictureAdjust(); a.brightness = 0.2; a.contrast = 1.3; a.saturation = 0.4; a.background = .blur; a.blur = 0.8
        let back = try JSONDecoder().decode(Clip.self, from: JSONEncoder().encode(project(a).clips[0]))
        XCTAssertEqual(back.picture, a)
        let wild = try JSONDecoder().decode(PictureAdjust.self, from: Data(#"{"brightness":9,"contrast":-3,"saturation":50,"background":"unknown"}"#.utf8))
        XCTAssertEqual(wild.brightness, 0.5); XCTAssertEqual(wild.contrast, 0.5); XCTAssertEqual(wild.saturation, 2); XCTAssertEqual(wild.background, .off)
    }
    func testOneUndoStepAndReset() {
        let e = ProjectEditor(project: project(nil)); let id = e.project.clips[0].id
        var a = PictureAdjust(); a.brightness = 0.1
        e.setPicture(id, a); XCTAssertEqual(e.project.clips[0].picture, a)
        e.setPicture(id, PictureAdjust()); XCTAssertNil(e.project.clips[0].picture, "neutral = no entry")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.clips[0].picture, a)
        XCTAssertTrue(e.undo()); XCTAssertNil(e.project.clips[0].picture)
        XCTAssertTrue(e.redo()); XCTAssertEqual(e.project.clips[0].picture, a)
    }
    func testPreviewAndExportShowTheSameAdjustedPicture() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.dir), "external test storage not available")
        try await Self.makeSource()
        let plain = try await Self.frame(of: AVURLAsset(url: URL(fileURLWithPath: Self.source)))
        var a = PictureAdjust(); a.brightness = 0.15; a.saturation = 0
        let p = project(a)
        let built = try await CompositionBuilder.buildFull(p)
        let vc = try XCTUnwrap(built.videoComposition(for: p))
        let preview = try await Self.frame(of: built.composition, composition: vc)
        let out = URL(fileURLWithPath: "\(Self.dir)/colour-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(p, to: out)
        let exported = try await Self.frame(of: AVURLAsset(url: out))
        print("COLOUR plain \(plain) preview \(preview) exported \(exported)")
        XCTAssertEqual(preview.r, preview.g, accuracy: 0.02); XCTAssertEqual(preview.g, preview.b, accuracy: 0.02)        // saturation 0 = grey
        XCTAssertGreaterThan(preview.g, plain.g + 0.08)                                                              // brighter
        XCTAssertEqual(exported.r, preview.r, accuracy: 0.03); XCTAssertEqual(exported.g, preview.g, accuracy: 0.03); XCTAssertEqual(exported.b, preview.b, accuracy: 0.03)
        // neutral project: untouched picture
        let n = project(nil), nb = try await CompositionBuilder.buildFull(n)
        XCTAssertNil(nb.videoComposition(for: n))
    }
}
