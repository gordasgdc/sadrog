// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

extension PresenterCorner {
    var symbol: String { switch self { case .topLeft: "arrow.up.left"; case .topRight: "arrow.up.right"; case .bottomLeft: "arrow.down.left"; case .bottomRight: "arrow.down.right" } }
    var label: String { switch self { case .topLeft: T("Stânga sus"); case .topRight: "Dreapta sus"; case .bottomLeft: T("Stânga jos"); case .bottomRight: "Dreapta jos" } }
}

extension EditorModel {
    static func square(_ n: CGSize) -> CGSize { let s = min(n.width, n.height); return CGSize(width: s, height: s) }
    /// The selected video item (main clip or video overlay), if any.
    var selectedVideoID: UUID? { selectedClip?.id ?? (selectedLayer?.kind == .video ? selectedLayer?.id : nil) }
    var selectedCrop: CircleCrop? { selectedClip?.crop ?? (selectedLayer?.kind == .video ? selectedLayer?.crop : nil) }
    var selectedRectCrop: RectCrop? { selectedClip?.rectCrop ?? (selectedLayer?.kind == .video ? selectedLayer?.rectCrop : nil) }
    /// Rectangular crop while a control is dragged (the viewer follows); `commitRectCrop` saves it as one undo step.
    /// The item is re-placed so the kept pixels do not move on the canvas (not for animated items: their two states would diverge).
    func liveRectCrop(_ c: RectCrop) {
        var c = c; c.normalize()
        var t: Transform?
        if !selectedAnimated, let n0 = selectedMedia.flatMap({ media[$0]?.size }), let cur = selectedTransform { t = RectCrop.placement(from: selectedRectCrop, to: c, cur, natural: n0, render: renderSize) }
        liveRectCrop(c, transform: t)
    }
    func liveRectCrop(_ c: RectCrop, transform: Transform?) {
        guard let id = selectedVideoID else { return }
        var c = c; c.normalize()
        if let i = project.clips.firstIndex(where: { $0.id == id }) { project.clips[i].rectCrop = c; if let t = transform { project.clips[i].transform = t } }
        else if let i = project.layers.firstIndex(where: { $0.id == id }) { project.layers[i].rectCrop = c; if let t = transform { project.layers[i].transform = t } }
        refreshVideoComposition()
    }
    func commitRectCrop() {
        guard let id = selectedVideoID else { return }
        let c = selectedRectCrop, t = selectedAnimated ? nil : selectedTransform
        apply(reload: false) { $0.setRectCrop(id, c, transform: t) }
    }
    /// Re-fits the cropped picture to the frame (centred, fit scale): the crop fills the canvas instead of leaving empty margins. One undo step.
    func fitCropToFrame() {
        guard let id = selectedVideoID, let t = selectedTransform else { return }
        let c = selectedRectCrop
        apply(reload: false) { $0.setRectCrop(id, c, transform: Transform(x: 0, y: 0, scale: 1, opacity: t.opacity, rotation: t.rotation)) }
    }
    func resetRectCrop() {
        guard let id = selectedVideoID else { return }
        var t: Transform?
        if !selectedAnimated, let n0 = selectedMedia.flatMap({ media[$0]?.size }), let cur = selectedTransform { t = RectCrop.placement(from: selectedRectCrop, to: RectCrop(), cur, natural: n0, render: renderSize) }
        cropEditing = false
        apply(reload: false) { $0.setRectCrop(id, nil, transform: t) }
    }
    func cornered(_ t: Transform, _ corner: PresenterCorner) -> Transform { PresenterPlacement.transform(t, corner: corner, render: renderSize) }
    /// „Prezentator în cerc”: one undo step. An item still at full size is made smaller and placed bottom right; one already placed keeps its place.
    func makePresenter() {
        guard let id = selectedVideoID, let t = selectedPairStart else { return }
        let crop = PresenterPlacement.defaultCrop
        let full = abs(t.scale - 1) < 0.001 && t.x == 0 && t.y == 0 && !selectedAnimated
        var placed = t; placed.scale = PresenterPlacement.scale
        apply(reload: false) { $0.setCrop(id, crop, transform: full ? self.cornered(placed, .bottomRight) : nil) }
    }
    /// Back to the full rectangle; the source and the transform stay as they are.
    func removePresenter() { if let id = selectedVideoID { apply(reload: false) { $0.setCrop(id, nil) } } }
    func placePresenter(_ c: PresenterCorner) { if let id = selectedVideoID, let t = selectedTransform { commitTransform(id, cornered(t, c)) } }

