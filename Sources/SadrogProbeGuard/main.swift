// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
// Mandatory guard for capture probes (development tool, not shipped). See ProbeGuard in SadrogCore.
//   sadrog-probe-guard preflight --probe <sadrog-syncprobe> --dir <folder>
//       ≤ 10 s, NO recording: the probe must play its tone, advance its clock, show its window, log ≥ 2 beeps + flashes.
//   sadrog-probe-guard run --probe <sadrog-syncprobe> --dir <folder> --dest <recording folder> [--beeps N] [--max-record S]
//       preflight first; then the app gets a hard recording limit and the stop hook; the probe waits for <dir>/trigger
//       (created once the recording runs, ≤ 120 s), is monitored (deadline, stall), and on any end the recording is stopped,
//       the probe killed, the app settings restored and the stop confirmed from the newest session.json in <dest>.
//   sadrog-probe-guard prepare --probe <bin> --dir <folder>   preflight, then opens the probe window (waiting for <dir>/trigger) and exits;
//       nothing is armed in the app — select the window first.
//   sadrog-probe-guard arm --dir <folder> --dest <folder> [--beeps N] [--max-record S] [--trigger-wait S]
//       sets the app limit + stop hook, waits for the trigger (default 60 s), monitors the prepared probe, stops the recording, confirms, restores.
// Exit codes: 0 valid, 2 invalid (reason in <dir>/GUARD_REPORT.txt).
import Foundation
import SadrogCore

