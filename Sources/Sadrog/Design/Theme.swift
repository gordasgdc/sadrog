// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// SADROG visual system. Dark-first graphite with a discreet cool-blue accent; glossy = a 1 px top highlight, a soft vertical gradient and
/// restrained shadows. Nothing here animates or glows enough to compete with the video.
enum Theme {
    /// Semantic palette: every surface/text/state colour of the app is one of these tokens; each resolves per appearance (dark = the graphite design, light = its
    /// counterpart with the same hierarchy). Constants drawn over media or over coloured clips (white labels on clips, black shadows) stay literal on purpose.
    /// All surfaces are opaque (no materials, no blur-behind), so there is no transparency to switch off; contrast pairs are checked by `ThemeContrastTests`.
    enum C {
        static let bg0 = Color(ThemePalette.bg0)      // canvas
        static let bg1 = Color(ThemePalette.bg1)      // panels
        static let bg2 = Color(ThemePalette.bg2)      // raised rows / hover
        static let bg3 = Color(ThemePalette.bg3)      // bars, controls
        static let field = Color(ThemePalette.field)    // inputs
        static let line = Color(ThemePalette.line)     // separators
        static let text = Color(ThemePalette.text)
        static let textDim = Color(ThemePalette.textDim)  // secondary, >= 7:1 on panels
        static let textFaint = Color(ThemePalette.textFaint) // tertiary, >= 4.5:1 on panels
        static let accent = Color(ThemePalette.accent)   // primary action / focus
        static let accentInk = Color.white
        static let sel = Color(ThemePalette.sel)      // clip selection
        static let selRing = Color(ThemePalette.selRing)   // outline of selected timeline items (yellow, both themes)
        static let selHalo = Color(hex: ThemePalette.selHalo)
        static let playhead = Color(ThemePalette.playhead)
        static let record = Color(ThemePalette.record)
        static let warn = Color(ThemePalette.warn)
        static let ok = Color(ThemePalette.ok)
        static let stage = Color(hex: 0x151617)    // behind the preview: always dark, so the picture is judged on the same backdrop in every theme
        static let clipVideo = Color(hex: 0x3D5A8C)
        static let clipAudio = Color(hex: 0x2F5E4A)
        static let clipTitle = Color(hex: 0x7A5C2E)
        static let clipCallout = Color(hex: 0x2E6B7A)
        static let wave = Color(hex: 0x8FD6AE)
    }
    enum S { static let xs: CGFloat = 4, sm: CGFloat = 8, md: CGFloat = 12, lg: CGFloat = 16, xl: CGFloat = 24 }
    enum R { static let control: CGFloat = 7, panel: CGFloat = 10, clip: CGFloat = 6 }
    enum F {
        static let title = Font.system(size: 20, weight: .semibold)
        static let heading = Font.system(size: 13, weight: .semibold)
        static let body = Font.system(size: 13)
        static let caption = Font.system(size: 11.5)
        static let label = Font.system(size: 11, weight: .semibold)
        static let mono = Font.system(size: 12, weight: .medium, design: .monospaced)
        static let timer = Font.system(size: 34, weight: .light, design: .monospaced)
        // one scale for the whole app: text never below 11 pt; icons 13 pt (11 in dense rows); disclosure glyphs 9 pt bold
        static let small = Font.system(size: 11)
        static let smallMedium = Font.system(size: 11, weight: .medium)
        static let monoSmall = Font.system(size: 11, weight: .medium, design: .monospaced)
        static let icon = Font.system(size: 13, weight: .regular)
        static let iconSmall = Font.system(size: 11, weight: .regular)
        static let iconLarge = Font.system(size: 15, weight: .regular)
        static let glyph = Font.system(size: 9, weight: .bold)
    }
    enum H { static let control: CGFloat = 28, compact: CGFloat = 24, toolbar: CGFloat = 46, hit: CGFloat = 28; static let tool = CGSize(width: 28, height: 24) }
}

extension Color {
    /// A colour that resolves with the window's appearance (the theme setting decides which one the window has).
    init(_ p: ThemePalette.Pair) { self.init(dark: p.dark, light: p.light) }
    init(dark: UInt32, light: UInt32) {
        self.init(nsColor: NSColor(name: nil) { a in
            let isDark = a.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua, h = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((h >> 16) & 0xFF) / 255, green: CGFloat((h >> 8) & 0xFF) / 255, blue: CGFloat(h & 0xFF) / 255, alpha: 1)
        })
    }
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }
}

/// The appearance the user chose in Settings; the window scenes follow it at once. Default: dark (the app's own look).
enum AppTheme: String, CaseIterable, Identifiable {
    case system, dark, light
    static let key = "sadrog.theme"
    var id: String { rawValue }
    var scheme: ColorScheme? { switch self { case .system: return nil; case .dark: return .dark; case .light: return .light } }
    var appearance: NSAppearance? { switch self { case .system: return nil; case .dark: return NSAppearance(named: .darkAqua); case .light: return NSAppearance(named: .aqua) } }
    var name: String { switch self { case .system: return T("Sistem"); case .dark: return T("Întunecat"); case .light: return T("Luminos") } }
    static var current: AppTheme { AppTheme(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .dark }
}
/// Applies the chosen theme to a window's content (and to the app, so system dialogs — open/save panels, alerts — follow it too).
struct ThemedModifier: ViewModifier {
    @AppStorage(AppTheme.key) private var raw = AppTheme.dark.rawValue
    func body(content: Content) -> some View {
        let t = AppTheme(rawValue: raw) ?? .dark
        content.preferredColorScheme(t.scheme).background(WindowAppearance(appearance: t.appearance)).onAppear { NSApp?.appearance = t.appearance }.onChange(of: raw) { _, _ in NSApp?.appearance = t.appearance }
    }
}
extension View { func appTheme() -> some View { modifier(ThemedModifier()) } }

/// Gives the HOSTING window the chosen appearance itself: the Settings scene and sheets keep the appearance they were created with unless their window is told (the app-wide appearance alone did not reach them).
struct WindowAppearance: NSViewRepresentable {
    let appearance: NSAppearance?
    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }
    func updateNSView(_ v: NSView, context: Context) { DispatchQueue.main.async { if v.window?.appearance != appearance { v.window?.appearance = appearance } } }
}
