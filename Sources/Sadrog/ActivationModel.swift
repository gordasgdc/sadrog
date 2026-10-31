// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import SadrogCore

/// The app's activation: one place, read by the recorder (new recordings) and the editor (export). Without activation, opening, editing,
/// saving and recovery stay free; nothing is deleted, encrypted or watermarked, and a recording or export already running always finishes.
@MainActor
final class ActivationModel: ObservableObject {
    static let shared = ActivationModel()

    @Published private(set) var access: SadrogAccess = .free(reason: .notActivated)
    @Published private(set) var state = ActivationState()
    @Published private(set) var requestState: String?
    @Published var message: String?
    @Published private(set) var busy = false

    let machineID = MachineID.current
    private let store = ActivationStore()
    private var device: DeviceKey?
    private var pollTask: Task<Void, Never>?
    private let log = DiagnosticLog("activation")

    private init() {
        state = store.load()
        do { device = try store.deviceKey() } catch { message = T("Cheia acestui Mac nu poate fi citită din Keychain. Activarea nu e disponibilă.") }
        recompute()
        Task { await refreshOnline() }
        if state.pendingRequestID != nil, state.licenseText == nil { startPolling() }
    }

    var allowsRecordAndExport: Bool { access.allowsRecordAndExport }
    /// The message shown where recording / export is blocked.
    var blockedText: String {
        switch access {
        case .free(.trialEnded): return T("Trialul s-a încheiat. Înregistrarea nouă și exportul cer licența permanentă (Activare).")
        case .free(.refused): return T("Licența acestui Mac a fost oprită. Editarea rămâne liberă; pentru înregistrare și export, vezi Activare.")
        default: return T("Înregistrarea nouă și exportul cer activarea (Trial 5 zile sau licența permanentă). Editarea rămâne liberă.")
        }
    }
    /// The server's request state, translated (the server speaks Romanian).
    static func stateLabel(_ s: String) -> String {
        switch s {
        case "nouă": return T("nouă — așteaptă verificarea")
        case "verificată": return T("verificată")
        case "aprobată": return T("aprobată")
        case "respinsă": return T("respinsă")
        case "licență emisă": return T("licență emisă")
        case "activată": return T("activată")
        case "expirată": return T("expirată")
        case "revocată": return T("revocată")
        case "dezactivată": return T("dezactivată")
        default: return s
        }
    }
    var statusLine: String {
        switch access {
        case .permanent: return T("Licență permanentă activă pe acest Mac")
        case .trial(let until): return L10n.f("Trial activ până la %@", L10n.date(until))
        case .free(.trialEnded): return T("Trialul s-a încheiat")
        case .free(.refused): return T("Licența a fost oprită")
        case .free(.invalid): return T("Licența importată nu e valabilă pe acest Mac")
        case .free(.notActivated): return T("Neactivat")
        }
    }

    private func client() -> ActivationClient? {
        guard let device else { return nil }
        return ActivationClient(device: device, machineID: machineID, language: AppLanguage.current.rawValue)
    }
    private func recompute() {
        guard let device else { access = .free(reason: .notActivated); return }
        access = AccessResolver.resolve(state: state, machineID: machineID, deviceKeyID: device.keyID, now: Date())
    }
    private func persist() { try? store.save(state); recompute() }

    // MARK: request

    /// Sends the request (or resends the pending one, same id: never a duplicate).
    func send(_ r: ActivationRequest) async {
        guard let c = client() else { return }
        if state.pendingOffer != r.offer || state.pendingRequestID == nil { state.pendingRequestID = UUID().uuidString.lowercased(); state.pendingOffer = r.offer }
        persist()
        busy = true; defer { busy = false }
        do {
            _ = try await c.submit(requestID: state.pendingRequestID!, r)
            if r.offer == .permanent { saveConsentProof(r, requestID: state.pendingRequestID!) }
            log.info("Cerere trimisă: \(r.offer.rawValue)")
            message = r.offer == .trial
                ? T("Cererea de trial a fost trimisă. După aprobare, SADROG preia singur activarea; cele 5 zile pornesc atunci.")
                : T("Cererea pentru licența permanentă a fost trimisă. După verificarea contribuției, SADROG preia singur licența.")
            startPolling()
        } catch { message = Self.describe(error); log.warning("Cererea nu a plecat: \(error)") }
    }

