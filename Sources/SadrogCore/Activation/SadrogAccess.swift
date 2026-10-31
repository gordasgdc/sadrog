// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import CryptoKit
import IOKit

/// The product and its two offers (catalog `gdc-sadrog`, D-COM-2/3). The amount is shown, never charged by the app.
public enum SadrogProduct {
    public static let id = "gdc-sadrog"
    public enum Offer: String, CaseIterable, Sendable, Codable {
        case trial = "sadrog-trial", permanent = "sadrog-permanent"
        public var version: Int { 1 }
    }
    public static let contributionEUR = 25
    public static let trialDays = 5
    public static let endpoint = URL(string: "https://jvxrclpyngdcqnbwvtfn.supabase.co/functions/v1/commercial")!
    /// Pinned public keys (rotation = a new key added here before it is used).
    public static let licenseRing: KeyRing = ["gdc-sadrog-license-g3-20261030": Data(base64Encoded: "SMELUxd/NO9n7irBYlWaP8aNeSiotfBy29R1fEbWTW4=")!]
    public static let leaseRing: KeyRing = ["gdc-commercial-lease-20261005": Data(base64Encoded: "attxwaCnPVjFnoKIzfXlYvcTwqXMV2aQAQaIaPE0/cY=")!]
    public static let releaseRing: KeyRing = ["gdc-sadrog-release-20261030": Data(base64Encoded: "3v8ip8G+t3zh38fHkdD7zspWP32FevmTkdwXNHdHLG0=")!]
}

/// Machine ID of this Mac: IOPlatformUUID → SHA-512 → first 6 bytes → RFC 4648 Base32, 10 characters (the common GDC formula).
public enum MachineID {
    public static func encode(platformUUID: String) -> String {
        let bytes = Array(SHA512.hash(data: Data(platformUUID.utf8)).prefix(6))
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
        var out = "", buffer = 0, bits = 0
        for b in bytes {
            buffer = (buffer << 8) | Int(b); bits += 8
            while bits >= 5 { out.append(alphabet[(buffer >> (bits - 5)) & 31]); bits -= 5 }
        }
        if bits > 0 { out.append(alphabet[(buffer << (5 - bits)) & 31]) }
        return out
    }
    public static var current: String? {
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let raw = IORegistryEntryCreateCFProperty(entry, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String,
              !raw.isEmpty else { return nil }
        return encode(platformUUID: raw)
    }
}

/// What the app may do. Without activation: open, edit, save and recover stay free; a NEW recording and an export need Full (D-COM-3).
/// Nothing is deleted or encrypted; a recording or export already running always finishes.
public enum SadrogAccess: Equatable, Sendable {
    case permanent
    case trial(until: Date)
    case free(reason: FreeReason)
    public enum FreeReason: Equatable, Sendable { case notActivated, trialEnded, refused, invalid }
    public var allowsRecordAndExport: Bool { switch self { case .permanent, .trial: return true; case .free: return false } }
}

/// Everything the app keeps about its activation (no private keys: the device key is in the Keychain).
public struct ActivationState: Codable, Equatable, Sendable {
    public var licenseText: String?
    public var lease: SignedEnvelope?
    public var leaseGeneration: Int?
    public var activationID: String?
    /// Licence ids refused by a signed backend notice (revoked / deactivated).
    public var refusedLicenses: [String] = []
    /// Trusted-time floor: never goes back offline (max of the clock and every verified server time).
    public var timeFloor: Date?
    /// The pending request (survives a restart; resending reuses the same id, so there is never a duplicate).
    public var pendingRequestID: String?
    public var pendingOffer: SadrogProduct.Offer?
    public init() {}
}

/// The access decision (pure, testable):
/// 1. a valid PERMANENT licence (lifetime, offer `sadrog-permanent`, this Mac, this device key, not refused) ⇒ permanent, no server needed, ever;
/// 2. a valid lease (signature, device, generation, trusted now < expires_at and < valid_until, entitlement active) ⇒ trial until valid_until;
/// 3. otherwise ⇒ free mode. A trial licence alone never gives access: the trial runs only on the backend-signed lease.
public enum AccessResolver {
    public static func resolve(state s: ActivationState, machineID: String?, deviceKeyID: String, now wall: Date,
                               licenseRing: KeyRing = SadrogProduct.licenseRing, leaseRing: KeyRing = SadrogProduct.leaseRing) -> SadrogAccess {
        let now = max(wall, s.timeFloor ?? .distantPast)
        var lic: LicenseG3?
        if let text = s.licenseText, let machineID {
            lic = try? LicenseG3.verify(text: text, ring: licenseRing, product: SadrogProduct.id, machineID: machineID, deviceKeyID: deviceKeyID).0
            if lic == nil { return .free(reason: .invalid) }
        }
        if let l = lic, s.refusedLicenses.contains(l.license_id) { return .free(reason: .refused) }
        if let l = lic, l.lifetime, l.offer.id == SadrogProduct.Offer.permanent.rawValue { return .permanent }
        if let env = s.lease, let activation = s.activationID,
           let lease = try? Lease.verify(env, ring: leaseRing, product: SadrogProduct.id, deviceKeyID: deviceKeyID),
           lease.activation_id == activation, lease.generation >= (s.leaseGeneration ?? 0) {
            let at = max(now, WireTime.parse(lease.server_time) ?? now)
            let ends = [WireTime.parse(lease.expires_at), WireTime.parse(lease.entitlement.valid_until)].compactMap { $0 }.min() ?? .distantPast
            if ["active", "grace"].contains(lease.entitlement.state), at < ends {
                if lease.entitlement.valid_until == nil { return .permanent }        // permanent right confirmed online (licence missing locally)
                return .trial(until: WireTime.parse(lease.entitlement.valid_until)!)
            }
            if lease.entitlement.offer_id == SadrogProduct.Offer.trial.rawValue { return .free(reason: .trialEnded) }
        }
        if let l = lic, l.offer.id == SadrogProduct.Offer.trial.rawValue, s.lease != nil { return .free(reason: .trialEnded) }
        return .free(reason: .notActivated)
    }
}
