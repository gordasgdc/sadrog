// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// Keyframe band along the bottom of the SELECTED video item: one diamond per keyframe (all, or only those that change the property chosen in the Inspector).
/// Click selects a key and moves the playhead to it; drag moves it in time (one undo step, Esc cancels, ⇧ = fine); double-click on empty band adds a key there;
/// Delete or the context menu removes it. The Inspector keeps the exact values. Keyframes hold the five placement properties together, so “changes the property”
/// means its value differs from the previous key’s (the first key is compared with the item’s start state).
struct KeyframeBand: View {
    @ObservedObject var m: EditorModel
    let id: UUID, duration: Double, pps: CGFloat, width: CGFloat, height: CGFloat
    let motion: Motion?, start: Transform
    @State private var drag: (index: Int, t: Double)?
    @State private var cancelled = false
    @State private var hovered: Int?
    @State private var esc = KeyMonitorBox()
    @State private var keys = KeyMonitorBox()
    private func value(_ t: Transform, _ p: ProjectEditor.KeyProperty) -> Double {
        switch p { case .x: return t.x; case .y: return t.y; case .scale: return t.scale; case .rotation: return t.rotation; case .opacity: return t.opacity }
    }
    private func name(_ p: ProjectEditor.KeyProperty) -> String {
        switch p { case .x: return T("Poziție X"); case .y: return T("Poziție Y"); case .scale: return T("Scară"); case .rotation: return T("Rotație"); case .opacity: return T("Opacitate") }
    }
    var body: some View {
        let ks = motion?.keys ?? []
        let shown = (motion ?? Motion()).keyIndices(changing: m.keyBandProp, start: start)
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Color.black.opacity(0.28)).frame(width: width, height: height)
                .overlay(alignment: .leading) {
                    if shown.isEmpty { Text(T("Dublu-clic: cheie nouă")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).padding(.leading, 6).lineLimit(1) }
                }
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2).onEnded { v in m.addKey(at: Double(v.location.x / pps)) })
                .help(T("Banda de chei: dublu-clic adaugă o cheie; trage rombul pentru timp (⇧ fin, Esc anulează); Delete șterge cheia selectată"))
                .accessibilityLabel(T("Banda de chei video"))
            ForEach(shown, id: \.self) { i in
                let k = ks[i], t = drag?.index == i ? drag!.t : k.t, on = m.editingKey == i
                Image(systemName: "diamond.fill").font(.system(size: on ? 11 : 9)).foregroundStyle(on ? Theme.C.sel : Color.white)
                    .shadow(color: .black.opacity(0.6), radius: 0.8)
                    .frame(width: 16, height: height).contentShape(Rectangle())
                    .accessibilityLabel(L10n.f("Cheia de la %@ s", String(format: "%.2f", k.t))).accessibilityValue(on ? T("editată") : "")
                    .help(T("Cheie: clic o alege, trage pentru timp, clic dreapta pentru interpolare sau ștergere"))
                    .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                    .onTapGesture { m.showKey(i) }
                    .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                        if cancelled { return }
                        m.showKey(i)
                        if esc.token == nil { esc.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in guard e.keyCode == 53 else { return e }; cancelled = true; drag = nil; return nil } }
                        let f: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                        drag = (i, max(0.05, min(duration - 0.05, k.t + Double(v.translation.width * f / pps))))
                    }.onEnded { _ in
                        defer { drag = nil; cancelled = false; esc.stop() }
                        if !cancelled, let d = drag { let to = (d.t * 100).rounded() / 100; m.apply(reload: false) { $0.moveKey(id, index: i, to: to) }; m.editingKey = m.selectedMotion?.keys.firstIndex { abs($0.t - to) < 0.06 } }
                    })
                    .contextMenu {
                        ForEach([Easing.smooth, .linear, .easeIn, .easeOut, .hold], id: \.self) { e in
                            Button(Self.easingName(e)) { m.apply(reload: false) { $0.setKeyEasing(id, index: i, e) } }
                        }
                        Divider()
                        Button(T("Șterge cheia")) { m.removeKey(i) }
                    }
                    .accessibilityAction(named: Text(T("Șterge cheia"))) { m.removeKey(i) }
                    .position(x: CGFloat(t) * pps, y: height / 2)   // LAST: gestures attached after .position() answer over the whole band
            }
            if let i = drag?.index ?? hovered, ks.indices.contains(i) {
                let t = drag?.t ?? ks[i].t
                let txt = (m.keyBandProp.map { p in String(format: "%@ %.2f", name(p), value(ks[i].transform, p) * (p == .scale || p == .opacity ? 100 : 1)) } ?? "")
                Text(verbatim: String(format: "%.2f s", t) + (txt.isEmpty ? "" : " · " + txt)).font(Theme.F.caption).monospacedDigit().padding(.horizontal, 5).padding(.vertical, 1)
                    .background(Theme.C.bg0.opacity(0.92), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Theme.C.text).fixedSize().allowsHitTesting(false)
                    .position(x: min(max(40, CGFloat(t) * pps), max(40, width - 40)), y: -9)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .onHover { inside in
            if inside, keys.token == nil {
                keys.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                    guard let i = m.editingKey, e.keyCode == 51 || e.keyCode == 117, !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
                    m.removeKey(i); return nil
                }
            } else if !inside { keys.stop() }
        }
        .onDisappear { keys.stop(); esc.stop() }
    }
    static func easingName(_ e: Easing) -> String {
        switch e { case .smooth: return T("Lin"); case .linear: return T("Liniar"); case .easeIn: return T("Intrare"); case .easeOut: return T("Ieșire"); case .hold: return T("Treaptă") }
    }
}
