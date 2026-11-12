// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

// MARK: surfaces
/// Flat graphite surface: a small tonal step from the canvas and a hairline. No gradient, no shadow per card (raised = one tone lighter).
struct PanelBackground: View {
    var radius: CGFloat = Theme.R.panel
    var raised = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        shape.fill(raised ? Theme.C.bg2 : Theme.C.bg1).overlay(shape.strokeBorder(Theme.C.line.opacity(0.7), lineWidth: 0.5))
    }
}

struct Panel<Content: View>: View {
    var raised = false
    var padding: CGFloat = Theme.S.lg
    @ViewBuilder var content: Content
    var body: some View { content.padding(padding).background(PanelBackground(raised: raised)) }
}

struct SectionLabel: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text).font(Theme.F.heading).foregroundStyle(Theme.C.text.opacity(0.92)).accessibilityAddTraits(.isHeader)
    }
}

/// Page title with the context of the operation underneath (what is being prepared, in what state).
struct PageHeader: View {
    let title: String
    var subtitle: String = ""
    var tone: Color = Theme.C.textFaint
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(Theme.F.title).foregroundStyle(Theme.C.text).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).font(Theme.F.caption).foregroundStyle(tone).lineLimit(1) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HairlineDivider: View {
    var vertical = false
    var body: some View { Rectangle().fill(Theme.C.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1) }
}

// MARK: buttons
enum GlossKind { case primary, record, secondary, ghost }

struct GlossButtonStyle: ButtonStyle {
    var kind: GlossKind = .secondary
    var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.forcedState) private var forced
    @State private var hover = false

    func makeBody(configuration: Configuration) -> some View {
        let st: ControlState = forced ?? (!enabled ? .disabled : configuration.isPressed ? .pressed : focused ? .focus : hover ? .hover : .normal)
        let shape = RoundedRectangle(cornerRadius: Theme.R.control, style: .continuous)
        configuration.label
            .font(Theme.F.body.weight(.medium))
            .foregroundStyle(kind == .primary || kind == .record ? Color.white : Theme.C.text)
            .padding(.horizontal, compact ? 10 : 14)
            .frame(minHeight: compact ? Theme.H.compact : Theme.H.control)
            .background(shape.fill(fill(st)))
            .overlay(Edge.outline(shape, border(st)))
            .overlay { if kind != .ghost || st == .hover { Edge.lit(shape, st == .pressed ? 0.03 : (kind == .secondary ? 0.06 : 0.16)) } }
            .overlay { if st == .focus { Edge.focus(shape) } }
            .opacity(st == .disabled ? 0.4 : 1)
            .contentShape(shape)
            .onHover { hover = $0 }
    }

    private func border(_ st: ControlState) -> Color {
        switch kind {
        case .primary: return Color.black.opacity(0.35)
        case .record: return Color.black.opacity(0.3)
        case .secondary: return st == .pressed ? Color.black.opacity(0.5) : Theme.C.line
        case .ghost: return st == .hover || st == .pressed ? Theme.C.line : .clear
        }
    }
    private func fill(_ st: ControlState) -> LinearGradient {
        let p = st == .pressed, h = st == .hover
        func g(_ top: Color, _ bot: Color) -> LinearGradient { LinearGradient(colors: [top, bot], startPoint: .top, endPoint: .bottom) }
        switch kind {
        case .primary: return p ? g(Theme.C.accent.opacity(0.78), Theme.C.accent.opacity(0.7)) : g(Theme.C.accent.opacity(h ? 1 : 0.96), Theme.C.accent.opacity(h ? 0.9 : 0.82))
        case .record: return p ? g(Theme.C.record.opacity(0.8), Theme.C.record.opacity(0.7)) : g(Theme.C.record, Theme.C.record.opacity(h ? 0.88 : 0.8))
        case .secondary: return p ? g(Theme.C.bg2, Theme.C.bg2) : g(Theme.C.bg3.opacity(h ? 1.0 : 0.92), Theme.C.bg3.opacity(h ? 0.94 : 0.86))
        case .ghost: return g(p ? Theme.C.bg1 : (h ? Theme.C.bg2 : .clear), p ? Theme.C.bg1 : (h ? Theme.C.bg2 : .clear))
        }
    }
}

extension ButtonStyle where Self == GlossButtonStyle {
    static func gloss(_ k: GlossKind = .secondary, compact: Bool = false) -> GlossButtonStyle { GlossButtonStyle(kind: k, compact: compact) }
}

/// Icon-only button with a mandatory text label (tooltip + VoiceOver) so no symbol is left unexplained.
struct IconButton: View {
    let symbol: String
    let label: String
    var shortcutHint: String? = nil
    var active = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(Theme.F.icon)
        }
        .buttonStyle(ToolButtonStyle(active: active))      // the same 28×24 tool button everywhere (toolbar, transport, rows)
        .help(shortcutHint.map { "\(label) (\($0))" } ?? label)
        .accessibilityLabel(label)
    }
}

struct Chip: View {
    enum Tone { case neutral, accent, warn, ok, record }
    let text: String
    var tone: Tone = .neutral
    var body: some View {
        let c: Color = { switch tone { case .neutral: Theme.C.textDim; case .accent: Theme.C.accent; case .warn: Theme.C.warn; case .ok: Theme.C.ok; case .record: Theme.C.record } }()
        Text(text).font(Theme.F.label).foregroundStyle(c).padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(c.opacity(0.14))).overlay(Capsule().strokeBorder(c.opacity(0.35), lineWidth: 1))
    }
}

/// Custom record glyph (original artwork, vector).
struct RecordGlyph: View {
    var stop = false
    var body: some View {
        ZStack {
            Circle().strokeBorder(.white.opacity(0.95), lineWidth: 1.8)
            if stop { RoundedRectangle(cornerRadius: 2).fill(.white).frame(width: 7, height: 7) }
            else { Circle().fill(.white).frame(width: 8, height: 8) }
        }.frame(width: 16, height: 16)
    }
}

func timecode(_ t: Double, frames: Bool = false) -> String {
    let t = max(0, t); let m = Int(t) / 60, s = Int(t) % 60
    return frames ? String(format: "%02d:%02d.%02d", m, s, Int((t - floor(t)) * 100)) : String(format: "%02d:%02d", m, s)
}
func bytesString(_ b: Int64) -> String { L10n.bytes(b) }
