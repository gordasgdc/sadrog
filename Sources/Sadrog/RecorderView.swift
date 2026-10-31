// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import SadrogCore

/// Start window: capture preparation and edit-document setup are separate pages of one compact window (sized to its content, resizable).
/// The editor replaces it in the same window and grows it; coming back restores the compact size.
struct RecorderView: View {
    @ObservedObject var m: RecorderModel
    /// Interface language: changing it re-renders every view below at once (no restart).
    @AppStorage("sadrog.language") private var language = AppLanguage.current.rawValue

    var body: some View {
        Group {
            if let e = m.editor { EditorView(m: e, addRecording: { m.beginAddRecording() }) { m.editor = nil; m.updateDestination() }.frame(minWidth: 900, minHeight: 620) }
            else { StartView(m: m).frame(minWidth: 680, minHeight: 500).background(StartWindowSizer()) }
        }
        .background(Theme.C.bg0).appTheme().id(language)
    }
}

enum StartPage: String, CaseIterable, Identifiable {
    case record, document, recent, permissions, activation
    var id: String { rawValue }
    var title: String { switch self { case .record: return T("Înregistrare nouă"); case .document: return T("Document nou"); case .recent: return T("Recente"); case .permissions: return T("Permisiuni"); case .activation: return T("Activare") } }
    var symbol: String { switch self { case .record: return "record.circle"; case .document: return "doc.badge.plus"; case .recent: return "clock"; case .permissions: return "lock.shield"; case .activation: return "key" } }
}

/// Brings the window back to a compact start size (880×640 pt content) when it is much larger, e.g. after the editor; never enlarges it.
struct StartWindowSizer: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async {
                if let e = ProcessInfo.processInfo.environment["SADROG_START_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), e.count == 2 { w.setContentSize(NSSize(width: e[0], height: e[1])); w.center(); return }
                let cur = w.contentRect(forFrameRect: w.frame).size
                guard cur.width > 820 || cur.height > 620 else { return }
                w.setContentSize(NSSize(width: min(cur.width, 740), height: min(cur.height, 560))); w.center()
            }
        }
    }
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ v: Probe, context: Context) {}
}

