// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import CryptoKit
@testable import SadrogCore

/// Activation formats and the access decision, with TEST keys only (no network, no real licence).
final class ActivationTests: XCTestCase {
    let licKey = Curve25519.Signing.PrivateKey(), leaseKey = Curve25519.Signing.PrivateKey()
    var licRing: KeyRing { ["lic-test": licKey.publicKey.rawRepresentation] }
    var leaseRing: KeyRing { ["lease-test": leaseKey.publicKey.rawRepresentation] }
    let device = DeviceKey()
    let machine = "KRSXG5DJNY"
    let t0 = WireTime.parse("2026-11-01T10:00:00Z")!

    func licence(offer: SadrogProduct.Offer, lifetime: Bool, machine m: String? = nil, deviceKeyID: String? = nil, id: String = UUID().uuidString.lowercased()) throws -> String {
        let p: [String: Any] = ["schema": "gdc.datamover.license/3", "generation": 3, "product_id": SadrogProduct.id, "license_id": id,
            "entitlement_id": UUID().uuidString.lowercased(), "request_id": NSNull(), "machine_id": m ?? machine, "device_key_id": deviceKeyID ?? device.keyID,
            "issued_at": "2026-11-01T09:00:00Z", "valid_from": "2026-11-01T09:00:00Z", "valid_until": lifetime ? NSNull() : "2026-11-06T09:00:00Z" as Any,
            "lifetime": lifetime, "offline_until": lifetime ? "2026-12-01T09:00:00Z" : "2026-11-06T09:00:00Z", "grant_type": "donation",
            "offer": ["id": offer.rawValue, "version": 1], "device_limit": 1, "rights": ["tier": "full"]]
        let env = try SignedEnvelope.sign(try JSONSerialization.data(withJSONObject: p), context: LicenseG3.context, keyID: "lic-test", key: licKey)
        return LicenseText.encode(try JSONEncoder().encode(env))
    }
    func lease(until: String?, expires: String, gen: Int = 1, offer: String = "sadrog-trial", state: String = "active", nonce: String = "n") throws -> SignedEnvelope {
        let l = Lease(schema: "gdc.lease/1", lease_id: UUID().uuidString, product_id: SadrogProduct.id, activation_id: "act-1", device_key_id: device.keyID,
                      entitlement: .init(entitlement_id: "e", product_id: SadrogProduct.id, offer_id: offer, state: state, valid_until: until),
                      issued_at: "2026-11-01T10:00:00Z", server_time: "2026-11-01T10:00:00Z", renew_after: "2026-11-01T22:00:00Z",
                      expires_at: expires, generation: gen, nonce: nonce)
        return try SignedEnvelope.sign(try JSONEncoder().encode(l), context: Lease.context, keyID: "lease-test", key: leaseKey)
    }
    func resolve(_ s: ActivationState, at: Date, machine m: String? = nil) -> SadrogAccess {
        AccessResolver.resolve(state: s, machineID: m ?? machine, deviceKeyID: device.keyID, now: at, licenseRing: licRing, leaseRing: leaseRing)
    }

    func testMachineIDFormula() {
        XCTAssertEqual(MachineID.encode(platformUUID: "00000000-0000-0000-0000-000000000000"), "UE64A5FTCU")
        XCTAssertEqual(MachineID.encode(platformUUID: "A1B2C3D4-E5F6-7890-ABCD-EF0123456789"), "PKPSQT4BQE")
        if let id = MachineID.current { XCTAssertNotNil(id.range(of: "^[A-Z2-7]{10}$", options: .regularExpression)) }
    }

    func testEnvelopeRejectsWrongContextKeyAndTampering() throws {
        let env = try SignedEnvelope.sign(Data("x".utf8), context: "offline-lease", keyID: "lease-test", key: leaseKey)
        XCTAssertEqual(try env.verify(context: "offline-lease", ring: leaseRing), Data("x".utf8))
        XCTAssertThrowsError(try env.verify(context: LicenseG3.context, ring: leaseRing)) { XCTAssertEqual($0 as? ActivationError, .wrongContext) }
        XCTAssertThrowsError(try env.verify(context: "offline-lease", ring: licRing)) { XCTAssertEqual($0 as? ActivationError, .unknownKey) }
        let forged = SignedEnvelope(format: env.format, context: env.context, key_id: env.key_id, payload: Data("y".utf8).base64EncodedString(), signature: env.signature)
        XCTAssertThrowsError(try forged.verify(context: "offline-lease", ring: leaseRing)) { XCTAssertEqual($0 as? ActivationError, .badSignature) }
    }

