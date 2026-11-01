// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AVFoundation
import SadrogCore

/// One card per source, one grid (measured from the chosen direction): [icon tile] [name · kind · key value (· notes)] [preview 150][configuration 116][switch + Activ/Oprit][more].
/// Wide: the columns sit on one line and `side` (camera picture, level meter) hangs under the buttons. Narrow: the buttons and `side` move under the name, same order, same sizes.
/// Each control carries its own tooltip and accessibility label; the card itself has none, so hovering a control explains that control.
struct SourceRow<Title: View, Primary: View, Detail: View>: View {
    let symbol: String
    var enabled: Binding<Bool>? = nil
    var toggleLocked = false
    var dimmed = false
    var principal = false
    var subtitle = ""
    var subtitleTone: Color = Theme.C.textFaint
    var hasDetail = false
    var preview: AnyView? = nil
    var config: AnyView? = nil
    var more: AnyView? = nil
    var extra: AnyView? = nil
    var side: AnyView? = nil
    var notes: AnyView? = nil
    @State private var open = false
    @ViewBuilder var title: Title
    @ViewBuilder var primary: Primary
    @ViewBuilder var detail: Detail

    private var names: some View {
        VStack(alignment: .leading, spacing: 0) {
            title
            if !subtitle.isEmpty { Text(subtitle).font(CM.small).foregroundStyle(subtitleTone == Theme.C.textFaint ? Theme.C.textDim : subtitleTone).lineLimit(2).padding(.top, 2) }
            HStack(spacing: 18) {
                primary
                if hasDetail {
                    Button { withAnimation(.easeOut(duration: 0.12)) { open.toggle() } } label: {
                        HStack(spacing: 4) { Text(T("Detalii rezoluție")); Image(systemName: open ? "chevron.down" : "info.circle").font(Theme.F.iconSmall) }.font(CM.small).contentShape(Rectangle())
                    }.buttonStyle(.plain).foregroundStyle(Theme.C.textDim)
                        .help(open ? T("Ascunde detaliile") : T("Arată detaliile (dimensiuni, canale)")).accessibilityLabel(open ? T("Ascunde detaliile") : T("Arată detaliile"))
                }
            }.padding(.top, 14)
            if let notes { notes.padding(.top, 10) }
        }.opacity(dimmed ? 0.6 : 1).frame(minWidth: 190, maxWidth: .infinity, alignment: .leading)
    }
    private var include: some View {
        Group {
            if principal { Chip(text: T("Principală"), tone: .neutral).help(T("Sursa principală a înregistrării: ceasul comun și fișierul de bază; nu poate fi oprită")) }
            else if let e = enabled {
                HStack(spacing: 10) {
                    Toggle("", isOn: e).toggleStyle(CMSwitchStyle()).labelsHidden().disabled(toggleLocked)
                        .help(e.wrappedValue ? T("Activ: sursa se înregistrează") : T("Oprit: sursa rămâne în listă, dar nu se înregistrează")).accessibilityLabel(T("Includere în înregistrare"))
                        .accessibilityValue(e.wrappedValue ? T("Activ") : T("Oprit"))
                    Text(e.wrappedValue ? T("Activ") : T("Oprit")).font(CM.small).foregroundStyle(e.wrappedValue ? Theme.C.text : Theme.C.textFaint).accessibilityHidden(true)
                }
            } else { Color.clear }
        }.frame(width: 98, alignment: .leading)
    }
    private var menuCol: some View { Group { if let more { more } else { Color.clear } }.frame(width: 26, height: 26) }
    private var controls: some View {
        HStack(spacing: 0) {
            Group { if let preview { preview } else { Color.clear } }.frame(width: CM.previewW, alignment: .trailing)
            Group { if let config { config.padding(.leading, 12) } else { Color.clear } }.frame(width: CM.configW + 12, alignment: .trailing)
            include.padding(.leading, 24)
            menuCol.padding(.leading, 6)
        }.frame(height: CM.buttonHeight)
    }
    private var wide: some View {
        HStack(alignment: .top, spacing: 19) {
            CMSourceIcon(symbol: symbol, dimmed: dimmed).padding(.top, 1)
            names.padding(.top, -1)
            VStack(alignment: .leading, spacing: 17) { controls; if let side { side } }.padding(.top, 2)
        }
    }
    private var narrow: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) { CMSourceIcon(symbol: symbol, dimmed: dimmed); names; menuCol }
            if preview != nil || config != nil { HStack(spacing: 12) { if let preview { preview }; if let config { config }; Spacer(minLength: 0) }.padding(.leading, 62) }
            include.padding(.leading, 62)
            if let side { side.padding(.leading, 62) }
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ViewThatFits(in: .horizontal) { wide; narrow }
            if let extra { extra.padding(.leading, 67).padding(.top, 10).frame(maxWidth: .infinity, alignment: .leading) }
            if open && hasDetail { detail.padding(.leading, 67).padding(.top, 12).frame(maxWidth: .infinity, alignment: .leading) }
        }
        .padding(.leading, 18).padding(.trailing, 18).padding(.top, 20).padding(.bottom, 20).frame(minHeight: 120, alignment: .top)
        .cmCard()
    }
}

