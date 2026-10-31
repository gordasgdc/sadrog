// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
// Sync probe v2 (development tool, not shipped): N beeps (440 Hz, 150 ms) every 2 s; the window flashes white when the player clock
// crosses each beep. v2 guards itself: it fails at once when the tone does not play, when its clock stops, or past its own deadline,
// and logs what the guard needs (window on screen, each beep and flash, END).
// Usage: sadrog-syncprobe <dir> [--beeps N] [--auto]   (--auto: start without waiting for <dir>/trigger)
import AppKit
import AVFoundation

let args = CommandLine.arguments
guard args.count >= 2 else { FileHandle.standardError.write("usage: sadrog-syncprobe <dir> [--beeps N] [--auto]\n".data(using: .utf8)!); exit(64) }
let dir = args[1]
let beeps = args.firstIndex(of: "--beeps").flatMap { args.indices.contains($0 + 1) ? Int(args[$0 + 1]) : nil } ?? 60
let auto = args.contains("--auto")
let sr = 48000.0, total = Double(beeps) * 2 + 4
var log = ""
func flush() { try? log.write(toFile: dir + "/probe_log.txt", atomically: true, encoding: .utf8) }
func fail(_ why: String, _ code: Int32) -> Never { log += "FAIL \(why)\n"; flush(); exit(code) }

var pcm = [Float](repeating: 0, count: Int(sr * total))
for k in 1...beeps { let s0 = Int(sr * Double(k) * 2); for i in 0..<Int(sr * 0.15) { let t = Double(i) / sr; pcm[s0 + i] = Float(0.5 * sin(2 * .pi * 440 * t) * min(1, t / 0.005)) } }
let wav = URL(fileURLWithPath: dir + "/probe_tone.wav")
let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(pcm.count))!
buf.frameLength = buf.frameCapacity; pcm.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: pcm.count) }
do { let file = try AVAudioFile(forWriting: wav, settings: fmt.settings); try file.write(from: buf) } catch { fail("tone file: \(error)", 3) }   // closed at end of scope
guard let player = try? AVAudioPlayer(contentsOf: wav) else { fail("cannot load tone", 3) }
player.prepareToPlay()

let app = NSApplication.shared; app.setActivationPolicy(.accessory)
let scr = NSScreen.screens.first { $0.localizedName.contains("BenQ") } ?? NSScreen.main!
let win = NSWindow(contentRect: NSRect(x: scr.frame.minX + 300, y: scr.frame.minY + 300, width: 700, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
win.title = "SADROG sync probe"; win.level = .floating; win.backgroundColor = .black; win.makeKeyAndOrderFront(nil)

var started = false, next = 1, tick = 0, startWall = 0.0, lastT = -1.0, lastMove = 0.0, checkedWindow = false
var endAt: Double? = nil
let launch = ProcessInfo.processInfo.systemUptime
Timer.scheduledTimer(withTimeInterval: 0.002, repeats: true) { _ in
    let now = ProcessInfo.processInfo.systemUptime
    if !checkedWindow, now - launch > 0.3 {
        checkedWindow = true
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let on = info.contains { ($0[kCGWindowNumber as String] as? Int) == win.windowNumber }
        log += "window onscreen=\(on)\n"; flush()
        if !on { fail("window not on screen", 6) }
    }
    if !started {
        guard checkedWindow, auto || FileManager.default.fileExists(atPath: dir + "/trigger") else { if now - launch > 600 { fail("no trigger within 600 s", 7) }; return }
        let ok = player.play(); started = true; startWall = now; lastMove = now
        log += "play() returned \(ok) dev=\(player.currentDevice ?? "default") dur=\(player.duration)\n"; flush()
        if !ok || player.duration <= 0 { fail("tone does not play (play=\(ok), dur=\(player.duration))", 3) }
        return
    }
    let t = player.currentTime
    if endAt == nil {
        if t > lastT + 0.0005 { lastT = t; lastMove = now } else if now - lastMove > 2 { fail("player clock stopped at \(t)", 4) }
        if now - startWall > total + 10 { fail("probe deadline exceeded", 5) }
    }
    tick += 1; if tick % 500 == 1 { log += "tick \(tick) t=\(t) playing=\(player.isPlaying)\n"; flush() }
    if next <= beeps, t >= Double(next) * 2 {
        win.backgroundColor = .white; log += "beep \(next) player=\(t) uptime=\(now)\nflash \(next)\n"; flush()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { win.backgroundColor = .black }; next += 1
    }
    // END: the window STAYS open (it is the captured source) until the guard closes it after the app confirmed the stop; closing it here
    // ended the recording as "source lost" before the guard could ask (2026-10-29, probe A). Own safety: exit 30 s after END at the latest.
    if next > beeps, t >= Double(beeps) * 2 + 1, endAt == nil { log += "END beeps=\(beeps)\n"; flush(); endAt = now }
    if let e = endAt, now - e > 30 { log += "EXIT after END timeout\n"; flush(); exit(0) }
}
app.run()
