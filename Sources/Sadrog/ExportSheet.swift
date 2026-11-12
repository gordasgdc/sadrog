// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import SadrogCore

struct ExportSheet: View {
    @ObservedObject var m: EditorModel
    @ObservedObject private var act = ActivationModel.shared
    private var running: Bool { if case .running = m.exportState { return true } else { return false } }

    /// The options SADROG really has, in the order a user decides them: file → preset → picture → sound → details.
    /// No format, codec or "lossless" label that is not implemented.
    private var fast: Bool { m.exportSettings.mode == .copy }
    /// ONE plan for everything the sheet says: summary, picture line, container, duration. It is what the exporter writes (`ExportPlanTests`).
    private var plan: ExportPlan {
        switch m.exportKind {
        case .audio: return .audio(m.project)
        case .archive: return .archive(m.project)
        case .video: return .video(m.project, documentSize: m.renderSize, documentFPS: m.fps, settings: m.exportSettings, copyPossible: m.reencodeReason == nil)
        }
    }
    private var res: String { "\(plan.width)×\(plan.height) px · \(m.fps.formatted(.number.precision(.fractionLength(0...2)))) cadre/s" }
    @State private var details = false
    @AppStorage("exportAdvanced") private var advanced = false
    @State private var newPresetName = ""
    @State private var namingPreset = false
    private var activePreset: ExportPreset? { m.exportPresets.matching(m.exportSettings) }
    /// Preset choice + the actions on it; shared by the simple and advanced views so the two never disagree.
    @ViewBuilder private var presetBar: some View {
        field(T("Preset")) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Picker(T("Preset"), selection: Binding(get: { activePreset?.id ?? "" }, set: { id in
                        if let p = m.exportPresets.all.first(where: { $0.id == id }) { m.exportSettings = p.settings(keeping: m.exportSettings); syncSizePick() }
                    })) {
                        if activePreset == nil { Text(T("Personalizat")).tag("") }
                        ForEach(ExportPreset.builtIns) { Text($0.name).tag($0.id) }
                        if !m.exportPresets.personal.isEmpty { Divider(); ForEach(m.exportPresets.personal) { Text($0.name).tag($0.id) } }
                    }.labelsHidden().frame(maxWidth: .infinity, alignment: .leading).disabled(running)      // takes the room that is left: a long preset name (EN/ES) truncates instead of pushing the sheet wider than its window
                    Picker(T("Mod export"), selection: $advanced) { Text(T("Simplu")).tag(false); Text(T("Avansat")).tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize().layoutPriority(1).disabled(running)
                }
                if advanced {
                    HStack(spacing: 6) {
                        if namingPreset {
                            AppTextField(placeholder: T("nume preset"), text: $newPresetName).frame(width: 150)
                            Button(T("Salvează")) { if m.exportPresets.save(name: newPresetName, settings: m.exportSettings) != nil { namingPreset = false; newPresetName = "" } }
                                .buttonStyle(.gloss(.secondary, compact: true)).disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
                            Button(T("Renunță")) { namingPreset = false }.buttonStyle(.gloss(.secondary, compact: true))
                        } else {
                            Button(T("Salvează ca preset…")) { namingPreset = true }.buttonStyle(.gloss(.secondary, compact: true)).disabled(running).help(running ? T("Disponibil după ce se termină exportul în curs.") : T("Salvează setările de acum ca preset reutilizabil."))
                            Button(T("Setează ca implicit")) { m.exportPresets.setDefault(activePreset?.id ?? m.exportPresets.save(name: T("Implicit"), settings: m.exportSettings)?.id) }
                                .buttonStyle(.gloss(.secondary, compact: true)).disabled(running || m.exportPresets.defaultID == activePreset?.id && activePreset != nil)
                            if let p = activePreset, !p.builtIn { Button(T("Șterge presetul")) { m.exportPresets.delete(id: p.id) }.buttonStyle(.gloss(.secondary, compact: true)).disabled(running) }
                            Button(T("Resetează")) { m.exportSettings = m.exportPresets.defaultSettings; syncSizePick() }.buttonStyle(.gloss(.secondary, compact: true)).disabled(running)
                        }
                    }
                }
            }
        }
    }
    /// Simple view: the preset already says everything; only the range choice remains, then the result and its size estimate.
    @ViewBuilder private var simpleFields: some View {
        if m.exportSettings.mode == .copy, let why = m.reencodeReason {
            field("") { Text(L10n.f("Copierea nu se poate pentru acest proiect: %@. Alege alt preset.", "\(why)")).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true) }
        }
        if m.exportSettings.mode != .copy { sizeField; qualityField }
        rangeAndResult
    }
    /// Resolution: the document's own size, the usual targets, or typed pixels. Shared by the simple and advanced views.
    @ViewBuilder private var sizeField: some View {
        field(T("Rezoluție")) {
            HStack(spacing: 6) {
                Picker(T("Rezoluție"), selection: $sizePick) { ForEach(SizePick.allCases) { Text($0 == .document ? L10n.f("Originală (%@×%@)", "\(Int(m.renderSize.width))", "\(Int(m.renderSize.height))") : $0.title).tag($0) } }.labelsHidden().fixedSize().disabled(running)
                    .onChange(of: sizePick) { _, _ in applySize() }
                if sizePick == .custom {
                    AppTextField(placeholder: "W", text: Binding(get: { String(customW) }, set: { customW = Int($0) ?? customW; applySize() })).frame(width: 56).disabled(running).accessibilityLabel(T("Lățime în pixeli"))
                    Text("×").foregroundStyle(Theme.C.textFaint)
                    AppTextField(placeholder: "H", text: Binding(get: { String(customH) }, set: { customH = Int($0) ?? customH; applySize() })).frame(width: 56).disabled(running).accessibilityLabel(T("Înălțime în pixeli"))
                    Text("px").font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
                }
            }
        }
    }
    /// Quality in plain words (compressed video with constant quality only).
    @ViewBuilder private var qualityField: some View {
        if m.exportSettings.mode == .compressed, rateControl == .quality {
            field(T("Calitate")) {
                Picker(T("Calitate"), selection: Binding(get: { qualityStep }, set: { m.exportSettings.quality = $0.value })) {
                    ForEach(ExportSettings.QualityStep.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(running)
                    .help(T("Compactă = fișierul cel mai mic; Înaltă = recomandată pentru text și interfețe; Maximă = fișier mult mai mare, pentru arhivă."))
            }
        }
    }
    private func syncSizePick() {
        switch m.exportSettings.size {
        case .document: sizePick = .document
        case .longSide(let l): sizePick = [1280: SizePick.p720, 1920: .p1080, 2560: .p1440, 3840: .uhd][l] ?? .custom
        case .custom(let w, let h): sizePick = .custom; customW = w; customH = h
        }
    }
    /// The estimate in a few words, for the simple view.
    private var shortEstimate: String? {
        func f(_ b: Int64) -> String { L10n.bytes(b) }
        if let r = ExportEstimate.qualityRange(plan, settings: m.exportSettings) { return L10n.f("Mărime estimată: %@ – %@", f(r.low), f(r.motion)) }      // static screen … continuous motion: the whole honest span
        return ExportEstimate.bytes(plan, settings: m.exportSettings).map { L10n.f("Mărime estimată: ≈ %@", f($0)) }
    }
    private var estimateLine: String? {
        if let r = ExportEstimate.qualityRange(plan, settings: m.exportSettings) {
            func f(_ b: Int64) -> String { L10n.bytes(b) }
            return L10n.f("Mărime estimată: %@ – %@ pentru captură de ecran (după conținut); cu video cu mișcare continuă, până la ≈ %@. Estimare, nu valoare garantată.", f(r.low), f(r.high), f(r.motion))
        }
        return ExportEstimate.bytes(plan, settings: m.exportSettings).map { L10n.f("Mărime estimată: ≈ %@ (estimare, nu valoare garantată)", L10n.bytes($0)) }
    }
    /// The result in one line, before anything is decided: what file, what picture, how long (of the range when only the range is exported).
    private var summary: String {
        let pl = plan, file = m.exportName + (pl.fileExtension.isEmpty ? "" : "." + pl.fileExtension)
        if pl.delivery == .archive { return "\(file) · \(ProjectArchive.mediaFiles(m.project).count) \(T("fișiere media"))" }
        if pl.delivery == .audio { return "\(file) · AAC · \(timecode(pl.duration))" }
        let span = pl.range.map { " (\(Self.clock($0.lowerBound))–\(Self.clock($0.upperBound)))" } ?? ""
        return "\(file) · " + (pl.delivery == .passthrough ? T("fără re-codificare") : pl.codec) + " · \(pl.width)×\(pl.height) · \(timecode(pl.duration))" + span
    }

    /// Why the export button is disabled (empty = enabled): the condition to fix, shown as its tooltip.
    private var exportBlockedWhy: String {
        if m.exportKind == .archive { return T("Creează o arhivă autonomă a proiectului.") }
        if m.exportKind == .audio && !m.deliveryConflicts.isEmpty { return T("Două fișiere audio ar avea același nume — schimbă numele sau opțiunile.") }
        if let r = m.fxBlockReason { return r }
        if m.exportKind == .video && m.exportSettings.mode == .copy, let r = m.reencodeReason { return r }
        if !act.allowsRecordAndExport { return ActivationModel.shared.blockedText }
        return T("Pornește exportul cu setările de mai sus.")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: T("Exportă proiectul"), subtitle: summary)
            HairlineDivider()
            VStack(alignment: .leading, spacing: 10) {
                field(T("Nume")) {
                    HStack(spacing: 4) { AppTextField(placeholder: T("nume"), text: $m.exportName).disabled(running); Text(plan.fileExtension.isEmpty ? "" : "." + plan.fileExtension).font(Theme.F.mono).foregroundStyle(Theme.C.textFaint) }
                }
                field(T("Unde")) {
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(Theme.C.textDim)
                        Text(m.exportFolder.lastPathComponent).font(Theme.F.body).lineLimit(1).truncationMode(.middle).help(m.exportFolder.path)
                        Spacer(minLength: 4)
                        Button(T("Schimbă…")) { m.chooseExportFolder() }.buttonStyle(.gloss(.secondary, compact: true)).disabled(running)
                    }
                }
                HairlineDivider().opacity(0.6)
                field(T("Ce")) {
                    Picker(T("Ce exporți"), selection: $m.exportKind) { ForEach(EditorModel.ExportKind.allCases) { Text(T($0.rawValue)).tag($0) } }.labelsHidden().fixedSize().disabled(running)
                }
                if m.exportKind == .audio { audioPlan } else if m.exportKind == .archive { archivePlan } else { presetBar; if advanced { videoFields } else { simpleFields } }
                DisclosureGroup(isExpanded: $details) {
                    VStack(alignment: .leading, spacing: 4) {
                        InfoRow(label: T("Document"), value: m.canvasDescription)
                        InfoRow(label: T("Container"), value: plan.container + (plan.codec.isEmpty ? "" : ", " + plan.codec))
                        InfoRow(label: T("Folder"), value: m.exportFolder.path)
                        Text(T("Mărimea și cadența se schimbă din inspector → Document. Sursele separate se exportă cu opțiunea „Audio: mix + surse separate”.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                    }.padding(.top, 6)
                } label: { Text(T("Detalii")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim) }
            }
            if let why = m.fxBlockReason, !running, !{ if case .done = m.exportState { return true }; return false }() {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "waveform.badge.exclamationmark").font(Theme.F.iconSmall).foregroundStyle(Theme.C.warn)
                    Text(why).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                }.accessibilityElement(children: .combine)
            }
            status
            if !act.allowsRecordAndExport {
                Text(act.blockedText).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                switch m.exportState {
                case .running: Button(m.exportKind == .archive ? T("Anulează arhivarea") : T("Anulează exportul")) { m.cancelExport() }.buttonStyle(.gloss(.secondary)).keyboardShortcut(.cancelAction)
                case .done(let url, _):
                    Button(T("Arată în Finder")) { NSWorkspace.shared.activateFileViewerSelecting(m.deliveredFiles.isEmpty ? [url] : m.deliveredFiles) }.buttonStyle(.gloss(.secondary))
                    Button(T("Gata")) { m.showExport = false }.buttonStyle(.gloss(.primary)).keyboardShortcut(.defaultAction)
                default:
                    Button(T("Închide")) { m.showExport = false }.buttonStyle(.gloss(.secondary)).keyboardShortcut(.cancelAction)
                    Button(m.exportKind == .audio ? L10n.f("Exportă %@ fișiere", "\(m.deliveryPlan.count)") : (m.exportKind == .archive ? T("Creează arhiva") : T("Exportă"))) { if m.exportKind == .audio { m.startAudioDelivery() } else if m.exportKind == .archive { m.startArchive() } else { m.startExport() } }
                        .buttonStyle(.gloss(.primary)).keyboardShortcut(.defaultAction).help(exportBlockedWhy).disabled(m.exportKind == .archive ? false : ((m.exportKind == .audio && !m.deliveryConflicts.isEmpty) || m.fxBlockReason != nil || (m.exportKind == .video && m.exportSettings.mode == .copy && m.reencodeReason != nil) || !act.allowsRecordAndExport))
                }
            }
        }
        .padding(20).frame(width: 624).background(Theme.C.bg1).appTheme()
        .onAppear { syncSizePick() }
    }
    static func clock(_ t: Double) -> String { let s = Int(t.rounded(.down)); return String(format: "%02d:%02d", s / 60, s % 60) }
    enum RateControl: Hashable { case quality, bitrate, size }
    private var rateControl: RateControl { m.exportSettings.videoMbps != nil ? .bitrate : (m.exportSettings.targetMB != nil ? .size : .quality) }
    private func setRateControl(_ r: RateControl) {
        switch r {
        case .quality: m.exportSettings.videoMbps = nil; m.exportSettings.targetMB = nil; m.exportSettings.quality = m.exportSettings.quality ?? ExportSettings.QualityStep.balanced.value
        case .bitrate: m.exportSettings.targetMB = nil; m.exportSettings.videoMbps = m.exportSettings.videoMbps ?? 8
        case .size: m.exportSettings.videoMbps = nil; m.exportSettings.targetMB = m.exportSettings.targetMB ?? 200
        }
    }
    /// The named step closest to the stored quality (a preset or an old file may hold an in-between value).
    private var qualityStep: ExportSettings.QualityStep { let q = m.exportSettings.quality ?? m.exportSettings.legacyQuality; return ExportSettings.QualityStep.allCases.min { abs($0.value - q) < abs($1.value - q) }! }
    @State private var sizePick = SizePick.document
    @State private var customW = 1920
    @State private var customH = 1080
    enum SizePick: String, CaseIterable, Identifiable { case document, p720, p1080, p1440, uhd, custom; var id: String { rawValue }
        var title: String { switch self { case .document: return T("Ca documentul"); case .p720: return "720p"; case .p1080: return "1080p (Full HD)"; case .p1440: return "1440p (QHD)"; case .uhd: return "4K UHD"; case .custom: return T("Personalizat…") } }
        var size: ExportSettings.Size? { switch self { case .document: return .document; case .p720: return .longSide(1280); case .p1080: return .longSide(1920); case .p1440: return .longSide(2560); case .uhd: return .longSide(3840); case .custom: return nil } } }
    private func applySize() { m.exportSettings.size = sizePick.size ?? .custom(customW, customH) }
    @ViewBuilder private var videoFields: some View {
        let s = Binding(get: { m.exportSettings }, set: { m.exportSettings = $0 })
        field(T("Mod")) {
            VStack(alignment: .leading, spacing: 3) {
                Picker(T("Mod"), selection: s.mode) {
                    Text(T("Rapid: copiere, fără procesare")).tag(ExportSettings.Mode.copy)
                    Text(T("Procesat, comprimat (H.264 / HEVC)")).tag(ExportSettings.Mode.compressed)
                    Text(T("Master ProRes (nu lossless)")).tag(ExportSettings.Mode.master)
                    Text(T("Lossless: cadre PNG + audio WAV")).tag(ExportSettings.Mode.lossless)
                }.labelsHidden().fixedSize().disabled(running)
                Text(modeDetail).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
        if m.exportSettings.mode == .copy, let why = m.reencodeReason {
            field("") { Text(L10n.f("Copierea nu se poate pentru acest proiect: %@. Alege un mod procesat.", "\(why)")).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true) }
        }
        if m.exportSettings.mode != .copy {
            sizeField
            field(T("Cadență")) {
                Picker(T("Cadență"), selection: Binding(get: { m.exportSettings.fps ?? 0 }, set: { m.exportSettings.fps = $0 == 0 ? nil : $0 })) {
                    Text(L10n.f("Ca documentul (%@)", "\(m.fps.formatted(.number.precision(.fractionLength(0...2))))")).tag(0.0)
                    ForEach([24.0, 25, 30, 50, 60], id: \.self) { Text("\(Int($0)) " + T("cadre/s")).tag($0) }
                }.labelsHidden().fixedSize().disabled(running)
            }
            if m.exportSettings.mode == .compressed {
                field(T("Format")) {
                    HStack(spacing: 8) {
                        Picker(T("Format"), selection: s.container) { Text("MP4 (.mp4)").tag(ExportSettings.Container.mp4); Text("QuickTime (.mov)").tag(ExportSettings.Container.mov) }.labelsHidden().fixedSize().disabled(running)
                            .help(T("MP4 pentru web, încărcări și redare pe orice dispozitiv; QuickTime pentru alte programe de montaj. Aceeași imagine și același sunet."))
                        Picker(T("Codec"), selection: s.codec) { Text("H.264").tag(ExportSettings.Codec.h264); Text("HEVC (H.265)").tag(ExportSettings.Codec.hevc) }.labelsHidden().fixedSize().disabled(running)
                            .help(T("H.264 se redă peste tot. HEVC face fișiere mai mici la aceeași calitate, dar unele browsere și televizoare mai vechi nu îl redau."))
                    }
                }
            }
            if m.exportSettings.mode == .compressed {
                field(T("Control")) {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker(T("Control"), selection: Binding(get: { rateControl }, set: { setRateControl($0) })) {
                            Text(T("Calitate")).tag(RateControl.quality); Text(T("Rată medie")).tag(RateControl.bitrate); Text(T("Mărime țintă")).tag(RateControl.size)
                        }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(running)
                            .help(T("Calitate: encoderul păstrează aceeași calitate, iar mărimea urmează conținutul. Rată medie: rata video e fixată. Mărime țintă: rata se calculează din durată; o singură trecere, deci mărime apropiată, nu exactă."))
                        switch rateControl {
                        case .quality:
                            Picker(T("Calitate"), selection: Binding(get: { qualityStep }, set: { m.exportSettings.quality = $0.value })) {
                                ForEach(ExportSettings.QualityStep.allCases) { Text($0.title).tag($0) }
                            }.labelsHidden().fixedSize().disabled(running)
                        case .bitrate:
                            Picker(T("Rată video"), selection: Binding(get: { m.exportSettings.videoMbps ?? 8 }, set: { m.exportSettings.videoMbps = $0; m.exportSettings.targetMB = nil })) {
                                ForEach([1.0, 2, 4, 6, 8, 12, 20, 35, 50, 100], id: \.self) { Text("\(Int($0)) Mb/s").tag($0) }
                            }.labelsHidden().fixedSize().disabled(running)
                        case .size:
                            HStack(spacing: 6) {
                                AppTextField(placeholder: "MB", text: Binding(get: { String(Int(m.exportSettings.targetMB ?? 200)) }, set: { if let v = Double($0), v > 0 { m.exportSettings.targetMB = v; m.exportSettings.videoMbps = nil } })).frame(width: 70).disabled(running)
                                Text("MB").foregroundStyle(Theme.C.textFaint)
                            }
                        }
                    }
                }
                field(T("Cadre cheie")) {
                    Picker(T("Cadre cheie"), selection: Binding(get: { m.exportSettings.keyframeSeconds ?? 0 }, set: { m.exportSettings.keyframeSeconds = $0 == 0 ? nil : $0 })) {
                        Text(L10n.f("Implicit (%@ s)", "\(Int(ExportSettings.defaultKeyframeSeconds))")).tag(0.0)
                        ForEach([0.5, 1.0, 2, 5, 10], id: \.self) { Text(L10n.f("la fiecare %@ s", $0.formatted(.number.precision(.fractionLength(0...1))))).tag($0) }
                    }.labelsHidden().fixedSize().disabled(running)
                }
                field(T("Rată audio")) {
                    Picker(T("Rată audio"), selection: Binding(get: { m.exportSettings.audioKbps ?? 0 }, set: { m.exportSettings.audioKbps = $0 == 0 ? nil : $0 })) {
                        Text(T("Automată (AAC 128 kb/s)")).tag(0)
                        ForEach([64, 96, 128, 192, 256, 320], id: \.self) { Text("AAC \($0) kb/s").tag($0) }
                    }.labelsHidden().fixedSize().disabled(running)
                }
                field(T("Canale")) {
                    Picker(T("Canale"), selection: s.audioMono) { Text(T("Stereo")).tag(false); Text(T("Mono")).tag(true) }.pickerStyle(.segmented).labelsHidden().fixedSize().disabled(running)
                        .help(T("Mono = un singur canal (voce), la jumătate din rata audio. Stereo păstrează stânga și dreapta."))
                }
                field(T("Codare")) {
                    Text(plan.hardware == true ? T("Accelerată hardware pe acest Mac (VideoToolbox), o singură trecere") : T("Software, o singură trecere (pentru această mărime nu există encoder hardware)"))
                        .font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                        .help(T("SADROG verifică encoderul înainte de export. Codarea în mai multe treceri nu este oferită de encoderul sistemului, deci nu apare ca opțiune."))
                }
            }
            if m.exportSettings.mode == .master {
                field(T("ProRes")) { Picker(T("ProRes"), selection: s.proRes) { Text("Apple ProRes 422").tag(ExportSettings.ProRes.p422); Text("Apple ProRes 4444").tag(ExportSettings.ProRes.p4444) }.labelsHidden().fixedSize().disabled(running) }
            }
        }
        rangeAndResult
    }
    @ViewBuilder private var rangeAndResult: some View {
        let s = Binding(get: { m.exportSettings }, set: { m.exportSettings = $0 })
        if let r = m.project.exportRange {
            field(T("Interval")) {
                Toggle(L10n.f("Doar între In și Out (%@)", "\(Self.clock(r.lowerBound)) – \(Self.clock(r.upperBound))"), isOn: s.onlyRange).toggleStyle(.checkbox).disabled(running)
            }
        }
        field(T("Rezultat")) {
            VStack(alignment: .leading, spacing: 3) {
                Text(fast ? T("codecul și mărimea sursei, fără re-codificare") : "\(plan.width)×\(plan.height) px · \(plan.fps.formatted(.number.precision(.fractionLength(0...2)))) " + T("cadre/s") + " · " + plan.codec).font(Theme.F.body).foregroundStyle(Theme.C.text).fixedSize(horizontal: false, vertical: true)
                if advanced {
                    if let e = estimateLine { Text(e).font(Theme.F.caption).foregroundStyle(Theme.C.textDim) }
                    Text(lossLabel).font(Theme.F.caption).foregroundStyle(plan.loss == .lossless ? Theme.C.ok : Theme.C.textDim)
                    ForEach(plan.notes, id: \.self) { Text($0).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true) }
                } else if let e = shortEstimate {      // simple view: one plain line; the full reasoning stays in Advanced
                    Text(e).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).help(estimateLine ?? e)
                }
            }
        }
        field(T("Sunet")) { Text(fast ? audioLine : (plan.audio.hasPrefix("AAC") ? audioLine : plan.audio)).font(Theme.F.body).foregroundStyle(Theme.C.text).fixedSize(horizontal: false, vertical: true) }
    }
    private var modeDetail: String {
        switch m.exportSettings.mode {
        case .copy: return T("Copiază fluxurile existente; tăieturile urmează lista de editare. Doar pentru proiecte fără procesare.")
        case .compressed: return T("Procesează imaginea și o comprimă cu pierderi; fișier mic, compatibil.")
        case .master: return T("Procesează și scrie un master de calitate foarte înaltă (ProRes); fișier mare, tot comprimat.")
        case .lossless: return T("Procesează și scrie fiecare cadru fără pierderi (PNG) plus sunetul necomprimat; folder mare.")
        }
    }
    private var lossLabel: String {
        switch plan.loss { case .none: return T("Fără pierderi: nimic nu se re-codifică."); case .lossy: return T("Comprimat cu pierderi."); case .highQuality: return T("Calitate foarte înaltă, dar NU lossless."); case .lossless: return T("Lossless față de cadrele procesate (după scalare și efecte).") }
    }
    /// Audio delivery: the files that will be written, the master-volume rule, conflicts — before anything is written.
    /// What the archive will contain, before anything is copied.
    @ViewBuilder private var archivePlan: some View {
        let files = ProjectArchive.mediaFiles(m.project), gone = files.filter { !FileManager.default.fileExists(atPath: $0) }
        let bytes = ProjectArchive.requiredBytes(m.project)
        field(T("Conține")) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.f("Proiectul și %@ fișiere media (%@)", "\(files.count - gone.count)", L10n.bytes(bytes))).font(Theme.F.body).foregroundStyle(Theme.C.text)
                Text(T("O copie: proiectul și media originale nu se schimbă. Arhiva se deschide ca orice proiect și își găsește media chiar dacă folderul e mutat.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                if !gone.isEmpty { Text(L10n.f("%@ fișiere lipsesc și nu pot fi arhivate.", "\(gone.count)")).font(Theme.F.caption).foregroundStyle(Theme.C.warn) }
            }
        }
    }
    @ViewBuilder private var audioPlan: some View {
        // after a finished export the files exist because THIS export wrote them: no conflict warning then
        let finished: Bool = { if case .done = m.exportState { return true }; return false }()
        let plan = m.deliveryPlan, conflicts = finished ? Set<String>() : Set(m.deliveryConflicts)
        field(T("Fișiere")) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(plan, id: \.fileName) { it in
                    HStack(spacing: 6) {
                        Image(systemName: conflicts.contains(it.fileName) ? "exclamationmark.triangle.fill" : (it.selection == .all ? "waveform" : "waveform.path")).font(Theme.F.iconSmall)
                            .foregroundStyle(conflicts.contains(it.fileName) ? Theme.C.warn : Theme.C.textFaint).frame(width: 14)
                        Text(it.fileName).font(Theme.F.caption).foregroundStyle(conflicts.contains(it.fileName) ? Theme.C.warn : Theme.C.text).lineLimit(1).truncationMode(.middle).help(it.label)
                    }
                }
            }
        }
        field(T("Format")) { Text(L10n.f("AAC .m4a, 48 kHz; toate fișierele încep la 0 și au durata documentului (%@), cu liniște unde sursa tace.", "\(timecode(m.project.timelineEnd))")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true) }
        field(T("Volum")) { Text(T("Efectele audio, volumul, mute-ul și fade-urile fiecărei surse se aplică în fișierul ei. Volumul general (Mix) se aplică doar fișierului „mix”. Sursele mute nu se exportă.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true) }
        if !conflicts.isEmpty { field("") { Text(T("Unele fișiere există deja; nimic nu se suprascrie. Schimbă numele sau folderul.")).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true) } }
    }
    private var audioLine: String {
        let n = m.mainSources.count + m.project.layers.filter { $0.kind == .audio }.count
        if m.project.clips.allSatisfy({ m.media[$0.media]?.hasAudio == false }) && n == 0 { return T("fără sunet") }
        if fast { return T("pista audio a sursei, copiată") }
        if m.exportSettings.audioMono && m.exportSettings.mode == .compressed { return T("AAC mono: mixul din previzualizare, într-un singur canal") }
        return n > 1 ? L10n.f("AAC stereo · %@ surse mixate într-o pistă, ca în previzualizare (sursele mute nu se aud)", "\(n)") : T("AAC stereo, ca în previzualizare")
    }

    /// One compact state panel per outcome: progress, success, failure, cancelled — each with its own icon and tone.
    @ViewBuilder private var status: some View {
        switch m.exportState {
        case .idle: EmptyView()
        case .running(let f):
            statePanel(tone: Theme.C.accent) {
                ProgressView().controlSize(.small).colorScheme(.dark)
                VStack(alignment: .leading, spacing: 6) {
                    HStack { Text(m.exportKind == .archive ? T("Se arhivează…") : T("Se exportă…")).font(Theme.F.body.weight(.medium)).foregroundStyle(Theme.C.text); Spacer(); Text("\(Int(f * 100))%").font(Theme.F.mono).foregroundStyle(Theme.C.text) }
                    ProgressView(value: f).tint(Theme.C.accent)
                    Text(m.exportKind == .archive ? T("Poți anula oricând; arhiva parțială se șterge.") : T("Poți anula oricând; fișierul parțial se șterge.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
                }
            }
        case .done(_, let size):
            statePanel(tone: Theme.C.ok) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.C.ok)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.exportKind == .archive ? T("Arhivă creată") : T("Export terminat")).font(Theme.F.body.weight(.medium)).foregroundStyle(Theme.C.text)
                    Text(m.exportKind == .archive ? (m.archiveMissing > 0 ? L10n.f("%@ · %@ fișiere lipsă nu au fost incluse", "\(bytesString(size))", "\(m.archiveMissing)") : L10n.f("Salvat · %@", "\(bytesString(size))")) : m.deliveredFiles.isEmpty ? L10n.f("Salvat · %@", "\(bytesString(size))") : L10n.f("%@ fișiere complete · %@", "\(m.deliveredFiles.count)", "\(bytesString(size))")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
                }
            }
        case .failed(let e):
            statePanel(tone: Theme.C.record) {
                Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 20)).foregroundStyle(Theme.C.record)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.exportKind == .archive ? T("Arhiva nu s-a putut crea") : T("Exportul nu s-a putut termina")).font(Theme.F.body.weight(.medium)).foregroundStyle(Theme.C.text)
                    Text(e).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .cancelled:
            statePanel(tone: Theme.C.warn) {
                Image(systemName: "stop.circle.fill").font(.system(size: 20)).foregroundStyle(Theme.C.warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text(T("Export anulat")).font(Theme.F.body.weight(.medium)).foregroundStyle(Theme.C.text)
                    Text(m.exportKind == .archive ? T("Arhivarea a fost oprită; nu a rămas nicio arhivă parțială.") : m.exportKind == .audio ? T("Exportul a fost oprit; fișierele deja scrise din acest set au fost șterse.") : T("Exportul a fost oprit; nu a rămas niciun fișier parțial.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
    private func statePanel<C: View>(tone: Color, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) { c() }
            .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(tone.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(tone.opacity(0.28), lineWidth: 0.7))
            .accessibilityElement(children: .combine)
    }

    private func field<C: View>(_ t: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) { Text(t).font(Theme.F.body).foregroundStyle(Theme.C.textDim).multilineTextAlignment(.trailing).frame(width: 92, alignment: .trailing); VStack(alignment: .leading, spacing: 4) { c() }.frame(maxWidth: .infinity, alignment: .leading) }
    }
}
