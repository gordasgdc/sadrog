// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// A number field that keeps its value locally while it is scrubbed or typed and applies it once (one undo step) when the gesture ends.
struct CommitNumber: View {
    let label: String, unit: String; let range: ClosedRange<Double>; var decimals = 1
    let current: Double; let apply: (Double) -> Void
    @State private var draft: Double?
    var body: some View {
        NumberRow(label: label, unit: unit, range: range,
                  value: Binding(get: { draft ?? current }, set: { draft = $0 }),
                  commit: { if let d = draft { draft = nil; apply(d) } }, decimals: decimals)
    }
}

/// Clip speed: presets, a custom value, the resulting length, pitch and mute. Applies to the selected main clip or picture/sound item.
struct SpeedGroup: View {
    @ObservedObject var m: EditorModel
    let id: UUID
    private var current: (speed: Double, span: Double, duration: Double, isClip: Bool)? {
        if let c = m.project.clips.first(where: { $0.id == id }) { return (c.speed, c.sourceSpan, c.duration, true) }
        if let l = m.project.layers.first(where: { $0.id == id }), l.kind == .video || l.kind == .audio { return (l.speed, l.sourceSpan, l.duration, false) }
        return nil
    }
    private func set(_ v: Double) { m.apply(reload: true) { ed in if current?.isClip == true { ed.setSpeed(clip: id, v) } else { ed.setSpeed(layer: id, v) } } }
    private func blocker(_ v: Double) -> String? {
        let ed = ProjectEditor(project: m.project)
        return current?.isClip == true ? ed.retimeBlocker(ofClip: id) : ed.layerSpeedBlocker(id, speed: v)
    }
    var body: some View {
        if let cur = current {
            let block = blocker(cur.speed)
            InspectorGroup(T("Viteză"), action: ("arrow.counterclockwise", T("Înapoi la 1×"), cur.speed == 1, { set(1) })) {
                HStack(spacing: 4) {
                    ForEach(Retime.presets, id: \.self) { p in
                        Button(Retime.label(p)) { set(p) }
                            .buttonStyle(.gloss(cur.speed == p ? .primary : .secondary, compact: true)).fixedSize()
                            .accessibilityLabel(L10n.f("Viteză %@", Retime.label(p))).accessibilityValue(cur.speed == p ? T("activă") : "")
                    }
                }.disabled(block != nil)
                CommitNumber(label: T("Personalizat"), unit: "×", range: Retime.range, decimals: 2, current: cur.speed, apply: { set($0) })
                    .disabled(block != nil).opacity(block != nil ? 0.45 : 1)
                    .help(T("Între 0,1× și 16×. 60 s de sursă la 6× devin 10 s; la 0,5× devin 120 s"))
                Text(verbatim: String(format: T("Sursă %.2f s → pe cronologie %.2f s"), cur.span, cur.duration))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                if let block { Text(block).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true) }
                else if cur.speed < 1 {
                    Text(T("Încetinirea repetă cadre (fără interpolare de mișcare): la viteze foarte mici mișcarea devine sacadată."))
                        .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                }
                if cur.speed != 1, cur.isClip, let c = m.project.clips.first(where: { $0.id == id }) {
                    Toggle(T("Fără sunet la viteza aceasta"), isOn: Binding(get: { c.speedMute }, set: { on in m.apply(reload: true) { $0.setSpeedMute(clip: id, on) } }))
                        .toggleStyle(.switch).controlSize(.mini).font(Theme.F.body).frame(height: 24)
                        .help(T("Sunetul clipului este oprit cât timp viteza nu e 1×; celelalte piste nu sunt atinse"))
                }
                if cur.speed != 1 {
                    Toggle(T("Păstrează înălțimea sunetului"), isOn: Binding(get: { m.project.keepPitch }, set: { on in m.apply(reload: true) { $0.setKeepPitch(on) } }))
                        .toggleStyle(.switch).controlSize(.mini).font(Theme.F.body).frame(height: 24)
                        .help(T("Pornit: sunetul accelerat sau încetinit își păstrează tonul. Oprit: tonul urcă sau coboară odată cu viteza. Se aplică întregului proiect"))
                }
            }
        }
    }
}

