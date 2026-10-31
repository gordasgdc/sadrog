// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// The Record button, drawn for every state: available, hover, pressed, disabled, preparing, countdown, recording, paused, stopping.
/// Available = bright ruby with a soft vertical gradient, a fine top reflection and a tight halo. Disabled stays visibly inactive (grey, hollow, no halo).
/// Recording is a steady ring + stop square: no decorative animation.
struct RecordButtonStyle: ButtonStyle {
    let phase: RecPhase
    @Environment(\.isEnabled) private var enabled
    @Environment(\.forcedState) private var forced
    @State private var hover = false

    static let rubyTop = Color(hex: 0xFF5A6A), rubyMid = Color(hex: 0xE5193F), rubyBottom = Color(hex: 0xA80D2C)

    func makeBody(configuration: Configuration) -> some View {
        let st: ControlState = forced ?? (!enabled ? .disabled : configuration.isPressed ? .pressed : hover ? .hover : .normal)
        RecordFace(phase: phase, state: st).onHover { hover = $0 }.contentShape(Circle())
    }
}

struct RecordFace: View {
    let phase: RecPhase
    var state: ControlState = .normal
    private var live: Bool { if case .recording = phase { return true }; if case .paused = phase { return true }; return false }
    private var busy: Bool { switch phase { case .preparing, .starting, .stopping: return true; default: return false } }

    var body: some View {
        let off = state == .disabled && !live
        let pressed = state == .pressed, hover = state == .hover
        ZStack {
            Circle().strokeBorder(ringStyle(off: off), lineWidth: 2.5).frame(width: 56, height: 56)
            if live {
                RoundedRectangle(cornerRadius: 5, style: .continuous).fill(ruby(pressed: pressed, hover: hover, tint: phase == .paused ? Theme.C.warn : nil)).frame(width: 21, height: 21)
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(.white.opacity(0.22), lineWidth: 0.7))
            } else {
                disc(off: off, pressed: pressed, hover: hover)
            }
        }
        .frame(width: 60, height: 60)
        .scaleEffect(pressed ? 0.965 : 1)
        .animation(.easeOut(duration: 0.1), value: pressed)
        .accessibilityLabel(phase == .idle || busy && phase != .stopping ? T("Înregistrează") : T("Oprește"))
    }

    private func ringStyle(off: Bool) -> AnyShapeStyle {
        if off { return AnyShapeStyle(Theme.C.line) }
        if live { return AnyShapeStyle((phase == .paused ? Theme.C.warn : RecordButtonStyle.rubyMid).opacity(0.95)) }
        return AnyShapeStyle(LinearGradient(colors: [Color.white.opacity(0.92), Color.white.opacity(0.62)], startPoint: .top, endPoint: .bottom))
    }
    private func ruby(pressed: Bool, hover: Bool, tint: Color? = nil) -> LinearGradient {
        let t = tint ?? RecordButtonStyle.rubyTop, m = tint ?? RecordButtonStyle.rubyMid, b = tint?.opacity(0.7) ?? RecordButtonStyle.rubyBottom
        let k: Double = pressed ? 0.78 : (hover ? 1.0 : 0.94)
        return LinearGradient(colors: [t.opacity(k), m.opacity(k), b.opacity(k)], startPoint: .top, endPoint: .bottom)
    }
    @ViewBuilder private func disc(off: Bool, pressed: Bool, hover: Bool) -> some View {
        if off {
            Circle().fill(LinearGradient(colors: [Color(hex: 0x3B3D42), Color(hex: 0x2D2F33)], startPoint: .top, endPoint: .bottom)).frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(.white.opacity(0.06), lineWidth: 0.7))
        } else {
            let dim = phase == .preparing
            Circle().fill(ruby(pressed: pressed, hover: hover)).frame(width: 44, height: 44).opacity(dim ? 0.55 : 1)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.8))
                .overlay(alignment: .top) {      // fine top reflection
                    Ellipse().fill(LinearGradient(colors: [.white.opacity(pressed ? 0.18 : 0.42), .white.opacity(0)], startPoint: .top, endPoint: .bottom))
                        .frame(width: 30, height: 17).padding(.top, 3).opacity(dim ? 0.4 : 1)
                }
                .shadow(color: RecordButtonStyle.rubyMid.opacity(pressed ? 0.25 : (hover ? 0.6 : 0.45)), radius: pressed ? 4 : (hover ? 9 : 7))
                .overlay { overlayContent }
        }
    }
    @ViewBuilder private var overlayContent: some View {
        switch phase {
        case .countdown(let n): Text("\(n)").font(.system(size: 21, weight: .semibold)).foregroundStyle(.white)
        case .preparing, .starting, .stopping: ProgressView().controlSize(.small).colorScheme(.dark)
        default: EmptyView()
        }
    }
}
