// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import UniformTypeIdentifiers
import SadrogCore

/// „Activare”: state, the request (Trial 5 days or permanent licence), the same request on WhatsApp / e-mail, and the manual import.
struct ActivationPage: View {
    @ObservedObject var a = ActivationModel.shared
    @State private var offer: SadrogProduct.Offer = .trial
    @State private var name = ""
    @State private var email = ""
    @State private var computer = Host.current().localizedName ?? ""
    @State private var licenseText = ""
    @State private var consentNow = false
    @State private var consentLoss = false

    private var request: ActivationRequest {
        ActivationRequest(offer: offer, name: name, email: email, computerLabel: computer,
                          consentImmediateSupply: offer == .permanent && consentNow, consentWithdrawalLoss: offer == .permanent && consentLoss)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                status
                if !a.access.allowsRecordAndExport || a.state.pendingRequestID != nil { requestSection }
                importSection
                DisclosureGroup { supportSection.padding(.top, 8) } label: { SectionLabel(T("Susținere voluntară")) }
                DisclosureGroup { legalSection.padding(.top, 8) } label: { SectionLabel(T("Drepturile tale")) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(T("Fără activare: deschiderea, editarea, salvarea și recuperarea proiectelor rămân libere. Nimic nu se șterge, nu se criptează și nu primește filigran; o înregistrare sau un export deja pornit se termină."))
                    Text(L10n.f("Acest Mac: %@", a.machineID ?? "—")).textSelection(.enabled)
                }.font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
            }.padding(.horizontal, 28).padding(.vertical, 24).frame(maxWidth: 660, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var status: some View {
        VStack(alignment: .leading, spacing: 10) {
            PageHeader(title: T("Activare"), subtitle: a.access.allowsRecordAndExport ? T("Înregistrarea și exportul sunt disponibile.") : T("Editarea rămâne liberă; înregistrarea și exportul cer activare."), tone: a.access.allowsRecordAndExport ? Theme.C.ok : Theme.C.textFaint)
            HStack(spacing: 10) {
                Image(systemName: a.access.allowsRecordAndExport ? "checkmark.seal.fill" : "seal").font(.system(size: 18)).foregroundStyle(a.access.allowsRecordAndExport ? Theme.C.ok : Theme.C.textFaint)
                Text(a.statusLine).font(Theme.F.heading)
                Spacer()
                if a.busy { ProgressView().controlSize(.small) }
            }.padding(.horizontal, 12).frame(minHeight: 44).background(PanelBackground(radius: 9))
            if let s = a.requestState, a.state.pendingRequestID != nil {
                Text(L10n.f("Cererea trimisă: %@. SADROG verifică singur la fiecare 20 de secunde cât e deschis.", ActivationModel.stateLabel(s))).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
            }
            if let msg = a.message { Text(msg).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).textSelection(.enabled) }
        }
    }

