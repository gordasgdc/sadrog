// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CryptoKit
import Security

/// The request a person sends from SADROG: the chosen offer, a name and an e-mail (so the owner can reply), an optional computer label.
/// A request grants nothing by itself: the owner verifies it (and, for the permanent licence, the contribution) and activates in Admin.
public struct ActivationRequest: Equatable, Sendable {
    public var offer: SadrogProduct.Offer
    public var name: String
    public var email: String
    public var computerLabel: String
    public var note: String
    /// Statutory withdrawal right (EU, paid permanent activation only): two separate, explicit agreements, never pre-ticked.
    /// Without both, the request still goes out; the owner then activates only after the 14-day period.
    public var consentImmediateSupply: Bool
    public var consentWithdrawalLoss: Bool
    public init(offer: SadrogProduct.Offer, name: String, email: String, computerLabel: String = "", note: String = "",
                consentImmediateSupply: Bool = false, consentWithdrawalLoss: Bool = false) {
        self.offer = offer; self.name = name; self.email = email; self.computerLabel = computerLabel; self.note = note
        self.consentImmediateSupply = consentImmediateSupply; self.consentWithdrawalLoss = consentWithdrawalLoss
    }
    /// The machine-readable record of the agreements, carried in the signed request (server keeps it with the request time).
    public var consentRecord: String? {
        guard offer == .permanent else { return nil }
        return "consent:v1 immediate=\(consentImmediateSupply ? "yes" : "no") withdrawal-loss=\(consentWithdrawalLoss ? "yes" : "no")"
    }
    /// The note actually sent: the consent record first, then the person's own note (500 characters in all).
    public var noteToSend: String {
        [consentRecord, note.trimmingCharacters(in: .whitespacesAndNewlines)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }
    public enum Problem: Equatable, Sendable { case name, email, computerLabel, note }
    /// The same limits as the server, checked before sending.
    public var problems: [Problem] {
        var p: [Problem] = []
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines), e = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if n.isEmpty || n.count > 120 { p.append(.name) }
        if e.count > 254 || e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil { p.append(.email) }
        if computerLabel.count > 80 { p.append(.computerLabel) }
        if noteToSend.count > 500 { p.append(.note) }
        return p
    }
}

public enum ActivationClientError: Error, Equatable, Sendable {
    case invalid([ActivationRequest.Problem])
    case noMachineID
    /// No connection: nothing reached the server; retrying reuses the SAME request id (no duplicate).
    case offline(String)
    case server(status: Int, code: String)
    case malformed
}

/// Signed calls to the GDC activation backend (`request.submit`, `request.poll`, `activate`, `renew`). No accounts, no passwords.
public final class ActivationClient: @unchecked Sendable {
    public typealias Transport = @Sendable (_ body: Data) async throws -> (status: Int, data: Data)
    let device: DeviceKey
    let machineID: String?
    let transport: Transport
    let language: String
    let appVersion: String
    let leaseRing: KeyRing

    public init(device: DeviceKey, machineID: String?, language: String, appVersion: String = AppInfo.version, leaseRing: KeyRing = SadrogProduct.leaseRing,
                transport: Transport? = nil) {
        self.device = device; self.machineID = machineID; self.language = language; self.appVersion = appVersion; self.leaseRing = leaseRing
        self.transport = transport ?? Self.http(SadrogProduct.endpoint)
    }

