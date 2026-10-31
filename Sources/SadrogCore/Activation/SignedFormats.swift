// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
// Independent implementation of the public GDC activation wire formats (signed envelope, device request, gen3 licence, lease, notice).
// No private keys live here: the app only VERIFIES with pinned public keys and SIGNS with its own per-device key.
import Foundation
import CryptoKit

public enum ActivationError: Error, Equatable, Sendable {
    case malformed, unsupportedFormat, wrongContext, unknownKey, badSignature
    case wrongSchema, wrongProduct, wrongMachine, wrongDevice, wrongActivation, staleGeneration, notYetValid, expired, inactive
}

/// Strict UTC time `YYYY-MM-DDTHH:MM:SSZ` (no fractions; impossible dates rejected).
public enum WireTime {
    private static let f: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"; f.isLenient = false; return f
    }()
    public static func parse(_ s: String?) -> Date? {
        guard let s, s.range(of: #"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$"#, options: .regularExpression) != nil, let d = f.date(from: s), f.string(from: d) == s else { return nil }
        return d
    }
    public static func format(_ d: Date) -> String { f.string(from: Date(timeIntervalSince1970: floor(d.timeIntervalSince1970))) }
}

/// Public key ring: key id → raw Ed25519 public key (32 bytes).
public typealias KeyRing = [String: Data]

/// `gdc.signed/1`: message = "gdc.signed/1\n" + context + "\n" ‖ payload bytes.
public struct SignedEnvelope: Codable, Equatable, Sendable {
    public let format: String, context: String, key_id: String, payload: String, signature: String
    public static let formatID = "gdc.signed/1"

    public static func decode(_ json: Data) throws -> SignedEnvelope {
        guard let e = try? JSONDecoder().decode(SignedEnvelope.self, from: json) else { throw ActivationError.malformed }
        return e
    }
    /// Verified payload bytes.
    public func verify(context expected: String, ring: KeyRing) throws -> Data {
        guard format == Self.formatID else { throw ActivationError.unsupportedFormat }
        guard context == expected else { throw ActivationError.wrongContext }
        guard let raw = ring[key_id], let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { throw ActivationError.unknownKey }
        guard let body = Data(base64Encoded: payload), let sig = Data(base64Encoded: signature), sig.count == 64 else { throw ActivationError.malformed }
        var msg = Data("\(Self.formatID)\n\(context)\n".utf8); msg.append(body)
        guard pub.isValidSignature(sig, for: msg) else { throw ActivationError.badSignature }
        return body
    }
    /// Test/tooling helper: signs with a private key (the app never holds licence or lease private keys).
    public static func sign(_ payload: Data, context: String, keyID: String, key: Curve25519.Signing.PrivateKey) throws -> SignedEnvelope {
        var msg = Data("\(formatID)\n\(context)\n".utf8); msg.append(payload)
        return SignedEnvelope(format: formatID, context: context, key_id: keyID, payload: payload.base64EncodedString(),
                              signature: try key.signature(for: msg).base64EncodedString())
    }
}

