// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// What the sync probe has reported so far (parsed from its probe_log.txt).
public struct ProbeObservation: Equatable, Sendable {
    public var playOK: Bool?            // nil until the probe has tried to play
    public var duration: Double?        // length of the loaded tone file (0 = the bug that caused the 37-minute run)
    public var playerTimes: [Double] = []   // player clock samples, in log order
    public var beeps = 0
    public var flashes = 0
    public var windowOnScreen: Bool?
    public var failure: String?         // the probe's own FAIL line
    public var finished = false         // the probe wrote END (all beeps played)
    public init() {}

    public var lastPlayerTime: Double { playerTimes.last ?? 0 }
    /// Parses the probe log; unknown lines are ignored, so older logs still parse.
    public static func parse(_ log: String) -> ProbeObservation {
        var o = ProbeObservation()
        func value(_ key: String, in line: Substring) -> String? {
            guard let r = line.range(of: key + "=") else { return nil }
            return String(line[r.upperBound...].prefix { !$0.isWhitespace })
        }
        for line in log.split(separator: "\n") {
            if line.hasPrefix("play() returned") {
                o.playOK = line.contains("returned true"); o.duration = value("dur", in: line).flatMap(Double.init)
            } else if line.hasPrefix("tick") || line.hasPrefix("beep") {
                if let t = value(line.hasPrefix("tick") ? "t" : "player", in: line).flatMap(Double.init) { o.playerTimes.append(t) }
                if line.hasPrefix("beep") { o.beeps += 1 }
            } else if line.hasPrefix("flash") { o.flashes += 1 }
            else if line.hasPrefix("window onscreen=") { o.windowOnScreen = line.hasSuffix("true") }
            else if line.hasPrefix("FAIL") { o.failure = String(line) }
            else if line.hasPrefix("END") { o.finished = true }
        }
        return o
    }
}

public enum ProbeVerdict: Equatable, Sendable {
    case waiting                 // nothing decided yet
    case ok                      // preflight passed / run completed
    case invalid(String)         // stop everything; the run is not evidence
}

/// Mandatory guard for long capture probes (after the 37-minute incident of the C5 attempt).
/// 1. Preflight (no recording): within `preflightLimit` s the probe must play (play() true, duration > 0), its clock must advance,
///    its window must be on screen and at least `minBeeps` beeps with their flashes must be logged. Otherwise: invalid.
/// 2. Monitoring of the real run: a hard deadline (`expected + margin`), and an early stop when the probe clock or the beep count
///    stops moving for `stallSeconds`. Every decision is a pure function of (elapsed wall time, observation), so it is unit-tested.
public struct ProbeGuard: Sendable {
    public var preflightLimit = 10.0, minBeeps = 2, stallSeconds = 6.0, margin = 15.0
    public var expected: Double              // planned length of the probe (s)
    public var beepInterval = 2.0
    private var lastProgress = 0.0, lastTime = -1.0, lastBeeps = -1
    public init(expected: Double) { self.expected = expected }

    public var deadline: Double { expected + margin }

    public func preflight(elapsed: Double, _ o: ProbeObservation) -> ProbeVerdict {
        if let f = o.failure { return .invalid("sonda a raportat eroare: \(f)") }
        if o.playOK == false { return .invalid("sonda nu redă sunet (play() = false)") }
        if let d = o.duration, d <= 0 { return .invalid("fișierul de ton are durata 0") }
        if o.windowOnScreen == false { return .invalid("fereastra sondei nu e pe ecran") }
        let advancing = o.playerTimes.count >= 2 && o.lastPlayerTime > (o.playerTimes.first ?? 0)
        if o.playOK == true, (o.duration ?? 0) > 0, advancing, o.windowOnScreen == true, o.beeps >= minBeeps, o.flashes >= minBeeps { return .ok }
        if elapsed >= preflightLimit {
            var why: [String] = []
            if o.playOK == nil { why.append("sonda nu a pornit redarea") }
            if !advancing { why.append("ceasul sondei nu avansează") }
            if o.windowOnScreen == nil { why.append("fereastra nu a fost confirmată pe ecran") }
            if o.beeps < minBeeps || o.flashes < minBeeps { why.append("\(o.beeps) beep-uri / \(o.flashes) flash-uri în \(Int(preflightLimit)) s (minim \(minBeeps))") }
            return .invalid("preverificare eșuată: " + why.joined(separator: "; "))
        }
        return .waiting
    }

    /// Call repeatedly during the real run with the time since the probe was triggered. `.ok` = the probe completed; `.invalid` = stop now.
    public mutating func monitor(elapsed: Double, _ o: ProbeObservation) -> ProbeVerdict {
        if let f = o.failure { return .invalid("sonda a raportat eroare: \(f)") }
        if o.playOK == false { return .invalid("sonda nu redă sunet (play() = false)") }
        if o.finished { return .ok }
        if elapsed >= deadline { return .invalid("limita de \(Int(deadline)) s depășită — oprire automată") }
        if o.lastPlayerTime > lastTime + 0.001 || o.beeps != lastBeeps { lastProgress = elapsed; lastTime = max(lastTime, o.lastPlayerTime); lastBeeps = o.beeps }
        // a beep is due every `beepInterval`: no new beep for longer than that plus the stall window also counts as no progress
        let stalled = elapsed - lastProgress >= stallSeconds
        if stalled { return .invalid("sonda nu mai progresează de \(Int(stallSeconds)) s (ceas \(String(format: "%.2f", o.lastPlayerTime)) s, \(o.beeps) beep-uri)") }
        return .waiting
    }
}