    /// Local copy of what was agreed, with the time (the signed request on the server is the other half of the proof).
    private func saveConsentProof(_ r: ActivationRequest, requestID: String) {
        let text = [L10n.f("Cererea %@ · %@", requestID, WireTime.format(Date())),
                    (r.consentImmediateSupply ? "[x] " : "[ ] ") + Self.consentImmediateText,
                    (r.consentWithdrawalLoss ? "[x] " : "[ ] ") + Self.consentLossText, r.consentRecord ?? ""].joined(separator: "\n")
        let url = store.stateURL.deletingLastPathComponent().appendingPathComponent("acord-\(requestID).txt")
        try? text.write(to: url, atomically: true, encoding: .utf8)
        log.info("Acordurile cererii permanente salvate local (\(r.consentRecord ?? ""))")
    }
    static var consentImmediateText: String { T("Cer activarea permanentă imediat după confirmarea contribuției, înainte de încheierea celor 14 zile de retragere.") }
    static var consentLossText: String { T("Iau la cunoștință că, odată începută activarea, pierd dreptul legal de retragere.") }

    /// Voluntary support: a message only; it activates nothing and shows no amount.
    func openSupport(whatsapp: Bool) {
        let t = T("Bună ziua, aș vrea să susțin voluntar proiectul SADROG. Cum pot face asta?")
        NSWorkspace.shared.open(whatsapp ? ContactLinks.whatsapp(text: t) : ContactLinks.mail(subject: T("SADROG — susținere voluntară"), body: t))
    }

    func contactText(_ r: ActivationRequest) -> String? {
        guard let c = client() else { return nil }
        if state.pendingOffer != r.offer || state.pendingRequestID == nil { state.pendingRequestID = UUID().uuidString.lowercased(); state.pendingOffer = r.offer; persist() }
        let intro = r.offer == .trial ? T("Bună ziua, cer Trialul SADROG de 5 zile pentru acest Mac.") : T("Bună ziua, cer licența permanentă SADROG (contribuție 25 EUR) pentru acest Mac.")
        return intro + "\n\n" + c.contactBlock(requestID: state.pendingRequestID!, r)
    }
    func openWhatsApp(_ r: ActivationRequest) {
        guard let t = contactText(r) else { return }
        NSWorkspace.shared.open(ContactLinks.whatsapp(text: t))
    }
    func openMail(_ r: ActivationRequest) {
        guard let t = contactText(r) else { return }
        NSWorkspace.shared.open(ContactLinks.mail(subject: "SADROG — " + (r.offer == .trial ? "Trial" : T("licență permanentă")), body: t))
    }

    func cancelPending() {
        pollTask?.cancel(); pollTask = nil
        state.pendingRequestID = nil; state.pendingOffer = nil; requestState = nil; persist()
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollOnce()
                if self.state.pendingRequestID == nil { return }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
    }
    func pollOnce() async {
        guard let c = client(), let id = state.pendingRequestID else { return }
        do {
            let st = try await c.poll(requestID: id)
            requestState = st.state
            if st.state == "respinsă" { message = T("Cererea a fost respinsă. Pentru detalii, scrie pe WhatsApp sau e-mail."); state.pendingRequestID = nil; persist(); return }
            if let lic = st.licenseText { await install(licenseText: lic, fromRequest: true) }
        } catch ActivationClientError.offline { /* retried at the next tick */ }
        catch { message = Self.describe(error) }
    }

    // MARK: licence

    /// Manual alternative: a licence received on WhatsApp / e-mail (text `GDC3-…` or a `.gdclicense` file).
    func importLicense(_ text: String) async { await install(licenseText: text.trimmingCharacters(in: .whitespacesAndNewlines), fromRequest: false) }

    private func install(licenseText text: String, fromRequest: Bool) async {
        guard let device, let machineID else { message = T("Acest Mac nu are un identificator citibil; activarea nu e posibilă."); return }
        let lic: LicenseG3
        do { lic = try LicenseG3.verify(text: text, ring: SadrogProduct.licenseRing, product: SadrogProduct.id, machineID: machineID, deviceKeyID: device.keyID).0 }
        catch ActivationError.wrongMachine { message = T("Licența e pentru alt Mac."); return }
        catch ActivationError.wrongDevice { message = T("Licența e pentru altă instalare (altă cheie a dispozitivului)."); return }
        catch { message = T("Textul nu e o licență SADROG valabilă."); return }
        state.licenseText = text
        if fromRequest || state.pendingRequestID != nil { state.pendingRequestID = nil; state.pendingOffer = nil; pollTask?.cancel() }
        persist()
        await activateOnline(text)
        if lic.lifetime { message = T("Licența permanentă e activă. Funcționează și fără internet.") }
    }