/// Draws a fade curve (0 → 1) in a small box.
struct CurvePreview: View {
    let curve: (Double) -> Double
    var body: some View {
        Canvas { ctx, size in
            var p = Path()
            for i in 0...48 { let u = Double(i) / 48, pt = CGPoint(x: u * size.width, y: size.height - curve(u) * size.height); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }
            ctx.stroke(p, with: .color(Theme.C.accent), lineWidth: 1.5)
        }
        .frame(height: 30).background(RoundedRectangle(cornerRadius: 4).fill(Theme.C.bg0)).accessibilityHidden(true)
    }
}

/// Shape and curvature of the fade-in / fade-out of the selected sound.
struct FadeShapeRows: View {
    @ObservedObject var m: EditorModel
    let id: UUID
    private func title(_ s: FadeShape) -> String {
        switch s { case .linear: return T("Liniar"); case .easeIn: return T("Intrare lentă"); case .easeOut: return T("Ieșire lentă"); case .sCurve: return T("Curbă S") }
    }
    private func row(_ label: String, isIn: Bool) -> some View {
        let e = m.audioEdit(id), cur = isIn ? e.fadeInCurve : e.fadeOutCurve
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(label).font(Theme.F.body).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Picker("", selection: Binding(get: { cur.shape }, set: { s in
                    let c = FadeCurve(shape: s, bend: cur.bend)
                    m.apply(reload: false) { $0.setFadeCurves(id, fadeIn: isIn ? c : nil, fadeOut: isIn ? nil : c) }
                })) { ForEach(FadeShape.allCases, id: \.self) { Text(title($0)).tag($0) } }
                    .labelsHidden().accessibilityLabel(label)
            }
            if cur.shape != .linear {
                CommitNumber(label: T("Curbură"), unit: "%", range: 0...100, decimals: 0, current: cur.bend * 100, apply: { v in
                    let c = FadeCurve(shape: cur.shape, bend: v / 100)
                    m.apply(reload: false) { $0.setFadeCurves(id, fadeIn: isIn ? c : nil, fadeOut: isIn ? nil : c) }
                })
            }
            CurvePreview { u in cur.gain(u) }
        }
    }
    var body: some View {
        row(T("Forma fade-in"), isIn: true)
        row(T("Forma fade-out"), isIn: false)
        Text(T("Curba de pe cronologie este cea aplicată. Resetarea fade-urilor păstrează punctele de volum."))
            .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
    }
}

