// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Voice presets (Apple's own high-pass, dynamics and peak limiter through the out-of-process host). Measured on synthetic signals, not listened to.
final class VoiceProcessingTests: XCTestCase {
    let work = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/voice-\(UUID().uuidString)")
    override func setUp() async throws { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }

    func write(_ name: String, _ f: (Int) -> Float, seconds: Double = 4) throws -> String {
        let sr = 48000.0, n = Int(seconds * sr), fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 1)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(n))!; b.frameLength = AVAudioFrameCount(n)
        for i in 0..<n { b.floatChannelData![0][i] = f(i) }
        let url = work.appendingPathComponent(name + ".caf"); try AVAudioFile(forWriting: url, settings: fmt.settings).write(from: b); return url.path
    }
    func run(_ preset: VoicePreset, _ path: String) async throws -> [Float] {
        let chain = try preset.effects(), k = EffectRenderer.key(media: path, track: 0, chain: chain)
        let job = EffectJob(media: path, track: 0, chain: chain, key: k, output: work.appendingPathComponent("\(k).caf"))
        _ = try await EffectRenderer.render(job); return try AudioEffectsTests.read(job.output.path)
    }
    func rms(_ x: ArraySlice<Float>) -> Double { sqrt(x.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(max(1, x.count))) }
    func db(_ v: Double) -> Double { 20 * log10(max(v, 1e-9)) }

    func testEveryPresetBuildsReorderableEffectsWithTheirParameters() throws {
        for p in VoicePreset.allCases {
            let fx = try p.effects(); XCTAssertEqual(fx.count, p.stages.count, "\(p)")
            XCTAssertTrue(fx.allSatisfy { VoicePreset.isVoiceStage($0) && $0.state != nil && !$0.bypassed })
        }
        let hp = try VoicePreset.highPassOnly.effects()[0]
        let u = try AUCatalog.instantiate(VoicePreset.highPass)
        try u.auAudioUnit.fullState = XCTUnwrap(hp.decodedState)
        XCTAssertEqual(u.auAudioUnit.parameterTree?.parameter(withAddress: 0)?.value ?? 0, 80, accuracy: 0.5, "the cut-off set by the preset is in the saved state")
    }
    func testHighPassRemovesHumAndKeepsTheVoiceBand() async throws {
        let sr = 48000.0
        let path = try write("hum") { i in Float(0.3 * sin(2 * .pi * 40 * Double(i) / sr) + 0.2 * sin(2 * .pi * 1000 * Double(i) / sr)) }
        let y = try await run(.highPassOnly, path)
        // tone amplitudes by correlation over 1 s in the settled part
        func amp(_ x: [Float], _ f: Double) -> Double {
            var a = 0.0, b = 0.0; let lo = 24000, hi = 72000
            for i in lo..<hi { let ph = 2 * Double.pi * f * Double(i) / sr; a += Double(x[i]) * sin(ph); b += Double(x[i]) * cos(ph) }
            return 2 * sqrt(a * a + b * b) / Double(hi - lo)
        }
        XCTAssertLessThan(db(amp(y, 40) / 0.3), -10, "an octave below the 80 Hz cut-off the hum is down about 11 dB (second-order filter, 12 dB per octave)")
        XCTAssertEqual(db(amp(y, 1000) / 0.2), 0, accuracy: 1.0, "1 kHz is left alone")
    }
    func testLimiterHoldsPeaksBelowFullScale() async throws {
        let sr = 48000.0
        let path = try write("loud") { i in Float(1.8 * sin(2 * .pi * 300 * Double(i) / sr)) }       // +5 dB over full scale
        let y = try await run(.limiterOnly, path)
        let peak = y[24000...].map { abs($0) }.max()!
        XCTAssertLessThan(peak, 1.05, "peak after the limiter (input peak 1.8)")
        XCTAssertGreaterThan(peak, 0.5, "the sound is limited, not silenced")
    }
    func testCleanVoiceNarrowsTheLoudQuietGapAndIsHonestAboutNoise() async throws {
        let sr = 48000.0
        // 1 s loud tone, 1 s quiet tone, 1 s very quiet "room" noise-like tone, 1 s loud
        let path = try write("levels") { i in
            let s = Double(i) / sr, amp: Double = s < 1 ? 0.5 : s < 2 ? 0.05 : s < 3 ? 0.001 : 0.5
            return Float(amp * sin(2 * .pi * 500 * s))
        }
        let y = try await run(.cleanVoice, path), x = try AudioEffectsTests.read(path)
        let seg = { (a: [Float], s: Int) in self.rms(a[(s * 48000 + 12000)..<(s * 48000 + 40000)]) }
        let gapBefore = db(seg(x, 0)) - db(seg(x, 1)), gapAfter = db(seg(y, 0)) - db(seg(y, 1))
        XCTAssertLessThan(gapAfter, gapBefore, "compression narrows the distance between loud and quiet passages (\(gapBefore) → \(gapAfter) dB)")
        let floorBefore = db(seg(x, 2)), floorAfter = db(seg(y, 2))
        XCTAssertLessThan(floorAfter, floorBefore + 0.5, "the expander never raises the quiet floor")
    }
    func testPresetsReplaceOnlyVoiceStagesAndUndoInOneStep() throws {
        let other = AudioEffect(component: AUComponentID(type: 0x61756678, subtype: 0x7a7a7a7a, manufacturer: 0x4e6f6264), name: "X", manufacturerName: "Y", componentVersion: 1)
        let e = ProjectEditor(project: SadrogProject(name: "v", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 4)]))
        e.setEffects(0, [other], media: "/a.mov")
        try e.setVoicePreset(.cleanVoice, source: 0, media: "/a.mov")
        XCTAssertEqual(e.project.recording("/a.mov").effects[0]?.count, 4, "the other plugin stays; three voice stages follow")
        try e.setVoicePreset(.highPassOnly, source: 0, media: "/a.mov")
        XCTAssertEqual(e.project.recording("/a.mov").effects[0]?.count, 2)
        try e.setVoicePreset(nil, source: 0, media: "/a.mov")
        XCTAssertEqual(e.project.recording("/a.mov").effects[0]?.map(\.name), ["X"], "reset removes only the voice stages")
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.recording("/a.mov").effects[0]?.count, 2)
    }
}
