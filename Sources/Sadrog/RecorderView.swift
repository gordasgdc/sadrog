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
            sidebar.frame(width: 204)
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
            VStack(alignment: .leading, spacing: 6) {
                Text(T("SADROG")).font(.system(size: 21, weight: .bold)).tracking(3).foregroundStyle(Theme.C.text)
                Text(T("Capturează. Explică. Creează.")).font(CM.small).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
            }.padding(.leading, 26).padding(.trailing, 8).padding(.top, 30).padding(.bottom, 26)
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
        }.frame(maxHeight: .infinity, alignment: .top).background(CM.sidebar)
    }
    private func sideItem(_ p: StartPage, badge: Color? = nil) -> some View {
        Button { page = p } label: {
            HStack(spacing: 8) {
                Image(systemName: p.symbol).font(.system(size: 14)).frame(width: 18)
                Text(p.title).font(.system(size: 14, weight: page == p ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
                if let b = badge { Circle().fill(b).frame(width: 7, height: 7) }
            }
            .foregroundStyle(page == p ? Theme.C.text : Theme.C.textDim)
            .padding(.horizontal, 10).frame(height: 44)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(page == p ? CM.navSel : .clear))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(page == p ? CM.navSelStroke : .clear, lineWidth: 1))
            .contentShape(Rectangle())
        }.buttonStyle(.plain).padding(.horizontal, 14)
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
    private func pageScroll<C: View>(wide: Bool = false, @ViewBuilder _ c: () -> C) -> some View {
        ScrollView { VStack(alignment: .leading, spacing: wide ? 20 : 22) { c() }.padding(.leading, wide ? 46 : 24).padding(.trailing, wide ? 48 : 24).padding(.top, wide ? 32 : 22).padding(.bottom, wide ? 40 : 22).frame(maxWidth: wide ? 1172 : 560, alignment: .leading).frame(maxWidth: .infinity) }
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
            pageScroll(wide: true) {
                if let t = m.addTarget {
                    Notice(symbol: "plus.rectangle.on.rectangle", text: L10n.f("Înregistrarea se adaugă în «%@», la sfârșitul proiectului. Proiectul rămâne salvat.", t.editor.project.name), action: T("Înapoi la editor")) { m.cancelAddRecording() }
                }
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) { recordTitle(); permissionChip }
                    VStack(alignment: .leading, spacing: 8) { recordTitle(compact: true); permissionChip }
                }
                finishedCard
                if !m.hasPermission { Notice(symbol: "lock.shield", text: T("Lipsește permisiunea „Înregistrare ecran”."), action: T("Permisiuni…")) { page = .permissions } }
                else if !act.allowsRecordAndExport { Notice(symbol: "key", text: T("Înregistrarea și exportul cer activare. Editarea rămâne liberă."), action: T("Activare")) { page = .activation } }
                sourcesSection
                AddSourceButton(disabled: m.phase != .idle) { addSourceItems }.padding(.top, 10)
                if !m.unfinished.isEmpty { unfinishedSection }
            }
            recordBar
        }.background(LinearGradient(colors: [CM.pageTop, CM.pageBottom], startPoint: .top, endPoint: .bottom))
    }

    private func recordTitle(compact: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Pregătește înregistrarea")).font(.system(size: compact ? 22 : 29, weight: .semibold)).foregroundStyle(Theme.C.text).lineLimit(2).fixedSize(horizontal: false, vertical: true).accessibilityAddTraits(.isHeader)
            if !compact { Text(T("Alege sursele. Verifică imaginea și sunetul. Înregistrează.")).font(.system(size: 15)).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Screen-recording permission at a glance; the tooltip lists the three permissions and a click opens their page.
    private var permissionChip: some View {
        let ok = m.hasPermission
        let mic = m.micAuth == .authorized ? T("acordat") : (m.micAuth == .denied ? T("refuzat") : T("se cere la prima folosire"))
        let cam = m.cameraAuth == .authorized ? T("acordată") : (m.cameraAuth == .denied || m.cameraAuth == .restricted ? T("refuzată") : T("se cere la prima folosire"))
        return Button { page = .permissions } label: {
            HStack(spacing: 8) {
                Circle().fill(ok ? CM.chipDot : Theme.C.warn).frame(width: 8, height: 8)
                Text(ok ? T("Permisiuni disponibile") : T("Permisiune lipsă")).font(CM.note).foregroundStyle(ok ? CM.chipText : Theme.C.warn)
            }.padding(.horizontal, 16).frame(height: 34).background(Capsule().fill(ok ? CM.chipFill : Theme.C.warn.opacity(0.12))).overlay(Capsule().strokeBorder(ok ? CM.chipStroke : Theme.C.warn.opacity(0.4), lineWidth: 1))
        }.buttonStyle(.plain)
            .help(L10n.f("Înregistrare ecran: %@ · Microfon: %@ · Cameră: %@. Clic pentru detalii.", ok ? T("acordată") : T("lipsește"), mic, cam))
            .accessibilityLabel(T("Permisiuni")).accessibilityValue(ok ? T("disponibile") : T("lipsă"))
    }

    /// What the next recording would contain, in one line (also the state: ready / why not).
    private var recordContext: String {
        let video = (m.selectedSource != nil ? 1 : 0) + m.extraScreens.filter(\.enabled).count + m.cameraRows.filter(\.enabled).count
        let audio = m.audio.filter { $0.enabled }.count
        let what = L10n.f("%@ video · %@ audio", "\(video)", "\(audio)") + " · " + T("fișiere separate")
        if m.canRecord { return what + " · " + T("gata de înregistrare") }
        if !m.hasPermission { return what + " · " + T("permisiune lipsă") }
        return what
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack { Text(T("Sursele înregistrării").uppercased()).font(CM.label).tracking(1.8).foregroundStyle(Theme.C.textDim).accessibilityAddTraits(.isHeader); Spacer(); Text(recordContext).font(CM.small).foregroundStyle(m.canRecord ? Theme.C.ok : Theme.C.textDim).lineLimit(1) }
            SourceList {
                mainVideoRow
                ForEach(m.extraScreens) { ExtraScreenRowView(m: m, r: $0) }
                ForEach(m.cameraRows) { CameraRowView(m: m, r: $0) }
                ForEach(m.audio) { audioRow($0) }
                if m.extraScreens.isEmpty && m.cameraRows.isEmpty && m.audio.isEmpty { EmptyHint(text: T("Nicio altă sursă. Adaugă o cameră, un microfon sau sunetul calculatorului cu «Adaugă sursă».")) }
            }
        }
    }

    private var mainKindName: String { m.mode == .window ? T("Fereastră") : (m.mode == .region ? T("Regiune") : T("Ecran · întregul monitor")) }
    private var mainSubtitle: String {
        var t = mainKindName
        if m.restoredDisplay, m.mode != .window, m.displayID != nil { t += " · " + T("ultima folosită") }
        return t
    }
    private var fpsText: String { "\(ScreenCapturer.defaultFPS) \(T("cadre/s"))" }
    private var mainVideoRow: some View {
        let list = m.mode == .window ? m.windows : m.displays
        let current = m.mode == .window ? m.windowID : m.displayID
        let title = list.first { $0.id == current }?.title ?? (m.selectedSource?.title ?? (m.mode == .window ? T("Alege fereastra…") : T("Alege monitorul…")))
        let z = m.sizes, s = m.selectedSource
        return SourceRow(symbol: m.mode == .window ? "macwindow" : (m.mode == .region ? "rectangle.dashed" : "display"), principal: true, subtitle: mainSubtitle, hasDetail: s != nil,
            preview: AnyView(RowTextButton(title: m.previewOn ? T("Oprește imaginea") : T("Previzualizare"), symbol: m.previewOn ? "eye.fill" : "eye", active: m.previewOn,
                                           help: m.previewOn ? T("Oprește previzualizarea") : T("Previzualizare: imagini statice la cerere; nu înregistrează")) { m.previewOn.toggle() }
                .disabled(s == nil).popover(isPresented: $m.previewOn, arrowEdge: .bottom) { stillPreview }),
            config: AnyView(sizeMenu),
            more: AnyView(RowMenu {
                Button { m.identify() } label: { Label(T("Identifică: ramă roșie pe sursă timp de 2 s (nu intră în înregistrare)"), systemImage: "scope") }.disabled(s == nil || m.phase != .idle)
                Divider()
                Picker(T("Captură"), selection: $m.mode) { Text(T("Monitor")).tag(VideoMode.display); Text(T("Fereastră")).tag(VideoMode.window); Text(T("Regiune")).tag(VideoMode.region) }.disabled(m.phase != .idle)
                if m.mode == .region { Button(m.regionSpec == nil ? T("Trasează regiunea…") : T("Retrasează…")) { m.drawRegion() }.disabled(m.displayID == nil || m.phase != .idle) }
            }),
            extra: m.mode == .region ? AnyView(regionHint) : nil) {
            SourceMenu(title: title, placeholder: s == nil, items: list.map { (String($0.id), $0.title, $0.id == current) }, disabled: m.phase != .idle,
                       onHover: m.mode == .region ? nil : { id in m.previewCandidate(id.flatMap(UInt32.init)) }) { id in
                let v = UInt32(id)
                if m.mode == .window { m.windowID = v } else { m.displayID = v }
            }
        } primary: {
            if let z { Text(verbatim: "\(T("Fișier")): \(z.out.w) × \(z.out.h) px · \(fpsText)").font(CM.small).foregroundStyle(Theme.C.text).lineLimit(1) }
            else { Text(T("Alege sursa ca să vezi dimensiunea fișierului")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(1) }
        } detail: {
            if let s, let z { sizeDetail(s, z) }
        }
    }
    @ViewBuilder private var regionHint: some View {
        HStack(spacing: 8) {
            Button(m.regionSpec == nil ? T("Trasează regiunea…") : T("Retrasează…")) { m.drawRegion() }.buttonStyle(.gloss(.secondary, compact: true)).disabled(m.displayID == nil || m.phase != .idle)
                .help(T("Trage pe monitor, în orice direcție; Esc anulează."))
            if m.regionSpec == nil { Text(T("Trage pe monitor, în orice direcție; Esc anulează.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
        }
    }
    @ViewBuilder private var stillPreview: some View {
        if let img = m.previewImage { Image(nsImage: img).resizable().scaledToFit().frame(maxWidth: 380, maxHeight: 240).padding(8) }
        else if m.previewFailed { Text(T("Nu s-a putut obține imaginea. Verifică permisiunea „Înregistrare ecran” și că sursa încă există.")).font(Theme.F.caption).frame(width: 260).padding(12) }
        else { ProgressView().padding(24) }
    }

    /// The size of the recorded file, chosen explicitly: 1:1 with the macOS render, the physical panel, or capped at 1920 px. Each choice shows the size it gives.
    private var sizeMenu: some View {
        let s = m.selectedSource
        func px(_ cap: RecorderModel.OutCap) -> String? {
            guard let s else { return nil }
            var src = s.pixels
            if m.mode == .region, let r = m.regionSpec, r.isValid { let p = RegionMath.pixels(points: RegionMath.sourceRect(r, displayPoints: CGSize(width: s.pointsWidth, height: s.pointsHeight)).size, scale: s.scale); src = (p.w, p.h) }
            let cap: Int? = { switch cap { case .source: return nil; case .hd: return 1920; case .panel: return s.panelWidth > 0 ? max(s.panelWidth, s.panelHeight) : nil } }()
            let o = RegionMath.output(source: src, maxLongSide: cap); return "\(o.w)×\(o.h)"
        }
        func item(_ cap: RecorderModel.OutCap, _ name: String) -> some View {
            Button { m.outCap = cap } label: { if m.outCap == cap { Label("\(name) · \(px(cap) ?? "")", systemImage: "checkmark") } else { Text("\(name) · \(px(cap) ?? "")") } }
        }
        return RowMenuButton(title: T("Dimensiune"), help: T("Dimensiunea fișierului înregistrat: 1:1 cu randarea macOS, panoul fizic sau maxim 1920 px"), disabled: s == nil || m.phase != .idle) {
            item(.source, T("1:1 cu sursa"))
            if let s, s.panelWidth > 0, m.mode != .window { item(.panel, T("Panoul fizic")) }
            item(.hd, T("Maxim 1920 px"))
        }
    }

    /// The four sizes, each named for what it is (points ≠ render pixels ≠ physical panel ≠ recorded file).
    @ViewBuilder private func sizeDetail(_ s: SourceInfo, _ z: (src: (w: Int, h: Int), out: (w: Int, h: Int))) -> some View {
        let b = SizeBreakdown.make(source: s, sourcePixels: z.src, file: z.out)
        VStack(alignment: .leading, spacing: 5) {
            detailLine(T("Dimensiune logică"), "\(b.logicalW) × \(b.logicalH) pt", T("puncte macOS: cât „încape” pe ecran"))
            detailLine(T("Randare internă macOS"), "\(b.renderW) × \(b.renderH) px", L10n.f("scară %@× — pixeli de randare, nu panoul", "\(String(format: "%g", b.scale))"))
            detailLine(T("Rezoluție fizică raportată"), b.panelW > 0 ? "\(b.panelW) × \(b.panelH) px" : T("nu este raportată"), b.panelW > 0 ? T("modul nativ al panoului, raportat de macOS") : T("fereastra nu are panou propriu"))
            detailLine(T("Rezoluție efectivă de captură"), "\(b.fileW) × \(b.fileH) px", b.fileIsRender ? T("fișierul înregistrat, egal cu randarea internă") : T("fișierul înregistrat"))
            if b.renderExceedsPanel && b.fileIsRender {
                Text(L10n.f("Randarea internă (%@×%@) este mai mare decât panoul fizic (%@×%@): fișierul 1:1 este mai mare decât imaginea pe care o poate afișa panoul. «Dimensiune» → «Panoul fizic» îl aduce la rezoluția panoului.", "\(b.renderW)", "\(b.renderH)", "\(b.panelW)", "\(b.panelH)"))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            if m.restoredDisplay, m.mode != .window, m.displayID != nil {
                Text(T("Monitorul folosit data trecută. Nimic nu se înregistrează sau monitorizează până nu pornești tu.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func detailLine(_ label: String, _ value: String, _ note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).frame(width: 178, alignment: .leading)
            Text(verbatim: value).font(Theme.F.mono).foregroundStyle(Theme.C.text)
            Text(note).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(2)
        }
    }

    /// One menu for every kind of source, usable again and again.
    @ViewBuilder private var addSourceItems: some View {
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
    }

    private func audioRow(_ a: AudioSourceSpec) -> some View {
        let dev = m.devices.first { $0.uid == a.deviceUID }
        let total = dev?.inputChannels ?? 0
        var sub = a.kind == .system ? T("Sunetul aplicațiilor") : T("Microfon / interfață audio")
        var tone = Theme.C.textFaint
        if let w = m.lost[a.id] { sub = L10n.f("%@. Nu se folosește alt dispozitiv în loc.", "\(w)"); tone = Theme.C.warn }
        else if a.kind == .input && m.micAuth == .denied { sub = T("Acces la microfon refuzat (Setări → Confidențialitate și securitate)."); tone = Theme.C.warn }
        else if a.kind == .input && dev == nil { sub = T("Dispozitivul lipsește"); tone = Theme.C.warn }
        let mon = m.monitoring.contains(a.id)
        return SourceRow(symbol: a.kind == .system ? "speaker.wave.2" : "mic", enabled: Binding(get: { a.enabled }, set: { m.setEnabled(a.id, $0) }), toggleLocked: m.phase != .idle, dimmed: !a.enabled, subtitle: sub, subtitleTone: tone,
            preview: AnyView(RowTextButton(title: mon ? T("Oprește nivelul") : T("Arată nivelul"), symbol: mon ? "waveform.circle.fill" : "waveform.circle", active: mon,
                                           help: mon ? T("Oprește afișarea nivelului") : T("Arată nivelul real al sursei (fără redare pe difuzoare)")) { m.toggleMonitor(a.id) }.disabled(m.phase != .idle && !mon)),
            config: a.kind == .input && total > 1 ? AnyView(ChannelPicker(m: m, spec: a, total: total)) : nil,
            more: AnyView(RowMenu { Button(role: .destructive) { m.remove(a.id) } label: { Label(T("Elimină sursa"), systemImage: "trash") }.disabled(m.phase != .idle) }),
            side: AnyView(LevelReadout(reading: m.readings[a.id], live: mon || m.phase == .recording) { m.clearClip(a.id) }),
            notes: a.kind == .input && total > 1 ? AnyView(Text(T("Alegerea canalelor nu modifică setările interfeței audio.")).font(CM.note).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)) : nil) {
            Text(a.deviceName).font(CM.title).foregroundStyle(Theme.C.text).lineLimit(1)
        } primary: {
            if a.kind == .system { Text(T("Stereo · toate aplicațiile")).font(CM.small).foregroundStyle(Theme.C.text).lineLimit(1) }
            else { Text(L10n.f("Canale selectate: %@ din %@", a.channels.map(String.init).joined(separator: ", "), "\(total)")).font(CM.small).foregroundStyle(Theme.C.text).lineLimit(1) }
        } detail: { EmptyView() }
    }

    private var unfinishedSection: some View {
        section(T("Sesiuni neterminate")) {
            ForEach(m.unfinished, id: \.id) { j in
                HStack { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.C.warn); Text("\(j.startedAt.formatted()) · \(j.width)×\(j.height)").font(Theme.F.body); Spacer()
                    Button(T("Verifică și recuperează")) { Task { await m.recover(j) } }.buttonStyle(.gloss(.secondary, compact: true)) }
            }
        }
    }

    private var pillText: String {
        switch m.phase {
        case .idle: return T("Începe înregistrarea")
        case .preparing: return T("Se pregătește…")
        case .countdown(let n): return L10n.f("Anulează · %@", "\(n)")
        case .starting: return T("Pornește…")
        case .recording, .paused: return T("Oprește înregistrarea")
        case .stopping: return T("Se salvează…")
        }
    }
    /// Footer: always visible under the scrolling list. Wide: folder | Record | countdown. Narrow: Record first, then folder and countdown on one line.
    private var recordBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                destinationBlock.frame(width: 230, alignment: .leading).padding(.top, 2)
                Spacer(minLength: 0)
                recordCenter()
                Spacer(minLength: 0)
                sideControls.frame(width: 230, alignment: .trailing)
            }.padding(.horizontal, 46).padding(.top, 26).padding(.bottom, 20).frame(minHeight: 143, alignment: .top)
            VStack(spacing: 8) {
                recordCenter(compact: true)
                HStack(alignment: .bottom) { destinationBlock; Spacer(minLength: 8); sideControls }
            }.padding(.horizontal, 24).padding(.vertical, 10)
        }
        .overlay(alignment: .top) { Rectangle().fill(Color(dark: 0x5B5E66, light: 0xC2C5CC).opacity(0.5)).frame(height: 1) }
    }
    private func recordCenter(compact: Bool = false) -> some View {
        VStack(spacing: compact ? 6 : 14) {
            Button { Task { await m.toggle() } } label: { Text(pillText).lineLimit(1) }
                .buttonStyle(RecordPillStyle(phase: m.phase, compact: compact)).keyboardShortcut(.return)
                .disabled(m.phase == .idle && !m.canRecord || m.phase == .stopping || m.phase == .starting)
                .help(m.phase == .idle ? T("Înregistrează (↩)") : T("Oprește"))
                .accessibilityLabel(pillText).accessibilityIdentifier("sadrog.record").accessibilityValue(phaseName)
            HStack(spacing: 8) {
                if m.phase == .recording || m.phase == .paused { Text(timeString(m.elapsed)).font(Theme.F.mono).foregroundStyle(Theme.C.text) }
                statusLine
                if m.simulatedCapture {
                    Chip(text: T("SIMULARE"), tone: .warn).fixedSize().accessibilityIdentifier("sadrog.simulated").help(T("SIMULARE — nu se înregistrează"))
                }
            }.frame(minHeight: 16)
        }.fixedSize(horizontal: true, vertical: false)
    }
    @ViewBuilder private var sideControls: some View {
        if m.phase == .recording || m.phase == .paused {
            Button { m.togglePause() } label: { Label(m.phase == .paused ? T("Reia") : T("Pauză"), systemImage: m.phase == .paused ? "play.fill" : "pause.fill") }
                .buttonStyle(CMButtonStyle()).fixedSize().keyboardShortcut("p", modifiers: [.command, .shift])
                .help(T("Pauză sau reluare pentru TOATE sursele în același moment (⇧⌘P)"))
        } else if m.phase == .idle {
            VStack(alignment: .leading, spacing: 10) {
                Text(T("Numărătoare")).font(CM.small).foregroundStyle(Theme.C.textDim)
                Menu {
                    Picker(T("Numărătoare"), selection: $m.countdownSeconds) { ForEach([0, 3, 5, 10, 15], id: \.self) { Text($0 == 0 ? T("fără") : "\($0) s").tag($0) } }.pickerStyle(.inline).labelsHidden()
                } label: {
                    HStack(spacing: 6) { Text(m.countdownSeconds == 0 ? T("fără") : "\(m.countdownSeconds) s").font(CM.button); Image(systemName: "chevron.down").font(Theme.F.glyph) }.frame(maxWidth: .infinity)
                }.menuStyle(.button).buttonStyle(CMButtonStyle(width: 148)).menuIndicator(.hidden).fixedSize()
                    .accessibilityLabel(T("Numărătoare")).accessibilityValue(m.countdownSeconds == 0 ? T("fără") : "\(m.countdownSeconds) s").help(T("Numărătoare înainte de start"))
            }
        } else { Color.clear.frame(width: 1, height: 1) }
    }
    /// Where recordings go and how much room is left: the folder name, the free space, and the action to change it.
    private var destinationBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(T("Salvare în")).font(CM.small).foregroundStyle(Theme.C.textDim)
            Text(m.destination?.lastPathComponent ?? T("Destinație nealeasă")).font(.system(size: 15)).lineLimit(1).truncationMode(.middle)
                .foregroundStyle(m.destination == nil ? Theme.C.warn : Theme.C.text).help(m.destination?.path ?? T("Alege folderul în care se salvează înregistrările"))
            HStack(spacing: 6) {
                Button(T("Schimbă folderul…")) { m.chooseDestination() }.buttonStyle(.plain).font(Theme.F.caption).foregroundStyle(Theme.C.accent).disabled(m.recording)
                    .help((m.destination?.path ?? T("Alege folderul în care se salvează înregistrările")) + " — " + T("Schimbă…")).accessibilityLabel(T("Destinația înregistrărilor"))
                if let f = m.freeGB { Text(L10n.f("%.0f GB liberi", f)).font(Theme.F.caption).foregroundStyle(f < 10 ? Theme.C.warn : Theme.C.textFaint) }
            }
        }.frame(maxWidth: 210, alignment: .leading)
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

/// One additional screen: monitor or window, its real size, on/off, preview on demand, remove.
struct ExtraScreenRowView: View {
    @ObservedObject var m: RecorderModel
    let r: ExtraScreenRow
    @State private var preview: NSImage?
    @State private var previewFailed = false
    @State private var showPreview = false
    private var list: [SourceInfo] { r.mode == .window ? m.windows : m.displays }
    private var chosen: SourceInfo? { list.first { $0.id == r.sourceID } }
    private func set(_ f: (inout ExtraScreenRow) -> Void) { if let i = m.extraScreens.firstIndex(where: { $0.id == r.id }) { f(&m.extraScreens[i]) } }
    private var fileSize: (w: Int, h: Int)? { chosen.map { RegionMath.output(source: $0.pixels, maxLongSide: m.maxLong) } }
    var body: some View {
        SourceRow(symbol: r.mode == .window ? "macwindow" : "display", enabled: Binding(get: { r.enabled }, set: { v in set { $0.enabled = v } }), toggleLocked: m.phase != .idle, dimmed: !r.enabled,
                  subtitle: r.mode == .window ? T("Fereastră") : T("Ecran · întregul monitor"), subtitleTone: chosen == nil && r.sourceID != nil ? Theme.C.warn : Theme.C.textFaint, hasDetail: chosen != nil,
                  preview: AnyView(RowTextButton(title: T("Previzualizare"), symbol: "eye", help: T("Previzualizare: o imagine statică, la cerere; nu înregistrează")) {
                      guard let c = chosen else { return }
                      previewFailed = false; preview = nil; showPreview = true
                      Task { if let img = await ScreenCapturer.snapshot(source: c, maxWidth: 360) { preview = NSImage(cgImage: img, size: .zero) } else { previewFailed = true } }
                  }.disabled(chosen == nil).popover(isPresented: $showPreview) {
                      if let p = preview { Image(nsImage: p).resizable().scaledToFit().frame(maxWidth: 360, maxHeight: 220).padding(8) }
                      else if previewFailed { Text(T("Nu s-a putut obține imaginea. Verifică permisiunea „Înregistrare ecran” și că sursa încă există.")).font(Theme.F.caption).frame(width: 260).padding(12) }
                      else { ProgressView().padding(24) }
                  }),
                  more: AnyView(RowMenu { Button(role: .destructive) { m.removeExtraScreen(r.id) } label: { Label(T("Elimină sursa"), systemImage: "trash") }.disabled(m.phase != .idle) })) {
            SourceMenu(title: chosen?.title ?? (r.mode == .window ? T("Alege fereastra…") : T("Alege monitorul…")), placeholder: chosen == nil, items: list.map { (String($0.id), $0.title, $0.id == r.sourceID) }, disabled: m.phase != .idle,
                       onHover: { id in m.previewCandidate(id.flatMap(UInt32.init), window: r.mode == .window) }) { id in set { $0.sourceID = UInt32(id) } }
        } primary: {
            if let f = fileSize { Text(verbatim: "\(T("Fișier")): \(f.w) × \(f.h) px · \(ScreenCapturer.defaultFPS) \(T("cadre/s"))").font(Theme.F.mono).foregroundStyle(Theme.C.text).lineLimit(1) }
            else { Text(T("Alege sursa ca să vezi dimensiunea fișierului")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(1) }
        } detail: {
            if let c = chosen, let f = fileSize {
                let b = SizeBreakdown.make(source: c, sourcePixels: c.pixels, file: f)
                VStack(alignment: .leading, spacing: 5) {
                    detailLine(T("Dimensiune logică"), "\(b.logicalW) × \(b.logicalH) pt")
                    detailLine(T("Randare internă macOS"), "\(b.renderW) × \(b.renderH) px")
                    detailLine(T("Rezoluție fizică raportată"), b.panelW > 0 ? "\(b.panelW) × \(b.panelH) px" : T("nu este raportată"))
                    detailLine(T("Rezoluție efectivă de captură"), "\(b.fileW) × \(b.fileH) px")
                    Text(T("Dimensiunea fișierului urmează setarea «Dimensiune» a sursei principale.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
                }
            }
        }
    }
    private func detailLine(_ label: String, _ value: String) -> some View {
        HStack(spacing: 10) { Text(label).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).frame(width: 178, alignment: .leading); Text(verbatim: value).font(Theme.F.mono).foregroundStyle(Theme.C.text) }
    }
}

/// Explicit channel choice for an input device: which channels of the device go into this track. It changes only what SADROG records;
/// the device's own settings (for example a MixPre's routing) are never written.
struct ChannelPicker: View {
    @ObservedObject var m: RecorderModel
    let spec: AudioSourceSpec
    let total: Int
    @State private var open = false
    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 6) { Text(T("Canale")).lineLimit(1); Image(systemName: "chevron.down").font(Theme.F.glyph) }.frame(maxWidth: .infinity)
        }.buttonStyle(CMButtonStyle(width: CM.configW, hPad: 8)).disabled(m.phase != .idle)
            .help(T("Alege canalele dispozitivului care intră în această pistă")).accessibilityLabel(T("Alege canalele")).accessibilityValue(spec.channels.map(String.init).joined(separator: ", "))
            .popover(isPresented: $open, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(L10n.f("Canalele dispozitivului (%@)", "\(total)")).font(Theme.F.smallMedium)
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(48), spacing: 6), count: 4), alignment: .leading, spacing: 6) {
                        ForEach(1...min(total, 32), id: \.self) { c in
                            let on = spec.channels.contains(c)
                            Button { m.toggleChannel(spec.id, c) } label: { Text("\(c)").font(Theme.F.monoSmall).frame(width: 44, height: 24) }
                                .buttonStyle(.plain).background(RoundedRectangle(cornerRadius: 5).fill(on ? Theme.C.accent.opacity(0.85) : Theme.C.field)).foregroundStyle(on ? Theme.C.accentInk : Theme.C.textDim)
                                .help(on ? L10n.f("Canalul %@ este în înregistrare; clic pentru a-l scoate", "\(c)") : L10n.f("Adaugă canalul %@ în înregistrare", "\(c)"))
                                .accessibilityLabel(L10n.f("Canalul %@", "\(c)")).accessibilityValue(on ? T("ales") : T("neales"))
                        }
                    }
                    Text(T("Alegerea canalelor se aplică doar înregistrării SADROG. Nu modifică setările interfeței audio (de exemplu MixPre).")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
                        .fixedSize(horizontal: false, vertical: true).frame(width: 240, alignment: .leading)
                }.padding(12)
            }
    }
}

