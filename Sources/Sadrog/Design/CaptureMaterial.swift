// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// Material of the capture panel, measured from the chosen direction (SADROG-Captura-Directie-Noua.svg; 1 SVG unit = 1 pt).
/// Every number below is read from that drawing; the light counterparts keep the same hierarchy.
/// Drawing is done here, with the control's native chrome switched off (`.plain` / `.borderlessButton`), so nothing native repaints the surface.
enum CM {
    // surfaces (svg: bg, card, button, ruby gradients; vertical, top → bottom)
    static let pageTop = Color(dark: 0x292B30, light: 0xF4F5F7), pageBottom = Color(dark: 0x191B1F, light: 0xE6E8EC)
    static let cardTop = Color(dark: 0x303238, light: 0xFFFFFF), cardBottom = Color(dark: 0x26282D, light: 0xF1F2F5), cardStroke = Color(dark: 0x50535B, light: 0xC6C9D1)
    static let sidebar = Color(dark: 0x222429, light: 0xE9EBEF), navSel = Color(dark: 0x3B3E45, light: 0xFFFFFF), navSelStroke = Color(dark: 0x555862, light: 0xB9BDC6)
    static let tile = Color(dark: 0x373B43, light: 0xE4E6EB)
    static let buttonTop = Color(dark: 0x45474E, light: 0xFFFFFF), buttonBottom = Color(dark: 0x33353B, light: 0xE9EBEF), buttonStroke = Color(dark: 0x60636B, light: 0xB4B8C1)
    static let addStroke = Color(dark: 0x747780, light: 0xA2A6B0), addDisc = Color(dark: 0x292D34, light: 0xE3E5EA), addDiscStroke = Color(dark: 0x818792, light: 0xA9ADB7)
    static let rubyTop = Color(hex: 0xF05767), rubyMid = Color(hex: 0xD52D46), rubyBottom = Color(hex: 0xAF1832), rubyStroke = Color(hex: 0xF17686), rubyGlyph = Color(hex: 0xFFF3F5)
    static let switchOn = Color(hex: 0x879CB5), switchOff = Color(dark: 0x4A4D55, light: 0xB9BCC4), knob = Color.white
    static let meterTrack = Color(dark: 0x17191C, light: 0xD5D8DE), meterOk = Color(hex: 0x87BFA3), meterWarn = Color(hex: 0xD9BD76), meterOff = Color(dark: 0x555861, light: 0xB3B6BE)
    static let previewBox = Color(dark: 0x15171C, light: 0x1B1D22), previewStroke = Color(dark: 0x5A5D68, light: 0x8D909A)
    static let chipFill = Color(dark: 0x272E2C, light: 0xE8F2EC), chipStroke = Color(dark: 0x44584C, light: 0x9FC4AE), chipDot = Color(hex: 0x8BC6A0), chipText = Color(dark: 0xB6D8C1, light: 0x2F6B48)
    static let icon = Color(dark: 0xD5D7DE, light: 0x4B4E57)
    // geometry
    static let cardRadius: CGFloat = 14, tileSize: CGFloat = 48, tileRadius: CGFloat = 12, buttonRadius: CGFloat = 8, buttonHeight: CGFloat = 34
    static let previewW: CGFloat = 150, configW: CGFloat = 116, switchW: CGFloat = 42, switchH: CGFloat = 25
    static let addW: CGFloat = 360, addH: CGFloat = 64, addRadius: CGFloat = 15
    static let recW: CGFloat = 342, recH: CGFloat = 70, recRadius: CGFloat = 18
    static let boxW: CGFloat = 185, boxH: CGFloat = 112, meterW: CGFloat = 335
    // type (svg: .title 20/600, .small 14, .button 14/500, .label 12 tracking 1.8)
    static let title = Font.system(size: 20, weight: .semibold), small = Font.system(size: 14), button = Font.system(size: 14, weight: .medium)
    static let note = Font.system(size: 12), label = Font.system(size: 12, weight: .semibold)
}

/// The surface of a control in one of its states. `ruby` is the Record gradient, `plain` the graphite button gradient.
struct CMFace: View {
    enum Kind { case plain, ruby }
    var kind: Kind = .plain
    var radius: CGFloat = CM.buttonRadius
    var state: ControlState = .normal
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let pressed = state == .pressed, hover = state == .hover, off = state == .disabled
        let colors: [Color] = kind == .ruby ? [CM.rubyTop, CM.rubyMid, CM.rubyBottom] : [CM.buttonTop, CM.buttonBottom]
        let stroke = kind == .ruby ? CM.rubyStroke : (radius > 10 ? CM.addStroke : CM.buttonStroke)
        shape.fill(LinearGradient(colors: colors, startPoint: .top, endPoint: .bottom))
            .overlay(shape.fill(Color.black.opacity(pressed ? 0.16 : 0)))
            .overlay(shape.fill(Color.white.opacity(hover ? 0.07 : 0)))
            .overlay(shape.strokeBorder(stroke, lineWidth: 1))
            .overlay { if !pressed { shape.inset(by: 1).strokeBorder(LinearGradient(colors: [.white.opacity(kind == .ruby ? 0.34 : 0.16), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.42)), lineWidth: 1) } }
            .overlay { if state == .focus { shape.inset(by: -3).strokeBorder(Theme.C.accent, lineWidth: 2) } }
            .shadow(color: .black.opacity(kind == .ruby ? 0 : (pressed ? 0.05 : 0.28)), radius: kind == .ruby ? 0 : 2, y: pressed ? 0 : 1)
            .saturation(off ? 0.15 : 1).opacity(off ? (kind == .ruby ? 0.62 : 0.45) : 1)
    }
}