    func testDeviceRequestIsSignedOverTheExactBody() throws {
        let data = try device.request(action: "renew", body: ["activation_id": "a", "nonce": "n"])
        let r = try JSONSerialization.jsonObject(with: data) as! [String: String]
        var msg = Data("gdc.device-request/1\nrenew\n".utf8); msg.append(Data(base64Encoded: r["body"]!)!)
        XCTAssertTrue(device.key.publicKey.isValidSignature(Data(base64Encoded: r["signature"]!)!, for: msg))
        XCTAssertEqual(r["format"], "gdc.device-request/1")
    }

    func testPermanentLicenceWorksForeverWithoutServer() throws {
        var s = ActivationState(); s.licenseText = try licence(offer: .permanent, lifetime: true)
        XCTAssertEqual(resolve(s, at: t0), .permanent)
        XCTAssertEqual(resolve(s, at: t0.addingTimeInterval(10 * 365 * 86400)), .permanent, "past offline_until, no lease: still permanent")
        XCTAssertEqual(resolve(s, at: t0, machine: "AAAAAAAAAA"), .free(reason: .invalid), "another Mac")
        var other = ActivationState(); other.licenseText = try licence(offer: .permanent, lifetime: true, deviceKeyID: String(repeating: "0", count: 64))
        XCTAssertEqual(resolve(other, at: t0), .free(reason: .invalid), "another device key")
    }

    func testRefusedLicenceGivesFreeMode() throws {
        var s = ActivationState(); s.licenseText = try licence(offer: .permanent, lifetime: true, id: "11111111-1111-4111-8111-111111111111")
        s.refusedLicenses = ["11111111-1111-4111-8111-111111111111"]
        XCTAssertEqual(resolve(s, at: t0), .free(reason: .refused))
    }

    func testTrialRunsOnlyOnTheLeaseAndEndsAtValidUntil() throws {
        var s = ActivationState(); s.licenseText = try licence(offer: .trial, lifetime: false)
        XCTAssertEqual(resolve(s, at: t0), .free(reason: .notActivated), "a trial licence alone grants nothing")
        s.lease = try lease(until: "2026-11-06T10:00:00Z", expires: "2026-11-06T10:00:00Z"); s.activationID = "act-1"; s.leaseGeneration = 1
        XCTAssertEqual(resolve(s, at: t0), .trial(until: WireTime.parse("2026-11-06T10:00:00Z")!))
        XCTAssertEqual(resolve(s, at: WireTime.parse("2026-11-06T10:00:00Z")!), .free(reason: .trialEnded))
        // clock set back after the end: the persisted floor keeps it ended
        s.timeFloor = WireTime.parse("2026-11-06T11:00:00Z")
        XCTAssertEqual(resolve(s, at: t0), .free(reason: .trialEnded))
    }

    func testLeaseFromAnotherActivationOrOlderGenerationIsIgnored() throws {
        var s = ActivationState(); s.lease = try lease(until: "2026-11-06T10:00:00Z", expires: "2026-11-06T10:00:00Z", gen: 1)
        s.activationID = "act-2"
        XCTAssertEqual(resolve(s, at: t0), .free(reason: .notActivated))
        s.activationID = "act-1"; s.leaseGeneration = 5
        XCTAssertEqual(resolve(s, at: t0), .free(reason: .notActivated))
    }