/// One camera (or other compatible video device): format and frame rate, preview on demand, access state, on/off, remove.
struct CameraRowView: View {
    @ObservedObject var m: RecorderModel
    let r: CameraRow
    private var present: Bool { r.uid.map { u in m.cameras.contains { $0.uid == u } } ?? true }
    private var sub: (String, Color) {
        guard r.uid != nil else { return (T("Cameră"), Theme.C.textFaint) }
        if !present { return (T("Camera lipsește"), Theme.C.warn) }
        switch m.cameraAuth {
        case .denied, .restricted: return (T("Cameră · acces refuzat"), Theme.C.warn)
        case .authorized: return (T("Cameră · prezentator"), Theme.C.textFaint)
        default: return (T("Cameră · accesul se cere la previzualizare sau la înregistrare"), Theme.C.textFaint)
        }
    }
    /// What the menu shows: the chosen mode, or "Automat" (the camera's own current mode, written next to it as plain text).
    private var formatChoice: String { r.format?.label ?? T("Automat") }
    private var autoMode: String? { r.format == nil ? r.uid.flatMap { m.cameraFormat($0) } : nil }
    private var formatText: String { autoMode.map { "\(formatChoice) · \($0)" } ?? formatChoice }
    private var previewState: CameraPreviewState? { m.cameraPreviews[r.id] }
    var body: some View {
        let live = previewState?.isRunning == true
        SourceRow(symbol: "video", enabled: Binding(get: { r.enabled }, set: { v in if let i = m.cameraRows.firstIndex(where: { $0.id == r.id }) { m.cameraRows[i].enabled = v } }), toggleLocked: m.phase != .idle, dimmed: !r.enabled,
                  subtitle: sub.0, subtitleTone: sub.1,
                  preview: r.uid == nil ? nil : AnyView(RowTextButton(title: live ? T("Ascunde imaginea") : T("Previzualizare"), symbol: live ? "eye.slash" : "eye", active: live,
                                           help: live ? T("Oprește previzualizarea și eliberează camera") : T("Previzualizare reală de la cameră: pornește camera și o oprește când o închizi")) { Task { await m.toggleCameraPreview(r.id) } }.disabled(m.phase != .idle)),
                  config: nil,
                  more: AnyView(RowMenu { Button(role: .destructive) { m.removeCameraRow(r.id) } label: { Label(T("Elimină camera"), systemImage: "trash") }.disabled(m.phase != .idle) }),
                  extra: previewState == .live ? AnyView(Text(T("Imagine reală de la cameră. Nu se înregistrează; se oprește când o ascunzi, când pleci din pagină sau când pornești înregistrarea.")).font(CM.note).foregroundStyle(Theme.C.textDim).frame(maxWidth: 520, alignment: .leading).fixedSize(horizontal: false, vertical: true)) : nil,
                  side: previewState.map { st in AnyView(CameraPreviewBox(state: st, session: m.cameraPreviewSession(r.id), retry: { Task { m.stopCameraPreview(r.id); await m.toggleCameraPreview(r.id) } },
                                       openSettings: { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera")!) }).padding(.leading, 163)) },
                  notes: r.uid != nil && present ? AnyView(VStack(alignment: .leading, spacing: 5) {
                      Text(T("Formatul real este confirmat la pregătire.")); Text(T("Previzualizarea nu pornește înregistrarea."))
                  }.font(CM.small).foregroundStyle(Theme.C.textDim)) : nil) {
            SourceMenu(title: m.cameras.first { $0.uid == r.uid }?.name ?? (r.uid == nil ? T("Alege camera…") : T("Cameră")), placeholder: r.uid == nil,
                       items: m.cameras.map { ($0.uid, $0.name, $0.uid == r.uid) }, disabled: m.phase != .idle) { uid in Task { await m.setCamera(r.id, uid) } }
        } primary: {
            if r.uid != nil && present {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { formatMenu; autoModeText }
                    VStack(alignment: .leading, spacing: 8) { formatMenu; autoModeText }
                }
            }
            else if r.uid != nil { Text(verbatim: "\(T("Format")): —").font(CM.small).foregroundStyle(Theme.C.textFaint) }
            else { Text(T("Alege camera ca să vezi formatul")).font(CM.small).foregroundStyle(Theme.C.textDim) }
        } detail: { EmptyView() }
    }
    @ViewBuilder private var autoModeText: some View {
        if let a = autoMode { Text(verbatim: L10n.f("modul curent: %@", a)).font(CM.small).foregroundStyle(Theme.C.textDim).lineLimit(1).fixedSize() }
    }
    /// Modes the camera really lists; "automatic" = the camera's own current mode. A chosen mode the camera cannot give stops the camera with a message.
    private var formatMenu: some View {
        Menu {
            Button { m.setCameraFormat(r.id, nil) } label: { if r.format == nil { Label(T("Automat (modul curent al camerei)"), systemImage: "checkmark") } else { Text(T("Automat (modul curent al camerei)")) } }
            Divider()
            ForEach(CameraFormats.options(forDeviceID: r.uid ?? "")) { o in
                Button { m.setCameraFormat(r.id, o) } label: { if r.format == o { Label(o.label, systemImage: "checkmark") } else { Text(o.label) } }
            }
        } label: {
            HStack(spacing: 6) { Text(verbatim: "\(T("Format")): \(formatChoice)").font(CM.button).lineLimit(1); Image(systemName: "chevron.down").font(Theme.F.glyph) }.frame(minWidth: 150)
        }.menuStyle(.button).buttonStyle(CMButtonStyle()).menuIndicator(.hidden).fixedSize().disabled(m.phase != .idle)
            .help(r.format.map { L10n.f("Mod ales: %@", $0.label) } ?? T("Alege modul camerei (mărime și cadre pe secundă)")).accessibilityLabel(T("Format cameră")).accessibilityValue(formatText)
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
