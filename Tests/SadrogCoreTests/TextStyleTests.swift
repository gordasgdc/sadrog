// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Multiline titles and their styles (bold, italic, shadow, box, line spacing): model round trip, old files, and what is really drawn.
final class TextStyleTests: XCTestCase {
    let R = CGSize(width: 1280, height: 720)
    func ink(_ img: CGImage) -> Int {
        var n = 0, px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height)); for i in stride(from: 3, to: px.count, by: 4) where px[i] > 20 { n += 1 }; return n
    }
    func testMultilineTitleIsTallerAndKeepsItsLines() throws {
        let one = TextOverlay(text: "Linia", start: 0), three = TextOverlay(text: "Linia\nA doua\nA treia", start: 0)
        let a = TextRenderer.layoutSize(one, render: R), b = TextRenderer.layoutSize(three, render: R)
        XCTAssertGreaterThan(b.height, a.height * 2.5); XCTAssertEqual(try JSONDecoder().decode(TextOverlay.self, from: JSONEncoder().encode(three)).text, "Linia\nA doua\nA treia")
        var loose = three; loose.lineSpacing = 1.6
        XCTAssertGreaterThan(TextRenderer.layoutSize(loose, render: R).height, b.height * 1.2, "line spacing changes the layout")
    }
    func testStylesRoundTripAndOldFilesStillOpen() throws {
        var t = TextOverlay(text: "x", start: 1); t.bold = true; t.italic = true; t.shadow = true; t.box = TextColor(r: 0, g: 0, b: 0, a: 0.5); t.lineSpacing = 1.3
        XCTAssertEqual(try JSONDecoder().decode(TextOverlay.self, from: JSONEncoder().encode(t)), t)
        let plain = TextOverlay(text: "x", start: 1); let json = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
        XCTAssertFalse(json.contains("bold") || json.contains("box") || json.contains("lineSpacing"), "defaults are not written")
        let old = try JSONDecoder().decode(TextOverlay.self, from: Data(json.utf8)); XCTAssertFalse(old.bold); XCTAssertNil(old.box); XCTAssertEqual(old.lineSpacing, 1)
    }
    func testBoldShadowAndBoxChangeThePixels() throws {
        let base = TextOverlay(text: "Titlu", start: 0, font: "Helvetica Neue")
        var bold = base; bold.bold = true; var sh = base; sh.shadow = true; var box = base; box.box = TextColor(r: 1, g: 0, b: 0, a: 1)
        let ib = ink(try XCTUnwrap(TextRenderer.image(base, render: R))), ibold = ink(try XCTUnwrap(TextRenderer.image(bold, render: R)))
        XCTAssertGreaterThan(ibold, ib, "bold covers more pixels")
        XCTAssertGreaterThan(ink(try XCTUnwrap(TextRenderer.image(sh, render: R))), ib, "shadow adds pixels")
        let bi = try XCTUnwrap(TextRenderer.image(box, render: R)); XCTAssertGreaterThan(ink(bi), ib * 3, "the box fills the image")
        // the corner of the box image (inside the rounded corner's inset) is the box colour
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(bi, in: CGRect(x: -6, y: -(bi.height - 7), width: bi.width, height: bi.height)); XCTAssertGreaterThan(px[0], 200); XCTAssertLessThan(px[1], 40)
    }
}