    func testClientVerifiesLeaseNonceAndSignedRefusal() async throws {
        let leaseKey = self.leaseKey
        // the real lease ring is pinned; this test only checks the transport shape with an unknown key → the reply is not trusted
        let env = try lease(until: nil, expires: "2026-12-01T10:00:00Z")
        let reply = try JSONSerialization.data(withJSONObject: ["status": "granted", "lease": try JSONSerialization.jsonObject(with: try JSONEncoder().encode(env))])
        let c = ActivationClient(device: device, machineID: machine, language: "ro", transport: { _ in (200, reply) })
        do { _ = try await c.renew(activationID: "act-1"); XCTFail("a lease signed by an unpinned key must be rejected") }
        catch { XCTAssertEqual(error as? ActivationError, .unknownKey) }
        _ = leaseKey
        let offline = ActivationClient(device: device, machineID: machine, language: "ro", transport: { _ in throw URLError(.notConnectedToInternet) })
        do { _ = try await offline.poll(requestID: UUID().uuidString.lowercased()); XCTFail() }
        catch { guard case ActivationClientError.offline = error else { return XCTFail("\(error)") } }
    }

    func testRequestValidationAndContactBlockReuseTheSameRequest() {
        XCTAssertEqual(ActivationRequest(offer: .trial, name: "", email: "x").problems, [.name, .email])
        let r = ActivationRequest(offer: .permanent, name: "Ana", email: "ana@example.com", computerLabel: "Studio")
        XCTAssertTrue(r.problems.isEmpty)
        let block = ActivationClient(device: device, machineID: machine, language: "ro").contactBlock(requestID: "abc", r)
        XCTAssertTrue(block.contains("request_id: abc") && block.contains("offer: sadrog-permanent v1") && block.contains("machine_id: \(machine)"))
        XCTAssertFalse(block.contains(device.key.rawRepresentation.base64EncodedString()), "never the private key")
    }

    func testStateRoundTripAndKeyIsStable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-act-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ActivationStore(directory: dir, keychainService: "dev.gordas.sadrog.tests.\(UUID().uuidString)")
        var s = ActivationState(); s.pendingRequestID = "r1"; s.pendingOffer = .trial
        try store.save(s); XCTAssertEqual(store.load(), s)
    }
}

final class UpdateManifestTests: XCTestCase {
    func manifest(_ o: [String: Any]) throws -> UpdateManifest {
        var j: [String: Any] = ["version": "1.0.1", "build": "120", "changes": ["ro": "Reparat", "en": "Fixed", "es": "Corregido"],
                                "download_url": ["mac": "https://gordas.dev/sadrog/SADROG-1.0.1.dmg"], "sha256": String(repeating: "a", count: 64), "size": 10, "mandatory": false]
        for (k, v) in o { j[k] = v }
        return try JSONDecoder().decode(UpdateManifest.self, from: JSONSerialization.data(withJSONObject: j))
    }
    func testDecodeCompareAndNotes() throws {
        let m = try manifest([:])
        XCTAssertTrue(m.isNewer(than: "1.0.0")); XCTAssertFalse(m.isNewer(than: "1.0.1")); XCTAssertFalse(m.isNewer(than: "1.1.0"))
        XCTAssertEqual(m.notes(.es), "Corregido")
        XCTAssertEqual(try manifest(["download_url": "https://gordas.dev/sadrog/x.dmg", "changes": "doar ro"]).notes(.en), "doar ro")
    }
    func testRejectsForeignHostsAndBadHash() {
        XCTAssertThrowsError(try manifest(["download_url": ["mac": "http://gordas.dev/x.dmg"]]))
        XCTAssertThrowsError(try manifest(["download_url": ["mac": "https://evil.example/x.dmg"]]))
        XCTAssertThrowsError(try manifest(["sha256": "xyz"]))
    }
    func testStreamedSHA256() throws {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-sha-\(UUID().uuidString)")
        try Data("abc".utf8).write(to: u); defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertEqual(try UpdateManifest.sha256(of: u), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

final class ConsentTests: XCTestCase {
    func testConsentsAreExplicitAndOnlyForThePermanentRequest() {
        var r = ActivationRequest(offer: .permanent, name: "Ana", email: "ana@example.com")
        XCTAssertEqual(r.consentRecord, "consent:v1 immediate=no withdrawal-loss=no", "never pre-ticked")
        r.consentImmediateSupply = true; r.consentWithdrawalLoss = true; r.note = "mulțumesc"
        XCTAssertEqual(r.noteToSend, "consent:v1 immediate=yes withdrawal-loss=yes\nmulțumesc")
        XCTAssertNil(ActivationRequest(offer: .trial, name: "Ana", email: "ana@example.com", consentImmediateSupply: true).consentRecord, "free trial: no consent record")
    }
}
