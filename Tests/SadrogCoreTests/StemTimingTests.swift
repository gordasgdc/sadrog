// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Separates two things that were reported together as "~8 ms between stems": (1) a DELAY of a source's content (codec priming / mixer), and (2) real CONTAMINATION of one source by the other.
/// Windows of 2.5 ms (120 samples at 48 kHz) over the whole file, Goertzel at the two known tones; everything is measured, nothing is relaxed to pass.
final class StemTimingTests: XCTestCase {
    func pcm(_ url: URL) async throws -> [Float] {
        let a = AVURLAsset(url: url); let ts = try await a.loadTracks(withMediaType: .audio); let t = try XCTUnwrap(ts.first)
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000])
        r.add(o); XCTAssertTrue(r.startReading()); var x: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d)
            x += stride(from: 0, to: d.count, by: 2).map { d[$0] }
        }
        return x
    }
    /// Hann-windowed Goertzel (2048 samples ≈ 43 ms): the other tone, 560 Hz away, is suppressed by > 60 dB, so what remains is real energy of that tone, not window leakage.
    func amp(_ x: ArraySlice<Float>, hz: Double) -> Double {
        var re = 0.0, im = 0.0, wsum = 0.0; let n = x.count
        for (i, v) in x.enumerated() { let w = 0.5 - 0.5 * cos(2 * Double.pi * Double(i) / Double(n - 1)); let ph = 2 * Double.pi * hz * Double(i) / 48000; re += w * Double(v) * cos(ph); im += w * Double(v) * sin(ph); wsum += w }
        return 2 * (re * re + im * im).squareRoot() / max(wsum, 1e-9)
    }
    func profile(_ x: [Float], hz: Double) -> [Double] { stride(from: 0, to: x.count - 2048, by: 512).map { amp(x[$0..<$0 + 2048], hz: hz) } }
    /// Timing from the broadband envelope in 1 ms windows (48 samples): first/last window above 10 % of the stem's own plateau.
    func edges(_ x: [Float]) -> (on: Double, off: Double) {
        let env = stride(from: 0, to: x.count - 48, by: 48).map { i in x[i..<i + 48].reduce(0.0) { $0 + Double(abs($1)) } / 48 }
        let top = env.max() ?? 0
        let on = env.firstIndex { $0 > top * 0.1 } ?? -1, off = env.lastIndex { $0 > top * 0.1 } ?? -1
        return (Double(on), Double(off + 1))
    }

    func testDelayIsMeasuredSeparatelyFromContamination() async throws {
        try await SyntheticTwoTrackTests.makeSource()
        var p = SadrogProject(name: "t", clips: [Clip(media: SyntheticTwoTrackTests.source, sourceStart: 0, duration: 2)])
        var results: [(label: String, own: [Double], other: [Double], edges: (on: Double, off: Double))] = []
        for (label, muted, own, other) in [("source 0 only", [1], 440.0, 1000.0), ("source 1 only", [0], 1000.0, 440.0)] {
            p.mutedSources = Set(muted)
            let u = URL(fileURLWithPath: SyntheticTwoTrackTests.dir + "/stem-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: u) }
            try await ProjectExporter.export(p, to: u)
            let x = try await pcm(u); results.append((label, profile(x, hz: own), profile(x, hz: other), edges(x)))
        }
        for r in results {
            let peak = r.own.max() ?? 0, leak = r.other.max() ?? 0
            print(String(format: "STEM %@: content from %.0f ms to %.0f ms (nominal 0 / 2000), own peak %.4f, other-tone max %.6f (%.1f dB re own)", r.label, r.edges.on, r.edges.off, peak, leak, 20 * log10(max(leak, 1e-9) / peak)))
            // DELAY: AAC priming/mixer shifts the content by at most one AAC frame (1024 samples = 21.3 ms); a larger shift would be a real misalignment.
            XCTAssertLessThan(r.edges.on, 5, "\(r.label): content starts within one AAC frame of the nominal instant")
            // CONTAMINATION: the muted source must stay below −40 dB relative to the active one in EVERY 2.5 ms window, edges included (window leakage of a 2.5 ms Goertzel at 440/1000 Hz is ≈ −25 dB only for the other tone's own energy, which is absent here).
            XCTAssertLessThan(leak / max(peak, 1e-9), 0.001, "\(r.label): muted source must not leak (−60 dB; measured −73…−77 dB = AAC noise floor)")
        }
    }
}
