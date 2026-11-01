// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import CoreImage
@testable import SadrogCore

/// Local lens: the whole selected area, magnified, in a display area that can be placed anywhere. Synthetic settings panel with four distinct corner marks.
final class LensTests: XCTestCase {
    static let R = CGSize(width: 800, height: 450)
    static let marks: [(name: String, r: Double, g: Double, b: Double)] = [("tl", 1, 0, 0), ("tr", 0, 1, 0), ("bl", 0, 0, 1), ("br", 1, 1, 0)]

    /// Grey screenshot with a lighter "panel" (x,y,w,h as frame fractions) carrying a 10 px mark in each of its four corners and a stripe of "text" lines.
    static func screenshot(panel p: CGRect) -> CIImage {
        let W = Int(R.width), H = Int(R.height)
        var data = [UInt8](repeating: 0, count: W * H * 4)
        func put(_ x: Int, _ y: Int, _ c: (Double, Double, Double)) { guard x >= 0, y >= 0, x < W, y < H else { return }; let i = (y * W + x) * 4; data[i] = UInt8(c.0 * 255); data[i + 1] = UInt8(c.1 * 255); data[i + 2] = UInt8(c.2 * 255); data[i + 3] = 255 }
        for y in 0..<H { for x in 0..<W { put(x, y, (0.4, 0.4, 0.4)) } }
        let x0 = Int(p.minX * R.width), y0 = Int(p.minY * R.height), x1 = Int(p.maxX * R.width), y1 = Int(p.maxY * R.height)
        for y in y0..<y1 { for x in x0..<x1 { put(x, y, (0.85, 0.85, 0.85)) } }
        for (i, m) in marks.enumerated() {
            let ox = i % 2 == 0 ? x0 : x1 - 10, oy = i < 2 ? y0 : y1 - 10
            for y in oy..<oy + 10 { for x in ox..<ox + 10 { put(x, y, (m.r, m.g, m.b)) } }
        }
        for line in 0..<4 { let y = y0 + 16 + line * 8; for x in (x0 + 16)..<(x1 - 16) where (x / 3) % 2 == 0 { put(x, y, (0.1, 0.1, 0.1)) } }
        let cs = CGColorSpaceCreateDeviceRGB()
        let img = CGDataProvider(data: Data(data) as CFData).flatMap { CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4, space: cs, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: $0, decode: nil, shouldInterpolate: false, intent: .defaultIntent) }!
        return CIImage(cgImage: img)
    }
    func px(_ img: CIImage, _ x: Int, _ y: Int) -> (r: Double, g: Double, b: Double) {      // top-left coordinates
        var p = [UInt8](repeating: 0, count: 4); let h = Int(img.extent.height)
        CIContext(options: [.workingColorSpace: NSNull()]).render(img, toBitmap: &p, rowBytes: 4, bounds: CGRect(x: x, y: h - 1 - y, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return (Double(p[0]) / 255, Double(p[1]) / 255, Double(p[2]) / 255)
    }
    func render(_ c: Callout, _ base: CIImage) -> CIImage { SadrogCompositor.apply(c, mask: CalloutMask.make(c.displayed, render: Self.R), to: base, size: Self.R) }
    func near(_ a: (r: Double, g: Double, b: Double), _ m: (name: String, r: Double, g: Double, b: Double), _ msg: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.r, m.r, accuracy: 0.05, msg, file: file, line: line); XCTAssertEqual(a.g, m.g, accuracy: 0.05, msg, file: file, line: line); XCTAssertEqual(a.b, m.b, accuracy: 0.05, msg, file: file, line: line)
    }
    /// The centres of the four marks must appear at the four corners of the display area.
    func assertCorners(_ out: CIImage, display b: CGRect, zoom k: Double, file: StaticString = #filePath, line: UInt = #line) {
        let W = Self.R.width, H = Self.R.height, m = 5 * k          // a 10 px mark is 10·k px big, its centre 5·k from the corner
        let pts = [(b.minX * W + m, b.minY * H + m), (b.maxX * W - m, b.minY * H + m), (b.minX * W + m, b.maxY * H - m), (b.maxX * W - m, b.maxY * H - m)]
        for (i, p) in pts.enumerated() { near(px(out, Int(p.0), Int(p.1)), Self.marks[i], "corner \(Self.marks[i].name) of the selection is visible in the magnified area", file: file, line: line) }
    }

    func testWholeSelectionIsShownMagnifiedWithAllFourCorners() {
        let panel = CGRect(x: 0.30, y: 0.30, width: 0.20, height: 0.20)
        let base = Self.screenshot(panel: panel)
        var c = Callout(start: 0, x: 0.30, y: 0.30, w: 0.20, h: 0.20); c.corner = 0; c.lens = 3
        XCTAssertEqual(c.lensEffective, 3, accuracy: 1e-9); let b = c.displayBox
        XCTAssertEqual(b.width, 0.60, accuracy: 1e-9); XCTAssertEqual(b.height, 0.60, accuracy: 1e-9)
        XCTAssertEqual(b.midX, 0.40, accuracy: 1e-9, "centred on the source by default")
        let out = render(c, base)
        assertCorners(out, display: b, zoom: 3)
        XCTAssertEqual(px(out, 10, 10).r, 0.4 * 0.4, accuracy: 0.02, "the rest of the screenshot stays visible, darkened")
        XCTAssertEqual(c.displayBox.width / c.displayBox.height, c.w / c.h * (Self.R.height / Self.R.width) * (Self.R.width / Self.R.height), accuracy: 1e-9, "proportions preserved")
    }
    func testPlacementMovesTheMagnifiedAreaAndKeepsContent() {
        let base = Self.screenshot(panel: CGRect(x: 0.10, y: 0.10, width: 0.20, height: 0.20))
        var c = Callout(start: 0, x: 0.10, y: 0.10, w: 0.20, h: 0.20); c.corner = 0; c.lens = 2; c.lensX = 0.55; c.lensY = 0.40
        let b = c.displayBox
        XCTAssertEqual(b.minX, 0.55, accuracy: 1e-9); XCTAssertEqual(b.minY, 0.40, accuracy: 1e-9)
        assertCorners(render(c, base), display: b, zoom: 2)
    }
    func testNearTheFrameEdgeTheAreaIsKeptInsideAndNothingIsCut() {
        let base = Self.screenshot(panel: CGRect(x: 0.82, y: 0.78, width: 0.16, height: 0.20))
        var c = Callout(start: 0, x: 0.82, y: 0.78, w: 0.16, h: 0.20); c.corner = 0; c.lens = 4
        XCTAssertEqual(c.lensEffective, 4, accuracy: 1e-9)
        let b = c.displayBox
        XCTAssertGreaterThanOrEqual(b.minX, 0); XCTAssertLessThanOrEqual(b.maxX, 1 + 1e-9); XCTAssertGreaterThanOrEqual(b.minY, 0); XCTAssertLessThanOrEqual(b.maxY, 1 + 1e-9)
        assertCorners(render(c, base), display: b, zoom: 4)
    }
    func testTooLargeAFactorIsLimitedToWhatFitsInTheFrame() {
        var c = Callout(start: 0, x: 0.2, y: 0.2, w: 0.5, h: 0.3); c.lens = 6
        XCTAssertEqual(c.lensEffective, 2, accuracy: 1e-9, "1 / width, so the display area never exceeds the frame")
        XCTAssertLessThanOrEqual(c.displayBox.width, 1 + 1e-9)
    }
    func testOffByDefaultOldProjectsAndPersistence() throws {
        let old = try JSONDecoder().decode(Callout.self, from: Data(#"{"id":"\#(UUID().uuidString)","start":1,"duration":2,"x":0.1,"y":0.1,"w":0.3,"h":0.3,"dim":0.6,"blur":0,"corner":0.1,"magnify":1}"#.utf8))
        XCTAssertFalse(old.isLens); XCTAssertEqual(old.lens, 0); XCTAssertEqual(old.magnify, 1); XCTAssertEqual(old.displayBox, CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.3))
        var c = Callout(start: 0, x: 0.2, y: 0.2, w: 0.2, h: 0.2); c.lens = 2.5; c.lensX = 0.5; c.lensY = 0.1
        let back = try JSONDecoder().decode(Callout.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c); XCTAssertEqual(back.lens, 2.5); XCTAssertEqual(back.lensX, 0.5)
        c.lens = 0; c.normalize(); XCTAssertNil(c.lensX, "turning it off forgets the placement")
    }
    func testLensDoesNotTouchOtherCalloutModes() {
        let base = Self.screenshot(panel: CGRect(x: 0.3, y: 0.3, width: 0.2, height: 0.2))
        var a = Callout(start: 0, x: 0.3, y: 0.3, w: 0.2, h: 0.2); a.corner = 0; a.magnify = 1
        let out = render(a, base)      // in-place magnification: unchanged behaviour (marks scaled about the centre, not placed elsewhere)
        XCTAssertEqual(px(out, 5, 5).r, 0.4 * 0.4, accuracy: 0.02)
        XCTAssertFalse(a.isLens)
    }
}
