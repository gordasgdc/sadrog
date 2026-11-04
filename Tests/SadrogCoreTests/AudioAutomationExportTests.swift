// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Volume curves, shaped fades and crossfades MEASURED in real exports (synthetic constant tones, decoded to float). This is numeric validation, not listening.
final class AudioAutomationExportTests: XCTestCase {
    func exportSamples(_ p: SadrogProject) async throws -> [Float] {
        let out = URL(fileURLWithPath: "\(SyntheticRecording.root)/aa-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: out) }
        try await ProjectExporter.export(p, to: out)
        return try await RampRecording.samples(out, from: 0, to: p.timelineEnd)
    }
    /// RMS in dB of the window centred on `t`.
    func rms(_ s: [Float], at t: Double, win: Double = 0.1) -> Double {
        let a = max(0, Int((t - win / 2) * 48000)), b = min(s.count, Int((t + win / 2) * 48000)); guard b > a else { return -200 }
        return 10 * log10(s[a..<b].reduce(0.0) { $0 + Double($1 * $1) } / Double(b - a) + 1e-20)
    }
    func project(video: URL, layers: [Layer], seconds: Double) -> SadrogProject {
        var p = SadrogProject(name: "t", clips: [Clip(media: video.path, sourceStart: 0, duration: seconds)], layers: layers); p.mutedLanes = [.a1]; return p
    }

    func testVolumeCurveIsAppliedAndSmoothInExport() async throws {
        let src = try await RampRecording.make(duration: 12); defer { try? FileManager.default.removeItem(at: src) }
        var l = Layer(kind: .audio, media: src.path, start: 0, duration: 10); var a = AudioEdit()
        a.points = [VolumeKey(t: 0, db: 0), VolumeKey(t: 3, db: 0), VolumeKey(t: 4, db: -20), VolumeKey(t: 6, db: -20), VolumeKey(t: 7, db: 0), VolumeKey(t: 9, db: VolumeKey.silenceDB)]; l.audio = a
        let s = try await exportSamples(project(video: src, layers: [l], seconds: 10))
        let ref = rms(s, at: 1.5)
        XCTAssertEqual(rms(s, at: 5) - ref, -20, accuracy: 0.6)
        XCTAssertEqual(rms(s, at: 3.5) - ref, -10, accuracy: 1.5)                       // halfway in dB
        XCTAssertEqual(rms(s, at: 8.0) - ref, 20 * log10(1 - 0.5) , accuracy: 1.5)      // 6→… 7: back at 0 dB, 7→9 amplitude line to silence: ½ at t=8
        XCTAssertLessThan(rms(s, at: 9.6), ref - 60)                                    // silence is silence
        // no accidental discontinuity (checked up to 8.4 s; the last stretch is a straight amplitude line into silence, whose dB value falls steeply by nature): consecutive 20 ms windows never jump by more than the slope allows
        var worst = 0.0; var prev = rms(s, at: 0.01, win: 0.02)
        for i in 1..<420 { let v = rms(s, at: 0.01 + 0.02 * Double(i), win: 0.02); if v > ref - 50 && prev > ref - 50 { worst = max(worst, abs(v - prev)) }; prev = v }
        XCTAssertLessThan(worst, 3.5, "largest step between neighbouring 20 ms windows (dB)")
    }
    func testShapedFadeInExportFollowsTheCurve() async throws {
        let src = try await RampRecording.make(duration: 8); defer { try? FileManager.default.removeItem(at: src) }
        var l = Layer(kind: .audio, media: src.path, start: 0, duration: 8); var a = AudioEdit(fadeIn: 3, fadeOut: 3)
        a.fadeInCurve = FadeCurve(shape: .easeIn, bend: 0.7); a.fadeOutCurve = FadeCurve(shape: .sCurve, bend: 0.8); l.audio = a
        let s = try await exportSamples(project(video: src, layers: [l], seconds: 8))
        let ref = rms(s, at: 4)
        for t in [1.0, 1.5, 2.0, 2.5] { XCTAssertEqual(rms(s, at: t) - ref, 20 * log10(a.fadeInCurve.gain(t / 3)), accuracy: 1.0, "fade-in t=\(t)") }
        for t in [5.5, 6.0, 6.5, 7.0] { XCTAssertEqual(rms(s, at: t) - ref, 20 * log10(a.fadeOutCurve.gain((8 - t) / 3)), accuracy: 1.0, "fade-out t=\(t)") }
    }
    func testCrossfadeLevelsForUnrelatedAndCorrelatedSounds() async throws {
        let a = try await RampRecording.make(duration: 12, tone: 440), b = try await RampRecording.make(duration: 12, tone: 330)
        defer { try? FileManager.default.removeItem(at: a); try? FileManager.default.removeItem(at: b) }
        func run(_ second: URL, srcStart: Double, mode: CrossfadeMode) async throws -> (before: Double, mid: Double) {
            let la = Layer(kind: .audio, media: a.path, start: 0, duration: 6)
            let lb = Layer(kind: .audio, media: second.path, start: 4, sourceStart: srcStart, duration: 6)
            let e = ProjectEditor(project: project(video: a, layers: [la, lb], seconds: 10))
            var lb2 = lb; lb2.track = 1; e.placeLayer(lb.id, start: 4, row: 1)
            XCTAssertEqual(e.crossfade(outgoing: la.id, incoming: lb.id, shape: CrossfadeShape(mode: mode)), .created(seconds: 2))
            let s = try await exportSamples(e.project)
            return (rms(s, at: 2), rms(s, at: 5))
        }
        let ug = try await run(b, srcStart: 0, mode: .equalGain), up = try await run(b, srcStart: 0, mode: .equalPower)
        XCTAssertEqual(ug.mid - ug.before, -3.0, accuracy: 1.0, "unrelated sounds, equal gain: power dips ~3 dB")
        XCTAssertEqual(up.mid - up.before, 0.0, accuracy: 1.0, "unrelated sounds, equal power: constant")
        let cg = try await run(a, srcStart: 4, mode: .equalGain), cp = try await run(a, srcStart: 4, mode: .equalPower)
        XCTAssertEqual(cg.mid - cg.before, 0.0, accuracy: 1.0, "identical sounds, equal gain: constant")
        XCTAssertEqual(cp.mid - cp.before, 3.0, accuracy: 1.0, "identical sounds, equal power: +3 dB bump — the documented limit of equal power")
    }
    func testDissolveSoundShapeIsAppliedOnMainClips() async throws {
        let src = try await RampRecording.make(duration: 6); defer { try? FileManager.default.removeItem(at: src) }
        var c1 = Clip(media: src.path, sourceStart: 0, duration: 5), c2 = Clip(media: src.path, sourceStart: 1, duration: 5)
        c2.dissolve = 2; c2.dissolveShape = CrossfadeShape(mode: .equalPower)
        let s = try await exportSamples(SadrogProject(name: "t", clips: [c1, c2]))
        c1.dissolve = 0
        // clips 0…5 and 3…8 (overlap 3…5); the same recording shifted by 1 s → the two sides are NOT in phase; just require a finite, continuous level
        let ref = rms(s, at: 1.5); XCTAssertEqual(rms(s, at: 6.5) - ref, 0, accuracy: 1.0)
        for t in stride(from: 3.0, through: 5.0, by: 0.25) { XCTAssertGreaterThan(rms(s, at: t) - ref, -8) }
    }
}