    private func activateOnline(_ text: String) async {
        guard let c = client() else { return }
        busy = true; defer { busy = false }
        do { apply(try await c.activate(licenseText: text)) }
        catch ActivationClientError.offline { if case .permanent = access {} else { message = T("Fără conexiune: trialul pornește la prima conectare.") } }
        catch { message = Self.describe(error) }
    }

    /// At launch and when the lease asks for it: renew (never blocks anything; offline keeps the current state).
    func refreshOnline() async {
        guard let c = client() else { return }
        if let id = state.activationID {
            let due = state.lease.flatMap { try? JSONDecoder().decode(Lease.self, from: Data(base64Encoded: $0.payload) ?? Data()) }.flatMap { WireTime.parse($0.renew_after) } ?? .distantPast
            if Date() >= due { if let o = try? await c.renew(activationID: id) { apply(o) } }
        } else if let text = state.licenseText {
            await activateOnline(text)
        }
        recompute()
    }

    private func apply(_ o: ActivationClient.Outcome) {
        switch o {
        case .granted(let env, let lease):
            log.info("Lease primit (generația \(lease.generation), până la \(lease.expires_at))")
            state.lease = env; state.activationID = lease.activation_id; state.leaseGeneration = lease.generation
            state.timeFloor = max(state.timeFloor ?? .distantPast, WireTime.parse(lease.server_time) ?? .distantPast)
        case .refused(let code, let licenseID):
            log.warning("Refuz semnat: \(code)")
            state.lease = nil; state.activationID = nil
            if let l = licenseID ?? licenseIDOfCurrent(), code.contains("revoked") || code.contains("deactivated") || code.contains("superseded") {
                if !state.refusedLicenses.contains(l) { state.refusedLicenses.append(l) }
            }
            if code.contains("expired") { message = T("Trialul s-a încheiat.") }
        }
        persist()
    }
    private func licenseIDOfCurrent() -> String? {
        guard let t = state.licenseText, let env = LicenseText.decode(t), let e = try? SignedEnvelope.decode(env),
              let p = Data(base64Encoded: e.payload), let o = try? JSONSerialization.jsonObject(with: p) as? [String: Any] else { return nil }
        return o["license_id"] as? String
    }

    static func describe(_ e: Error) -> String {
        switch e {
        case ActivationClientError.invalid: return T("Completează numele și o adresă de e-mail validă.")
        case ActivationClientError.offline: return T("Fără conexiune. Cererea nu a plecat; o poți retrimite (aceeași cerere) sau trimite pe WhatsApp / e-mail.")
        case ActivationClientError.noMachineID: return T("Acest Mac nu are un identificator citibil; activarea nu e posibilă.")
        case ActivationClientError.server(_, let code):
            switch code {
            case "too_many_requests", "rate_limited": return T("Prea multe cereri de pe acest Mac azi. Încearcă mâine sau scrie pe WhatsApp / e-mail.")
            case "offer_not_available", "unknown_offer_version": return T("Oferta nu mai e disponibilă. Actualizează SADROG.")
            case "request_exists": return T("Cererea există deja de pe altă instalare.")
            default: return L10n.f("Serverul a refuzat cererea (%@).", code)
            }
        default: return L10n.f("Eroare: %@", e.localizedDescription)
        }
    }
}

/// Contact links. The number and the address are the public ones of gordas.dev; built at run time so they are not one string in the source.
enum ContactLinks {
    private static let phone = ["34", "643", "109", "970"].joined()
    private static let mailbox = ["academiagdc", "gmail.com"].joined(separator: "@")
    private static func q(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics; allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }
    static func whatsapp(text: String) -> URL { URL(string: "https://wa.me/\(phone)?text=\(q(text))")! }
    static func mail(subject: String, body: String) -> URL { URL(string: "mailto:\(mailbox)?subject=\(q(subject))&body=\(q(body))")! }
}