/// Volume automation of the selected sound: points in dB at times local to the item (0 = its start).
struct AutomationGroup: View {
    @ObservedObject var m: EditorModel
    let id: UUID
    private var itemTime: Double { m.time - m.selectedStart }
    private func dbText(_ db: Double) -> String { db <= VolumeKey.silenceDB ? T("Mut") : String(format: "%+.1f dB", db) }
    var body: some View {
        let e = m.audioEdit(id), d = m.selectedAudioDuration, pts = e.points
        InspectorGroup(T("Automatizare volum"), action: ("arrow.counterclockwise", T("Șterge toate punctele"), pts.isEmpty, { m.apply(reload: false) { $0.resetVolumePoints(id) } })) {
            HStack(spacing: 6) {
                Button { let t = max(0, min(d, itemTime)); m.apply(reload: false) { $0.addVolumePoint(id, at: t) } } label: { Label(T("Punct la cursor"), systemImage: "diamond") }
                    .buttonStyle(.gloss(.secondary, compact: true)).fixedSize().disabled(itemTime < 0 || itemTime > d)
                    .help(T("Adaugă un punct de volum la poziția cursorului, la nivelul curent al automatizării"))
                Button { if let i = e.previousPoint(before: itemTime) { m.seek(m.selectedStart + pts[i].t) } } label: { Image(systemName: "chevron.left") }
                    .buttonStyle(.gloss(.secondary, compact: true)).disabled(e.previousPoint(before: itemTime) == nil).accessibilityLabel(T("Punctul anterior"))
                Button { if let i = e.nextPoint(after: itemTime) { m.seek(m.selectedStart + pts[i].t) } } label: { Image(systemName: "chevron.right") }
                    .buttonStyle(.gloss(.secondary, compact: true)).disabled(e.nextPoint(after: itemTime) == nil).accessibilityLabel(T("Punctul următor"))
                Spacer(minLength: 0)
            }
            if pts.isEmpty {
                Text(T("Fără puncte: volumul rămâne cel fix de mai sus. Valorile sunt în dB, relativ la volumul clipului; „Mut” înseamnă liniște completă."))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(pts.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 4) {
                    Text(verbatim: String(format: "%.2f s", p.t)).font(Theme.F.monoSmall).frame(width: 52, alignment: .leading)
                    Text(dbText(p.db)).font(Theme.F.monoSmall).foregroundStyle(Theme.C.textDim).frame(width: 60, alignment: .leading)
                    Spacer(minLength: 0)
                    Button { m.apply(reload: false) { $0.removeVolumePoint(id, index: i) } } label: { Image(systemName: "xmark").font(Theme.F.iconSmall).frame(width: 18, height: 22) }
                        .buttonStyle(.plain).foregroundStyle(Theme.C.textFaint).accessibilityLabel(T("Șterge punctul"))
                }
                CommitNumber(label: T("Nivel"), unit: "dB", range: VolumeKey.silenceDB...VolumeKey.maxDB, decimals: 1, current: p.db,
                             apply: { v in m.apply(reload: false) { $0.moveVolumePoint(id, index: i, t: p.t, db: v) } })
                CommitNumber(label: T("Moment"), unit: "s", range: 0...max(0.01, d), decimals: 2, current: p.t,
                             apply: { v in m.apply(reload: false) { $0.moveVolumePoint(id, index: i, t: v, db: p.db) } })
            }
            let peak = e.automationPeakDB
            if peak > 0 {
                Text(verbatim: String(format: T("Atenție: automatizarea ridică volumul până la %+.1f dB; exportul poate tăia vârfurile."), peak))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            Text(T("Ordinea: volumul sursei și al clipului, apoi automatizarea, fade-urile, tranziția dintre piese, efectele și volumul general. Nimic nu se aplică de două ori."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Interpolation and time of the selected keyframe, plus navigation between keys.
struct KeyEditRows: View {
    @ObservedObject var m: EditorModel
    var body: some View {
        if let id = m.selection, let i = m.editingKey, let mo = m.selectedMotion, mo.keys.indices.contains(i) {
            let k = mo.keys[i], dur = m.selectedDuration
            HStack(spacing: 8) {
                Text(T("De la cheia asta")).font(Theme.F.body).lineLimit(1).fixedSize(horizontal: true, vertical: false)
                Picker("", selection: Binding<Int>(get: { Self.code(k.easing) }, set: { v in m.apply(reload: false) { $0.setKeyEasing(id, index: i, Self.easing(v)) } })) {
                    Text(T("Implicit")).tag(0); Text(T("Liniar")).tag(1); Text(T("Treaptă")).tag(2); Text(T("Intrare")).tag(3); Text(T("Ieșire")).tag(4); Text(T("Lin")).tag(5)
                }.labelsHidden().accessibilityLabel(T("Interpolarea până la cheia următoare"))
                    .help(T("Cum trece valoarea de la această cheie la următoare. Treaptă = rămâne neschimbată și sare la cheia următoare"))
            }
            CommitNumber(label: T("Momentul cheii"), unit: "s", range: 0.05...max(0.1, dur - 0.05), decimals: 2, current: k.t,
                         apply: { v in m.apply(reload: false) { $0.moveKey(id, index: i, to: v) } })
        }
        HStack(spacing: 6) {
            Button { if let id = m.selection, let j = m.keyBefore { m.showKey(j); _ = id } } label: { Image(systemName: "chevron.left") }
                .buttonStyle(.gloss(.secondary, compact: true)).disabled(m.keyBefore == nil).accessibilityLabel(T("Cheia anterioară"))
            Button { if let j = m.keyAfter { m.showKey(j) } } label: { Image(systemName: "chevron.right") }
                .buttonStyle(.gloss(.secondary, compact: true)).disabled(m.keyAfter == nil).accessibilityLabel(T("Cheia următoare"))
            Spacer(minLength: 0)
        }
    }
    static func code(_ e: Easing?) -> Int {
        switch e { case nil: return 0; case .linear?: return 1; case .hold?: return 2; case .easeIn?: return 3; case .easeOut?: return 4; case .smooth?: return 5 }
    }
    static func easing(_ c: Int) -> Easing? { [nil, .linear, .hold, .easeIn, .easeOut, .smooth][max(0, min(5, c))] }
}

extension EditorModel {
    /// Index of the key just before / after the playhead (for “go to key”).
    var keyBefore: Int? { selection.flatMap { ProjectEditor(project: project).previousKey($0, before: time - selectedStart) } }
    var keyAfter: Int? { selection.flatMap { ProjectEditor(project: project).nextKey($0, after: time - selectedStart) } }
}

/// Crossfade between two independent sound items (A2), and the sound shape of a picture dissolve on the main track.
struct CrossfadeGroup: View {
    @ObservedObject var m: EditorModel
    let id: UUID
    @State private var note: String?
    private func previous(of l: Layer) -> Layer? {
        m.project.layers.filter { $0.kind == .audio && $0.id != l.id && $0.start < l.start - 1e-6 && $0.end <= l.end + 1e-6 && $0.end >= l.start - 0.01 }.max { $0.end < $1.end }
    }
    private func modeTitle(_ x: CrossfadeMode) -> String { x == .equalGain ? T("Câștig egal") : T("Putere egală") }
    private func shapeTitle(_ s: FadeShape) -> String {
        switch s { case .linear: return T("Liniar"); case .easeIn: return T("Intrare lentă"); case .easeOut: return T("Ieșire lentă"); case .sCurve: return T("Curbă S") }
    }
    @ViewBuilder private func shapeControls(_ cur: CrossfadeShape, set: @escaping (CrossfadeShape) -> Void) -> some View {
        HStack(spacing: 8) {
            Text(T("Tip")).font(Theme.F.body).fixedSize(horizontal: true, vertical: false)
            Picker("", selection: Binding(get: { cur.mode }, set: { v in var s = cur; s.mode = v; set(s) })) {
                ForEach(CrossfadeMode.allCases, id: \.self) { Text(modeTitle($0)).tag($0) }
            }.labelsHidden().accessibilityLabel(T("Tipul încrucișării"))
        }
        Text(cur.mode == .equalGain
             ? T("Câștig egal: nivelurile însumează 1. Constant pentru același sunet pe ambele părți; scade cu până la 3 dB la mijloc pentru sunete diferite.")
             : T("Putere egală: puterea rămâne constantă pentru sunete diferite; pentru același sunet pe ambele părți mijlocul urcă cu până la 3 dB."))
            .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
        HStack(spacing: 8) {
            Text(T("Curba")).font(Theme.F.body).fixedSize(horizontal: true, vertical: false)
            Picker("", selection: Binding(get: { cur.curve.shape }, set: { v in var s = cur; s.curve = FadeCurve(shape: v, bend: cur.curve.bend); set(s) })) {
                ForEach(FadeShape.allCases, id: \.self) { Text(shapeTitle($0)).tag($0) }
            }.labelsHidden().accessibilityLabel(T("Curba încrucișării"))
        }
        if cur.curve.shape != .linear {
            CommitNumber(label: T("Curbură"), unit: "%", range: 0...100, decimals: 0, current: cur.curve.bend * 100, apply: { v in var s = cur; s.curve = FadeCurve(shape: cur.curve.shape, bend: v / 100); set(s) })
        }
        CurvePreview { u in cur.gains(u).incoming }
    }
    var body: some View {
        if let l = m.project.layers.first(where: { $0.id == id && $0.kind == .audio }) {
            let secs = m.project.crossfadeSeconds(l), prev = previous(of: l)
            InspectorGroup(T("Încrucișare între piese")) {
                if secs > 0, let link = l.audio?.crossfade, let o = m.project.layers.first(where: { $0.id == link.outgoing }) {
                    CommitNumber(label: T("Durată"), unit: "s", range: 0.02...max(0.03, l.duration - 0.05), decimals: 2, current: secs, apply: { v in
                        let newStart = o.end - v
                        m.apply(reload: false) { $0.trimLayerStart(id, by: newStart - l.start) }
                    })
                    shapeControls(link.shape) { s in m.apply(reload: false) { $0.setCrossfadeShape(incoming: id, s) } }
                    Button(T("Elimină încrucișarea")) { m.apply(reload: false) { $0.removeCrossfade(incoming: id) }; note = nil }.controlSize(.small)
                    Text(T("Durata este suprapunerea reală a celor două piese: o poți schimba aici sau mutând/tăind piesele."))
                        .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                } else if let o = prev {
                    Button(T("Încrucișează cu piesa anterioară")) {
                        var r = ProjectEditor.CrossfadeResult.invalid("")
                        m.apply(reload: false) { r = $0.crossfade(outgoing: o.id, incoming: id, seconds: 0.5, outgoingSourceLength: m.media[o.media]?.duration) }
                        switch r {
                        case .created: note = nil
                        case .noMaterial: note = T("Nu există material sursă pentru suprapunere: nicio piesă nu poate fi prelungită. Taie piesele mai scurt sau suprapune-le manual.")
                        case .locked: note = T("Pista de sunet este blocată.")
                        case .invalid: note = T("Piesele nu pot fi încrucișate: trebuie să fie sunete independente, iar prima să se termine în a doua.")
                        }
                    }.controlSize(.small).help(T("Suprapune finalul piesei anterioare cu începutul acesteia și le fuzionează cu un fade în X"))
                    Text(T("Fără încrucișare: piesele se aud una peste alta sau una după alta."))
                        .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(T("Nicio piesă anterioară alăturată pe care să o încrucișezi."))
                        .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                }
                if let note { Text(note).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true) }
            }
        } else if let c = m.project.clips.first(where: { $0.id == id }), c.dissolve > 0 {
            InspectorGroup(T("Sunetul tranziției")) {
                shapeControls(c.dissolveShape) { s in m.apply(reload: false) { $0.setDissolveShape(clip: id, s) } }
            }
        }
    }
}

/// Holds the local key monitor that listens for Esc while a point is being dragged.
final class KeyMonitorBox {
    var token: Any?
    func stop() { if let t = token { NSEvent.removeMonitor(t); token = nil } }
    deinit { stop() }
}

/// The volume automation drawn over a sound item: a line in dB with a handle per point. Dragging a handle moves it in time and level (one undo step per drag);
/// dragging it far above or below the item, or pressing Esc during the drag, cancels the move (nothing reaches the project, no undo step). Adding and deleting points is in the Inspector (“Automatizare volum”).
struct VolumeCurveOverlay: View {
    @ObservedObject var m: EditorModel
    let id: UUID, duration: Double, pps: CGFloat, height: CGFloat
    @State private var drag: (index: Int, t: Double, db: Double)?
    @State private var cancelled = false
    @State private var escMonitor = KeyMonitorBox()
    @State private var selected: Int?
    @State private var hovered: Int?
    @State private var keyMonitor = KeyMonitorBox()
    static let lo = -36.0, hi = 12.0
    private var editing: Bool { m.tool == .volume }
    private func y(_ db: Double) -> CGFloat { height * (1 - CGFloat((max(Self.lo, min(Self.hi, db)) - Self.lo) / (Self.hi - Self.lo))) }
    private func db(forY v: CGFloat) -> Double { Self.lo + Double(1 - max(0, min(1, v / max(1, height)))) * (Self.hi - Self.lo) }
    /// Level for a dragged point: ⇧ = fine (1/10 of the movement), magnet to 0 dB within 0.75 dB unless ⌥ is held.
    private func level(_ raw: Double) -> Double {
        let r = (raw * 10).rounded() / 10
        return (!NSEvent.modifierFlags.contains(.option) && abs(r) < 0.75) ? 0 : r
    }
    private func removeSelected() { if let i = selected { selected = nil; m.apply(reload: false) { $0.removeVolumePoint(id, index: i) } } }
    private func label(_ k: VolumeKey) -> some View {
        Text(verbatim: String(format: "%.2f s · %+.1f dB", k.t, k.db)).font(Theme.F.caption).monospacedDigit().padding(.horizontal, 5).padding(.vertical, 2)
            .background(Theme.C.bg0.opacity(0.92), in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Theme.C.text).fixedSize().allowsHitTesting(false)
    }
    var body: some View {
        var pts = m.audioEdit(id).points
        if let d = drag, pts.indices.contains(d.index) { pts[d.index] = VolumeKey(t: d.t, db: d.db) }
        pts.sort { $0.t < $1.t }
        return Group {
            if !pts.isEmpty || editing {
                ZStack(alignment: .topLeading) {
                    if editing {       // the volume tool owns clicks on this item: nothing here moves or cuts the clip; double-click adds a point
                        Color.clear.contentShape(Rectangle())
                            .gesture(SpatialTapGesture(count: 2).onEnded { v in
                                let t = max(0, min(duration, Double(v.location.x / pps)))
                                m.apply(reload: false) { $0.addVolumePoint(id, at: t, db: pts.isEmpty ? level(db(forY: v.location.y)) : nil) }
                            })
                            .simultaneousGesture(TapGesture().onEnded { selected = nil })
                            .help(T("Unealta Volum: dublu-clic adaugă un punct; trage un punct pentru timp și nivel (⇧ fin, ⌥ fără magnetism); Delete îl șterge; Esc anulează tragerea"))
                    }
                    Canvas { ctx, size in
                        var p = Path()
                        if pts.isEmpty { p.move(to: CGPoint(x: 0, y: y(0))); p.addLine(to: CGPoint(x: CGFloat(duration) * pps, y: y(0))) }
                        else {
                            p.move(to: CGPoint(x: 0, y: y(pts[0].db)))
                            for k in pts { p.addLine(to: CGPoint(x: CGFloat(k.t) * pps, y: y(k.db))) }
                            p.addLine(to: CGPoint(x: CGFloat(duration) * pps, y: y(pts.last!.db)))
                        }
                        ctx.stroke(p, with: .color(Theme.C.sel), style: StrokeStyle(lineWidth: 1.4, dash: pts.isEmpty ? [4, 3] : []))
                    }.allowsHitTesting(false)
                    ForEach(Array(m.audioEdit(id).points.enumerated()), id: \.offset) { i, k in
                        let shown = (drag?.index == i) ? VolumeKey(t: drag!.t, db: drag!.db) : k
                        let on = selected == i
                        Circle().fill(on ? Color.white : Theme.C.sel).frame(width: on ? 10 : 8, height: on ? 10 : 8)
                            .overlay(Circle().stroke(on ? Theme.C.sel : Theme.C.bg0, lineWidth: on ? 2 : 1))
                            .contentShape(Circle().inset(by: -5))
                            .onHover { hovered = $0 ? i : (hovered == i ? nil : hovered) }
                            .accessibilityLabel(L10n.f("Punct de volum la %@ s", String(format: "%.2f", k.t))).accessibilityValue(String(format: "%+.1f dB", k.db))
                            .accessibilityAction(named: Text(T("Șterge punctul"))) { m.apply(reload: false) { $0.removeVolumePoint(id, index: i) } }
                            .contextMenu {
                                Button(T("Șterge punctul")) { selected = nil; m.apply(reload: false) { $0.removeVolumePoint(id, index: i) } }
                                Button(T("Nivel 0 dB")) { m.apply(reload: false) { $0.moveVolumePoint(id, index: i, t: k.t, db: 0) } }.disabled(k.db == 0)
                            }
                            .onTapGesture { selected = i }
                            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .local)
                                .onChanged { v in
                                    if cancelled { return }
                                    selected = i
                                    if escMonitor.token == nil {
                                        escMonitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                                            guard e.keyCode == 53 else { return e }
                                            cancelled = true; drag = nil
                                            return nil
                                        }
                                    }
                                    let f: CGFloat = NSEvent.modifierFlags.contains(.shift) ? 0.1 : 1
                                    let t = max(0, min(duration, k.t + Double(v.translation.width * f / pps)))
                                    drag = (i, t, level(db(forY: y(k.db) + v.translation.height * f)))
                                }
                                .onEnded { v in
                                    defer { drag = nil; cancelled = false; escMonitor.stop() }
                                    guard !cancelled, let d = drag, abs(v.translation.height) < height * 3 else { return }
                                    m.apply(reload: false) { $0.moveVolumePoint(id, index: i, t: d.t, db: d.db) }
                                })
                            // position LAST: gestures attached after .position() answer over the whole container, so a drag anywhere on the clip would move the point
                            .position(x: CGFloat(shown.t) * pps, y: y(shown.db))
                    }
                    if let i = drag?.index ?? hovered ?? selected, pts.indices.contains(i) || drag != nil {
                        let k = drag.map { VolumeKey(t: $0.t, db: $0.db) } ?? m.audioEdit(id).points[min(i, m.audioEdit(id).points.count - 1)]
                        label(k).position(x: min(max(46, CGFloat(k.t) * pps), max(46, CGFloat(duration) * pps - 46)), y: max(10, y(k.db) - 14))
                    }
                }.frame(width: CGFloat(duration) * pps, height: height, alignment: .topLeading)
                .accessibilityElement(children: .contain).accessibilityLabel(T("Curba de volum"))
                .onHover { inside in
                    // Delete / ⌫ removes the selected point, unless a text field has the keyboard
                    if inside, keyMonitor.token == nil {
                        keyMonitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                            guard selected != nil, e.keyCode == 51 || e.keyCode == 117, !(NSApp.keyWindow?.firstResponder is NSText) else { return e }
                            removeSelected(); return nil
                        }
                    } else if !inside { keyMonitor.stop() }
                }
                .onDisappear { keyMonitor.stop(); escMonitor.stop() }
            }
        }
    }
}
