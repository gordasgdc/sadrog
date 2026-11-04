// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
import AudioToolbox
@testable import SadrogCore

/// Audio Unit chains on recording sources: model, catalog, offline render (out of process), delay policy, cache key, cancel, missing plugin,
/// export. Synthetic voice + Apple's own effects (always installed); 4LO checks run only when those plugins are installed. Measured, not listened to.
final class AudioEffectsTests: XCTestCase {
    static let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG"
    static let voice = root + "/synthetic/effects/voice_mono_6s.caf"
    let work = URL(fileURLWithPath: "\(root)/temp/fx-\(UUID().uuidString)")
    override func setUp() async throws { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true); try Self.makeVoice() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    /// Synthetic voice: 120 Hz glottal pulses with vibrato through three formants, 0.3 s syllables; mono 48 kHz, peak −9 dBFS, 6 s (last 1 s silent).
    static func makeVoice() throws {
        guard !FileManager.default.fileExists(atPath: voice) else { return }
        try FileManager.default.createDirectory(atPath: (voice as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let sr = 48000.0, n = Int(6 * sr), N = Int(5 * sr)
        var x = [Float](repeating: 0, count: n)
        let formants: [[(Double, Double)]] = [[(700, 110), (1220, 120), (2600, 160)], [(300, 60), (2300, 100), (3000, 140)], [(500, 80), (900, 90), (2400, 140)]]
        var phase = 0.0, seed: UInt32 = 12345; var st = [[Double]](repeating: [0, 0], count: 3)
        for i in 0..<N {
            let t = Double(i) / sr; phase += 120 * (1 + 0.03 * sin(2 * .pi * 5 * t)) / sr
            var e = 0.0; if phase >= 1 { phase -= 1; e = 1 }
            seed = seed &* 1664525 &+ 1013904223; e += (Double(seed >> 8) / 16777216 - 0.5) * 0.02
            let syl = Int(t / 0.3), inSyl = t - Double(syl) * 0.3, env = inSyl < 0.22 ? sin(.pi * inSyl / 0.22) : 0
            var y = 0.0
            for (k, (f, bw)) in formants[syl % 3].enumerated() { let r = exp(-.pi * bw / sr), c1 = 2 * r * cos(2 * .pi * f / sr), c2 = -r * r; let v = e * (1 - r) + c1 * st[k][0] + c2 * st[k][1]; st[k][1] = st[k][0]; st[k][0] = v; y += v }
            x[i] = Float(y * env)
        }
        let pk = x.map { abs($0) }.max()!; for i in 0..<n { x[i] *= 0.35 / pk }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!; b.frameLength = AVAudioFrameCount(n)
        x.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: n) }
        try AVAudioFile(forWriting: URL(fileURLWithPath: voice), settings: fmt.settings).write(from: b)
    }
    static func read(_ path: String) throws -> [Float] {
        // one read(into:) may return fewer frames than asked (seen: 287744 of 288000) — read until the end
        let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
        let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536)!; var x: [Float] = []
        while f.framePosition < f.length { try f.read(into: b); if b.frameLength == 0 { break }; x += UnsafeBufferPointer(start: b.floatChannelData![0], count: Int(b.frameLength)) }
        return x
    }
    static func apple(_ sub: String) -> AUComponentID { AUComponentID(type: kAudioUnitType_Effect, subtype: fourcc(sub), manufacturer: kAudioUnitManufacturer_Apple) }
    static func fourcc(_ s: String) -> UInt32 { s.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
    /// An effect entry with one parameter set (address → value) on a fresh out-of-process instance, its full state captured as the editor does.
    static func effect(_ id: AUComponentID, _ params: [AUParameterAddress: AUValue] = [:]) throws -> AudioEffect {
        let u = try AUCatalog.instantiate(id)
        for (a, v) in params { u.auAudioUnit.parameterTree?.parameter(withAddress: a)?.setValue(v, originator: nil) }
        let info = try XCTUnwrap(AUCatalog.installed(id))
        return AudioEffect(component: id, name: info.name, manufacturerName: info.manufacturerName, componentVersion: info.version, state: AudioEffect.encode(state: u.auAudioUnit.fullState))
    }
    func job(_ chain: [AudioEffect], media: String = voice, track: Int = 0) -> EffectJob {
        let k = EffectRenderer.key(media: media, track: track, chain: chain)
        return EffectJob(media: media, track: track, chain: chain, key: k, output: work.appendingPathComponent("\(k).caf"))
    }
    func lag(_ x: [Float], _ y: [Float], range: ClosedRange<Int> = -480...4800) -> Int {
        var best = (0, -Double.infinity)
        let a0 = 24000, a1 = min(x.count, y.count) - 5000
        for L in range { var s = 0.0; for i in stride(from: a0, to: a1, by: 2) { s += Double(x[i]) * Double(y[i + L]) }; if s > best.1 { best = (L, s) } }
        return best.0
    }

    // model ------------------------------------------------------------------
    func testModelFormat11UndoAndOldProjects() throws {
        let old = #"{"formatVersion":10,"name":"o","clips":[]}"#
        XCTAssertTrue(try JSONDecoder().decode(SadrogProject.self, from: Data(old.utf8)).sourceEffects.isEmpty)
        let e = ProjectEditor(project: SadrogProject(name: "m"))
        let fx = AudioEffect(component: Self.apple("lpas"), name: "AULowpass", manufacturerName: "Apple", componentVersion: 1, state: Data([1, 2, 3]))
        var b = fx; b.bypassed = true
        e.setEffects(1, [fx, b])
        XCTAssertEqual(e.project.activeEffects(ofSource: 1).count, 1)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project))
        XCTAssertEqual(back.sourceEffects[1], [fx, b]); XCTAssertGreaterThanOrEqual(back.formatVersion, 11)
        e.setEffects(1, []); XCTAssertNil(e.project.sourceEffects[1])
        e.undo(); XCTAssertEqual(e.project.sourceEffects[1]?.count, 2)
    }
    func testStateBytesAreCanonical() throws {
        let st: [String: Any] = ["b": 1, "a": Data([1, 2]), "c": ["z": 1, "y": "x", "w": [1, 2]], "d": 2.5, "e": "t", "f": true, "g": 3]
        let a = AudioEffect.encode(state: st), b = AudioEffect.encode(state: Dictionary(uniqueKeysWithValues: st.reversed()))
        XCTAssertEqual(a, b, "the same state must always give the same bytes (cache key, undo)")
    }
    func testCatalogIsGenericAndIncludesMusicEffects() {
        let all = AUCatalog.effects()
        XCTAssertTrue(all.contains { $0.id == Self.apple("lpas") }, "Apple effects must be listed")
        XCTAssertTrue(all.allSatisfy { $0.id.type == kAudioUnitType_Effect || $0.id.type == kAudioUnitType_MusicEffect })
        if AUCatalog.installed(AUComponentID(type: kAudioUnitType_MusicEffect, subtype: Self.fourcc("acp1"), manufacturer: Self.fourcc("4Lod"))) != nil {
            XCTAssertTrue(all.contains { $0.isMusicEffect && $0.name.contains("Auto Comp") })
        }
    }

    // render -----------------------------------------------------------------
    /// AUSampleDelay delays by a set number of frames and reports latency 0: the measured constant delay is compensated → output == input.
    func testUnreportedConstantDelayIsMeasuredAndCompensated() async throws {
        let fx = try Self.effect(Self.apple("sdly"), [0: 480])
        let j = job([fx]); let rep = try await EffectRenderer.render(j)
        XCTAssertEqual(rep.delays.first?.source, .measured); XCTAssertEqual(rep.delays.first?.samples, 480)
        let x = try Self.read(Self.voice), y = try Self.read(j.output.path)
        XCTAssertEqual(y.count, x.count + 48000, "file time kept + 1 s tail")
        let m = zip(x, y).map { abs($0 - $1) }.max()!
        XCTAssertLessThan(m, 1e-6, "compensated output must equal the input")
        XCTAssertFalse(FileManager.default.fileExists(atPath: j.output.deletingPathExtension().appendingPathExtension("partial.caf").path))
        XCTAssertEqual(EffectRenderer.report(for: j.output), rep)
    }
    func testRenderIsReproducibleAndKeyFollowsChain() async throws {
        let lp = try Self.effect(Self.apple("lpas"), [0: 800])
        let j1 = job([lp]); _ = try await EffectRenderer.render(j1)
        var j2 = j1; j2.output = work.appendingPathComponent("again.caf"); _ = try await EffectRenderer.render(j2)
        XCTAssertEqual(try Self.read(j1.output.path), try Self.read(j2.output.path), "fresh instances → identical result")
        let hp = try Self.effect(Self.apple("hpas"))
        let k = EffectRenderer.key(media: Self.voice, track: 0, chain: [lp, hp])
        XCTAssertNotEqual(k, EffectRenderer.key(media: Self.voice, track: 0, chain: [hp, lp]), "order")
        var lp2 = lp; lp2.state = try Self.effect(Self.apple("lpas"), [0: 900]).state
        XCTAssertNotEqual(k, EffectRenderer.key(media: Self.voice, track: 0, chain: [lp2, hp]), "state")
        var hpB = hp; hpB.bypassed = true
        XCTAssertEqual(EffectRenderer.key(media: Self.voice, track: 0, chain: [lp, hpB]), EffectRenderer.key(media: Self.voice, track: 0, chain: [lp]), "a bypassed plugin does not process")
        XCTAssertNotEqual(k, EffectRenderer.key(media: Self.voice, track: 1, chain: [lp, hp]), "input")
    }
    func testCancelLeavesNoFile() async throws {
        let lp = try Self.effect(Self.apple("lpas"))
        let path = RecordingAudioTests.c5; try XCTSkipUnless(FileManager.default.fileExists(atPath: path))
        let j = job([lp], media: path, track: 1)
        let t = Task { try await EffectRenderer.render(j) { f in if f > 0.05 { withUnsafeCurrentTask { _ in } } } }
        try await Task.sleep(nanoseconds: 300_000_000); t.cancel()
        do { _ = try await t.value; XCTFail("must be cancelled") } catch { XCTAssertEqual(error as? EffectError, .cancelled) }
        let left = try FileManager.default.contentsOfDirectory(atPath: work.path)
        XCTAssertTrue(left.isEmpty, "nothing left after cancel: \(left)")
    }
    /// Product contract, independent of machine load: a cancel requested while the worker is stuck in a slow plugin call is answered as `.cancelled` after a short grace
    /// (never as `.stalled`, never after the 20 s stall limit), and leaves no file.
    func testCancelWhileWorkerIsBlockedIsAnsweredAsCancelledPromptly() async throws {
        let j = job([try Self.effect(Self.apple("lpas"))])
        EffectRenderer.testBlockSeconds = 8; defer { EffectRenderer.testBlockSeconds = 0 }
        let t0 = Date()
        let t = Task { try await EffectRenderer.render(j) }
        try await Task.sleep(nanoseconds: 300_000_000); t.cancel()
        do { _ = try await t.value; XCTFail("must be cancelled") } catch { XCTAssertEqual(error as? EffectError, .cancelled) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "answered after the grace, not after the stall limit")
        try await Task.sleep(nanoseconds: 9_000_000_000)             // the worker wakes, sees the cancel and cleans up
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
    }
    /// A render that stops making progress is stopped after `stall` seconds and leaves no file; the caller gets `.stalled`, not a hang.
    func testStalledRenderIsStoppedWithoutLeavingFiles() async throws {
        let j = job([try Self.effect(Self.apple("lpas"))])
        EffectRenderer.testStallAfterStart = true; defer { EffectRenderer.testStallAfterStart = false }
        let t0 = Date()
        do { _ = try await EffectRenderer.render(j, stall: 1); XCTFail("must stop") } catch { XCTAssertEqual(error as? EffectError, .stalled(1)) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8)
        try await Task.sleep(nanoseconds: 300_000_000)                      // the stuck worker notices the stop and cleans up
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: work.path), [])
    }
    func testMissingPluginIsReportedAndBlocksExport() async throws {
        let ghost = AudioEffect(component: AUComponentID(type: kAudioUnitType_Effect, subtype: Self.fourcc("zzzz"), manufacturer: Self.fourcc("Nobd")), name: "Fantomă", manufacturerName: "Nimeni", componentVersion: 1)
        do { _ = try await EffectRenderer.render(job([ghost])); XCTFail() } catch { XCTAssertEqual(error as? EffectError, .missing("Fantomă")) }
        var p = SadrogProject(name: "t", clips: [Clip(media: Self.voice, sourceStart: 0, duration: 5)]); p.sourceEffects[0] = [ghost]
        let plan = await EffectRenderer.plan(p, folder: work)
        XCTAssertEqual(plan.sourcesPending, [0])
        XCTAssertThrowsError(try ProjectExporter.requireProcessed(p, plan))
        XCTAssertThrowsError(try ProjectExporter.requireProcessed(p, nil))
        var off = ghost; off.bypassed = true; p.sourceEffects[0] = [off]       // bypass keeps the entry and allows the export
        let plan2 = await EffectRenderer.plan(p, folder: work); XCTAssertNoThrow(try ProjectExporter.requireProcessed(p, plan2))
    }
    /// The processed copy replaces the source in the mix AND in its stem; volume and fades still apply on top; durations unchanged.
    func testExportAndStemUseTheProcessedSource() async throws {
        let lp = try Self.effect(Self.apple("lpas"), [0: 400])
        var p = SadrogProject(name: "t", clips: [Clip(media: Self.voice, sourceStart: 0.5, duration: 4)]); p.sourceEffects[0] = [lp]; p.sourceGains[0] = -6
        var plan = await EffectRenderer.plan(p, folder: work); XCTAssertEqual(plan.jobs.count, 1)
        _ = try await EffectRenderer.render(plan.jobs[0])
        plan = await EffectRenderer.plan(p, folder: work); XCTAssertTrue(plan.jobs.isEmpty); XCTAssertEqual(plan.ready.count, 1)
        let out = work.appendingPathComponent("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let items = AudioDelivery.plan(p, sources: [AudioSourceInfo(index: 0, name: "Voce", kind: .input)], baseName: "t")
        let urls = try await AudioDelivery.export(p, items: items, to: out, effects: plan)
        let stem = try XCTUnwrap(urls.first { $0.lastPathComponent.contains("A1-1") })
        func pcm(_ u: URL) async throws -> [Float] {
            let a = AVURLAsset(url: u); let t = try await a.loadTracks(withMediaType: .audio)[0]
            // left channel of the stereo file (a mono read would sum L+R of a centred mono source: +3 dB artefact)
            let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000])
            r.add(o); r.startReading(); var x: [Float] = []
            while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) { let n = CMBlockBufferGetDataLength(bb); var v = [Float](repeating: 0, count: n / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: &v); x += stride(from: 0, to: v.count, by: 2).map { v[$0] } }
            return x
        }
        let s = try await pcm(stem)
        XCTAssertEqual(Double(s.count) / 48000, 4, accuracy: 0.002)
        let proc = Array(try Self.read(plan.ready.values.first!.path)[24000..<(24000 + 192000)]), orig = Array(try Self.read(Self.voice)[24000..<(24000 + 192000)])
        func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(x.count)) }
        let w = 24000..<168000
        XCTAssertEqual(20 * log10(rms(s[w]) / rms(proc[w])), -6, accuracy: 0.3, "stem = processed source at −6 dB")
        let resid = zip(proc[w], orig[w]).map { $0 - $1 }
        XCTAssertGreaterThan(20 * log10(rms(resid[...]) / rms(orig[w])), -10, "the low-pass must really change the source")
        XCTAssertEqual(lag(proc, s), 0, "stem aligned with the processed source")
    }
    /// 4LO chain (only when installed): voxium's unreported 20 ms delay measured and compensated, DXB without delay; result aligned with the input.
    func testFourLOChainAlignedWhenInstalled() async throws {
        let vox = AUComponentID(type: kAudioUnitType_Effect, subtype: Self.fourcc("Tz4o"), manufacturer: Self.fourcc("4LOD"))
        let dxb = AUComponentID(type: kAudioUnitType_Effect, subtype: Self.fourcc("Dxc2"), manufacturer: Self.fourcc("4LOD"))
        try XCTSkipUnless(AUCatalog.installed(vox) != nil && AUCatalog.installed(dxb) != nil, "4LO not installed")
        // 4LO plugins refuse to start for the xctest host (OSStatus −128); the same calls work from a signed or ad-hoc tool and in the app
        let chain: [AudioEffect]
        do { chain = [try Self.effect(vox), try Self.effect(dxb)] }
        catch EffectError.instantiate(let w) where w.contains("-128") { throw XCTSkip("4LO refuză gazda xctest (−128); verificat prin probă și în aplicație") }
        let j = job(chain); let rep = try await EffectRenderer.render(j)
        XCTAssertEqual(rep.delays.map(\.source), [.measured, .none]); XCTAssertEqual(rep.delays[0].samples, 959, accuracy: 1)
        XCTAssertEqual(lag(try Self.read(Self.voice), try Self.read(j.output.path)), 0, "compensated chain is aligned with the input")
    }
}
