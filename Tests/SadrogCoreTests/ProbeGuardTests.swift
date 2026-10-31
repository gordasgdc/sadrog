// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

final class ProbeGuardTests: XCTestCase {
    let good = """
    window onscreen=true
    play() returned true dev=default dur=124.0
    tick 1 t=0.0 playing=true
    tick 501 t=1.01 playing=true
    beep 1 player=2.0 uptime=10
    flash 1
    tick 1001 t=3.1 playing=true
    beep 2 player=4.0 uptime=12
    flash 2
    """
    func testParse() {
        let o = ProbeObservation.parse(good)
        XCTAssertEqual(o.playOK, true); XCTAssertEqual(o.duration, 124); XCTAssertEqual(o.beeps, 2); XCTAssertEqual(o.flashes, 2)
        XCTAssertEqual(o.windowOnScreen, true); XCTAssertEqual(o.lastPlayerTime, 4.0)
    }
    func testPreflightPassesOnRealSoundAndPicture() {
        XCTAssertEqual(ProbeGuard(expected: 120).preflight(elapsed: 4.5, .parse(good)), .ok)
    }
    /// The C5 incident: the tone file was not closed when loaded → duration 0, play() false, black window. Caught at once, not after 37 minutes.
    func testPreflightCatchesTheC5Incident() {
        let bad = ProbeObservation.parse("window onscreen=true\nplay() returned false dev=default dur=0.0\ntick 1 t=0.0 playing=false\n")
        guard case .invalid = ProbeGuard(expected: 120).preflight(elapsed: 0.5, bad) else { return XCTFail() }
    }
    func testPreflightTimesOutWithoutBeeps() {
        let g = ProbeGuard(expected: 120)
        let slow = ProbeObservation.parse("window onscreen=true\nplay() returned true dev=default dur=124.0\ntick 1 t=0.0 playing=true\n")
        XCTAssertEqual(g.preflight(elapsed: 5, slow), .waiting)
        guard case .invalid(let why) = g.preflight(elapsed: 10, slow) else { return XCTFail() }
        XCTAssertTrue(why.contains("ceasul sondei nu avansează"))
        let noWindow = ProbeObservation.parse(good.replacingOccurrences(of: "window onscreen=true", with: ""))
        guard case .invalid = g.preflight(elapsed: 10, noWindow) else { return XCTFail("picture not confirmed must fail") }
    }
    func testMonitorStopsAStalledProbe() {
        var g = ProbeGuard(expected: 120)
        var o = ProbeObservation.parse(good)
        XCTAssertEqual(g.monitor(elapsed: 5, o), .waiting)
        XCTAssertEqual(g.monitor(elapsed: 10, o), .waiting)
        guard case .invalid(let why) = g.monitor(elapsed: 11.5, o) else { return XCTFail() }   // nothing moved since 5 s
        XCTAssertTrue(why.contains("nu mai progresează"))
        o.playerTimes.append(6); o.beeps = 3
        var g2 = ProbeGuard(expected: 120); _ = g2.monitor(elapsed: 5, .parse(good))
        XCTAssertEqual(g2.monitor(elapsed: 10, o), .waiting)                                     // progress resets the window
    }
    func testMonitorHardDeadlineAndCompletion() {
        var g = ProbeGuard(expected: 120)
        var o = ProbeObservation.parse(good)
        for t in stride(from: 1.0, through: 134.0, by: 1.0) { o.playerTimes.append(t); XCTAssertEqual(g.monitor(elapsed: t, o), .waiting) }
        o.playerTimes.append(200)
        guard case .invalid(let why) = g.monitor(elapsed: 135, o) else { return XCTFail() }
        XCTAssertTrue(why.contains("135"))
        o.finished = true; XCTAssertEqual(g.monitor(elapsed: 100, o), .ok)
    }
}