let a = CommandLine.arguments
func opt(_ k: String) -> String? { a.firstIndex(of: k).flatMap { a.indices.contains($0 + 1) ? a[$0 + 1] : nil } }
guard a.count >= 2, let dir = opt("--dir"), let probe = opt("--probe") ?? (a[1] == "arm" ? "" : nil) else {
    print("usage: sadrog-probe-guard preflight|run --probe <bin> --dir <folder> [--dest <folder>] [--beeps N]"); exit(64)
}
let beeps = opt("--beeps").flatMap(Int.init) ?? 60
let fm = FileManager.default
var report = "probe-guard \(a[1]) \(ISO8601DateFormatter().string(from: Date()))\n"
func say(_ s: String) { print(s); report += s + "\n"; try? report.write(toFile: dir + "/GUARD_REPORT.txt", atomically: true, encoding: .utf8) }
func readLog(_ d: String) -> ProbeObservation { .parse((try? String(contentsOfFile: d + "/probe_log.txt", encoding: .utf8)) ?? "") }
func launch(_ d: String, extra: [String]) -> Process {
    let p = Process(); p.executableURL = URL(fileURLWithPath: probe); p.arguments = [d] + extra
    try? fm.removeItem(atPath: d + "/probe_log.txt"); try? fm.removeItem(atPath: d + "/trigger")
    do { try p.run() } catch { say("INVALID: nu pot porni sonda: \(error)"); exit(2) }
    return p
}
func kill(_ p: Process) { if p.isRunning { p.terminate(); let t = Date(); while p.isRunning, Date().timeIntervalSince(t) < 3 { usleep(50_000) }; if p.isRunning { Darwin.kill(p.processIdentifier, SIGKILL) } } }
let app = "dev.gordas.sadrog"
func defaults(_ args: [String]) { let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/defaults"); p.arguments = args; try? p.run(); p.waitUntilExit() }
func stopRecording(_ why: String, request: String = UUID().uuidString) { DistributedNotificationCenter.default().postNotificationName(.init("dev.gordas.sadrog.probeGuard.stop"), object: nil, userInfo: ["reason": why, "request": request], deliverImmediately: true) }
/// Newest session folder under `dest` (the one being recorded).
func newestSession(_ dest: String) -> URL? {
    ((try? fm.contentsOfDirectory(atPath: dest)) ?? []).filter { $0.hasPrefix("SADROG-") }.map { URL(fileURLWithPath: dest + "/" + $0) }
        .max { ((try? fm.attributesOfItem(atPath: $0.path)[.creationDate] as? Date) ?? .distantPast) < ((try? fm.attributesOfItem(atPath: $1.path)[.creationDate] as? Date) ?? .distantPast) }
}
/// The tested stop protocol: post the request, wait for the app's `finalized` event, then close the probe; logs comparable uptimes.
func guardedStop(_ dest: String, why: String, closeProbe: () -> Void) async -> Bool {
    let request = UUID().uuidString, session = newestSession(dest)
    say(String(format: "cerere de oprire trimisă: request=%@ uptime=%.3f", request, ProcessInfo.processInfo.systemUptime))
    let out = await GuardStopProtocol(timeout: 20).run(request: request, post: { stopRecording(why, request: $0) },
        finalized: { session.flatMap(SessionEventLog.finalized) }, closeProbe: { say(String(format: "sonda se închide: uptime=%.3f", ProcessInfo.processInfo.systemUptime)); closeProbe() })
    switch out {
    case .confirmed(let after, let cause):
        let f = session.flatMap(SessionEventLog.finalized)
        say(String(format: "confirmat în %.2f s: cauza=%@ request=%@ (cerut %@) finalized_uptime=%.3f sesiune=%@", after, cause ?? "-", f?.request ?? "-", request, f?.uptime ?? 0, f?.session ?? "-"))
        return true
    case .notConfirmed: say("ATENȚIE: oprirea NU a fost confirmată (fără eveniment finalized) în 20 s; sonda închisă după expirare"); return false
    }
}
func restoreApp() { defaults(["delete", app, "maxRecordSeconds"]); defaults(["delete", app, "probeGuardStop"]) }

// arm: the probe was opened by `prepare` and the window selected in SADROG; only now the app gets its limit and stop hook ----------------
if a[1] == "arm" {
    guard let dest = opt("--dest"), let pidText = try? String(contentsOfFile: dir + "/probe.pid", encoding: .utf8), let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)), Darwin.kill(pid, 0) == 0
    else { say("INVALID: sonda pregătită lipsește (rulează întâi prepare)"); exit(2) }
    let beepsA = opt("--beeps").flatMap(Int.init) ?? 3, wait = opt("--trigger-wait").flatMap(Double.init) ?? 60
    var g = ProbeGuard(expected: Double(beepsA) * 2)
    let maxRecord = opt("--max-record").flatMap(Double.init) ?? (g.deadline + 20)
    func alive() -> Bool { Darwin.kill(pid, 0) == 0 }
    func killProbe() { if alive() { Darwin.kill(pid, SIGTERM); let t = Date(); while alive(), Date().timeIntervalSince(t) < 3 { usleep(50_000) }; if alive() { Darwin.kill(pid, SIGKILL) } } }
    defaults(["write", app, "maxRecordSeconds", "-float", String(maxRecord)]); defaults(["write", app, "probeGuardStop", "-bool", "true"])
    say("armat: limită dură în aplicație \(Int(maxRecord)) s; aștept trigger (max \(Int(wait)) s)")
    let tw = Date()
    while !fm.fileExists(atPath: dir + "/trigger") {
        usleep(100_000)
        if Date().timeIntervalSince(tw) > wait || !alive() { killProbe(); stopRecording("fără trigger"); restoreApp(); say("INVALID: trigger absent în \(Int(wait)) s sau sonda s-a oprit"); exit(2) }
    }
    let tr = Date(); var v = ProbeVerdict.waiting
    while v == .waiting {
        usleep(250_000)
        v = g.monitor(elapsed: Date().timeIntervalSince(tr), readLog(dir))
        if v == .waiting, !alive(), !readLog(dir).finished { v = .invalid("sonda s-a oprit înainte de final") }
    }
    let stopped = await guardedStop(dest, why: v == .ok ? "sonda terminată" : "probă invalidă", closeProbe: killProbe)
    restoreApp()
    if case .invalid(let w) = v { say("INVALID: \(w)"); exit(2) }
    say("VALID: \(readLog(dir).beeps) beep-uri"); exit(stopped ? 0 : 2)
}