struct StartView: View {
    @ObservedObject var m: RecorderModel
    @ObservedObject private var act = ActivationModel.shared
    @ObservedObject private var updates = UpdateChecker.shared
    @State private var page: StartPage = .record
    @State private var docName = T("Proiect nou")
    @State private var showSizeDetail = false
    @State private var docW: Double = 1920
    @State private var docH: Double = 1080
    @State private var docFps: Double = 30
    private let labelW: CGFloat = 104

    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: 196)
            HairlineDivider(vertical: true)
            VStack(spacing: 0) {
                switch page {
                case .record: recordPage
                case .document: documentPage
                case .recent: recentPage
                case .permissions: permissionsPage
                case .activation: ActivationPage()
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.C.bg0)
        }
        .task { m.observeProbeGuard(); if let r = m.requestedPage, let pg = StartPage(rawValue: r) { page = pg; m.requestedPage = nil }; await m.refresh(); await m.openRequestedProject() }
        // coming back to SADROG (from the window you want to record, for instance) refreshes the list; nothing starts
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in if m.phase == .idle { Task { await m.refresh() } } }
        .onChange(of: page) { _, p in if p != .record { m.leaveContext() } }    // preview / identify / meters belong to the capture page only
        .onDisappear { m.leaveContext() }
    }

    // MARK: sidebar
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                LogoMark().frame(width: 26, height: 16).foregroundStyle(Theme.C.text)
                Text(T("SADROG")).font(.system(size: 13, weight: .semibold)).tracking(1.0).foregroundStyle(Theme.C.text)
            }.padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 16)
            ForEach([StartPage.record, .document, .recent], id: \.self) { sideItem($0) }
            Spacer()
            sideItem(.activation, badge: act.allowsRecordAndExport ? nil : Theme.C.warn)
            sideItem(.permissions, badge: m.hasPermission ? nil : Theme.C.warn)
            if case .available(let u) = updates.status {
                Button(L10n.f("Versiune nouă: %@", u.version)) { updates.present(u) }.buttonStyle(.gloss(.primary, compact: true)).padding(.horizontal, 14)
            }
            HStack(spacing: 6) {
                Button { updates.checkManually() } label: { Image(systemName: "arrow.triangle.2.circlepath") }.buttonStyle(.plain).foregroundStyle(Theme.C.textFaint)
                    .help(T("Caută actualizări")).accessibilityLabel(T("Caută actualizări")).disabled(updates.status == .checking)
                Text(verbatim: "\(AppInfo.version) · build \(AppInfo.build)").font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(1).fixedSize()
                Spacer(minLength: 2)
                LanguagePicker()
            }.padding(.horizontal, 14).padding(.vertical, 8)
        }.frame(maxHeight: .infinity, alignment: .top).background(Theme.C.bg1)
    }
    private func sideItem(_ p: StartPage, badge: Color? = nil) -> some View {
        Button { page = p } label: {
            HStack(spacing: 9) {
                Image(systemName: p.symbol).font(Theme.F.icon).frame(width: 18)
                Text(p.title).font(Theme.F.body)
                Spacer(minLength: 0)
                if let b = badge { Circle().fill(b).frame(width: 7, height: 7) }
            }
            .foregroundStyle(page == p ? Theme.C.text : Theme.C.textDim)
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(page == p ? Theme.C.bg3 : .clear))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 8)
        .accessibilityLabel(p.title).accessibilityAddTraits(page == p ? .isSelected : [])
    }

    // MARK: shared layout
    private func section<C: View>(_ title: String, trailing: AnyView? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { SectionLabel(title); Spacer(); if let t = trailing { t } }
            c()
        }
    }
    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(label).font(Theme.F.body).foregroundStyle(Theme.C.textDim).frame(width: labelW, alignment: .trailing)
            c().frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func pageScroll<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: 22) { c() }.padding(.horizontal, 24).padding(.vertical, 22).frame(maxWidth: 560, alignment: .leading).frame(maxWidth: .infinity) }
    }

    // MARK: record page
    /// After a recording ends: where does it go? Every choice keeps the recording on disk; "keep in Recent" only closes this card.
    @ViewBuilder private var finishedCard: some View {
        if let f = m.finished {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.C.ok)
                    Text(T("Înregistrare salvată")).font(Theme.F.smallMedium).foregroundStyle(Theme.C.text)
                    Text("\(CaptureControlText.clock(f.duration)) · \(f.journal.width)×\(f.journal.height)").font(Theme.F.monoSmall).foregroundStyle(Theme.C.textDim)
                    Spacer()
                }
                row(T("Nume document")) { AppTextField(placeholder: T("Nume"), text: $m.finishName).frame(maxWidth: 320) }
                HStack(spacing: 8) {
                    Button(T("Document nou cu această înregistrare")) { Task { await m.finishIntoNewDocument() } }.buttonStyle(.gloss(.primary, compact: true))
                    Menu(T("Adaugă la un proiect existent")) {
                        ForEach(Array(m.documents.prefix(8).enumerated()), id: \.element.folder) { _, d in Button(d.name) { Task { await m.finishIntoProject(d.folder) } } }
                        if !m.documents.isEmpty { Divider() }
                        Button(T("Alt proiect…")) { Task { await m.finishIntoOtherProject() } }
                    }.menuStyle(.borderlessButton).fixedSize()
                    Spacer()
                    Button(T("Păstrează în Recente")) { m.dismissFinished() }.buttonStyle(.gloss(.ghost, compact: true)).help(T("Înregistrarea rămâne pe disc; o găsești în Recente"))
                }
            }.padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.C.ok.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Theme.C.ok.opacity(0.25), lineWidth: 0.7))
        }
    }

    private var recordPage: some View {
        VStack(spacing: 0) {
            pageScroll {
                if let t = m.addTarget {
                    Notice(symbol: "plus.rectangle.on.rectangle", text: L10n.f("Înregistrarea se adaugă în «%@», la sfârșitul proiectului. Proiectul rămâne salvat.", t.editor.project.name), action: T("Înapoi la editor")) { m.cancelAddRecording() }
                }
                PageHeader(title: T("Înregistrare nouă"), subtitle: recordContext, tone: m.canRecord ? Theme.C.ok : Theme.C.textFaint)
                finishedCard
                if !m.hasPermission { Notice(symbol: "lock.shield", text: T("Lipsește permisiunea „Înregistrare ecran”."), action: T("Permisiuni…")) { page = .permissions } }
                else if !act.allowsRecordAndExport { Notice(symbol: "key", text: T("Înregistrarea și exportul cer activare. Editarea rămâne liberă."), action: T("Activare")) { page = .activation } }
                sourcesSection
                if !m.unfinished.isEmpty { unfinishedSection }
            }
            recordBar
        }
    }

    /// What the next recording would contain, in one line (also the state: ready / why not).
    private var recordContext: String {
        let video = (m.selectedSource != nil ? 1 : 0) + m.extraScreens.count + m.cameraRows.count
        let audio = m.audio.filter { $0.enabled }.count
        let what = L10n.f("%@ video · %@ audio", "\(video)", "\(audio)")
        if m.canRecord { return what + " · " + T("gata de înregistrare") }
        if !m.hasPermission { return what + " · " + T("permisiune lipsă") }
        if !ActivationModel.shared.allowsRecordAndExport { return what + " · " + T("înregistrarea cere activare") }
        return what
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { SectionLabel(T("Surse")); Spacer(); addSourceMenu }
            SourceList {
                mainVideoRow
                ForEach(m.extraScreens) { ExtraScreenRowView(m: m, r: $0) }
                ForEach(m.cameraRows) { CameraRowView(m: m, r: $0) }
                ForEach(m.audio) { audioRow($0) }
                if m.extraScreens.isEmpty && m.cameraRows.isEmpty && m.audio.isEmpty { quickAdd }
            }
        }
    }

    /// Empty list: the three most common additions as direct actions (the menu above has everything).
    private var quickAdd: some View {
        HStack(spacing: 8) {
            Button { m.addExtraScreen(.window) } label: { Label(T("Fereastră"), systemImage: "macwindow") }
            Button { m.addCameraRow() } label: { Label(T("Cameră"), systemImage: "video") }.disabled(m.cameras.isEmpty)
            Button { m.addSystemAudio() } label: { Label(T("Sunetul calculatorului"), systemImage: "speaker.wave.2") }
            Spacer(minLength: 0)
        }.buttonStyle(.gloss(.ghost, compact: true)).disabled(m.phase != .idle).padding(.horizontal, 8).padding(.vertical, 8)
    }

    private var mainKindName: String { m.mode == .window ? T("Fereastră") : (m.mode == .region ? T("Regiune") : T("Monitor")) }
    private var mainSubtitle: String {
        var parts = [mainKindName]
        if let z = m.sizes { parts.append("\(z.src.w)×\(z.src.h) px") }
        if m.restoredDisplay, m.mode != .window, m.displayID != nil { parts.append(T("ultima folosită")) }
        return parts.joined(separator: " · ")
    }
    private var mainVideoRow: some View {
        let list = m.mode == .window ? m.windows : m.displays
        let current = m.mode == .window ? m.windowID : m.displayID
        let title = list.first { $0.id == current }?.title ?? (m.selectedSource?.title ?? (m.mode == .window ? T("Alege fereastra…") : T("Alege monitorul…")))
        return SourceRow(symbol: m.mode == .window ? "macwindow" : (m.mode == .region ? "rectangle.dashed" : "display"), subtitle: mainSubtitle, hasDetail: true) {
            SourceMenu(title: title, placeholder: m.selectedSource == nil, items: list.map { (String($0.id), $0.title, $0.id == current) }, disabled: m.phase != .idle,
                       onHover: m.mode == .region ? nil : { id in m.previewCandidate(id.flatMap(UInt32.init)) }) { id in
                let v = UInt32(id)
                if m.mode == .window { m.windowID = v } else { m.displayID = v }
            }
        } actions: {
            IconButton(symbol: "scope", label: T("Identifică: ramă roșie pe sursă timp de 2 s (nu intră în înregistrare)")) { m.identify() }.disabled(m.selectedSource == nil || m.phase != .idle).accessibilityIdentifier("sadrog.identify")
            IconButton(symbol: m.previewOn ? "eye.fill" : "eye", label: m.previewOn ? T("Oprește previzualizarea") : T("Previzualizare (imagini statice; nu înregistrează)"), active: m.previewOn) { m.previewOn.toggle() }.disabled(m.selectedSource == nil)
                .popover(isPresented: $m.previewOn, arrowEdge: .bottom) {
                    if let img = m.previewImage { Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 380, maxHeight: 240).padding(8) } else { ProgressView().padding(24) }
                }
        } detail: {
            VStack(alignment: .leading, spacing: 10) {
                Picker(T("Captură"), selection: $m.mode) { Text(T("Monitor")).tag(VideoMode.display); Text(T("Fereastră")).tag(VideoMode.window); Text(T("Regiune")).tag(VideoMode.region) }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 250).disabled(m.phase != .idle)
                if m.mode == .region {
                    HStack(spacing: 8) {
                        Button(m.regionSpec == nil ? T("Trasează regiunea…") : T("Retrasează…")) { m.drawRegion() }.buttonStyle(.gloss(.secondary, compact: true)).disabled(m.displayID == nil || m.phase != .idle)
                        if m.regionSpec == nil { Text(T("Trage pe monitor, în orice direcție; Esc anulează.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
                    }
                }
                if let s = m.selectedSource, let z = m.sizes { sizeRows(s, z) }
                if m.restoredDisplay, m.mode != .window, m.displayID != nil {
                    Text(T("Monitorul folosit data trecută. Nimic nu se înregistrează sau monitorizează până nu pornești tu.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Source size, physical panel and capture-file size, each named for what it is (points ≠ pixels; the backing store of a scaled mode ≠ the panel).
    @ViewBuilder private func sizeRows(_ s: SourceInfo, _ z: (src: (w: Int, h: Int), out: (w: Int, h: Int))) -> some View {
        row(T("Sursa")) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(verbatim: sourcePoints(s).map { "\($0) · \(z.src.w)×\(z.src.h) px" } ?? "\(z.src.w)×\(z.src.h) px").font(Theme.F.mono)
                    Button { showSizeDetail.toggle() } label: { Image(systemName: showSizeDetail ? "info.circle.fill" : "info.circle").font(Theme.F.iconSmall).foregroundStyle(Theme.C.textFaint).frame(width: 24, height: 22).contentShape(Rectangle()) }
                        .buttonStyle(.plain).help(showSizeDetail ? T("Ascunde detaliile") : T("Detalii: puncte, scară și panoul fizic")).accessibilityLabel(T("Detalii rezoluție"))
                }
                if showSizeDetail { Text(sourceDetail(s)).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true) }
            }
        }
        row(T("Fișier captură")) {
            HStack(spacing: 8) {
                Picker(T("Fișier captură"), selection: $m.outCap) {
                    Text(T("1:1 cu sursa")).tag(RecorderModel.OutCap.source)
                    if s.panelWidth > 0, m.mode != .window { Text(verbatim: "Panoul fizic (\(s.panelWidth)×\(s.panelHeight))").tag(RecorderModel.OutCap.panel) }
                    Text(T("Maxim 1920 px")).tag(RecorderModel.OutCap.hd)
                }.labelsHidden().fixedSize().disabled(m.phase != .idle)
                Text(verbatim: "→ \(z.out.w)×\(z.out.h) px").font(Theme.F.mono).foregroundStyle(Theme.C.text)
            }
        }
    }
    /// Size of the source in logical points (window or region), shown next to its pixels; nil for a whole monitor (its points are in the detail).
    private func sourcePoints(_ s: SourceInfo) -> String? {
        if m.mode == .window { return "\(s.width)×\(s.height) pt" }
        if m.mode == .region, let r = m.regionSpec, r.isValid { let q = RegionMath.sourceRect(r, displayPoints: CGSize(width: s.pointsWidth, height: s.pointsHeight)); return "\(Int(q.width))×\(Int(q.height)) pt" }
        return nil
    }
    private func sourceDetail(_ s: SourceInfo) -> String {
        let pts = m.mode == .window ? "\(s.width)×\(s.height) pt" : "\(Int(s.pointsWidth))×\(Int(s.pointsHeight)) pt"
        var t = L10n.f("%@%@ la scara %@× (pixeli de randare macOS)", "\(m.mode == .region ? "regiune pe " : "")", "\(pts)", "\(String(format: "%g", s.scale))")
        if m.mode != .window, s.panelWidth > 0 {
            t += s.panelWidth == s.pixels.w ? T(" · panoul fizic are aceeași rezoluție") : L10n.f(" · panoul fizic: %@×%@ px (mod nativ raportat de macOS)", "\(s.panelWidth)", "\(s.panelHeight)")
        }
        return t
    }

    private var audioSection: some View {
        section(T("Audio")) {
            if m.audio.isEmpty {
                Text(T("Fără sunet. Adaugă sunetul calculatorului, un microfon sau canalele unui echipament extern; fiecare sursă devine o pistă separată în editor."))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) { ForEach(m.audio) { a in audioRow(a); if a.id != m.audio.last?.id { HairlineDivider().opacity(0.6) } } }
            if let b = m.blocker, m.phase == .idle, m.video != nil || !m.audio.isEmpty, m.destination != nil, m.hasPermission { Text(b).font(Theme.F.caption).foregroundStyle(Theme.C.warn) }
        }
    }
    /// One menu for every kind of source, usable again and again.
    private var addSourceMenu: some View {
        Menu {
            Section(T("Video")) {
                Button { m.addExtraScreen(.display) } label: { Label(T("Monitor"), systemImage: "display") }
                Button { m.addExtraScreen(.window) } label: { Label(T("Fereastră"), systemImage: "macwindow") }
                Button { m.addCameraRow() } label: { Label(T("Cameră sau dispozitiv video"), systemImage: "video") }.disabled(m.cameras.isEmpty)
            }
            Section(T("Audio")) {
                Button { m.addSystemAudio() } label: { Label(T("Sunetul calculatorului"), systemImage: "speaker.wave.2") }.disabled(m.audio.contains { $0.kind == .system })
                ForEach(m.devices, id: \.uid) { d in
                    Button("\(d.name) — \(d.inputChannels == 1 ? "mono" : "\(d.inputChannels) canale")") { m.addInput(d) }
                    if d.inputChannels > 2 { Button(L10n.f("%@ — fiecare canal pe pistă separată (%@)", "\(d.name)", "\(d.inputChannels)")) { m.addInputSplit(d) } }
                }
                if m.devices.isEmpty { Text(T("Nicio intrare audio detectată")) }
            }
        } label: { Label(T("Adaugă sursă"), systemImage: "plus").font(Theme.F.body.weight(.medium)) }
        .menuStyle(.button).buttonStyle(.gloss(.secondary, compact: true)).menuIndicator(.hidden).fixedSize().disabled(m.phase != .idle).accessibilityLabel(T("Adaugă sursă"))
    }
    private func audioRow(_ a: AudioSourceSpec) -> some View {
        let dev = m.devices.first { $0.uid == a.deviceUID }
        let multi = a.kind == .input && (dev?.inputChannels ?? 0) > 1 && (a.channels.count != 1 || !a.deviceName.contains("· canal"))
        var sub = a.kind == .system ? T("Sunetul aplicațiilor · stereo") : L10n.f("Canale %@ din %@", "\(a.channels.map(String.init).joined(separator: ", "))", "\(dev?.inputChannels ?? 0)")
        var tone = Theme.C.textFaint
        if let w = m.lost[a.id] { sub = L10n.f("%@. Nu se folosește alt dispozitiv în loc.", "\(w)"); tone = Theme.C.warn }
        else if a.kind == .input && m.micAuth == .denied { sub = T("Acces la microfon refuzat (Setări → Confidențialitate și securitate)."); tone = Theme.C.warn }
        return SourceRow(symbol: a.kind == .system ? "speaker.wave.2" : "mic", enabled: Binding(get: { a.enabled }, set: { m.setEnabled(a.id, $0) }), toggleLocked: m.phase != .idle, dimmed: !a.enabled, subtitle: sub, subtitleTone: tone, hasDetail: multi) {
            Text(a.deviceName).font(Theme.F.body.weight(.medium)).foregroundStyle(Theme.C.text).lineLimit(1)
        } actions: {
            LevelMeter(level: m.levels[a.id] ?? 0, live: m.monitoring.contains(a.id) || m.phase == .recording).frame(width: 84, height: 5)
            IconButton(symbol: m.monitoring.contains(a.id) ? "waveform.circle.fill" : "waveform.circle", label: m.monitoring.contains(a.id) ? T("Oprește afișarea nivelului") : T("Arată nivelul real (fără redare pe difuzoare)"), active: m.monitoring.contains(a.id)) { m.toggleMonitor(a.id) }
            RowMenu { Button(role: .destructive) { m.remove(a.id) } label: { Label(T("Elimină sursa"), systemImage: "trash") }.disabled(m.phase != .idle) }
        } detail: {
            if let d = dev {
                HStack(spacing: 3) {
                    Text(T("Canale")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).padding(.trailing, 4)
                    ForEach(1...min(d.inputChannels, 16), id: \.self) { c in
                        let on = a.channels.contains(c)
                        Button("\(c)") { m.toggleChannel(a.id, c) }.buttonStyle(.plain).font(Theme.F.monoSmall).frame(width: 22, height: 18)
                            .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.C.accent.opacity(0.85) : Theme.C.field)).foregroundStyle(on ? Theme.C.accentInk : Theme.C.textDim)
                            .disabled(m.phase != .idle).accessibilityLabel("Canal \(c)").accessibilityValue(on ? "ales" : "neales")
                    }
                }
            }
        }
    }

    private var unfinishedSection: some View {
        section(T("Sesiuni neterminate")) {
            ForEach(m.unfinished, id: \.id) { j in
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.C.warn); Text("\(j.startedAt.formatted()) · \(j.width)×\(j.height)").font(Theme.F.body); Spacer()
                    Button(T("Verifică și recuperează")) { Task { await m.recover(j) } }.buttonStyle(.gloss(.secondary, compact: true)) }
            }
        }
    }

    private var recordBar: some View {
        HStack(spacing: 14) {
            Button { Task { await m.toggle() } } label: { Color.clear.frame(width: 60, height: 60) }
                .buttonStyle(RecordButtonStyle(phase: m.phase)).keyboardShortcut(.return)
                .disabled(m.phase == .idle && !m.canRecord || m.phase == .stopping || m.phase == .starting)
                .help(m.phase == .idle ? T("Înregistrează (↩)") : T("Oprește"))
                .accessibilityIdentifier("sadrog.record").accessibilityValue(phaseName)
            VStack(alignment: .leading, spacing: 2) {
                Text(timeString(m.elapsed)).font(.system(size: 22, weight: .light, design: .monospaced)).foregroundStyle(m.recording ? Theme.C.text : Theme.C.textDim).lineLimit(1).fixedSize()
                statusLine
            }
            if m.simulatedCapture {
                ViewThatFits(in: .horizontal) {         // the full notice when there is room, the short one otherwise: the timer never wraps
                    Chip(text: T("SIMULARE — nu se înregistrează"), tone: .warn).fixedSize()
                    Chip(text: T("SIMULARE"), tone: .warn).fixedSize()
                }.accessibilityIdentifier("sadrog.simulated")
            }
            Spacer(minLength: 6)
            if m.phase == .recording || m.phase == .paused {
                Button { m.togglePause() } label: { Label(m.phase == .paused ? "Reia" : T("Pauză"), systemImage: m.phase == .paused ? "play.fill" : "pause.fill") }
                    .buttonStyle(.gloss(.secondary, compact: true)).fixedSize().keyboardShortcut("p", modifiers: [.command, .shift])
                    .help(T("Pauză sau reluare pentru TOATE sursele în același moment (⇧⌘P)"))
            }
            if m.phase == .idle {
                HStack(spacing: 4) {
                    Image(systemName: "timer").font(Theme.F.iconSmall).foregroundStyle(Theme.C.textFaint)
                    Picker("", selection: $m.countdownSeconds) { ForEach([0, 3, 5, 10, 15], id: \.self) { Text($0 == 0 ? T("fără") : "\($0) s").tag($0) } }
                        .labelsHidden().pickerStyle(.menu).fixedSize().accessibilityLabel(T("Numărătoare"))
                }.help(T("Numărătoare înainte de start"))
            }
            destinationButton
        }
        .padding(.horizontal, 18).frame(height: 80).background(Theme.C.bg1).overlay(alignment: .top) { HairlineDivider().opacity(0.6) }
    }
    /// Where recordings go and how much room is left: a compact summary, the full path on hover, the folder panel on click.
    private var destinationButton: some View {
        Button { m.chooseDestination() } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(Theme.F.icon).foregroundStyle(m.destination == nil ? Theme.C.warn : Theme.C.textDim)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.destination?.lastPathComponent ?? T("Destinație nealeasă")).font(Theme.F.body).lineLimit(1).truncationMode(.middle).foregroundStyle(m.destination == nil ? Theme.C.warn : Theme.C.text)
                    if let f = m.freeGB { Text(L10n.f("%.0f GB liberi", f)).font(Theme.F.caption).foregroundStyle(f < 10 ? Theme.C.warn : Theme.C.textFaint) }
                }
            }
            .padding(.horizontal, 10).frame(maxWidth: 190, minHeight: 40, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.C.bg2)).contentShape(Rectangle())
        }.buttonStyle(.plain).disabled(m.recording)
        .help((m.destination?.path ?? T("Alege folderul în care se salvează înregistrările")) + " — " + T("Schimbă…"))
        .accessibilityLabel(T("Destinația înregistrărilor"))
    }
    /// Current state of the Record button for accessibility (checked before acting on it).
    private var phaseName: String { switch m.phase { case .idle: return T("repaus"); case .preparing: return T("pregătire"); case .countdown(let n): return L10n.f("numărătoare %@", "\(n)"); case .starting: return T("pornire"); case .recording: return T("înregistrare"); case .paused: return T("pauză"); case .stopping: return T("salvare") } }
    @ViewBuilder private var statusLine: some View {
        switch m.phase {
        case .recording: Label(T("Se înregistrează"), systemImage: "record.circle.fill").font(Theme.F.body).foregroundStyle(Theme.C.record)
        case .paused: Label(T("În pauză — toate sursele"), systemImage: "pause.circle").font(Theme.F.body).foregroundStyle(Theme.C.warn)
        case .countdown(let n): Text(L10n.f("Pornește în %@ s…", "\(n)")).font(Theme.F.body).foregroundStyle(Theme.C.warn)
        case .stopping: Text(T("Se salvează…")).font(Theme.F.body).foregroundStyle(Theme.C.textDim)
        case .preparing: Text(m.preparingCameras ? T("Se pregătesc camerele… (clic din nou anulează)") : T("Se verifică sursele… (clic din nou anulează)")).font(Theme.F.body).foregroundStyle(Theme.C.textDim)
        case .starting: Text(T("Pornește…")).font(Theme.F.body).foregroundStyle(Theme.C.warn)
        case .idle:
            if !m.message.isEmpty { Text(m.message).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).lineLimit(1) }
            else if !ActivationModel.shared.allowsRecordAndExport { Text(T("Indisponibilă")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).lineLimit(1) }
            else if let b = m.blocker { Text(b).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(1) }
            else { Text(T("Gata de înregistrare")).font(Theme.F.caption).foregroundStyle(Theme.C.ok) }
        }
    }

    // MARK: document page
    private var docFormat: DocumentFormat { DocumentFormat(width: Int(docW), height: Int(docH), fps: docFps) }
    private var documentPage: some View {
        VStack(spacing: 0) {
            pageScroll {
                section(T("Document de montaj")) {
                    Text(T("Dimensiunea și cadența documentului se aplică previzualizării și exportului. Nu depind de mărimea ferestrei sau de zoomul previzualizării; înregistrările se încadrează în document."))
                        .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                    row(T("Nume")) { AppTextField(placeholder: T("Nume"), text: $docName).frame(maxWidth: 300) }
                    row(T("Preset")) {
                        Picker(T("Preset"), selection: Binding(get: { docFormat.preset?.id ?? "custom" }, set: { id in if let p = DocumentFormat.presets.first(where: { $0.id == id }) { docW = Double(p.width); docH = Double(p.height) } })) {
                            ForEach(DocumentFormat.presets) { p in Text(verbatim: "\(p.name) · \(p.width)×\(p.height)").tag(p.id) }
                            if docFormat.preset == nil { Divider(); Text(T("Personalizat")).tag("custom") }
                        }.labelsHidden().fixedSize()
                    }
                    row(T("Lățime")) { ScrubField(label: T("Lățime"), unit: "px", range: 16...8192, value: $docW, width: 52, step: 2, perPoint: 4) {}.fixedSize() }
                    row(T("Înălțime")) { ScrubField(label: T("Înălțime"), unit: "px", range: 16...8192, value: $docH, width: 52, step: 2, perPoint: 4) {}.fixedSize() }
                    row(T("Proporții")) {
                        HStack(spacing: 8) {
                            Text(docFormat.aspect).font(Theme.F.mono)
                            Button { (docW, docH) = (docH, docW) } label: { Label(T("Inversează"), systemImage: "arrow.left.arrow.right") }.buttonStyle(.gloss(.ghost, compact: true)).help(T("Orizontal ↔ vertical"))
                        }
                    }
                    row(T("Cadre/s")) {
                        Picker(T("Cadre pe secundă"), selection: $docFps) { ForEach(DocumentFormat.frameRates, id: \.self) { Text($0.formatted()).tag($0) } }.labelsHidden().fixedSize()
                    }
                    row(T("Se salvează în")) { Text(m.destination?.path ?? T("alege folderul în «Înregistrare nouă»")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(1).truncationMode(.middle) }
                }
            }
            HStack {
                if !m.message.isEmpty { Text(m.message).font(Theme.F.caption).foregroundStyle(Theme.C.warn) }
                Spacer()
                Text(verbatim: "\(docFormat.width)×\(docFormat.height) · \(docFormat.fps.formatted()) cadre/s").font(Theme.F.mono).foregroundStyle(Theme.C.textDim)
                Button(T("Creează documentul")) { Task { await m.createDocument(name: docName, format: docFormat) } }.buttonStyle(.gloss(.primary)).disabled(m.destination == nil).keyboardShortcut(.defaultAction)
            }.padding(.horizontal, 20).frame(height: 64).background(Theme.C.bg1).overlay(alignment: .top) { HairlineDivider() }
        }
    }

    // MARK: recent page
    private var recentPage: some View {
        pageScroll {
            section(T("Înregistrări")) {
                if m.editable.isEmpty { Text(T("Nicio înregistrare în folderul de destinație.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
                VStack(spacing: 0) {
                    ForEach(Array(m.editable.enumerated()), id: \.element.journal.id) { i, e in
                        if i > 0 { HairlineDivider().opacity(0.6) }
                        recentRow(symbol: "film", title: L10n.date(e.journal.startedAt), detail: L10n.f("fișier captură %@×%@ px", "\(e.journal.width)", "\(e.journal.height)"), tag: e.journal.state == .recovered ? T("recuperată") : nil) { Task { await m.openEditor(e) } }
                    }
                }
            }
            section(T("Documente")) {
                HStack {
                    Spacer()
                    Button { m.openProjectFromDisk() } label: { Label(T("Deschide un proiect…"), systemImage: "folder") }
                        .buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                        .help(T("Deschide un proiect SADROG din orice folder (de exemplu proiectul demonstrativ al versiunii intermediare)"))
                }
                if m.documents.isEmpty { Text(T("Niciun document creat separat.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
                VStack(spacing: 0) {
                    ForEach(Array(m.documents.enumerated()), id: \.element.folder) { i, d in
                        if i > 0 { HairlineDivider().opacity(0.6) }
                        recentRow(symbol: "doc", title: d.name, detail: L10n.date(d.date), tag: nil) { Task { await m.openDocument(d.folder) } }
                    }
                }
            }
        }
    }
    private func recentRow(symbol: String, title: String, detail: String, tag: String?, open: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(Theme.C.textDim).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) { Text(title).font(Theme.F.body); Text(detail).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
            if let tag { Chip(text: tag, tone: .warn) }
            Spacer()
            Button(T("Deschide")) { open() }.buttonStyle(.gloss(.secondary, compact: true))
        }.padding(.vertical, 7)
    }

    // MARK: permissions page
    private var permissionsPage: some View {
        pageScroll {
            section(T("Permisiuni macOS")) {
                permRow(T("Înregistrare ecran"), ok: m.hasPermission, detail: m.hasPermission ? T("acordată") : T("necesară pentru orice captură; după acordare, repornește aplicația")) {
                    if !m.hasPermission { Button(T("Acordă…")) { m.requestPermission() }.buttonStyle(.gloss(.secondary, compact: true)) }
                }
                permRow(T("Microfon"), ok: m.micAuth == .authorized, detail: m.micAuth == .authorized ? T("acordată") : (m.micAuth == .denied ? T("refuzată — se schimbă din Setări de sistem") : T("se cere la prima sursă de microfon"))) { EmptyView() }
                permRow(T("Cameră"), ok: m.cameraAuth == .authorized, detail: m.cameraAuth == .authorized ? T("acordată") : T("se cere doar când alegi o cameră la înregistrare")) { EmptyView() }
            }
        }
    }
    private func permRow<C: View>(_ t: String, ok: Bool, detail: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed").foregroundStyle(ok ? Theme.C.ok : Theme.C.textFaint).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) { Text(t).font(Theme.F.body); Text(detail).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
            Spacer(); c()
        }.padding(.vertical, 6)
    }

    private func timeString(_ t: TimeInterval) -> String { String(format: "%02d:%02d:%02d", Int(t) / 3600, Int(t) / 60 % 60, Int(t) % 60) }
}

/// Peak meter driven by real samples (`live` false = meter off, drawn dimmed).
struct LevelMeter: View {
    let level: Float; let live: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.C.field)
                Capsule().fill(LinearGradient(colors: [Theme.C.ok, Theme.C.ok, Theme.C.warn, Theme.C.record], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(0, g.size.width * CGFloat(min(1, pow(max(level, 0), 0.5)))))   // sqrt scale: quiet signals stay visible
                    .opacity(live ? 1 : 0.15)
            }
        }
        .overlay(Capsule().stroke(Theme.C.line, lineWidth: 0.5))
        .accessibilityLabel(live ? T("Nivel audio") : T("Nivel audio oprit"))
    }
}

/// One additional screen: monitor or window, its real size, on/off, preview on demand, remove.
struct ExtraScreenRowView: View {
    @ObservedObject var m: RecorderModel
    let r: ExtraScreenRow
    @State private var preview: NSImage?
    @State private var showPreview = false
    private var list: [SourceInfo] { r.mode == .window ? m.windows : m.displays }
    private var chosen: SourceInfo? { list.first { $0.id == r.sourceID } }
    private func set(_ f: (inout ExtraScreenRow) -> Void) { if let i = m.extraScreens.firstIndex(where: { $0.id == r.id }) { f(&m.extraScreens[i]) } }
    var body: some View {
        SourceRow(symbol: r.mode == .window ? "macwindow" : "display", enabled: Binding(get: { r.enabled }, set: { v in set { $0.enabled = v } }), toggleLocked: m.phase != .idle, dimmed: !r.enabled,
                  subtitle: (r.mode == .window ? T("Fereastră") : T("Monitor")) + (chosen.map { " · \($0.pixels.w)×\($0.pixels.h) px" } ?? "")) {
            SourceMenu(title: chosen?.title ?? (r.mode == .window ? T("Alege fereastra…") : T("Alege monitorul…")), placeholder: chosen == nil, items: list.map { (String($0.id), $0.title, $0.id == r.sourceID) }, disabled: m.phase != .idle,
                       onHover: { id in m.previewCandidate(id.flatMap(UInt32.init), window: r.mode == .window) }) { id in set { $0.sourceID = UInt32(id) } }
        } actions: {
            IconButton(symbol: "eye", label: T("Previzualizare (o imagine, la cerere)")) {
                guard let c = chosen else { return }
                Task { if let img = await ScreenCapturer.snapshot(source: c, maxWidth: 360) { preview = NSImage(cgImage: img, size: .zero); showPreview = true } }
            }.disabled(chosen == nil)
            .popover(isPresented: $showPreview) { if let p = preview { Image(nsImage: p).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 220).padding(8) } }
            RowMenu { Button(role: .destructive) { m.removeExtraScreen(r.id) } label: { Label(T("Elimină sursa"), systemImage: "trash") }.disabled(m.phase != .idle) }
        } detail: { EmptyView() }
    }
}

