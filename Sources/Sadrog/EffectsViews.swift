// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// One line under a recording source's volume: what the chain is, its processing state, and the button that opens the chain.
struct EffectsRow: View {
    @ObservedObject var m: EditorModel
    let k: Int
    @State private var show = false
    private var summary: String {
        let c = m.effects(k); if c.isEmpty { return T("Fără efecte") }
        let on = c.filter { !$0.bypassed }
        return on.isEmpty ? L10n.f("Efecte ocolite (%@)", "\(c.count)") : on.map(\.name).joined(separator: T(" › "))
    }
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "slider.vertical.3").font(Theme.F.iconSmall).foregroundStyle(m.effects(k).isEmpty ? Theme.C.textFaint : Theme.C.textDim).frame(width: 14)
            Text(summary).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            FxStatusBadge(state: m.fxState(k))
            Button(T("Efecte…")) { show = true }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                .help(T("Pluginuri audio (Audio Unit) pe această sursă")).accessibilityLabel(L10n.f("Efecte audio pentru %@", "\(m.sourceName(k))"))
                .popover(isPresented: $show, arrowEdge: .leading) { EffectsPopover(m: m, k: k) }
        }.frame(height: 24)
    }
}

struct FxStatusBadge: View {
    let state: FxState?
    var body: some View {
        switch state {
        case .processing(let f):
            HStack(spacing: 3) { ProgressView().controlSize(.mini); Text(verbatim: "\(Int(f * 100))%").font(Theme.F.monoSmall).foregroundStyle(Theme.C.textDim) }
                .help(T("Se procesează; până la final se aude sursa fără efecte")).accessibilityLabel(L10n.f("Se procesează %@ la sută", "\(Int(f * 100))"))
        case .failed(let w):
            Image(systemName: "exclamationmark.triangle.fill").font(Theme.F.iconSmall).foregroundStyle(Theme.C.warn).help(w).accessibilityLabel(T("Procesare eșuată"))
        case .ready:
            Image(systemName: "checkmark.circle").font(Theme.F.iconSmall).foregroundStyle(Theme.C.ok).help(T("Efectele sunt procesate; previzualizarea și exportul le folosesc")).accessibilityLabel(T("Procesat"))
        case nil: EmptyView()
        }
    }
}

