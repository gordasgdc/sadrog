// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import SadrogCore

extension EditorModel {
    /// While a cursor control is dragged: the viewer follows, nothing is recorded. `commitMouseFX` saves it as ONE undo step.
    func liveMouseFX(_ id: UUID, _ fx: MouseFX) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        var v = fx; v.normalize(); project.clips[i].mouseFX = v; refreshVideoComposition()
    }
    func commitMouseFX(_ id: UUID, _ fx: MouseFX? = nil) {
        let v = fx ?? project.clips.first { $0.id == id }?.mouseFX
        apply(reload: false) { $0.setMouseFX(clip: id, v) }
    }
}

/// A row of colour swatches plus the system colour panel; `set(colour, final)` — final = commit (a swatch click), not final = live (dragging in the panel).
struct SwatchRow: View {
    let label: String; let current: TextColor; let set: (TextColor, Bool) -> Void
    @State private var pending: DispatchWorkItem?
    static var palette: [(String, TextColor)] { [
        (T("Galben"), MouseFX.legacyColor), (T("Alb"), .white), (T("Roșu"), TextColor(r: 1, g: 0.27, b: 0.23)), (T("Portocaliu"), TextColor(r: 1, g: 0.58, b: 0.0)),
        (T("Verde"), TextColor(r: 0.2, g: 0.84, b: 0.29)), (T("Turcoaz"), TextColor(r: 0.19, g: 0.82, b: 0.86)), (T("Albastru"), MouseFX.modernClickColor), (T("Mov"), TextColor(r: 0.75, g: 0.35, b: 0.95))] }
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(Theme.F.body).lineLimit(1).frame(width: 70, alignment: .leading)
            ForEach(Self.palette, id: \.0) { name, col in
                Button { set(col, true) } label: {
                    Circle().fill(Color(red: col.r, green: col.g, blue: col.b)).frame(width: 16, height: 16)
                        .overlay(Circle().strokeBorder(current == col ? Theme.C.sel : Color.white.opacity(0.35), lineWidth: current == col ? 2 : 1))
                }.buttonStyle(.plain).help(name).accessibilityLabel("\(label): \(name)")
            }
            ColorPicker("", selection: Binding(get: { Color(red: current.r, green: current.g, blue: current.b) }, set: { v in
                guard let ns = NSColor(v).usingColorSpace(.sRGB) else { return }
                let c = TextColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent)); set(c, false)
                pending?.cancel(); let w = DispatchWorkItem { set(c, true) }; pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
            }), supportsOpacity: false).labelsHidden().frame(width: 34).help(T("Altă culoare")).accessibilityLabel("\(label): " + T("Altă culoare"))
            Spacer(minLength: 0)
        }.frame(height: 26)
    }
}

