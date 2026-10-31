import XCTest
@testable import SadrogCore

/// Direct crop: changing the crop must not move or rescale the kept pixels on the canvas (any rotation, any aspect).
final class RectCropPlacementTests: XCTestCase {
    private func canvas(_ p: CGPoint, crop: RectCrop?, _ t: Transform, n0: CGSize, R: CGSize) -> CGPoint {
        let w = (crop ?? RectCrop()).window(of: n0), f = min(R.width / w.width, R.height / w.height), s = f * t.scale, a = t.rotation * .pi / 180
        let dx = (p.x - w.midX) * s, dy = (p.y - w.midY) * s
        return CGPoint(x: R.width / 2 + t.x * R.width + dx * cos(a) - dy * sin(a), y: R.height / 2 + t.y * R.height + dx * sin(a) + dy * cos(a))
    }
    func testKeptPixelsStayPut() {
        let n0 = CGSize(width: 3840, height: 2160), R = CGSize(width: 1920, height: 1080)
        for rot in [0.0, 17, -90, 135] {
            let t0 = Transform(x: 0.12, y: -0.08, scale: 0.7, rotation: rot)
            let c0 = RectCrop(left: 0.1, right: 0.05, top: 0.0, bottom: 0.2)
            let c1 = RectCrop(left: 0.3, right: 0.02, top: 0.15, bottom: 0.1)
            let t1 = RectCrop.placement(from: c0, to: c1, t0, natural: n0, render: R)
            for p in [CGPoint(x: 1700, y: 700), CGPoint(x: 2500, y: 1200)] {      // inside both windows
                let a = canvas(p, crop: c0, t0, n0: n0, R: R), b = canvas(p, crop: c1, t1, n0: n0, R: R)
                XCTAssertEqual(a.x, b.x, accuracy: 0.01, "rot \(rot)"); XCTAssertEqual(a.y, b.y, accuracy: 0.01, "rot \(rot)")
            }
        }
    }
    func testRemovingCropRestoresPlacement() {
        let n0 = CGSize(width: 1920, height: 1080), R = CGSize(width: 1280, height: 720), t0 = Transform(x: 0.1, y: 0.1, scale: 0.5)
        let c = RectCrop(left: 0.25, right: 0.25, top: 0.1, bottom: 0.1)
        let t1 = RectCrop.placement(from: nil, to: c, t0, natural: n0, render: R)
        let back = RectCrop.placement(from: c, to: RectCrop(), t1, natural: n0, render: R)
        XCTAssertEqual(back.x, t0.x, accuracy: 1e-9); XCTAssertEqual(back.y, t0.y, accuracy: 1e-9); XCTAssertEqual(back.scale, t0.scale, accuracy: 1e-9)
    }

    /// Minimal project (one V1 clip, identity, no animation/titles/callouts/overlays, canvas = source): a rectangular crop alone must reach the compositor.
    func testRectCropAloneActivatesTheCompositorAndSurvivesSaveLoad() async throws {
        let blue = CompositionTests.dir + "/blue.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 2)])
        let plain = try await CompositionBuilder.buildFull(p)
        XCTAssertFalse(p.needsCompositing); XCTAssertNil(plain.videoComposition(for: p), "control: no crop, no compositor")
        p.clips[0].rectCrop = RectCrop()
        XCTAssertFalse(p.needsCompositing, "an empty crop changes nothing")
        p.clips[0].rectCrop = RectCrop(left: 0.25)
        XCTAssertTrue(p.needsCompositing)
        let built = try await CompositionBuilder.buildFull(p)
        XCTAssertNotNil(built.videoComposition(for: p), "the crop must be drawn")
        let dir = URL(fileURLWithPath: "\(TestRoot.path)/temp/rc-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: dir) }
        try ProjectStore.save(p, to: dir)
        let back = try ProjectStore.load(from: dir)
        XCTAssertEqual(back.clips[0].rectCrop?.left, 0.25); XCTAssertTrue(back.needsCompositing)
        let rebuilt = try await CompositionBuilder.buildFull(back); XCTAssertNotNil(rebuilt.videoComposition(for: back))
    }
}