/// A text button for a row column (preview, size, format, channels): same size and material everywhere; the tooltip names what it does.
struct RowTextButton: View {
    let title: String; var symbol: String? = nil; var active = false; var help: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) { if let symbol { Image(systemName: symbol).font(.system(size: 13)) }; Text(title).lineLimit(1) }.frame(maxWidth: .infinity)
        }.buttonStyle(CMButtonStyle(width: CM.previewW, active: active)).help(help).accessibilityLabel(help)
    }
}

/// A menu button for a row column, with a visible disclosure arrow; the label is the current choice.
struct RowMenuButton<Items: View>: View {
    let title: String; var symbol: String? = nil; var help: String; var disabled = false
    @ViewBuilder var items: Items
    var body: some View {
        Menu { items } label: {
            HStack(spacing: 6) { if let symbol { Image(systemName: symbol).font(.system(size: 13)) }; Text(title).font(CM.button).lineLimit(1); Image(systemName: "chevron.down").font(Theme.F.glyph) }
        }.menuStyle(.button).buttonStyle(CMButtonStyle(width: CM.configW, hPad: 8)).menuIndicator(.hidden).fixedSize().disabled(disabled).help(help).accessibilityLabel(help).accessibilityValue(title)
    }
}

/// Peak meter with its numbers: a bar in dBFS (−60…0), the held peak as text with the unit, a state word and a clipping flag that stays until cleared.
/// Colour is never the only carrier: the zone is also written.
struct LevelReadout: View {
    let reading: MeterReading?
    let live: Bool
    var onClearClip: () -> Void = {}
    private static let okPos = CGFloat(AudioLevelMath.position(peak: powf(10, AudioLevelMath.okLimit / 20)))
    private static let hotPos = CGFloat(AudioLevelMath.position(peak: powf(10, AudioLevelMath.hotLimit / 20)))
    private var peak: Float { live ? (reading?.heldPeak ?? 0) : 0 }
    private var zone: AudioLevelMath.Zone { AudioLevelMath.zone(peak: peak) }
    private var zoneColor: Color { switch zone { case .silent: return Theme.C.textFaint; case .ok: return Theme.C.ok; case .high: return Theme.C.warn; case .hot, .clip: return Theme.C.record } }
    private var zoneText: String {
        if !live { return T("Nivel oprit") }
        switch zone { case .silent: return T("Fără semnal"); case .ok: return T("Normal"); case .high: return T("Ridicat"); case .hot: return T("Aproape de limită"); case .clip: return T("Clipping") }
    }
    private static let segments = 38
    /// Wide: 38 segments (335 pt track). Narrow cards: 20 segments, same colours and thresholds.
    var body: some View { ViewThatFits(in: .horizontal) { meter(Self.segments); meter(20) } }
    @ViewBuilder private func meter(_ segments: Int) -> some View {
        let trackW = CGFloat(segments) * 8.7 + 6
        let pos = live ? CGFloat(AudioLevelMath.position(peak: peak)) : 0
        let lit = live && peak > 0 ? max(1, Int((pos * CGFloat(segments)).rounded(.up))) : 0
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(T("NIVEL DE INTRARE")).font(CM.note).foregroundStyle(Theme.C.textDim)
                Text(zoneText).font(CM.note.weight(.medium)).foregroundStyle(live ? zoneColor : Theme.C.textFaint)
                Spacer(minLength: 0)
                if reading?.clipped == true {
                    Button(action: onClearClip) { Label(T("Clipping detectat — șterge"), systemImage: "exclamationmark.triangle.fill").font(CM.note.weight(.medium)).lineLimit(1).fixedSize() }
                        .buttonStyle(.plain).foregroundStyle(Theme.C.record)
                        .help(T("Vârful a atins nivelul maxim digital (0 dBFS). Semnalul poate fi distorsionat; scade câștigul sursei. Clic pentru a șterge semnalul."))
                        .accessibilityLabel(T("Clipping detectat. Clic pentru a șterge semnalul"))
                }
            }.frame(width: trackW + 93)
            HStack(spacing: 9) {
                HStack(spacing: 2.7) {
                    ForEach(0..<segments, id: \.self) { i in
                        let p = CGFloat(i) / CGFloat(segments)
                        RoundedRectangle(cornerRadius: 1, style: .continuous).fill(i < lit ? (p < Self.okPos ? CM.meterOk : (p < Self.hotPos ? CM.meterWarn : Theme.C.record)) : CM.meterOff).frame(width: 6, height: 6)
                    }
                }.padding(.horizontal, 3).frame(width: trackW, height: 12, alignment: .leading).background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(CM.meterTrack))
                Text(verbatim: live ? AudioLevelMath.readout(peak: peak) : "— dBFS").font(.system(size: 13).monospacedDigit()).foregroundStyle(live ? Theme.C.text : Theme.C.textDim).frame(width: 84, alignment: .leading)
            }
            Text(verbatim: "−60 … −18 … −3 … 0 dBFS · \(T("vârf"))").font(CM.note).foregroundStyle(Theme.C.textFaint).lineLimit(1)
        }
        .help(T("Vârful digital al semnalului în dBFS: verde până la −18, galben până la −3, roșu peste −3; la 0 dBFS apare clipping."))
        .accessibilityElement(children: .contain)
    }
}

