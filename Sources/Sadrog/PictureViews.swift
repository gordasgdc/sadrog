// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

extension EditorModel {
    /// Colour controls / person background of the selected video item (main clip or video overlay); nil = neutral.
    var selectedPicture: PictureAdjust? { selectedClip?.picture ?? (selectedLayer?.kind == .video ? selectedLayer?.picture : nil) }
    /// While a control is dragged: the viewer follows, nothing is recorded. `commitPicture` saves it as ONE undo step.
    func livePicture(_ v: PictureAdjust) {
        guard let id = selectedVideoID else { return }
        var v = v; v.normalize()
        if let i = project.clips.firstIndex(where: { $0.id == id }) { project.clips[i].picture = v }
        else if let i = project.layers.firstIndex(where: { $0.id == id }) { project.layers[i].picture = v }
        refreshVideoComposition()
    }
    func commitPicture(_ v: PictureAdjust? = nil) {
        guard let id = selectedVideoID else { return }
        let value = v ?? selectedPicture
        apply(reload: false) { $0.setPicture(id, value) }
    }
}

/// Colour controls of the selected picture: brightness, contrast, saturation. Neutral by default; reset per value (double-click) or for the whole group.
struct ColorGroup: View {
    @ObservedObject var m: EditorModel
    private func bind(_ kp: WritableKeyPath<PictureAdjust, Double>, _ k: Double) -> Binding<Double> {
        Binding(get: { (m.selectedPicture ?? PictureAdjust())[keyPath: kp] * k }, set: { v in var p = m.selectedPicture ?? PictureAdjust(); p[keyPath: kp] = v / k; m.livePicture(p) })
    }
    private func resetColor() { var p = m.selectedPicture ?? PictureAdjust(); p.brightness = 0; p.contrast = 1; p.saturation = 1; m.commitPicture(p) }
    var body: some View {
        InspectorGroup(T("Culoare"), action: ("arrow.counterclockwise", T("Resetează culoarea"), m.selectedPicture?.colorIsNeutral ?? true, resetColor)) {
            NumberRow(label: T("Strălucire"), unit: "", range: -100...100, value: bind(\.brightness, 200), commit: { m.commitPicture() }, reset: 0)
            NumberRow(label: T("Contrast"), unit: "%", range: 50...150, value: bind(\.contrast, 100), commit: { m.commitPicture() }, reset: 100)
            NumberRow(label: T("Saturație"), unit: "%", range: 0...200, value: bind(\.saturation, 100), commit: { m.commitPicture() }, reset: 100)
            Text(T("Doar pe acest clip. Se vede la fel în previzualizare și în fișierul exportat; sursa rămâne neschimbată."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Person background of the selected picture (camera): blur it or remove it. Computed on this Mac at edit time.
struct PersonBackgroundGroup: View {
    @ObservedObject var m: EditorModel
    private var p: PictureAdjust { m.selectedPicture ?? PictureAdjust() }
    var body: some View {
        InspectorGroup(T("Fundal (persoană)")) {
            Picker("", selection: Binding(get: { p.background }, set: { v in var n = p; n.background = v; m.commitPicture(n) })) {
                Text(T("Oprit")).tag(PersonBackground.off); Text(T("Estompat")).tag(PersonBackground.blur); Text(T("Eliminat")).tag(PersonBackground.remove)
            }.labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Fundalul din spatele persoanei"))
                .help(T("Estompat = fundalul din spatele persoanei devine neclar. Eliminat = rămâne doar persoana, peste ce este dedesubt."))
            if p.background == .blur {
                NumberRow(label: T("Estompare"), unit: "%", range: 5...100, value: Binding(get: { p.blur * 100 }, set: { v in var n = p; n.blur = v / 100; m.livePicture(n) }), commit: { m.commitPicture() }, reset: 50)
            }
            Text(T("Se aplică la editare, pe acest Mac: apare în previzualizare și în export, nu în fișierul înregistrat, deci poate fi oprit oricând. Gândit pentru o persoană filmată cu camera; exportul durează mai mult."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            if p.background != .off, let why = PersonMask.lastFailure {
                Label(L10n.f("Persoana nu a putut fi separată în acest cadru: %@", why), systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