struct EffectsPopover: View {
    @ObservedObject var m: EditorModel
    let k: Int
    @State private var search = ""
    @State private var catalog: [AUInfo] = []
    @State private var adding = false
    var body: some View {
        let chain = m.effects(k)
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(L10n.f("Efecte — %@", "\(m.sourceName(k))")).font(Theme.F.heading)
                Text(T("Se aplică în ordine, înaintea volumului și fade-urilor sursei, pe toată înregistrarea (tăieturile nu le resetează). Pluginul rulează într-un proces separat; sunetul se procesează offline și se aude după procesare."))
                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
            if chain.isEmpty {
                Text(T("Niciun efect pe această sursă.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(chain.enumerated()), id: \.element.id) { i, e in
                        EffectChainRow(m: m, k: k, index: i, count: chain.count, e: e)
                        if i < chain.count - 1 { Rectangle().fill(Theme.C.line.opacity(0.5)).frame(height: 1) }
                    }
                }
            }
            statusBlock
            Rectangle().fill(Theme.C.line).frame(height: 1)
            voiceBlock
            Rectangle().fill(Theme.C.line).frame(height: 1)
            if adding { addList } else {
                Button { adding = true; if catalog.isEmpty { catalog = AUCatalog.effects() } } label: { Label(T("Adaugă efect…"), systemImage: "plus") }
                    .buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
            }
        }.padding(14).frame(width: 380)
    }

    @State private var voiceError: String?
    private func title(_ p: VoicePreset) -> String {
        switch p { case .highPassOnly: return T("Doar filtru de joase"); case .cleanVoice: return T("Voce curată"); case .podcast: return T("Voce de podcast"); case .limiterOnly: return T("Doar limitator") }
    }
    private func detail(_ p: VoicePreset) -> String {
        switch p {
        case .highPassOnly: return T("Taie zgomotul și bubuitul sub 80 Hz. Nu elimină zgomotul din banda vocii.")
        case .cleanVoice: return T("Filtru de joase la 80 Hz, compresor ușor și expander conservator între cuvinte, limitator de vârfuri.")
        case .podcast: return T("Filtru la 90 Hz, compresie mai fermă pentru nivel constant, expander conservator, limitator de vârfuri.")
        case .limiterOnly: return T("Doar limitator de vârfuri: nu lasă sunetul să depășească 0 dBFS.")
        }
    }
    @ViewBuilder private var voiceBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(T("Procesare de voce")).font(Theme.F.heading)
            Text(T("Folosește efectele Apple din sistem, prin același gazdă ca orice plugin: fiecare treaptă apare mai sus și poate fi ocolită, mutată, deschisă sau ștearsă. Expanderul NU este eliminare inteligentă a zgomotului."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            ForEach(VoicePreset.allCases, id: \.self) { p in
                Button(title(p)) {
                    voiceError = nil
                    Task.detached(priority: .userInitiated) {
                        do { let fx = try p.effects(); await MainActor.run { m.apply { try? $0.setVoicePreset(p, source: k, media: m.shownMedia, effects: fx) } } }
                        catch { await MainActor.run { voiceError = "\(error)" } }
                    }
                }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize().help(detail(p)).accessibilityHint(detail(p))
            }
            Button(T("Resetează procesarea de voce")) { m.apply { try? $0.setVoicePreset(nil, source: k, media: m.shownMedia) } }
                .buttonStyle(.gloss(.secondary, compact: true)).fixedSize().disabled(!chainHasVoice)
            if let voiceError { Text(voiceError).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true) }
        }
    }
    private var chainHasVoice: Bool { m.effects(k).contains { VoicePreset.isVoiceStage($0) } }

    @ViewBuilder private var statusBlock: some View {
        switch m.fxState(k) {
        case .processing(let f):
            VStack(alignment: .leading, spacing: 4) {
                HStack { ProgressView(value: f).progressViewStyle(.linear); Button(T("Oprește")) { m.stopEffects(k) }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize() }
                Text(L10n.f("Se procesează (%@%%). Până la final se aude sursa fără efecte; exportul devine disponibil după final.", "\(Int(f * 100))")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
            }
        case .failed(let w):
            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.C.warn).font(Theme.F.iconSmall)
                Text(w + T(". Se aude sursa fără efecte; exportul e blocat până la reușită sau până ocolești efectul.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button(T("Reîncearcă")) { m.retryEffects(k) }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
            }
        case .ready:
            if let r = m.fxReport(k) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(r.delays.enumerated()), id: \.offset) { _, d in
                        if d.source != .none { Text(delayText(d)).font(Theme.F.caption).foregroundStyle(d.source == .undetermined ? Theme.C.warn : Theme.C.textDim).fixedSize(horizontal: false, vertical: true) }
                    }
                    if r.delays.allSatisfy({ $0.source == .none }) { Text(T("Procesat; niciun plugin nu întârzie sunetul.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim) }
                    ForEach(r.versionChanged, id: \.self) { Text(L10n.f("Versiune instalată diferită de cea cu care s-a salvat starea: %@", "\($0)")).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true) }
                }
            }
        case nil: EmptyView()
        }
    }
    private func delayText(_ d: EffectDelay) -> String {
        let ms = String(format: "%.1f", Double(d.samples) / 48)
        switch d.source {
        case .reported: return L10n.f("%@: întârziere %@ ms raportată de plugin, compensată", "\(d.name)", "\(ms)")
        case .measured: return L10n.f("%@: întârziere constantă %@ ms măsurată (nu e raportată de plugin), compensată", "\(d.name)", "\(ms)")
        case .undetermined: return L10n.f("%@: întârzierea nu se poate determina — nu e compensată", "\(d.name)")
        case .none: return ""
        }
    }

    private var filtered: [AUInfo] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? catalog : catalog.filter { $0.name.lowercased().contains(q) || $0.manufacturerName.lowercased().contains(q) }
    }
    @ViewBuilder private var addList: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                AppTextField(placeholder: T("Caută după nume sau producător"), text: $search)
                Button(T("Gata")) { adding = false; search = "" }.buttonStyle(.gloss(.ghost, compact: true)).fixedSize()
            }
            Text(filtered.count == catalog.count ? L10n.f("%@ efecte instalate (Audio Unit)", "\(catalog.count)") : L10n.f("%@ din %@ efecte instalate (Audio Unit)", "\(filtered.count)", "\(catalog.count)")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { info in
                        Button { m.addEffect(k, info) } label: {
                            HStack(spacing: 6) {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(info.name).font(Theme.F.body).lineLimit(1)
                                    Text("\(info.manufacturerName) · \(info.versionString)\(info.isMusicEffect ? " · efect muzical" : "")").font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).lineLimit(1)
                                }
                                Spacer(minLength: 4)
                                Image(systemName: "plus.circle").font(Theme.F.icon).foregroundStyle(Theme.C.textDim)
                            }.padding(.vertical, 4).padding(.horizontal, 4).contentShape(Rectangle())
                        }.buttonStyle(.plain).help(T("Adaugă la sfârșitul lanțului")).accessibilityLabel(L10n.f("Adaugă %@ de %@", "\(info.name)", "\(info.manufacturerName)"))
                    }
                }
            }.frame(height: 210)
        }
    }
}

