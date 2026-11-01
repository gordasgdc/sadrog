// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// The semantic palette's values (dark = the graphite design, light = its counterpart), kept here — free of UI — so the contrast of every text/background pair
/// can be tested in both appearances. The app's `Theme.C` resolves each token from this table.
public enum ThemePalette {
    public struct Pair: Sendable { public let dark: UInt32, light: UInt32 }
    public static let bg0 = Pair(dark: 0x161719, light: 0xE9EAED)
    public static let bg1 = Pair(dark: 0x212225, light: 0xF6F6F8)
    public static let bg2 = Pair(dark: 0x2A2C30, light: 0xECEDF0)
    public static let bg3 = Pair(dark: 0x34363B, light: 0xDEDFE3)
    public static let field = Pair(dark: 0x141517, light: 0xFFFFFF)
    public static let line = Pair(dark: 0x3C3E44, light: 0xC4C6CC)
    public static let text = Pair(dark: 0xECEDEF, light: 0x1B1C1F)
    public static let textDim = Pair(dark: 0xB3B5BC, light: 0x474951)
    public static let textFaint = Pair(dark: 0x8E9098, light: 0x62646D)
    public static let accent = Pair(dark: 0x0A84FF, light: 0x0A62D0)
    public static let sel = Pair(dark: 0xF3CA52, light: 0xA86F00)
    /// The outline of a selected timeline item: one clear yellow in both appearances (the old `sel` turns brown in Light). It is always drawn with a dark halo
    /// (`selHalo`), so it stays visible over thumbnails, waveforms, the track colours and the light panel; `sel` keeps its other uses (tool highlight, lock, guides).
    public static let selRing = Pair(dark: 0xFFD60A, light: 0xFFC800)
    public static let selHalo: UInt32 = 0x1A1A1C
    public static let playhead = Pair(dark: 0xEF655D, light: 0xD2403A)
    public static let record = Pair(dark: 0xFF5256, light: 0xE0292E)
    public static let warn = Pair(dark: 0xF5A524, light: 0xA85F00)
    public static let ok = Pair(dark: 0x4CD18F, light: 0x17794F)
    /// WCAG contrast ratio between two sRGB colours.
    public static func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        func lum(_ h: UInt32) -> Double {
            func c(_ v: UInt32) -> Double { let x = Double(v) / 255; return x <= 0.03928 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
            return 0.2126 * c((h >> 16) & 0xFF) + 0.7152 * c((h >> 8) & 0xFF) + 0.0722 * c(h & 0xFF)
        }
        let (x, y) = (lum(a), lum(b)); return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    /// Pairs that must stay readable: (name, foreground, background, minimum contrast).
    public static let readable: [(String, Pair, Pair, Double)] = [
        ("text/bg1", text, bg1, 7), ("textDim/bg1", textDim, bg1, 7), ("textFaint/bg1", textFaint, bg1, 4.5),
        ("text/bg0", text, bg0, 7), ("textDim/bg0", textDim, bg0, 7), ("textFaint/bg0", textFaint, bg0, 4.5),
        ("text/bg2", text, bg2, 7), ("textDim/bg2", textDim, bg2, 4.5), ("text/bg3", text, bg3, 7), ("textDim/bg3", textDim, bg3, 4.5),
        ("text/field", text, field, 7), ("textFaint/field", textFaint, field, 4.5),
        ("accent/bg1", accent, bg1, 3), ("warn/bg1", warn, bg1, 3), ("ok/bg1", ok, bg1, 3), ("record/bg1", record, bg1, 3), ("sel/bg1", sel, bg1, 3), ("playhead/bg0", playhead, bg0, 3),
    ]
}