    /// While a control is dragged: the project changes in memory and the viewer follows; `commitCrop` saves it (one undo step).
    func liveCrop(_ c: CircleCrop) {
        guard let id = selectedVideoID else { return }
        var c = c; c.normalize()
        if let i = project.clips.firstIndex(where: { $0.id == id }) { project.clips[i].crop = c }
        else if let i = project.layers.firstIndex(where: { $0.id == id }) { project.layers[i].crop = c }
        refreshVideoComposition()
    }
    /// Framing mode: starts (remembering the state for „Anulează”), ends keeping the change, or cancels back to the start.
    func beginFraming() { guard let c = selectedCrop else { return }; framingStart = c; circleFraming = true; refreshVideoComposition() }
    func endFraming() { guard circleFraming else { return }; circleFraming = false; framingStart = nil; refreshVideoComposition() }
    func cancelFraming() { if let c = framingStart, c != selectedCrop { setCrop(c) }; endFraming() }
    /// Live pan of the PICTURE (source pixels) while the circle stays; `commitCrop` closes the gesture as ONE undo step.
    func framingPan(from c0: CircleCrop, by d: CGSize) {
        guard let n = selectedMedia.flatMap({ media[$0]?.size }) else { return }
        var c = c0; c.pan(imageBy: d, in: n); liveCrop(c)
    }
    func framingZoom(from c0: CircleCrop, to z: Double) {
        guard let n = selectedMedia.flatMap({ media[$0]?.size }) else { return }
        var c = c0; c.setZoom(min(max(z, 1), 4), keepingCentreIn: n); liveCrop(c)
    }
    func framingRecentre() { guard var c = selectedCrop else { return }; c.recentre(); setCrop(c) }
    func commitCrop() { if let id = selectedVideoID, let c = selectedCrop { apply(reload: false) { $0.setCrop(id, c) } } }
    func setCrop(_ c: CircleCrop) { liveCrop(c); commitCrop() }

    private var selectedPairStart: Transform? { selectedClip?.transform ?? (selectedLayer?.kind == .video ? selectedLayer?.transform : nil) }
}

/// Compact inspector group: the action when the item is a rectangle; position, framing and outline when it is a circle.
struct PresenterGroup: View {
    @ObservedObject var m: EditorModel
    @State private var colorCommit: DispatchWorkItem?
    static let quick: [(String, TextColor)] = [("Alb", .white), (T("Roșu"), .presenterRed)]

    private func bind(_ get: @escaping (CircleCrop) -> Double, _ set: @escaping (inout CircleCrop, Double) -> Void) -> Binding<Double> {
        Binding(get: { m.selectedCrop.map(get) ?? 0 }, set: { v in guard var c = m.selectedCrop else { return }; set(&c, v); m.liveCrop(c) })
    }
    private func border(_ f: @escaping (inout CircleBorder) -> Void) { guard var c = m.selectedCrop, var b = c.border else { return }; f(&b); c.border = b; m.setCrop(c) }