struct EffectChainRow: View {
    @ObservedObject var m: EditorModel
    let k: Int, index: Int, count: Int
    let e: AudioEffect
    var body: some View {
        let installed = m.isInstalled(e)
        HStack(spacing: 4) {
            Text("\(index + 1)").font(Theme.F.monoSmall).foregroundStyle(Theme.C.textFaint).frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.name).font(Theme.F.body).lineLimit(1).opacity(e.bypassed ? 0.5 : 1).strikethrough(e.bypassed)
                Text(installed ? (e.bypassed ? "\(e.manufacturerName) · ocolit" : e.manufacturerName) : L10n.f("%@ · LIPSEȘTE pe acest Mac (starea e păstrată)", "\(e.manufacturerName)"))
                    .font(Theme.F.caption).foregroundStyle(installed ? Theme.C.textFaint : Theme.C.warn).lineLimit(installed ? 1 : 2).fixedSize(horizontal: false, vertical: !installed)
            }
            Spacer(minLength: 4)
            icon(e.bypassed ? "power.circle" : "power.circle.fill", e.bypassed ? T("Activează efectul") : T("Ocolește efectul (bypass): rămâne în lanț, nu procesează"), tint: e.bypassed ? Theme.C.textFaint : Theme.C.ok) { m.setBypass(k, e.id, !e.bypassed) }
            icon("chevron.up", T("Mută mai devreme în lanț")) { m.moveEffect(k, e.id, by: -1) }.disabled(index == 0).opacity(index == 0 ? 0.35 : 1)
            icon("chevron.down", T("Mută mai târziu în lanț")) { m.moveEffect(k, e.id, by: 1) }.disabled(index == count - 1).opacity(index == count - 1 ? 0.35 : 1)
            icon("macwindow", T("Deschide interfața pluginului")) { m.openPlugin(k, e.id) }.disabled(!installed).opacity(installed ? 1 : 0.35)
            icon("trash", T("Elimină efectul")) { m.removeEffect(k, e.id) }
        }.padding(.vertical, 5)
    }
    private func icon(_ name: String, _ help: String, tint: Color = Theme.C.textDim, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(Theme.F.icon).frame(width: 24, height: 22).contentShape(Rectangle()) }
            .buttonStyle(.plain).foregroundStyle(tint).help(help).accessibilityLabel("\(help) — \(e.name)")
    }
}
