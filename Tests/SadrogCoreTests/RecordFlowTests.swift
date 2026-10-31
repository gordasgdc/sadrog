// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// The Record button flow with a SIMULATED capturer: no screen is captured, no device is touched.
@MainActor
final class RecordFlowTests: XCTestCase {
    /// These expectations are the Romanian source texts; the interface language is pinned so the run does not depend on the Mac's language.
    override func setUp() { super.setUp(); UserDefaults.standard.set("ro", forKey: "sadrog.language") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "sadrog.language"); super.tearDown() }
    /// A gate the test opens when it wants: lets a refresh or a countdown second "take time" deterministically.
    final class Gate { private var waiters: [CheckedContinuation<Void, Never>] = []; private(set) var opened = false
        func wait() async { if opened { return }; await withCheckedContinuation { waiters.append($0) } }
        func open() { opened = true; waiters.forEach { $0.resume() }; waiters = [] }
    }
    final class Sim { var starts = 0, stops = 0, identifyClosed = 0, prepares = 0; var phases: [RecordFlow.Phase] = []; var causes: [StopCause] = [] }

    func make(countdown: Int, prepareGate: Gate? = nil, tickGate: Gate? = nil, blocker: String? = nil) -> (RecordFlow, Sim) {
        let sim = Sim()
        let f = RecordFlow(countdownSeconds: countdown,
                           prepare: { sim.prepares += 1; await prepareGate?.wait(); return blocker },
                           startCapture: { sim.starts += 1 },
                           stopCapture: { c, _ in sim.stops += 1; sim.causes.append(c) },
                           closeIdentification: { sim.identifyClosed += 1 },
                           sleep: { _ in await tickGate?.wait() })
        f.onPhase = { sim.phases.append($0) }
        return (f, sim)
    }
    func yieldAll() async { for _ in 0..<20 { await Task.yield() } }

    func testIdentificationClosesOnPressAndBeforeStart() async {
        let (f, sim) = make(countdown: 2)
        f.press(); XCTAssertEqual(sim.identifyClosed, 1, "closed at once on the press, before preparing")
        await f.settle()
        XCTAssertEqual(sim.phases, [.preparing, .countdown(2), .countdown(1), .starting, .recording])
        XCTAssertEqual(sim.identifyClosed, 2, "closed again right before the capture starts"); XCTAssertEqual(sim.starts, 1)
        f.press(); await f.settle(); XCTAssertEqual(f.phase, .idle); XCTAssertEqual(sim.stops, 1)
    }
    /// Cancel while the sources are still being refreshed: the refresh finishes later and must NOT start anything.
    func testCancelDuringSourceRefreshNeverStarts() async {
        let gate = Gate(); let (f, sim) = make(countdown: 0, prepareGate: gate)
        f.press(); await yieldAll(); XCTAssertEqual(f.phase, .preparing)
        f.press()                                                        // the same button cancels while preparing
        XCTAssertEqual(f.phase, .idle)
        gate.open(); await yieldAll(); await f.settle()                 // the late refresh completes after the cancel
        XCTAssertEqual(sim.starts, 0); XCTAssertEqual(f.phase, .idle)
    }
    /// Cancel during the countdown: a second that "elapses" after the cancel must not continue the countdown or start.
    func testCancelDuringCountdownBlocksDelayedStart() async {
        let tick = Gate(); let (f, sim) = make(countdown: 3, tickGate: tick)
        f.press(); await yieldAll(); XCTAssertEqual(f.phase, .countdown(3))
        f.press(); XCTAssertEqual(f.phase, .idle)
        tick.open(); await yieldAll(); await f.settle()
        XCTAssertEqual(sim.starts, 0); XCTAssertEqual(f.phase, .idle)
        XCTAssertFalse(sim.phases.contains(.starting))
    }
    /// A second press while preparing is a cancel, never a second parallel start (the old flow stayed "idle" during the refresh).
    func testDoublePressNeverStartsTwice() async {
        let gate = Gate(); let (f, sim) = make(countdown: 0, prepareGate: gate)
        f.press(); await yieldAll(); f.press(); f.press()                // cancel, then a fresh start
        XCTAssertEqual(f.phase, .preparing)
        gate.open(); await yieldAll(); await f.settle()
        XCTAssertEqual(sim.starts, 1, "only the last, uncancelled flow may start"); XCTAssertEqual(sim.prepares, 2)
    }
    func testBlockerStopsBeforeCountdown() async {
        let (f, sim) = make(countdown: 3, blocker: "Alege destinația.")
        f.press(); await f.settle()
        XCTAssertEqual(f.phase, .idle); XCTAssertEqual(f.message, "Alege destinația."); XCTAssertEqual(sim.starts, 0)
    }
    func testPressWhileStartingIsIgnored() async {
        let (f, sim) = make(countdown: 0)
        f.press(); await yieldAll()
        if f.phase == .starting { f.press() }                           // ignored: a starting capture is not cancelled half-way
        await f.settle(); XCTAssertEqual(f.phase, .recording); XCTAssertEqual(sim.starts, 1)
    }
    /// The stop cause must be readable by an observer at the moment the flow returns to idle (it was lost before: phase changed first).
    func testStopCauseIsVisibleWhenIdle() async {
        var seen: [String] = []
        let (f, _) = make(countdown: 0)
        f.press(); await f.settle()
        f.onPhase = { p in if p == .idle { seen.append(f.message) } }
        f.stop(reason: "Oprit de garda probei.", cause: .guardRequest); await f.settle()
        XCTAssertEqual(seen, ["Oprit de garda probei."])
        f.onPhase = nil; f.press(); await f.settle()
        f.onPhase = { p in if p == .idle { seen.append(f.message) } }
        f.captureEnded("Sursa a dispărut.")
        XCTAssertEqual(seen.last, "Sursa a dispărut.")
        f.onPhase = nil; f.press(); await f.settle()
        f.onPhase = { p in if p == .idle { seen.append(f.message) } }
        f.press(); await f.settle()
        XCTAssertEqual(seen.last, "Oprit din buton; înregistrarea a fost salvată.")
    }

    /// Pause/resume act on the whole capture through one place; stop works from pause; a flow without pause hooks cannot pause.
    func testPauseResumeAndStopFromPause() async {
        let (f, sim) = make(countdown: 0)
        f.togglePause(); XCTAssertEqual(f.phase, .idle, "nothing to pause")
        f.press(); await f.settle(); XCTAssertEqual(f.phase, .recording)
        f.togglePause(); XCTAssertEqual(f.phase, .recording, "no pause hook: stays recording")
        var paused = 0, resumed = 0
        f.pauseCapture = { paused += 1 }; f.resumeCapture = { resumed += 1 }
        f.togglePause(); XCTAssertEqual(f.phase, .paused); XCTAssertEqual(paused, 1)
        f.togglePause(); XCTAssertEqual(f.phase, .recording); XCTAssertEqual(resumed, 1)
        f.togglePause(); f.press(); await f.settle()
        XCTAssertEqual(f.phase, .idle); XCTAssertEqual(sim.stops, 1, "stopped from pause, once")
    }
    /// Cameras prepared for a start are released when the start is cancelled or blocked — never left running.
    func testAbandonedStartReleasesPreparation() async {
        var released = 0
        let gate = Gate()
        let (f, _) = make(countdown: 3, tickGate: gate)
        f.onStartAbandoned = { released += 1 }
        f.press(); await yieldAll(); f.cancel()
        XCTAssertEqual(released, 1)
        let (g, sim) = make(countdown: 0, blocker: "Camera nu s-a stabilizat")
        g.onStartAbandoned = { released += 1 }
        g.press(); await g.settle()
        XCTAssertEqual(released, 2); XCTAssertEqual(sim.starts, 0)
    }
}