/// A graphite row button (preview, format, size, channels, countdown): 34 pt, radius 8, 14 pt medium text.
struct CMButtonStyle: ButtonStyle {
    var width: CGFloat? = nil
    var maxWidth: CGFloat? = nil
    var height: CGFloat = CM.buttonHeight
    var radius: CGFloat = CM.buttonRadius
    var hPad: CGFloat = 14
    var active = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.forcedState) private var forced
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let st: ControlState = forced ?? (!enabled ? .disabled : configuration.isPressed ? .pressed : focused ? .focus : hover ? .hover : .normal)
        configuration.label.font(CM.button).foregroundStyle(Theme.C.text).padding(.horizontal, hPad)
            .frame(width: width, height: height).frame(maxWidth: maxWidth)
            .background(CMFace(radius: radius, state: st))
            .overlay { if active { RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Theme.C.accent.opacity(0.85), lineWidth: 1.5) } }
            .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .onHover { hover = $0 }
    }
}

/// The inclusion switch: 42×25 track, 18 pt knob (svg). The word "Activ"/"Oprit" is drawn next to it by the row.
struct CMSwitchStyle: ToggleStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.toggle() } label: {
            ZStack(alignment: configuration.isOn ? .trailing : .leading) {
                Capsule().fill(configuration.isOn ? CM.switchOn : CM.switchOff).overlay(Capsule().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
                Circle().fill(CM.knob).frame(width: 18, height: 18).shadow(color: .black.opacity(0.3), radius: 1.5, y: 1).padding(3.5)
            }.frame(width: CM.switchW, height: CM.switchH).opacity(enabled ? 1 : 0.5).animation(.easeOut(duration: 0.12), value: configuration.isOn)
        }.buttonStyle(.plain)
    }
}

extension View {
    /// Source card: vertical graphite gradient, 1 pt stroke, radius 14.
    func cmCard() -> some View {
        let s = RoundedRectangle(cornerRadius: CM.cardRadius, style: .continuous)
        return background(s.fill(LinearGradient(colors: [CM.cardTop, CM.cardBottom], startPoint: .top, endPoint: .bottom)))
            .overlay(s.strokeBorder(CM.cardStroke, lineWidth: 1))
    }
}

// MARK: line icons (svg symbols, 28 × 28)
struct CMIconShape: Shape {
    enum Kind { case screen, camera, mic }
    let kind: Kind
    func path(in r: CGRect) -> Path {
        let k = r.width / 28
        func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: CGFloat) -> Path { Path(roundedRect: CGRect(x: x * k, y: y * k, width: w * k, height: h * k), cornerRadius: c * k, style: .continuous) }
        var p = Path()
        switch kind {
        case .screen:
            p.addPath(rr(3, 4, 22, 16, 3)); p.move(to: CGPoint(x: 10 * k, y: 25 * k)); p.addLine(to: CGPoint(x: 18 * k, y: 25 * k)); p.move(to: CGPoint(x: 14 * k, y: 20 * k)); p.addLine(to: CGPoint(x: 14 * k, y: 25 * k))
        case .camera:
            p.addPath(rr(2, 7, 17, 15, 4)); p.move(to: CGPoint(x: 19 * k, y: 12 * k)); p.addLine(to: CGPoint(x: 26 * k, y: 8 * k)); p.addLine(to: CGPoint(x: 26 * k, y: 21 * k)); p.addLine(to: CGPoint(x: 19 * k, y: 17 * k))
        case .mic:
            p.addPath(rr(10, 2, 8, 15, 4)); p.move(to: CGPoint(x: 6 * k, y: 12 * k)); p.addLine(to: CGPoint(x: 6 * k, y: 14 * k))
            p.addArc(center: CGPoint(x: 14 * k, y: 14 * k), radius: 8 * k, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: true)
            p.addLine(to: CGPoint(x: 22 * k, y: 12 * k)); p.move(to: CGPoint(x: 14 * k, y: 22 * k)); p.addLine(to: CGPoint(x: 14 * k, y: 26 * k)); p.move(to: CGPoint(x: 10 * k, y: 26 * k)); p.addLine(to: CGPoint(x: 18 * k, y: 26 * k))
        }
        return p
    }
}
struct CMSourceIcon: View {
    let symbol: String
    var dimmed = false
    var body: some View {
        let kind: CMIconShape.Kind? = { switch symbol { case "display": return .screen; case "video": return .camera; case "mic": return .mic; default: return nil } }()
        ZStack {
            RoundedRectangle(cornerRadius: CM.tileRadius, style: .continuous).fill(CM.tile)
            if let kind { CMIconShape(kind: kind).stroke(CM.icon, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)).frame(width: 28, height: 28) }
            else { Image(systemName: symbol).font(.system(size: 22, weight: .regular)).foregroundStyle(CM.icon) }
        }.frame(width: CM.tileSize, height: CM.tileSize).opacity(dimmed ? 0.6 : 1).accessibilityHidden(true)
    }
}