/// One camera (or other compatible video device): real format, access state, on/off, remove.
struct CameraRowView: View {
    @ObservedObject var m: RecorderModel
    let r: CameraRow
    private var sub: (String, Color) {
        guard let u = r.uid else { return (T("Cameră"), Theme.C.textFaint) }
        if !m.cameras.contains(where: { $0.uid == u }) { return (T("Camera lipsește"), Theme.C.warn) }
        switch m.cameraAuth {
        case .denied, .restricted: return (T("Acces refuzat"), Theme.C.warn)
        case .authorized: return ([T("Cameră"), m.cameraFormat(u)].compactMap { $0 }.joined(separator: " · "), Theme.C.textFaint)
        default: return ([T("Cameră"), m.cameraFormat(u)].compactMap { $0 }.joined(separator: " · ") + " · " + T("acces necerut"), Theme.C.textFaint)
        }
    }
    var body: some View {
        SourceRow(symbol: "video", enabled: Binding(get: { r.enabled }, set: { v in if let i = m.cameraRows.firstIndex(where: { $0.id == r.id }) { m.cameraRows[i].enabled = v } }), toggleLocked: m.phase != .idle, dimmed: !r.enabled, subtitle: sub.0, subtitleTone: sub.1) {
            SourceMenu(title: m.cameras.first { $0.uid == r.uid }?.name ?? (r.uid == nil ? T("Alege camera…") : T("Camera lipsește")), placeholder: r.uid == nil,
                       items: m.cameras.map { ($0.uid, $0.name, $0.uid == r.uid) }, disabled: m.phase != .idle) { uid in Task { await m.setCamera(r.id, uid) } }
        } actions: {
            if let u = r.uid, m.cameras.contains(where: { $0.uid == u }) {
                // modes the camera really lists; "automatic" = the camera's own current mode. A chosen mode the camera cannot give stops the camera with a message.
                Menu {
                    Button { m.setCameraFormat(r.id, nil) } label: { if r.format == nil { Label(T("Automat (modul curent al camerei)"), systemImage: "checkmark") } else { Text(T("Automat (modul curent al camerei)")) } }
                    Divider()
                    ForEach(CameraFormats.options(forDeviceID: u)) { o in
                        Button { m.setCameraFormat(r.id, o) } label: { if r.format == o { Label(o.label, systemImage: "checkmark") } else { Text(o.label) } }
                    }
                } label: { Image(systemName: "camera.metering.matrix").font(Theme.F.icon).frame(width: 24, height: 24).contentShape(Rectangle()) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(r.format == nil ? Theme.C.textDim : Theme.C.sel).disabled(m.phase != .idle)
                    .help(r.format.map { L10n.f("Mod ales: %@", $0.label) } ?? T("Alege modul camerei (mărime și cadre pe secundă)")).accessibilityLabel(T("Modul camerei"))
            }
            RowMenu { Button(role: .destructive) { m.removeCameraRow(r.id) } label: { Label(T("Elimină camera"), systemImage: "trash") }.disabled(m.phase != .idle) }
        } detail: { EmptyView() }
        .help(T("Camera se înregistrează în fișierul ei, pe ceasul comun; se pregătește înainte de numărătoare. În editor apare ca prezentator în cerc."))
    }
}

/// RO / EN / ES, applied at once; the choice is remembered.
struct LanguagePicker: View {
    @AppStorage("sadrog.language") private var language = AppLanguage.current.rawValue
    var body: some View {
        Menu {
            ForEach(AppLanguage.allCases) { l in Button { language = l.rawValue } label: { if l.rawValue == language { Label(l.name, systemImage: "checkmark") } else { Text(l.name) } } }
        } label: { Text(language.uppercased()).font(Theme.F.monoSmall) }
        .menuStyle(.borderlessButton).fixedSize().help(T("Limba interfeței")).accessibilityLabel(T("Limba interfeței"))
    }
}
