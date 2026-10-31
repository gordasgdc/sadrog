// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Whole guard stop protocol with a SIMULATED capturer: request → app receives → session finalized (file + sources.json + event) →
/// guard confirms → only then the probe is closed. No screen capture, no device.
@MainActor
final class GuardStopProtocolTests: XCTestCase {
    /// These expectations are the Romanian source texts; the interface language is pinned so the run does not depend on the Mac's language.
    override func setUp() { super.setUp(); UserDefaults.standard.set("ro", forKey: "sadrog.language") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "sadrog.language"); super.tearDown() }
    var dir: URL!
    override func setUp() async throws {
        dir = URL(fileURLWithPath: "\(TestRoot.path)/temp/guardproto-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    /// App side, as in RecorderModel: RecordFlow + GuardStopReceiver + the single SessionFinalizer. `finishDelay` = time the file takes to close.
    @MainActor final class SimApp {
        let flow: RecordFlow; var receiver: GuardStopReceiver!; let finalizer: SessionFinalizer
        var finishDelayTicks = 0; var probeClosedWhenFinalized: Bool?
        var probeClosed = false
        init(dir: URL) {
            let fin = SessionFinalizer(session: "S1", folder: dir); finalizer = fin
            var me: SimApp?
            flow = RecordFlow(countdownSeconds: 0, prepare: { nil }, startCapture: {}, stopCapture: { cause, request in
                await fin.finalize(cause: cause, request: request, finish: {
                    for _ in 0..<(me?.finishDelayTicks ?? 0) { await Task.yield() }
                }, writeManifest: { try Data("{}".utf8).write(to: dir.appendingPathComponent(SourcesManifest.fileName)) })
            }, closeIdentification: {}, sleep: { _ in })
            receiver = GuardStopReceiver(flow: flow, enabled: { true }, log: { e, r in SessionEventLog.append(SessionEvent(session: "S1", event: e, request: r), to: dir) })
            me = self
        }
        func record() async { flow.press(); await flow.settle() }
    }

    func testStopRequestIsConfirmedOnlyAfterFinalizationThenProbeCloses() async {
        let app = SimApp(dir: dir); app.finishDelayTicks = 50; await app.record(); XCTAssertEqual(app.flow.phase, .recording)
        var order: [String] = []
        let out = await GuardStopProtocol(timeout: 5, poll: 0.01).run(request: "R1",
            post: { r in order.append("post"); app.receiver.receive(request: r) },
            finalized: { SessionEventLog.finalized(self.dir) },
            closeProbe: { order.append("close"); app.probeClosedWhenFinalized = FileManager.default.fileExists(atPath: self.dir.appendingPathComponent(SourcesManifest.fileName).path) },
            sleep: { _ in await Task.yield() })
        guard case .confirmed(_, let cause) = out else { return XCTFail("not confirmed") }
        XCTAssertEqual(cause, "guard"); XCTAssertEqual(order, ["post", "close"])
        XCTAssertEqual(app.probeClosedWhenFinalized, true, "the probe must close only after sources.json exists")
        await app.flow.settle(); XCTAssertEqual(app.flow.phase, .idle); XCTAssertEqual(app.flow.message, "Oprit de garda probei; înregistrarea a fost salvată.")
        let ev = SessionEventLog.read(dir).map(\.event)
        XCTAssertEqual(ev, ["guard_request_received", "finalizing", "finalized"])
        XCTAssertEqual(SessionEventLog.finalized(dir)?.request, "R1")
    }
    /// The app never answers (hook disabled / app gone): not confirmed, probe still closed after the timeout, nothing claimed.
    func testNoConfirmationTimesOutAndStillClosesTheProbe() async {
        var closed = false
        let out = await GuardStopProtocol(timeout: 0.05, poll: 0.01).run(request: "R2", post: { _ in }, finalized: { nil }, closeProbe: { closed = true }, sleep: { _ in })
        XCTAssertEqual(out, .notConfirmed); XCTAssertTrue(closed)
    }
    /// A repeated request (or a second cause racing in) finalizes ONCE; the extra one is logged, not acted on.
    func testRepeatedRequestAndRaceWithSourceLossFinalizeOnce() async {
        let app = SimApp(dir: dir); await app.record()
        XCTAssertEqual(app.receiver.receive(request: "R3"), .stopping)
        XCTAssertEqual(app.receiver.receive(request: "R3"), .ignored("stopping"))
        await app.flow.settle()
        // the window closes at the same time: source-loss path through the same finalizer
        let again = await app.finalizer.finalize(cause: .sourceLost, finish: {}, writeManifest: {})
        XCTAssertFalse(again)
        let ev = SessionEventLog.read(dir)
        XCTAssertEqual(ev.filter { $0.event == "finalized" }.count, 1)
        XCTAssertEqual(ev.first { $0.event == "finalized" }?.cause, "guard")
        XCTAssertEqual(ev.last?.event, "stop_ignored"); XCTAssertEqual(ev.last?.cause, "source_lost")
        XCTAssertEqual(app.receiver.receive(request: "R4"), .ignored("idle"))
    }
    /// Every end path writes sources.json and the cause, and the flow is back to idle with its message.
    func testEveryCauseUsesTheSameFinalization() async throws {
        for (cause, act) in [(StopCause.button, "button"), (.durationLimit, "limit"), (.lowSpace, "space"), (.sourceLost, "lost")] {
            let d = dir.appendingPathComponent(act); try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
            let app = SimApp(dir: d); await app.record()
            switch act {
            case "button": app.flow.press()
            case "lost": _ = await app.finalizer.finalize(cause: .sourceLost, finish: {}, writeManifest: { try Data("{}".utf8).write(to: d.appendingPathComponent(SourcesManifest.fileName)) }); app.flow.captureEnded("Sursa a dispărut.")
            default: app.flow.stop(reason: "oprit: \(act)", cause: cause)
            }
            await app.flow.settle()
            XCTAssertTrue(FileManager.default.fileExists(atPath: d.appendingPathComponent(SourcesManifest.fileName).path), "\(act): sources.json")
            XCTAssertEqual(SessionEventLog.finalized(d)?.cause, cause.rawValue, act)
            XCTAssertEqual(app.flow.phase, .idle, act); XCTAssertFalse(app.flow.message.isEmpty, act)
        }
    }
    func testDisabledHookIgnoresRequests() async {
        let app = SimApp(dir: dir); await app.record()
        let r = GuardStopReceiver(flow: app.flow, enabled: { false }, log: { _, _ in })
        XCTAssertEqual(r.receive(request: "R5"), .disabled); XCTAssertEqual(app.flow.phase, .recording)
    }
}