/// AVCaptureVideoPreviewLayer host (a real camera picture; never a still stand-in).
struct CameraPreviewLayerView: NSViewRepresentable {
    let session: AVCaptureSession
    final class V: NSView {
        let layerX = AVCaptureVideoPreviewLayer()
        override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true; layer = CALayer(); layerX.videoGravity = .resizeAspect; layer?.addSublayer(layerX) }
        required init?(coder: NSCoder) { nil }
        override func layout() { super.layout(); layerX.frame = bounds }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.layerX.session = session; return v }
    func updateNSView(_ v: V, context: Context) { if v.layerX.session !== session { v.layerX.session = session } }
}

/// The camera preview area: one of loading / live / denied / restricted / absent / failed. Never an illustration.
struct CameraPreviewBox: View {
    let state: CameraPreviewState
    let session: AVCaptureSession?
    var retry: () -> Void = {}
    var openSettings: () -> Void = {}
    var body: some View {
        ZStack {
            Rectangle().fill(CM.previewBox)
            switch state {
            case .live: if let session { CameraPreviewLayerView(session: session) }
            case .loading: VStack(spacing: 6) { ProgressView().controlSize(.small).colorScheme(.dark); Text(T("Se pornește camera…")).font(Theme.F.caption).foregroundStyle(.white.opacity(0.75)) }
            case .denied: message(T("Acces la cameră refuzat"), T("Permite accesul în Setări de sistem → Confidențialitate și securitate → Cameră."), action: (T("Deschide Setările"), openSettings))
            case .restricted: message(T("Acces la cameră restricționat"), T("O politică a sistemului nu permite folosirea camerei."), action: nil)
            case .absent: message(T("Camera lipsește"), T("Dispozitivul nu mai este conectat. Nu se folosește alt dispozitiv în loc."), action: nil)
            case .failed(let why): message(T("Previzualizarea nu a pornit"), why, action: (T("Reîncearcă"), retry))
            case .off: EmptyView()
            }
        }
        .frame(width: CM.boxW).frame(minHeight: CM.boxH).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(CM.previewStroke, lineWidth: 1))
        .accessibilityElement(children: .contain).accessibilityLabel(T("Previzualizare cameră"))
    }
    private func message(_ t: String, _ d: String, action: (String, () -> Void)?) -> some View {
        VStack(spacing: 4) {
            Image(systemName: "video.slash").font(Theme.F.iconLarge).foregroundStyle(Theme.C.warn)
            Text(t).font(Theme.F.smallMedium).foregroundStyle(.white.opacity(0.92)).multilineTextAlignment(.center)
            Text(d).font(Theme.F.small).foregroundStyle(.white.opacity(0.62)).multilineTextAlignment(.center).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let action { Button(action.0, action: action.1).buttonStyle(CMButtonStyle()) }
        }.padding(8)
    }
}