/// Cursor tab of a main-track clip that has a pointer track: the continuous highlight, the click effect, and — apart from both — the zoom that follows the pointer.
struct CursorGroups: View {
    @ObservedObject var m: EditorModel
    let c: Clip
    @State private var advanced = false
    private var fx: MouseFX { c.mouseFX ?? { var f = MouseFX.modern; f.highlight = false; f.clickRing = false; return f }() }
    private func num(_ kp: WritableKeyPath<MouseFX, Double>, _ k: Double) -> Binding<Double> {
        Binding(get: { fx[keyPath: kp] * k }, set: { v in var n = fx; n[keyPath: kp] = v / k; m.liveMouseFX(c.id, n) })
    }
    private func change(_ edit: (inout MouseFX) -> Void) { var n = fx; edit(&n); m.commitMouseFX(c.id, n) }
    var body: some View {
        let f = fx
        InspectorGroup(T("Evidențiere cursor"), action: ("arrow.counterclockwise", T("Resetează aspectul cursorului"), f.lookIsDefault, { change { $0.resetLook() } })) {
            Toggle(T("Evidențiază cursorul"), isOn: Binding(get: { f.highlight }, set: { v in change { $0.highlight = v } })).toggleStyle(.switch).controlSize(.small).font(Theme.F.body)
                .help(T("Desenează un semn care urmărește cursorul pe tot clipul; apare și în export."))
            Group {
                Picker("", selection: Binding(get: { f.style }, set: { v in change { $0.style = v; if v == .ring, $0.opacity < 0.6 { $0.opacity = 0.9 }; if v == .disc, $0.opacity > 0.6 { $0.opacity = 0.35 } } })) {
                    Text(T("Contur")).tag(MouseFX.Style.ring); Text(T("Halo")).tag(MouseFX.Style.halo); Text(T("Disc")).tag(MouseFX.Style.disc)
                }.labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Forma evidențierii"))
                    .help(T("Contur = un cerc gol, conținutul de sub cursor rămâne vizibil. Halo = o lumină moale, fără margine. Disc = un cerc plin, discret."))
                SwatchRow(label: T("Culoare"), current: f.color) { col, final in var n = fx; n.color = col; if final { m.commitMouseFX(c.id, n) } else { m.liveMouseFX(c.id, n) } }
                NumberRow(label: T("Mărime"), unit: "%", range: 40...300, value: num(\.size, 100), commit: { m.commitMouseFX(c.id) }, reset: 100)
                NumberRow(label: T("Opacitate"), unit: "%", range: 5...100, value: num(\.opacity, 100), commit: { m.commitMouseFX(c.id) }, reset: f.style == .disc ? 35 : 90)
                if f.style == .ring { NumberRow(label: T("Grosime"), unit: "%", range: 4...50, value: num(\.stroke, 100), commit: { m.commitMouseFX(c.id) }, reset: 12).help(T("Grosimea conturului, în procente din rază")) }
            }.disabled(!f.highlight).opacity(f.highlight ? 1 : 0.45)
        }
        InspectorGroup(T("Efect la clic")) {
            Toggle(T("Inele la clic"), isOn: Binding(get: { f.clickRing }, set: { v in change { $0.clickRing = v } })).toggleStyle(.switch).controlSize(.small).font(Theme.F.body)
                .help(T("La fiecare clic, un inel pornește de la cursor, se lărgește și se stinge."))
            Group {
                SwatchRow(label: T("Culoare"), current: f.clickColor) { col, final in var n = fx; n.clickColor = col; if final { m.commitMouseFX(c.id, n) } else { m.liveMouseFX(c.id, n) } }
                VStack(alignment: .leading, spacing: 2) {
                    legend("circle", T("Clic stânga: un inel"))
                    legend("circle.inset.filled", T("Clic dreapta: inel subțire cu interior colorat"))
                    legend("circle.circle", T("Dublu clic: două inele, unul după altul"))
                }
                Button { advanced.toggle() } label: { HStack(spacing: 4) { Image(systemName: "chevron.right").font(Theme.F.glyph).rotationEffect(.degrees(advanced ? 90 : 0)); Text(T("Avansat")).font(Theme.F.caption) }.foregroundStyle(Theme.C.textDim) }
                    .buttonStyle(.plain).accessibilityLabel(T("Avansat")).accessibilityValue(advanced ? "extins" : T("restrâns"))
                if advanced {
                    NumberRow(label: T("Durată"), unit: "s", range: 0.2...1.5, value: num(\.clickSeconds, 1), commit: { m.commitMouseFX(c.id) }, decimals: 2, reset: 0.5)
                    NumberRow(label: T("Intensitate"), unit: "%", range: 10...100, value: num(\.clickStrength, 100), commit: { m.commitMouseFX(c.id) }, reset: 90)
                }
            }.disabled(!f.clickRing).opacity(f.clickRing ? 1 : 0.45)
            if m.selectedMouseTrack?.rightTracked != true {
                Text(T("Această înregistrare a fost făcută înainte de versiunea 1.7.0 și a reținut doar butonul principal: clicurile dreapta nu pot fi deosebite și nu se desenează. Clicul stânga și dublul clic funcționează."))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
        InspectorGroup(T("Zoom după cursor")) {
            Button { m.followMouse(c.id, scale: 1.8) } label: { Label(T("Zoom care urmărește cursorul"), systemImage: "scope") }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                .help(T("Mărește cadrul (×1,8) și îl mută după cursor; rezultatul sunt chei obișnuite, pe care le poți edita la Animație"))
            Text(T("Independent de evidențiere și de efectul la clic.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
        }
    }
    private func legend(_ symbol: String, _ text: String) -> some View {
        HStack(spacing: 6) { Image(systemName: symbol).font(Theme.F.iconSmall).foregroundStyle(Theme.C.textDim).frame(width: 16); Text(text).font(Theme.F.caption).foregroundStyle(Theme.C.textDim) }
    }
}