// 1. preflight -------------------------------------------------------------
let pre = dir + "/preflight"; try? fm.createDirectory(atPath: pre, withIntermediateDirectories: true)
let g0 = ProbeGuard(expected: Double(beeps) * 2)
let pp = launch(pre, extra: ["--beeps", "3", "--auto"]); let t0 = Date()
var verdict = ProbeVerdict.waiting
while verdict == .waiting { usleep(200_000); verdict = g0.preflight(elapsed: Date().timeIntervalSince(t0), readLog(pre)); if !pp.isRunning, verdict == .waiting { verdict = g0.preflight(elapsed: g0.preflightLimit, readLog(pre)) } }
kill(pp)
let o0 = readLog(pre)
say(String(format: "preverificare (%.1f s): play=%@ dur=%.1f beep=%d flash=%d fereastră=%@", Date().timeIntervalSince(t0), o0.playOK.map(String.init) ?? "-", o0.duration ?? 0, o0.beeps, o0.flashes, o0.windowOnScreen.map(String.init) ?? "-"))
guard verdict == .ok else { if case .invalid(let w) = verdict { say("INVALID: \(w)") }; exit(2) }
say("preverificare OK (imagine: fereastra pe ecran + flash-uri logate; sunet: redare pornită și ceas care avansează — nu înseamnă sunet auzit)")
if a[1] == "preflight" { exit(0) }
if a[1] == "prepare" {
    let pp2 = launch(dir, extra: ["--beeps", String(beeps)])
    try? String(pp2.processIdentifier).write(toFile: dir + "/probe.pid", atomically: true, encoding: .utf8)
    usleep(800_000)
    say("pregătit: sonda deschisă (pid \(pp2.processIdentifier)), așteaptă trigger; aplicația NU e armată — selectează fereastra, apoi rulează arm")
    exit(0)
}

// 2. guarded run -------------------------------------------------------------
guard a[1] == "run", let dest = opt("--dest") else { say("INVALID: lipsește --dest pentru run"); exit(2) }
var g = ProbeGuard(expected: Double(beeps) * 2)
// hard recording limit in the app: explicit --max-record (seconds) when the approval sets one, else deadline + 20 s
let maxRecord = opt("--max-record").flatMap(Double.init) ?? (g.deadline + 20)
say("limită dură a înregistrării în aplicație: \(Int(maxRecord)) s")
defaults(["write", app, "maxRecordSeconds", "-float", String(maxRecord)]); defaults(["write", app, "probeGuardStop", "-bool", "true"])
let rp = launch(dir, extra: ["--beeps", String(beeps)])
say("sonda pornită; aștept \(dir)/trigger (max 120 s) — pornește înregistrarea, apoi creează fișierul trigger")
let tw = Date()
while !fm.fileExists(atPath: dir + "/trigger") {
    usleep(200_000)
    if Date().timeIntervalSince(tw) > 120 || !rp.isRunning { kill(rp); stopRecording("fără trigger"); restoreApp(); say("INVALID: trigger absent în 120 s sau sonda s-a oprit"); exit(2) }
}
let tr = Date(); verdict = .waiting
while verdict == .waiting {
    usleep(250_000)
    verdict = g.monitor(elapsed: Date().timeIntervalSince(tr), readLog(dir))
    if verdict == .waiting, !rp.isRunning, !readLog(dir).finished { verdict = .invalid("sonda s-a oprit înainte de final (cod \(rp.terminationStatus))") }
}
stopRecording(verdict == .ok ? "sonda terminată" : "probă invalidă"); kill(rp)
// confirm the stop from the newest session of the destination
var stopped = false; let ts = Date()
while Date().timeIntervalSince(ts) < 20 {
    let sessions = ((try? fm.contentsOfDirectory(atPath: dest)) ?? []).filter { $0.hasPrefix("SADROG-") }.map { dest + "/" + $0 }
    if let newest = sessions.max(by: { ((try? fm.attributesOfItem(atPath: $0)[.modificationDate] as? Date) ?? .distantPast) < ((try? fm.attributesOfItem(atPath: $1)[.modificationDate] as? Date) ?? .distantPast) }),
       let s = try? String(contentsOfFile: newest + "/session.json", encoding: .utf8), s.contains("\"finished\"") { stopped = true; say("înregistrare oprită: \(newest)"); break }
    usleep(500_000)
}
restoreApp()
if !stopped { say("ATENȚIE: oprirea înregistrării NU a fost confirmată în 20 s — verifică aplicația") }
switch verdict { case .ok: say("VALID: \(readLog(dir).beeps) beep-uri"); exit(stopped ? 0 : 2)
case .invalid(let w): say("INVALID: \(w)"); exit(2)
case .waiting: exit(2) }
