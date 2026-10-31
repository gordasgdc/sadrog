// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// End to end against the REAL backend code on a local throwaway database (`backend/sadrog-e2e-server.ts` in the private core repo).
/// Runs only with SADROG_E2E_URL set (e.g. http://127.0.0.1:54911); test keys only, never production.
final class ActivationE2ETests: XCTestCase {
    var base: URL!
    var rings: (license: KeyRing, lease: KeyRing)!
    override func setUp() async throws {
        guard let s = ProcessInfo.processInfo.environment["SADROG_E2E_URL"], let u = URL(string: s) else { throw XCTSkip("SADROG_E2E_URL not set") }
        base = u
        let (d, _) = try await URLSession.shared.data(from: u.appendingPathComponent("_test/keys"))
        let k = try JSONSerialization.jsonObject(with: d) as! [String: [String: String]]
        rings = (k["license"]!.mapValues { Data(base64Encoded: $0)! }, k["lease"]!.mapValues { Data(base64Encoded: $0)! })
    }
    func post(_ path: String, _ body: [String: Any]) async throws -> [String: Any] {
        var r = URLRequest(url: base.appendingPathComponent(path)); r.httpMethod = "POST"; r.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (d, resp) = try await URLSession.shared.data(for: r)
        XCTAssertEqual((resp as? HTTPURLResponse)?.statusCode, 200, String(decoding: d, as: UTF8.self))
        return try JSONSerialization.jsonObject(with: d) as! [String: Any]
    }
    func client(_ dev: DeviceKey, machine: String) -> ActivationClient {
        ActivationClient(device: dev, machineID: machine, language: "ro", appVersion: "1.0.0", leaseRing: rings.lease, transport: ActivationClient.http(base))
    }
    func resolve(_ s: ActivationState, _ dev: DeviceKey, _ m: String) -> SadrogAccess {
        AccessResolver.resolve(state: s, machineID: m, deviceKeyID: dev.keyID, now: Date(), licenseRing: rings.license, leaseRing: rings.lease)
    }
    func randomMachine() -> String { String((0..<10).map { _ in "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567".randomElement()! }) }

    func testTrialRequestApproveActivateAndOnePerMac() async throws {
        let dev = DeviceKey(), m = randomMachine(), c = client(dev, machine: m)
        let req = ActivationRequest(offer: .trial, name: "Test SADROG", email: "test@example.com", computerLabel: "E2E")
        let id = UUID().uuidString.lowercased()
        let s1 = try await c.submit(requestID: id, req), s2 = try await c.submit(requestID: id, req)
        XCTAssertEqual([s1, s2], [id, id], "resend = same request")
        var st = try await c.poll(requestID: id); XCTAssertEqual(st.state, "nouă"); XCTAssertNil(st.licenseText)
        _ = try await post("_test/approve", ["request_id": id])
        try await Task.sleep(nanoseconds: 1_100_000_000)   // the server time is in whole seconds; the trial must start AFTER approval
        _ = try await post("_test/shift", ["request_id": id, "days": 3])       // 3 days between approval and first activation
        st = try await c.poll(requestID: id); XCTAssertEqual(st.state, "licență emisă")
        let lic = try XCTUnwrap(st.licenseText)
        var s = ActivationState(); s.licenseText = lic
        XCTAssertEqual(resolve(s, dev, m), .free(reason: .notActivated), "the licence alone does not start the trial")
        guard case .granted(let env, let lease) = try await c.activate(licenseText: lic) else { return XCTFail("not granted") }
        s.lease = env; s.activationID = lease.activation_id; s.leaseGeneration = lease.generation
        guard case .trial(let until) = resolve(s, dev, m) else { return XCTFail("\(resolve(s, dev, m))") }
        XCTAssertEqual(until.timeIntervalSinceNow, 5 * 86400, accuracy: 120, "5 days from the FIRST activation, not from approval")
        // a reinstall (new device key) on the same Mac: a second trial is refused in Admin
        let dev2 = DeviceKey(), id2 = UUID().uuidString.lowercased()
        _ = try await client(dev2, machine: m).submit(requestID: id2, req)
        var r = URLRequest(url: base.appendingPathComponent("_test/approve")); r.httpMethod = "POST"
        r.httpBody = try JSONSerialization.data(withJSONObject: ["request_id": id2])
        let (d, _) = try await URLSession.shared.data(for: r)
        XCTAssertTrue(String(decoding: d, as: UTF8.self).contains("trial_already_used"))
        // renewal works; revocation gives a SIGNED refusal the client trusts
        guard case .granted(_, let l2) = try await c.renew(activationID: lease.activation_id) else { return XCTFail() }
        XCTAssertGreaterThan(l2.generation, lease.generation)
        _ = try await post("_test/revoke", ["request_id": id])
        guard case .refused(let code, _) = try await c.renew(activationID: lease.activation_id) else { return XCTFail("revocation not seen") }
        XCTAssertTrue(code.hasPrefix("entitlement_") || code.hasPrefix("activation_"), code)
    }

    func testPermanentLicenceIsVerifiedLocally() async throws {
        let dev = DeviceKey(), m = randomMachine(), c = client(dev, machine: m)
        let id = UUID().uuidString.lowercased()
        _ = try await c.submit(requestID: id, ActivationRequest(offer: .permanent, name: "Test SADROG", email: "test@example.com"))
        _ = try await post("_test/approve", [:].merging(["request_id": id]) { a, _ in a })
        let polled = try await c.poll(requestID: id)
        let lic = try XCTUnwrap(polled.licenseText)
        var s = ActivationState(); s.licenseText = lic
        XCTAssertEqual(resolve(s, dev, m), .permanent, "no server needed")
        guard case .granted = try await c.activate(licenseText: lic) else { return XCTFail() }
        XCTAssertEqual(resolve(s, DeviceKey(), m), .free(reason: .invalid), "another device key cannot use it")
    }
}