    var body: some View {
        if let c = m.selectedCrop {
            InspectorGroup(T("Prezentator în cerc"), action: ("rectangle", T("Revino la dreptunghi (sursa rămâne neschimbată)"), false, { m.removePresenter() })) {
                HStack(spacing: 4) {
                    Text(T("Poziție")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                    ForEach(PresenterCorner.allCases) { k in
                        IconButton(symbol: k.symbol, label: L10n.f("Mută cercul în colțul %@", "\(k.label.lowercased())")) { m.placePresenter(k) }.help(k.label)
                    }
                    Spacer(minLength: 0)
                }.frame(height: 28)
                HStack(spacing: 6) {
                    if m.circleFraming {
                        Button { m.endFraming() } label: { Label(T("Gata"), systemImage: "checkmark") }.buttonStyle(.gloss(.primary, compact: true)).fixedSize()
                        Button { m.cancelFraming() } label: { Text(T("Anulează")) }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                        Button { m.framingRecentre() } label: { Text(T("Recentrează")) }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                    } else {
                        Button { m.beginFraming() } label: { Label(T("Încadrează imaginea în cerc"), systemImage: "viewfinder.circle") }
                            .buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                            .help(T("Cercul rămâne pe loc; vezi tot dreptunghiul camerei, estompat în afara cercului. Tragi imaginea sau colțurile ei ca să alegi ce apare în cerc. Dreptunghiul nu apare la export."))
                    }
                    Spacer(minLength: 0)
                }.frame(height: 28)
                NumberRow(label: T("Încadrare"), unit: "%", range: 100...400, value: bind({ $0.zoom * 100 }, { $0.zoom = $1 / 100 }), commit: { m.commitCrop() }, reset: 100)
                    .help(T("Mărirea imaginii în cerc; cercul nu își schimbă mărimea. În viewer: ⌥ + tragere mută imaginea în cerc."))
                NumberRow(label: T("Orizontal"), unit: "%", range: -100...100, value: bind({ $0.offsetX * 100 }, { $0.offsetX = $1 / 100 }), commit: { m.commitCrop() }, reset: 0)
                NumberRow(label: T("Vertical"), unit: "%", range: -100...100, value: bind({ $0.offsetY * 100 }, { $0.offsetY = $1 / 100 }), commit: { m.commitCrop() }, reset: 0)
                HStack(spacing: 8) {
                    Text(T("Contur")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                    Picker("", selection: Binding(get: { c.border?.style.rawValue ?? "none" }, set: { v in
                        var n = c
                        if v == "none" { n.border = nil } else { var b = c.border ?? CircleBorder(); b.style = CircleBorderStyle(rawValue: v) ?? .simple; n.border = b }
                        m.setCrop(n)
                    })) { Text(T("Fără")).tag("none"); Text(T("Simplu")).tag(CircleBorderStyle.simple.rawValue); Text(T("Lucios")).tag(CircleBorderStyle.glossy.rawValue) }
                        .labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Contur"))
                }.frame(height: 28)
                if let b = c.border {
                    HStack(spacing: 6) {
                        Text(T("Culoare")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                        ForEach(Self.quick, id: \.0) { name, col in
                            Button { border { $0.color = col } } label: {
                                Circle().fill(Color(red: col.r, green: col.g, blue: col.b)).frame(width: 16, height: 16)
                                    .overlay(Circle().strokeBorder(b.color == col ? Theme.C.sel : Color.white.opacity(0.35), lineWidth: b.color == col ? 2 : 1))
                            }.buttonStyle(.plain).help(name).accessibilityLabel("Contur \(name.lowercased())")
                        }
                        ColorPicker("", selection: Binding(get: { Color(red: b.color.r, green: b.color.g, blue: b.color.b) }, set: { v in
                            guard let ns = NSColor(v).usingColorSpace(.sRGB), var cc = m.selectedCrop, var bb = cc.border else { return }
                            bb.color = TextColor(r: Double(ns.redComponent), g: Double(ns.greenComponent), b: Double(ns.blueComponent)); cc.border = bb; m.liveCrop(cc)
                            colorCommit?.cancel(); let w = DispatchWorkItem { m.commitCrop() }; colorCommit = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: w)
                        }), supportsOpacity: false).labelsHidden().frame(width: 34).help(T("Altă culoare")).accessibilityLabel(T("Culoare personalizată a conturului"))
                        Spacer(minLength: 0)
                    }.frame(height: 28)
                    NumberRow(label: T("Grosime"), unit: "%", range: 0.5...8, value: bind({ ($0.border?.width ?? 0.02) * 100 }, { $0.border?.width = $1 / 100 }), commit: { m.commitCrop() }, decimals: 1)
                        .help(T("Din diametrul cercului; conturul e desenat în interiorul marginii"))
                    NumberRow(label: T("Opacitate"), unit: "%", range: 0...100, value: bind({ ($0.border?.opacity ?? 1) * 100 }, { $0.border?.opacity = $1 / 100 }), commit: { m.commitCrop() })
                }
            }
        } else {
            InspectorGroup(T("Prezentator în cerc")) {
                Button { m.makePresenter() } label: { Label(T("Prezentator în cerc"), systemImage: "person.crop.circle") }
                    .buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                    .help(T("Arată clipul ca un cerc (de exemplu camera peste ecran). Sursa rămâne neschimbată; revii oricând la dreptunghi."))
            }
        }
    }
}

/// Rectangular crop of the selected picture: four sides in % of the source, reset. Not shown while the circle (presenter) is on.
struct RectCropGroup: View {
    @ObservedObject var m: EditorModel
    private func bind(_ kp: WritableKeyPath<RectCrop, Double>) -> Binding<Double> {
        Binding(get: { (m.selectedRectCrop?[keyPath: kp] ?? 0) * 100 }, set: { v in var c = m.selectedRectCrop ?? RectCrop(); c[keyPath: kp] = v / 100; m.liveRectCrop(c) })
    }
    var body: some View {
        if m.selectedCrop == nil {
            InspectorGroup(T("Decupare")) {
                NumberRow(label: T("Stânga"), unit: "%", range: 0...90, value: bind(\.left), commit: { m.commitRectCrop() }, decimals: 1, reset: 0)
                NumberRow(label: T("Dreapta"), unit: "%", range: 0...90, value: bind(\.right), commit: { m.commitRectCrop() }, decimals: 1, reset: 0)
                NumberRow(label: T("Sus"), unit: "%", range: 0...90, value: bind(\.top), commit: { m.commitRectCrop() }, decimals: 1, reset: 0)
                NumberRow(label: T("Jos"), unit: "%", range: 0...90, value: bind(\.bottom), commit: { m.commitRectCrop() }, decimals: 1, reset: 0)
                HStack(spacing: 8) {
                    Button { m.cropEditing.toggle() } label: { Label(T("Decupare în vizor"), systemImage: "crop") }
                        .buttonStyle(.gloss(m.cropEditing ? .primary : .secondary, compact: true)).fixedSize().disabled(m.selectedAnimated)
                        .help(m.selectedAnimated ? T("Elementul are animație: decuparea în vizor nu e disponibilă; folosește câmpurile.") : T("Trage marginile imaginii direct în vizor; conținutul rămâne pe loc."))
                    Button { m.resetRectCrop() } label: { Label(T("Fără decupare"), systemImage: "arrow.uturn.backward") }
                        .buttonStyle(.gloss(.secondary, compact: true)).fixedSize().disabled(m.selectedRectCrop == nil)
                }
                Button { m.fitCropToFrame() } label: { Label(T("Umple cadrul"), systemImage: "arrow.up.left.and.arrow.down.right") }
                    .buttonStyle(.gloss(.secondary, compact: true)).fixedSize().disabled(m.selectedRectCrop == nil || m.selectedAnimated)
                    .help(T("Centrează imaginea decupată și o mărește până umple cadrul."))
                Text(T("Decuparea nu modifică sursa; revii oricând la imaginea întreagă.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