/// The large, centred "+ Add source" control and what it can add: 360×64, radius 15, graphite relief, a 34 pt disc with the plus (svg).
struct AddSourceButton<Items: View>: View {
    var disabled = false
    var forced: ControlState? = nil
    @ViewBuilder var items: Items
    var body: some View {
        VStack(spacing: 14) {
            Menu { items } label: {
                HStack(spacing: 14) {
                    ZStack { Circle().fill(CM.addDisc); Circle().strokeBorder(CM.addDiscStroke, lineWidth: 1); Image(systemName: "plus").font(.system(size: 15, weight: .semibold)) }.frame(width: 34, height: 34)
                    Text(T("Adaugă sursă")).font(.system(size: 19, weight: .semibold))
                    Image(systemName: "chevron.down").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.C.textDim)
                }
            }.menuStyle(.button).buttonStyle(CMButtonStyle(width: CM.addW, height: CM.addH, radius: CM.addRadius)).menuIndicator(.hidden).fixedSize().environment(\.forcedState, forced).disabled(disabled)
                .help(T("Adaugă un monitor, o fereastră, o cameră, un microfon sau sunetul calculatorului")).accessibilityLabel(T("Adaugă sursă"))
            Text(T("Ecran · fereastră · cameră · microfon · sunetul calculatorului")).font(CM.small).foregroundStyle(Theme.C.textDim).multilineTextAlignment(.center)
        }.frame(maxWidth: .infinity)
    }
}

/// The Record control: 342×70, radius 18, ruby vertical gradient, lit top edge, outline and a soft shadow (svg). Disabled keeps the shape, desaturated; recording shows the stop square.
struct RecordPillStyle: ButtonStyle {
    let phase: RecPhase; var compact = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.isFocused) private var focused
    @Environment(\.forcedState) private var forced
    @State private var hover = false
    func makeBody(configuration: Configuration) -> some View {
        let st: ControlState = forced ?? (!enabled ? .disabled : configuration.isPressed ? .pressed : focused ? .focus : hover ? .hover : .normal)
        RecordPillFace(phase: phase, state: st, compact: compact, label: configuration.label).onHover { hover = $0 }.contentShape(RoundedRectangle(cornerRadius: CM.recRadius, style: .continuous))
    }
}
struct RecordPillFace<L: View>: View {
    let phase: RecPhase; var state: ControlState = .normal; var compact = false; let label: L
    private var live: Bool { if case .recording = phase { return true }; if case .paused = phase { return true }; return false }
    var body: some View {
        let off = state == .disabled && !live, pressed = state == .pressed
        HStack(spacing: 18) {
            if live { RoundedRectangle(cornerRadius: 3, style: .continuous).fill(CM.rubyGlyph).frame(width: 14, height: 14).frame(width: 22, height: 22) }
            else { Circle().fill(CM.rubyGlyph).frame(width: 22, height: 22) }
            label.font(.system(size: 21, weight: .semibold))
        }
        .foregroundStyle(Color.white)
        .frame(minWidth: compact ? 300 : CM.recW, minHeight: compact ? 46 : CM.recH).padding(.horizontal, 18)
        .background(CMFace(kind: .ruby, radius: CM.recRadius, state: state))
        .shadow(color: off ? .clear : .black.opacity(pressed ? 0.15 : 0.35), radius: pressed ? 8 : 16, y: pressed ? 4 : 10)
        .scaleEffect(pressed ? 0.99 : 1).animation(.easeOut(duration: 0.1), value: pressed)
    }
}
