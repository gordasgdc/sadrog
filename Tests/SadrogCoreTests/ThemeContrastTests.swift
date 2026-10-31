// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Every text/background pair of the semantic palette stays readable in BOTH appearances.
final class ThemeContrastTests: XCTestCase {
    func testPairsReadableInDarkAndLight() {
        for (name, fg, bg, min) in ThemePalette.readable {
            XCTAssertGreaterThanOrEqual(ThemePalette.contrast(fg.dark, bg.dark), min, "dark \(name)")
            XCTAssertGreaterThanOrEqual(ThemePalette.contrast(fg.light, bg.light), min, "light \(name)")
        }
        XCTAssertGreaterThanOrEqual(ThemePalette.contrast(0xFFFFFF, ThemePalette.accent.light), 4.5, "white label on the light accent")
        XCTAssertGreaterThanOrEqual(ThemePalette.contrast(0xFFFFFF, ThemePalette.accent.dark), 3.5, "white label on the dark accent")
    }
    func testSurfacesKeepTheirHierarchyInBothThemes() {
        func lum(_ h: UInt32) -> Double { Double((h >> 16) & 0xFF) * 0.2126 + Double((h >> 8) & 0xFF) * 0.7152 + Double(h & 0xFF) * 0.0722 }
        XCTAssertLessThan(lum(ThemePalette.bg0.dark), lum(ThemePalette.bg1.dark)); XCTAssertLessThan(lum(ThemePalette.bg1.dark), lum(ThemePalette.bg3.dark))
        XCTAssertGreaterThan(lum(ThemePalette.bg1.light), lum(ThemePalette.bg0.light)); XCTAssertGreaterThan(lum(ThemePalette.bg0.light), lum(ThemePalette.bg3.light), "light: panels brightest, controls darkest")
    }
}