    public static func http(_ url: URL) -> Transport { { body in
        var r = URLRequest(url: url, timeoutInterval: 30)
        r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, resp) = try await URLSession.shared.data(for: r)
        return ((resp as? HTTPURLResponse)?.statusCode ?? 0, data)
    } }

    static func nonce() -> String {
        var b = [UInt8](repeating: 0, count: 24); _ = SecRandomCopyBytes(kSecRandomDefault, b.count, &b)
        return Data(b).base64EncodedString()
    }

    struct Reply { let status: Int; let json: [String: Any]; let nonce: String }
    func send(_ action: String, _ fields: [String: String], now: Date = Date()) async throws -> Reply {
        var body = fields
        let n = Self.nonce(); body["nonce"] = n; body["client_time"] = WireTime.format(now)
        let req = try device.request(action: action, body: body)
        let status: Int, data: Data
        do { (status, data) = try await transport(req) } catch { throw ActivationClientError.offline(error.localizedDescription) }
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw ActivationClientError.malformed }
        return Reply(status: status, json: obj, nonce: n)
    }

    /// Sends (or resends, same id) the request. Returns the request id.
    public func submit(requestID: String, _ r: ActivationRequest, now: Date = Date()) async throws -> String {
        guard r.problems.isEmpty else { throw ActivationClientError.invalid(r.problems) }
        guard let machineID else { throw ActivationClientError.noMachineID }
        var f: [String: String] = ["request_id": requestID, "product_id": SadrogProduct.id, "offer_id": r.offer.rawValue, "offer_version": String(r.offer.version),
                                   "name": r.name.trimmingCharacters(in: .whitespacesAndNewlines), "email": r.email.trimmingCharacters(in: .whitespacesAndNewlines),
                                   "language": language, "platform": "macos", "app_version": appVersion, "machine_id": machineID, "source": "sadrog-app"]
        let label = r.computerLabel.trimmingCharacters(in: .whitespacesAndNewlines); if !label.isEmpty { f["computer_label"] = label }
        let note = r.noteToSend; if !note.isEmpty { f["note"] = note }
        let reply = try await send("request.submit", f, now: now)
        guard reply.status == 200 else { throw ActivationClientError.server(status: reply.status, code: reply.json["code"] as? String ?? "http_\(reply.status)") }
        guard let q = reply.json["request"] as? [String: Any], let id = q["request_id"] as? String else { throw ActivationClientError.malformed }
        return id
    }

    public struct RequestStatus: Equatable, Sendable {
        /// Server state: nouă · verificată · aprobată · respinsă · licență emisă · activată · expirată · revocată · dezactivată.
        public let state: String
        public let licenseText: String?
    }
    public func poll(requestID: String) async throws -> RequestStatus {
        let reply = try await send("request.poll", ["request_id": requestID])
        guard reply.status == 200 else { throw ActivationClientError.server(status: reply.status, code: reply.json["code"] as? String ?? "http_\(reply.status)") }
        guard let q = reply.json["request"] as? [String: Any], let state = q["state"] as? String else { throw ActivationClientError.malformed }
        return RequestStatus(state: state, licenseText: q["license"] as? String)
    }

    /// The outcome of `activate` / `renew`: a verified lease, a verified refusal, or a transient error.
    public enum Outcome: Equatable, Sendable {
        case granted(SignedEnvelope, Lease)
        case refused(code: String, licenseID: String?)
    }
    public func activate(licenseText: String) async throws -> Outcome {
        guard let machineID else { throw ActivationClientError.noMachineID }
        return try outcome(await send("activate", ["product_id": SadrogProduct.id, "machine_id": machineID, "platform": "macos",
                                                    "credential_type": "gen3-license", "credential": licenseText]))
    }
    public func renew(activationID: String) async throws -> Outcome {
        try outcome(await send("renew", ["activation_id": activationID]))
    }

    func outcome(_ r: Reply) throws -> Outcome {
        if r.status == 200, let raw = r.json["lease"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let env = try? SignedEnvelope.decode(data) {
            let lease = try Lease.verify(env, ring: leaseRing, product: SadrogProduct.id, deviceKeyID: device.keyID)
            guard lease.nonce == r.nonce else { throw ActivationClientError.malformed }
            return .granted(env, lease)
        }
        if r.json["status"] as? String == "denied", let raw = r.json["notice"], let data = try? JSONSerialization.data(withJSONObject: raw),
           let env = try? SignedEnvelope.decode(data), let n = try? Notice.verify(env, ring: leaseRing, nonce: r.nonce) {
            return .refused(code: n.code, licenseID: n.license_id)
        }
        throw ActivationClientError.server(status: r.status, code: r.json["code"] as? String ?? "http_\(r.status)")
    }

    /// The text of the optional WhatsApp / e-mail message: the SAME request id and offer as the online request, so the owner sees ONE request.
    /// No private key: the public device key binds the licence to this Mac.
    public func contactBlock(requestID: String, _ r: ActivationRequest, now: Date = Date()) -> String {
        var l = ["request_id: \(requestID)", "product: \(SadrogProduct.id)", "platform: macos", "app: \(appVersion)", "machine_id: \(machineID ?? "-")",
                 "device_key: \(device.publicKeyBase64)", "time: \(WireTime.format(now))", "offer: \(r.offer.rawValue) v\(r.offer.version)",
                 "lang: \(language)", "name: \(r.name.trimmingCharacters(in: .whitespacesAndNewlines))", "email: \(r.email.trimmingCharacters(in: .whitespacesAndNewlines))"]
        let label = r.computerLabel.trimmingCharacters(in: .whitespacesAndNewlines); if !label.isEmpty { l.append("computer: \(label)") }
        if let c = r.consentRecord { l.append(c) }
        return l.joined(separator: "\n")
    }
}

/// Local persistence: the device key in the Keychain (survives a reinstall, so a reinstall is the SAME device, never a new trial),
/// the activation state as a small JSON file in Application Support.
public final class ActivationStore: @unchecked Sendable {
    public let stateURL: URL
    let keychainService: String
    /// `SADROG_KEYCHAIN_SERVICE` gives an isolated verification package its own Keychain item: an ad-hoc signed copy must never touch (or wait on an access prompt for)
    /// the device key of the app in use. Honoured ONLY for a bundle id ending ".verif" (never the product or an intermediate: no trial reset by environment).
    public static var defaultKeychainService: String {
        if Bundle.main.bundleIdentifier?.hasSuffix(".verif") == true, let o = ProcessInfo.processInfo.environment["SADROG_KEYCHAIN_SERVICE"], !o.isEmpty { return o }
        return "dev.gordas.sadrog.device-key"
    }
    public init(directory: URL? = nil, keychainService: String = ActivationStore.defaultKeychainService) {
        let base = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SADROG", isDirectory: true)
        stateURL = base.appendingPathComponent("activation.json"); self.keychainService = keychainService
    }

    public func load() -> ActivationState {
        guard let d = try? Data(contentsOf: stateURL), let s = try? JSONDecoder().decode(ActivationState.self, from: d) else { return ActivationState() }
        return s
    }
    public func save(_ s: ActivationState) throws {
        try FileManager.default.createDirectory(at: stateURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(s).write(to: stateURL, options: [.atomic])
    }

    /// The device key: read from the Keychain or created once.
    public func deviceKey() throws -> DeviceKey {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService,
                                kSecAttrAccount as String: "ed25519", kSecReturnData as String: true]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data, let k = try? Curve25519.Signing.PrivateKey(rawRepresentation: d) {
            return DeviceKey(k)
        }
        let k = Curve25519.Signing.PrivateKey()
        let add: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: keychainService, kSecAttrAccount as String: "ed25519",
                                  kSecValueData as String: k.rawRepresentation, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let st = SecItemAdd(add as CFDictionary, nil)
        guard st == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(st)) }
        return DeviceKey(k)
    }
}
