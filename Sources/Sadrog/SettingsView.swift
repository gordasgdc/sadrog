// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// The Settings window (⌘,), by purpose: General (language, appearance), Recording, Export (default preset), About. Every control writes the same value the
/// main window uses, applies at once, and there is nothing to confirm. The appearance follows the system, or is fixed dark/light.
struct SettingsView: View {
    @ObservedObject var m: RecorderModel
    @AppStorage("sadrog.language") private var language = AppLanguage.current.rawValue
    @AppStorage(AppTheme.key) private var theme = AppTheme.dark.rawValue
    @AppStorage(RecorderModel.collectMouseKey) private var collectMouse = false
    @AppStorage(RecorderModel.collectWindowKey) private var collectWindow = false
    @AppStorage(RecorderModel.collectKeysKey) private var collectKeys = false
    @State private var presets = SettingsView.store()
    static func store() -> ExportPresetStore { ExportPresetStore(url: AppInfo.supportFolder.appendingPathComponent("ExportPresets.json")) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PageHeader(title: T("Setări"), subtitle: T("Se aplică imediat"))
            HairlineDivider()
            section(T("General"))
            row(T("Limba")) {
                Picker("", selection: $language) { ForEach(AppLanguage.allCases) { Text($0.name).tag($0.rawValue) } }.labelsHidden().fixedSize()
            }
            row(T("Aspect")) {
                Picker("", selection: $theme) { ForEach(AppTheme.allCases) { Text($0.name).tag($0.rawValue) } }.labelsHidden().pickerStyle(.segmented).frame(width: 230).id(language).accessibilityLabel(T("Aspectul aplicației"))
            }
            section(T("Înregistrare"))
            row(T("Numărătoare înainte de înregistrare")) {
                Picker("", selection: $m.countdownSeconds) { ForEach([0, 3, 5, 10, 15], id: \.self) { Text($0 == 0 ? T("fără") : "\($0) s").tag($0) } }.labelsHidden().fixedSize()
            }
            row(T("Salvează mișcarea cursorului")) {
                Toggle("", isOn: $collectMouse).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityHint(T("Doar poziția și clicurile, doar cât înregistrezi; nu se citește tastatura"))
            }
            Text(T("Doar poziția și clicurile cursorului, doar cât ține înregistrarea; nu se citește tastatura și nimic nu pornește la deschiderea aplicației. Le folosești apoi în editor: evidențiere, cercuri la clic, zoom care urmărește cursorul."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            row(T("Salvează comenzile de tastatură")) {
                Toggle("", isOn: Binding(get: { collectKeys }, set: { on in collectKeys = on; if on, !CGPreflightListenEventAccess() { _ = CGRequestListenEventAccess() } })).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityHint(T("Doar combinațiile cu ⌘, ⌃ sau ⌥ și tastele funcționale, doar cât înregistrezi; celelalte taste sunt ignorate pe loc și nu se păstrează"))
            }
            Text(T("Doar comenzile (de exemplu ⌘K) și tastele funcționale, doar cât ține înregistrarea, ca să le poți arăta în editor. Sistemul trimite aplicației toate apăsările de taste cât ține înregistrarea; fiecare e clasificată pe loc și se păstrează doar eticheta unei comenzi — textul scris și tastele simple se aruncă și nu ajung în niciun fișier. Cât timp un câmp securizat (parolă) cere Secure Input, sistemul nu trimite taste și nu se salvează nimic. Cere permisiunea Monitorizare intrare; nimic nu pornește la deschiderea aplicației."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            row(T("Salvează fereastra din prim-plan")) {
                Toggle("", isOn: $collectWindow).labelsHidden().toggleStyle(.switch).controlSize(.small)
                    .accessibilityHint(T("Poziția ferestrei din față și numele aplicației, doar cât înregistrezi; fără titluri sau conținut"))
            }
            Text(T("Poziția și dimensiunea ferestrei aflate în față și aplicația ei, doar cât ține înregistrarea; titlul ferestrei și conținutul ei nu se citesc și nimic nu pornește la deschiderea aplicației. Se salvează lângă înregistrare; editorul nu le folosește încă."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            row(T("Folder de destinație")) {
                HStack(spacing: 8) {
                    Text(m.destination?.path ?? T("nealeasă")).font(Theme.F.body).foregroundStyle(m.destination == nil ? Theme.C.warn : Theme.C.textDim).lineLimit(1).truncationMode(.middle).frame(maxWidth: 230, alignment: .trailing)
                    Button(T("Alege…")) { m.chooseDestination() }.buttonStyle(.gloss(.secondary, compact: true))
                }
            }
            section(T("Export"))
            row(T("Preset implicit")) {
                Picker("", selection: Binding(get: { presets.defaultID ?? "" }, set: { presets.setDefault($0.isEmpty ? nil : $0); presets = Self.store() })) {
                    Text(T("Calitate maximă (ca documentul)")).tag("")
                    ForEach(presets.all) { Text($0.name).tag($0.id) }
                }.labelsHidden().fixedSize()
            }
            Text(T("Cu ce preset pornește fereastra de export. Presetele personale se salvează din fereastra de export, în modul Avansat."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            section(T("Comenzi rapide"))
            ShortcutsSettings()
            section(T("Despre"))
            row(T("Versiune")) { Text(AppInfo.fullVersion).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled) }
        }
        .padding(20).frame(width: 560).background(Theme.C.bg1).appTheme()
    }
    private func section(_ t: String) -> some View {
        VStack(alignment: .leading, spacing: 4) { Text(t.uppercased()).font(Theme.F.caption.weight(.semibold)).foregroundStyle(Theme.C.textDim).padding(.top, 4); HairlineDivider() }
    }
    private func row<C: View>(_ label: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label).font(Theme.F.body).foregroundStyle(Theme.C.text).frame(width: 190, alignment: .leading).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0); c()
        }.frame(minHeight: 26)
    }
}