    private var requestSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(T("Cere activarea"))
            Picker("", selection: $offer) {
                Text(T("Trial Full · 5 zile")).tag(SadrogProduct.Offer.trial)
                Text(L10n.f("Licență permanentă · contribuție %d EUR", SadrogProduct.contributionEUR)).tag(SadrogProduct.Offer.permanent)
            }.pickerStyle(.radioGroup).labelsHidden()
            .onChange(of: offer) { _, _ in consentNow = false; consentLoss = false }
            Text(offer == .trial
                 ? T("Un singur trial per Mac. Cele 5 zile pornesc la prima activare, după aprobare; reinstalarea nu dă un trial nou.")
                 : T("Fără abonament și fără expirare; un Mac (transferul se face la cerere). Funcționează și dacă serviciul de activare nu mai există. Actualizările ulterioare sunt incluse. Contribuția se trimite după răspunsul nostru; cererea nu e o plată."))
                .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            if offer == .permanent {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle(ActivationModel.consentImmediateText, isOn: $consentNow).toggleStyle(.checkbox)
                    Toggle(ActivationModel.consentLossText, isOn: $consentLoss).toggleStyle(.checkbox)
                    Text(T("Opțional. Fără ambele acorduri, cererea pleacă oricum, iar activarea permanentă se face după 14 zile de la confirmarea contribuției. Confirmarea acordurilor îți vine odată cu licența."))
                        .foregroundStyle(Theme.C.textFaint)
                }.font(Theme.F.caption).fixedSize(horizontal: false, vertical: true)
            }
            labeled(T("Nume")) { AppTextField(placeholder: T("Numele tău"), text: $name) }
            labeled(T("E-mail")) { AppTextField(placeholder: "nume@exemplu.ro", text: $email) }
            labeled(T("Calculator")) { AppTextField(placeholder: T("opțional"), text: $computer) }
            HStack(spacing: 8) {
                Button(a.state.pendingRequestID != nil && a.state.pendingOffer == offer ? T("Retrimite cererea") : T("Trimite cererea")) { Task { await a.send(request) } }
                    .buttonStyle(.gloss(.primary)).disabled(!request.problems.isEmpty || a.busy)
                Button(T("WhatsApp")) { a.openWhatsApp(request) }.buttonStyle(.gloss(.secondary)).disabled(!request.problems.isEmpty)
                    .help(T("Deschide WhatsApp cu aceeași cerere (același identificator); nu se creează o cerere nouă."))
                Button(T("E-mail")) { a.openMail(request) }.buttonStyle(.gloss(.secondary)).disabled(!request.problems.isEmpty)
                    .help(T("Deschide un e-mail cu aceeași cerere (același identificator)."))
                if a.state.pendingRequestID != nil { Button(T("Renunță la cerere")) { a.cancelPending() }.buttonStyle(.gloss(.ghost)) }
            }
            Text(T("Numele și e-mailul servesc doar ca să-ți putem răspunde despre această cerere.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
        }
    }

    private var importSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(T("Ai primit licența pe WhatsApp sau e-mail?"))
            HStack(spacing: 8) {
                AppTextField(placeholder: "GDC3-…", text: $licenseText, mono: true)
                Button(T("Importă")) { Task { await a.importLicense(licenseText); licenseText = "" } }.buttonStyle(.gloss(.secondary)).disabled(licenseText.isEmpty)
                Button(T("Din fișier…")) { pickFile() }.buttonStyle(.gloss(.secondary))
            }
        }
    }

    private var supportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(T("Separată de activare: nu deblochează nimic și nu e niciodată obligatorie.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
            HStack(spacing: 8) {
                Button(T("WhatsApp")) { a.openSupport(whatsapp: true) }.buttonStyle(.gloss(.secondary))
                Button(T("E-mail")) { a.openSupport(whatsapp: false) }.buttonStyle(.gloss(.secondary))
            }
        }
    }

    private var legalSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Group {
                Text(T("Politica voluntară: SADROG nu oferă o rambursare voluntară suplimentară."))
                Text(T("Dreptul legal de retragere (UE, 14 zile) se aplică activării permanente plătite și încetează la activare doar dacă ai cerut expres activarea imediată și ai confirmat că pierzi acest drept (cele două bife de mai sus)."))
                Text(T("Drepturile legale în caz de neconformitate se aplică întotdeauna: remediere, iar dacă nu e posibilă într-un termen rezonabil, reducerea contribuției sau încetarea contractului, în condițiile legii."))
                Text(T("SADROG este software liber (GNU GPL v3 sau ulterioară), oferit „așa cum este” conform licenței; aceasta nu restrânge drepturile legale de mai sus."))
            }.font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Link(T("Termeni"), destination: URL(string: "https://gordas.dev/termeni")!)
                Link(T("Confidențialitate"), destination: URL(string: "https://gordas.dev/confidentialitate")!)
                Link("GPL v3", destination: URL(string: "https://www.gnu.org/licenses/gpl-3.0.html")!)
            }.font(Theme.F.caption)
        }
    }

    private func labeled<C: View>(_ l: String, @ViewBuilder _ c: () -> C) -> some View {
        HStack(spacing: 10) { Text(l).font(Theme.F.body).foregroundStyle(Theme.C.textDim).frame(width: 90, alignment: .leading); c() }
    }
    private func pickFile() {
        let p = NSOpenPanel(); p.allowsMultipleSelection = false; p.canChooseDirectories = false
        p.allowedContentTypes = [UTType(filenameExtension: "gdclicense") ?? .data, .plainText]
        guard p.runModal() == .OK, let u = p.url, let t = try? String(contentsOf: u, encoding: .utf8) else { return }
        Task { await a.importLicense(t) }
    }
}
