// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// „Despre SADROG”: name, creator, version, build, source id, site, licences, update check.
struct AboutView: View {
    @ObservedObject var updates = UpdateChecker.shared
    @ObservedObject var act = ActivationModel.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                LogoMark().frame(width: 54, height: 32).foregroundStyle(Theme.C.text)
                VStack(alignment: .leading, spacing: 2) {
                    Text("SADROG").font(.system(size: 20, weight: .semibold)).tracking(3)
                    Text(T("Captură de ecran și editare pentru macOS")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
                }
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 5) {
                info(T("Creator"), "Dumitru Cristinel Gordas")
                info(T("Versiune"), AppInfo.version)
                info(T("Build"), AppInfo.build + (AppInfo.buildDate.isEmpty ? "" : " · \(AppInfo.buildDate)"))
                info(T("Sursa"), AppInfo.sourceID)
                info(T("Activare"), act.statusLine)
                GridRow {
                    Text(T("Site")).foregroundStyle(Theme.C.textFaint)
                    Link("gordas.dev/sadrog", destination: URL(string: "https://gordas.dev/sadrog/")!)
                }
                GridRow {
                    Text(T("Cod sursă")).foregroundStyle(Theme.C.textFaint)
                    Link("github.com/gordasgdc/sadrog", destination: URL(string: "https://github.com/gordasgdc/sadrog")!)
                }
            }.font(Theme.F.body)
            Text(T("Licență: GNU GPL v3 sau ulterioară. Software liber, fără nicio garanție. Folosește doar framework-urile macOS (Apple), fără biblioteci terțe incluse; pluginurile Audio Unit pe care le alegi rămân ale producătorilor lor și nu fac parte din SADROG."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(T("Caută actualizări…")) { updates.checkManually() }.buttonStyle(.gloss(.secondary)).disabled(updates.status == .checking)
                Button(T("Manual de utilizare…")) { NSWorkspace.shared.open(UserManual.url(.current)) }.buttonStyle(.gloss(.secondary))
                if updates.status == .checking { ProgressView().controlSize(.small) }
                Spacer()
                Button(T("Licența GPL…")) { NSWorkspace.shared.open(URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!) }.buttonStyle(.gloss(.ghost))
            }
        }
        .padding(22).frame(width: 440).background(Theme.C.bg1).appTheme()
    }
    private func info(_ k: String, _ v: String) -> some View {
        GridRow { Text(k).foregroundStyle(Theme.C.textFaint); Text(v).textSelection(.enabled) }
    }
}
