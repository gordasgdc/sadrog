// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// Interaction states a control can show. `forcedState` lets the component board render every state from the real styles.
enum ControlState { case normal, hover, pressed, focus, disabled }
private struct ForcedStateKey: EnvironmentKey { static let defaultValue: ControlState? = nil }
extension EnvironmentValues { var forcedState: ControlState? { get { self[ForcedStateKey.self] } set { self[ForcedStateKey.self] = newValue } } }

/// One edge language for every control: 1 px controlled outline, a fine lit top edge, no per-element drop shadow.
struct Edge {
    static func outline(_ shape: RoundedRectangle, _ c: Color = Theme.C.line) -> some View { shape.strokeBorder(c, lineWidth: 1) }
    static func lit(_ shape: RoundedRectangle, _ o: Double = 0.10) -> some View {
        shape.inset(by: 1).strokeBorder(LinearGradient(colors: [.white.opacity(o), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.45)), lineWidth: 1)
    }
    static func focus(_ shape: RoundedRectangle) -> some View { shape.strokeBorder(Theme.C.accent, lineWidth: 2).padding(-1) }
}

/// Small icon button used in the timeline toolbar and transport; `active` = selected tool.
struct ToolButtonStyle: ButtonStyle {
    var active = false
    var size = Theme.H.tool
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.forcedState) private var forced
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let st = forced ?? (!enabled ? .disabled : configuration.isPressed ? .pressed : focused ? .focus : hover ? .hover : .normal)
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        configuration.label.frame(width: size.width, height: size.height)
            .font(Theme.F.icon).foregroundStyle(active ? Theme.C.accentInk : Theme.C.text)
            .background(
                shape.fill(active ? (st == .pressed ? Theme.C.accent.opacity(0.8) : Theme.C.accent) : (st == .pressed ? Theme.C.bg0 : (st == .hover || st == .focus ? Theme.C.bg2 : .clear)))
            )
            .overlay { if active { Edge.lit(shape, 0.28) } else if st == .hover || st == .focus { Edge.lit(shape, 0.07) } }
            .overlay { if st == .pressed && !active { Edge.outline(shape, Color.black.opacity(0.5)) } }
            .overlay { if st == .focus { Edge.focus(shape) } }
            .opacity(st == .disabled ? 0.38 : 1)
            .contentShape(shape).onHover { hover = $0 }
    }
}

/// Recessed field surface (inputs, readouts): darker than the panel, one outline, a thin shade under the top edge.
struct FieldSurface: ViewModifier {
    var focused = false
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        content.background(shape.fill(Theme.C.field))
            .overlay(shape.strokeBorder(focused ? Theme.C.accent : Theme.C.line, lineWidth: focused ? 1.5 : 1))
            .overlay(alignment: .top) { Rectangle().fill(Color.black.opacity(0.28)).frame(height: 1).padding(.horizontal, 2).padding(.top, 1) }
    }
}
extension View { func fieldSurface(focused: Bool = false) -> some View { modifier(FieldSurface(focused: focused)) } }

/// Inspector row: label (dim) · value in a recessed field.
struct ValueRow: View {
    let label: String, value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.F.body).foregroundStyle(Theme.C.textDim).frame(width: 96, alignment: .leading).lineLimit(1)
            Text(value).font(Theme.F.mono).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.horizontal, 8).frame(height: 24).fieldSurface()
        }.frame(height: 28)
    }
}

/// Grouped control strip (tool selector, transport): one raised capsule-free container so members read as a set.
struct ControlGroup2<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        HStack(spacing: 2) { content }.padding(2).background(shape.fill(Theme.C.bg0.opacity(0.55))).overlay(Edge.outline(shape, Theme.C.line.opacity(0.7)))
    }
}

