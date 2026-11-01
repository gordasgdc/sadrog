// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// The magnifying lens must look the same in the preview (the in-app composition) and in the exported file: same geometry, same content.
/// Synthetic clip: left half green, right half yellow. The lens is placed over the colour boundary and offset, so a wrong position, size or content would move
/// or recolour the magnified area. Both frames are read at the same time and compared pixel-wise at a reduced size.
final class LensPreviewExportTests: XCTestCase {
    func testLensLooksTheSameInPreviewAndInExport() async throws {
        let src = CircleCropTests.halves
        try XCTSkipUnless(FileManager.default.fileExists(atPath: src), "synthetic clips")
        var p = SadrogProject(name: "lens", clips: [Clip(media: src, sourceStart: 0, duration: 4)])
        var c = Callout(start: 0.5, x: 0.42, y: 0.35, w: 0.16, h: 0.2); c.duration = 3; c.corner = 0; c.lens = 2.5; c.lensX = 0.10; c.lensY = 0.55
        p.callouts = [c]
        XCTAssertTrue(c.isLens)
        let out = URL(fileURLWithPath: CircleCropTests.root + "/temp/lens-\(UUID().uuidString).mov")
        try await ProjectExporter.export(p, to: out); defer { try? FileManager.default.removeItem(at: out) }
        let built = try await CompositionBuilder.buildFull(p)
        let pg = AVAssetImageGenerator(asset: built.composition); pg.videoComposition = built.videoComposition(for: p)
        pg.requestedTimeToleranceBefore = .zero; pg.requestedTimeToleranceAfter = .zero
        let eg = AVAssetImageGenerator(asset: AVURLAsset(url: out)); eg.requestedTimeToleranceBefore = .zero; eg.requestedTimeToleranceAfter = .zero
        let W = 160, H = 90
        func px(_ im: CGImage) -> [Double] {
            var d = [UInt8](repeating: 0, count: W * H * 4)
            let ctx = CGContext(data: &d, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(im, in: CGRect(x: 0, y: 0, width: W, height: H)); return d.enumerated().filter { $0.offset % 4 != 3 }.map { Double($0.element) }
        }
        for t in [1.0, 2.5] {
            let ct = CMTime(seconds: t, preferredTimescale: 600)
            let a = px(try await pg.image(at: ct).image), b = px(try await eg.image(at: ct).image)
            let mad = zip(a, b).map { abs($0 - $1) }.reduce(0, +) / Double(a.count)
            let big = zip(a, b).filter { abs($0 - $1) > 60 }.count
            print("LENS preview-vs-export t=\(t): mean abs diff \(mad), pixels off by >60: \(big) of \(a.count / 3 * 3)")
            XCTAssertLessThan(mad, 3, "t=\(t)")
            XCTAssertLessThan(Double(big) / Double(a.count), 0.01, "t=\(t): no region of the frame differs strongly")
        }
        // and the lens is really there: the magnified area (left, lower) shows the colour boundary that the source has at the centre
        let withLens = px(try await eg.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image)
        var q = p; q.callouts = []
        let out2 = URL(fileURLWithPath: CircleCropTests.root + "/temp/lens0-\(UUID().uuidString).mov")
        try await ProjectExporter.export(q, to: out2); defer { try? FileManager.default.removeItem(at: out2) }
        let g2 = AVAssetImageGenerator(asset: AVURLAsset(url: out2)); g2.requestedTimeToleranceBefore = .zero; g2.requestedTimeToleranceAfter = .zero
        let without = px(try await g2.image(at: CMTime(seconds: 1, preferredTimescale: 600)).image)
        let changed = zip(withLens, without).filter { abs($0 - $1) > 40 }.count
        XCTAssertGreaterThan(changed, 300, "the lens changes the picture (\(changed) channel values)")
    }
}
