// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Per-source volume in dB: model, undo, persistence, the shared mix, and measured levels in exports (numbers only — not listened to).
final class SourceGainTests: XCTestCase {
    func testModelUndoPersistenceAndLegacy() throws {
        let old = try JSONDecoder().decode(SadrogProject.self, from: Data(#"{"formatVersion":7,"name":"o","clips":[]}"#.utf8))
        XCTAssertTrue(old.sourceGains.isEmpty); XCTAssertEqual(old.gain(ofSource: 0), 0)
        let e = ProjectEditor(project: old)
        e.setSourceGain(1, dB: -6.04); XCTAssertEqual(e.project.gain(ofSource: 1), -6.0)
        e.setSourceGain(1, dB: 99); XCTAssertEqual(e.project.gain(ofSource: 1), 12)
        e.setSourceGain(1, dB: 0); XCTAssertNil(e.project.sourceGains[1], "0 dB = neutral, stored as no entry")
        e.undo(); XCTAssertEqual(e.project.gain(ofSource: 1), 12); e.undo(); XCTAssertEqual(e.project.gain(ofSource: 1), -6)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project))
        XCTAssertEqual(back.sourceGains, [1: -6])
        XCTAssertEqual(SadrogProject.linear(dB: -6.0206), 0.5, accuracy: 1e-4)
    }
    func testMixCarriesGainAndMuteWins() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5 not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 0, duration: 4)])
        let b = try await CompositionBuilder.buildFull(p)
        let t0 = b.mainAudio[0]!.trackID, t1 = b.mainAudio[1]!.trackID
        p.sourceGains = [0: -6.0206, 1: 6.0206]
        let v = mixVolumes(b.audioMix(for: p))
        XCTAssertEqual(v[t0]!, 0.5, accuracy: 1e-4); XCTAssertEqual(v[t1]!, 2.0, accuracy: 1e-3)
        p.mutedSources = [1]; XCTAssertEqual(mixVolumes(b.audioMix(for: p))[t1], 0)
        // a single track at a non-neutral gain also gets a mix (else the gain would be lost)
        let one = SadrogProject(name: "o", clips: [Clip(media: RecordingAudioTests.c4.replacingOccurrences(of: "5EA2BB6B-993F-4EE5-AB6C-E99D881E81ED", with: "84EB0F01-BD65-472B-A8E8-20142925CBF3"), sourceStart: 0, duration: 2)])
        if FileManager.default.fileExists(atPath: one.clips[0].media) {
            var q = one; q.sourceGains = [0: -12]
            let bq = try await CompositionBuilder.buildFull(q)
            XCTAssertEqual(Array(mixVolumes(bq.audioMix(for: q)).values).first ?? 1, SadrogProject.linear(dB: -12), accuracy: 1e-4)
        }
    }
    /// Export levels follow the gain (measured on the file): system sound alone at 0 dB vs −6 dB vs +12 dB.
    func testExportLevelFollowsGainAndClippingIsVisible() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5 not available")
        func levels(_ url: URL) async throws -> (rms: Double, peak: Double) {
            let a = AVURLAsset(url: url); let ts = try await a.loadTracks(withMediaType: .audio); let t = try XCTUnwrap(ts.first)
            let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1])
            r.add(o); r.startReading(); var s = 0.0, n = 0, pk = 0.0
            while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d)
                for v in d { s += Double(v * v); pk = max(pk, Double(abs(v))) }; n += d.count
            }
            return (10 * log10(s / Double(max(n, 1)) + 1e-24), 20 * log10(pk + 1e-12))
        }
        let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp"
        func export(_ gain: Double) async throws -> (rms: Double, peak: Double) {
            var p = SadrogProject(name: "t", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 10, duration: 4)])
            p.mutedSources = [1]; p.sourceGains = [0: gain]
            let u = URL(fileURLWithPath: "\(dir)/gain-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: u) }
            try await ProjectExporter.export(p, to: u); return try await levels(u)
        }
        let n0 = try await export(0), m6 = try await export(-6), p12 = try await export(12)
        print(String(format: "GAIN 0 dB: rms %.2f peak %.2f | −6 dB: rms %.2f peak %.2f | +12 dB: rms %.2f peak %.2f dBFS", n0.rms, n0.peak, m6.rms, m6.peak, p12.rms, p12.peak))
        XCTAssertEqual(m6.rms - n0.rms, -6, accuracy: 0.5)
        XCTAssertGreaterThan(p12.rms - n0.rms, 6, "a +12 dB gain raises the level (it may clip: nothing limits it)")
    }
}