/// Editable number: click to TYPE (Return applies, Esc discards, leaving the field applies), press-and-drag to SCRUB (3 pt threshold, so a click never
/// scrubs; right = more, Shift = 10× finer, Esc during the drag restores). One typed entry or one drag = ONE undo step (`commit` once).
struct ScrubField: View {
    let label: String; var unit = ""; let range: ClosedRange<Double>
    let value: Binding<Double>; var decimals = 0; var width: CGFloat = 38
    /// Values are multiples of `step` (e.g. 2 px for even video sizes); `perPoint` = change per dragged point (default: range/200).
    var step: Double? = nil; var perPoint: Double? = nil
    /// Fixed outer width of the field (aligned columns of equal boxes); nil = fits its content.
    var boxWidth: CGFloat? = nil
    var editing: (Bool) -> Void = { _ in }
    var commit: () -> Void
    @State private var typing = false
    @State private var scrubStart: Double?
    @State private var cancelled = false
    @State private var keyMonitor: Any?
    @State private var hover = false
    @FocusState private var focused: Bool
    @State private var draft = ""
    @State private var token = UUID()
    /// Posted when a field starts typing: any other field still typing ends (and applies) its entry — focus moved away.
    static let beganTyping = Notification.Name("SadrogScrubFieldBeganTyping")
    private func startTyping() {
        draft = text; typing = true; editing(true)
        NotificationCenter.default.post(name: Self.beganTyping, object: token)
    }
    private func rounded(_ v: Double) -> Double { if let st = step, st > 0 { return (v / st).rounded() * st }; let k = pow(10, Double(decimals)); return (v * k).rounded() / k }
    private func clamp(_ v: Double) -> Double { max(range.lowerBound, min(range.upperBound, v)) }
    private var text: String { let r = rounded(value.wrappedValue); return (r == 0 ? 0 : r).formatted(.number.precision(.fractionLength(decimals)).grouping(.never)) }   // never "-0"
    private func finishTyping(apply: Bool) {
        guard typing else { return }
        typing = false; editing(false)
        if apply, let v = Double(draft.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)) {
            let n = clamp(rounded(v)); if n != value.wrappedValue { value.wrappedValue = n; commit() }
        }
    }
    private var scrub: some Gesture {
        DragGesture(minimumDistance: 3).onChanged { g in
            if scrubStart == nil {
                scrubStart = value.wrappedValue; cancelled = false; editing(true)
                keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    if e.keyCode == 53 { cancelled = true; if let s = scrubStart { value.wrappedValue = s }; return nil }
                    return e
                }
            }
            guard let s = scrubStart, !cancelled else { return }
            let perPoint = (self.perPoint ?? (range.upperBound - range.lowerBound) / 200) * (NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1)
            value.wrappedValue = clamp(rounded(s + g.translation.width * perPoint))
        }.onEnded { _ in
            if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
            if !cancelled, let s = scrubStart, s != value.wrappedValue { commit() }
            scrubStart = nil; editing(false)
        }
    }
    var body: some View {
        HStack(spacing: 2) {
            if typing {
                TextField("", text: $draft).textFieldStyle(.plain).font(Theme.F.mono).multilineTextAlignment(.trailing).frame(width: width)
                    .focused($focused).onSubmit { finishTyping(apply: true) }.onExitCommand { finishTyping(apply: false) }
                    .onChange(of: focused) { _, f in if !f && typing { finishTyping(apply: true) } }
                    .onAppear { DispatchQueue.main.async { focused = true } }      // the field must exist before it can take focus
                    .accessibilityLabel("\(label), valoare")
            } else {
                Text(text).font(Theme.F.mono).frame(width: width, alignment: .trailing).contentShape(Rectangle())
                    .onHover { inside in hover = inside; if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                    .gesture(scrub)
                    .onTapGesture { startTyping() }
                    .help(T("Clic: tastezi valoarea · trage stânga/dreapta: reglaj (Shift = fin)"))
                    .accessibilityLabel("\(label), valoare").accessibilityValue(Text("\(text) \(unit)"))
                    .accessibilityAdjustableAction { d in
                        let step = (range.upperBound - range.lowerBound) / 100
                        value.wrappedValue = clamp(value.wrappedValue + (d == .increment ? step : -step)); commit()
                    }
            }
            if !unit.isEmpty { Text(unit).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize() }
        }
        .padding(.horizontal, 6).frame(width: boxWidth, height: 24, alignment: .trailing)
        .fieldSurface(focused: typing || scrubStart != nil)
        .onReceive(NotificationCenter.default.publisher(for: Self.beganTyping)) { n in if typing, (n.object as? UUID) != token { finishTyping(apply: true) } }
        .onDisappear { if typing { finishTyping(apply: false) } }       // the field left the screen (selection changed): nothing is written to another item
        .overlay(RoundedRectangle(cornerRadius: Theme.R.control).strokeBorder(Theme.C.textFaint.opacity(hover && !typing ? 0.5 : 0), lineWidth: 1))
    }
}


/// The one text-field look of the app (same surface as the numeric fields): plain field, 24 pt high, hairline, focus ring.
struct AppTextField: View {
    let placeholder: String; @Binding var text: String; var mono = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField(placeholder, text: $text).textFieldStyle(.plain).font(mono ? Theme.F.mono : Theme.F.body).focused($focused)
            .padding(.horizontal, 7).frame(height: 24).fieldSurface(focused: focused)
    }
}