/// Licence transport text: `GDC3-` + base64url(envelope JSON).
public enum LicenseText {
    public static func decode(_ text: String) -> Data? {
        let t = text.components(separatedBy: .whitespacesAndNewlines).joined()
        guard t.hasPrefix("GDC3-") else { return nil }
        var p = String(t.dropFirst(5)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        p += String(repeating: "=", count: (4 - p.count % 4) % 4)
        return Data(base64Encoded: p)
    }
    public static func encode(_ envelopeJSON: Data) -> String {
        "GDC3-" + envelopeJSON.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

/// The per-device key (kept in the Keychain by the app). `keyID` = SHA-256 hex of the raw public key.
public struct DeviceKey: Sendable {
    public let key: Curve25519.Signing.PrivateKey
    public init(_ key: Curve25519.Signing.PrivateKey = .init()) { self.key = key }
    public var publicKeyBase64: String { key.publicKey.rawRepresentation.base64EncodedString() }
    public var keyID: String { SHA256.hash(data: key.publicKey.rawRepresentation).map { String(format: "%02x", $0) }.joined() }

    /// `gdc.device-request/1`: body = JSON with sorted string keys; message = "gdc.device-request/1\n" + action + "\n" ‖ body.
    public func request(action: String, body: [String: String]) throws -> Data {
        let sortedBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        var msg = Data("gdc.device-request/1\n\(action)\n".utf8); msg.append(sortedBody)
        let sig = try key.signature(for: msg)
        let req: [String: String] = ["format": "gdc.device-request/1", "action": action, "device_public_key": publicKeyBase64,
                                     "body": sortedBody.base64EncodedString(), "signature": sig.base64EncodedString()]
        return try JSONSerialization.data(withJSONObject: req, options: [.sortedKeys])
    }
}

/// gen3 licence payload (`gdc.datamover.license/3`, the common GDC gen3 schema). Unknown fields are rejected.
public struct LicenseG3: Codable, Equatable, Sendable {
    public struct Offer: Codable, Equatable, Sendable { public let id: String; public let version: Int }
    public struct Rights: Codable, Equatable, Sendable { public let tier: String }
    public let schema: String, generation: Int, product_id: String, license_id: String, entitlement_id: String, request_id: String?
    public let machine_id: String, device_key_id: String, issued_at: String, valid_from: String, valid_until: String?, lifetime: Bool
    public let offline_until: String, grant_type: String, offer: Offer, device_limit: Int, rights: Rights

    public static let context = "datamover-license-g3"
    static let fields = ["schema", "generation", "product_id", "license_id", "entitlement_id", "request_id", "machine_id", "device_key_id",
                         "issued_at", "valid_from", "valid_until", "lifetime", "offline_until", "grant_type", "offer", "device_limit", "rights"].sorted()

    /// Signature + structure + binding to this Mac and this device key. Time is NOT checked here (see `SadrogAccess`).
    public static func verify(text: String, ring: KeyRing, product: String, machineID: String, deviceKeyID: String) throws -> (LicenseG3, Data) {
        guard let envJSON = LicenseText.decode(text) else { throw ActivationError.malformed }
        let body = try SignedEnvelope.decode(envJSON).verify(context: context, ring: ring)
        guard let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any], obj.keys.sorted() == fields,
              let l = try? JSONDecoder().decode(LicenseG3.self, from: body) else { throw ActivationError.malformed }
        guard l.schema == "gdc.datamover.license/3", l.generation == 3 else { throw ActivationError.wrongSchema }
        guard l.product_id == product else { throw ActivationError.wrongProduct }
        guard l.rights.tier == "full", l.lifetime == (l.valid_until == nil), WireTime.parse(l.issued_at) != nil,
              WireTime.parse(l.offline_until) != nil, WireTime.parse(l.valid_from) != nil,
              l.valid_until == nil || WireTime.parse(l.valid_until) != nil else { throw ActivationError.malformed }
        guard l.machine_id == machineID else { throw ActivationError.wrongMachine }
        guard l.device_key_id == deviceKeyID else { throw ActivationError.wrongDevice }
        return (l, envJSON)
    }
}

/// Backend-signed offline lease (`gdc.lease/1`).
public struct Lease: Codable, Equatable, Sendable {
    public struct Entitlement: Codable, Equatable, Sendable {
        public let entitlement_id: String, product_id: String, offer_id: String?, state: String, valid_until: String?
    }
    public let schema: String, lease_id: String, product_id: String, activation_id: String, device_key_id: String
    public let entitlement: Entitlement, issued_at: String, server_time: String, renew_after: String, expires_at: String, generation: Int, nonce: String

    public static let context = "offline-lease"
    public static func verify(_ envelope: SignedEnvelope, ring: KeyRing, product: String, deviceKeyID: String) throws -> Lease {
        let body = try envelope.verify(context: context, ring: ring)
        guard let l = try? JSONDecoder().decode(Lease.self, from: body) else { throw ActivationError.malformed }
        guard l.schema == "gdc.lease/1" else { throw ActivationError.wrongSchema }
        guard l.product_id == product, l.entitlement.product_id == product else { throw ActivationError.wrongProduct }
        guard l.device_key_id == deviceKeyID else { throw ActivationError.wrongDevice }
        guard let i = WireTime.parse(l.issued_at), WireTime.parse(l.server_time) != nil, let r = WireTime.parse(l.renew_after),
              let e = WireTime.parse(l.expires_at), i <= e, r <= e else { throw ActivationError.malformed }
        return l
    }
}

/// Backend-signed refusal (`gdc.notice/1`): revoked / expired / deactivated. Trusted only with the echoed nonce.
public struct Notice: Codable, Equatable, Sendable {
    public let schema: String, activation_id: String, code: String, nonce: String, server_time: String
    public let license_id: String?
    public static let context = "backend-notice"
    public static func verify(_ envelope: SignedEnvelope, ring: KeyRing, nonce: String) throws -> Notice {
        let body = try envelope.verify(context: context, ring: ring)
        guard let n = try? JSONDecoder().decode(Notice.self, from: body), n.schema == "gdc.notice/1" else { throw ActivationError.malformed }
        guard n.nonce == nonce else { throw ActivationError.malformed }
        return n
    }
}
