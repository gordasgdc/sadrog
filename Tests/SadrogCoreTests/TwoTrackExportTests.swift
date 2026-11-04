// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// A recording with two audio tracks (system + microphone), exported with nothing muted, must contain BOTH.
final class TwoTrackExportTests: XCTestCase {
    func energy(_ url: URL) async throws -> (rms: Double, tracks: Int) {
        let a = AVURLAsset(url: url); let ts = try await a.loadTracks(withMediaType: .audio); let t = try XCTUnwrap(ts.first)
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
        r.add(o); r.startReading(); var s = 0.0, n = 0
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d)
            for v in d { s += Double(v * v) }; n += d.count
        }
        return (s / Double(max(n, 1)), ts.count)
    }
    func testUnmutedExportKeepsMicrophone() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5 not available")
        let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp"
        func run(_ muted: Set<Int>) async throws -> (rms: Double, tracks: Int) {
            var p = SadrogProject(name: "t", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 10, duration: 4)])
            p.mutedSources = muted
            let u = URL(fileURLWithPath: "\(dir)/two-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: u) }
            try await ProjectExporter.export(p, to: u); return try await energy(u)
        }
        var rawRatio = 1.0
        // reference: sum of the two raw source tracks over the same range
        do {
            let a = AVURLAsset(url: URL(fileURLWithPath: RecordingAudioTests.c5)); let ts = try await a.loadTracks(withMediaType: .audio)
            var pcm: [[Float]] = []
            for t in ts.prefix(2) {
                let r = try AVAssetReader(asset: a); r.timeRange = CMTimeRange(start: CMTime(seconds: 10, preferredTimescale: 6000), duration: CMTime(seconds: 4, preferredTimescale: 6000))
                let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000])
                r.add(o); r.startReading(); var x: [Float] = []
                while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) { let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d); x += d }
                pcm.append(x)
            }
            let n = min(pcm[0].count, pcm[1].count); var e0 = 0.0, e1 = 0.0, es = 0.0
            for i in 0..<n { e0 += Double(pcm[0][i] * pcm[0][i]); e1 += Double(pcm[1][i] * pcm[1][i]); let v = pcm[0][i] + pcm[1][i]; es += Double(v * v) }
            rawRatio = es / e0
            print("RAW tracks \(ts.count) ms0 \(e0 / Double(n)) ms1 \(e1 / Double(n)) sum \(es / Double(n))")
        }
        let both = try await run([]), sysOnly = try await run([1]), micOnly = try await run([0])
        print("TWO both \(both) sys \(sysOnly) mic \(micOnly)")
        XCTAssertGreaterThan(micOnly.rms, 1e-9, "fixture: mic has sound")
        // the export must equal the sum of the two source tracks (here the quiet mic is partly in antiphase with system bleed, so the sum is slightly LOWER than system alone)
        XCTAssertEqual(both.rms / sysOnly.rms, rawRatio, accuracy: 0.03, "unmuted export must be the sum of both tracks")
        XCTAssertNotEqual(both.rms, sysOnly.rms, accuracy: 1e-5, "the mic must change the result")
    }
}

/// Fully synthetic: a source with TWO audio tracks (440 Hz at 0.25 and 1000 Hz at 0.10, stereo 48 kHz). The export must carry both at their known
/// amplitudes (Goertzel on the first channel, steady window), follow mute and per-source gain, and stay as long as the video. No private material.
final class SyntheticTwoTrackTests: XCTestCase {
    static let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp"
    static var source: String { dir + "/two_tracks_440_1000.mov" }

    static func tone(_ path: String, hz: Double, amp: Double) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let n = AVAudioFrameCount(48000 * 4), buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
        for ch in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![ch][i] = Float(amp * sin(2 * .pi * hz * Double(i) / 48000)) } }
        try? FileManager.default.removeItem(atPath: path)
        try AVAudioFile(forWriting: URL(fileURLWithPath: path), settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192000]).write(from: buf)
    }
    static func makeSource() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: CompositionTests.dir + "/blue.mov"), "synthetic colour clips not available")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard !FileManager.default.fileExists(atPath: source) else { return }
        try tone(dir + "/t440.m4a", hz: 440, amp: 0.25); try tone(dir + "/t1000.m4a", hz: 1000, amp: 0.10)
        let comp = AVMutableComposition(); let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 4, preferredTimescale: 48000))
        let vAsset = AVURLAsset(url: URL(fileURLWithPath: CompositionTests.dir + "/blue.mov")); let v = try await vAsset.loadTracks(withMediaType: .video)[0]
        try comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(v.timeRange, of: v, at: .zero)
        var keep: [AVURLAsset] = [vAsset]
        for f in ["t440.m4a", "t1000.m4a"] {
            let aAsset = AVURLAsset(url: URL(fileURLWithPath: dir + "/" + f)); let a = try await aAsset.loadTracks(withMediaType: .audio)[0]
            try comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!.insertTimeRange(CMTimeRange(start: .zero, duration: CMTime(seconds: 2, preferredTimescale: 48000)), of: a, at: .zero)
            keep.append(aAsset)
        }
        _ = range; _ = keep
        let s = try XCTUnwrap(AVAssetExportSession(asset: comp, presetName: AVAssetExportPresetPassthrough))
        try await s.export(to: URL(fileURLWithPath: source), as: .mov)
    }
    /// Amplitude of `hz` in the first channel between 0.5 s and 1.5 s.
    func amplitude(_ url: URL, hz: Double) async throws -> Double {
        let a = AVURLAsset(url: url); let ts = try await a.loadTracks(withMediaType: .audio); let t = try XCTUnwrap(ts.first)
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 2, AVSampleRateKey: 48000])
        r.add(o); XCTAssertTrue(r.startReading(), "\(String(describing: r.error))"); var x: [Float] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d)
            x += stride(from: 0, to: d.count, by: 2).map { d[$0] }
        }
        XCTAssertNil(r.error); let w = Array(x[24000..<min(x.count, 72000)]); XCTAssertEqual(w.count, 48000, "steady window available")
        var re = 0.0, im = 0.0
        for (i, v) in w.enumerated() { let ph = 2 * Double.pi * hz * Double(i) / 48000; re += Double(v) * cos(ph); im += Double(v) * sin(ph) }
        return 2 * (re * re + im * im).squareRoot() / Double(w.count)
    }
    func export(_ p: SadrogProject) async throws -> (a440: Double, a1000: Double, dur: Double) {
        let u = URL(fileURLWithPath: Self.dir + "/two-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(p, to: u)
        return (try await amplitude(u, hz: 440), try await amplitude(u, hz: 1000), try await AVURLAsset(url: u).load(.duration).seconds)
    }
    func testBothTracksAtKnownAmplitudesWithMuteAndGain() async throws {
        try await Self.makeSource()
        var p = SadrogProject(name: "t", clips: [Clip(media: Self.source, sourceStart: 0, duration: 2)])
        let both = try await export(p)
        XCTAssertEqual(both.a440, 0.25, accuracy: 0.02); XCTAssertEqual(both.a1000, 0.10, accuracy: 0.015); XCTAssertEqual(both.dur, 2, accuracy: 0.1)
        p.mutedSources = [0]; let onlySecond = try await export(p)
        XCTAssertLessThan(onlySecond.a440, 0.005); XCTAssertEqual(onlySecond.a1000, 0.10, accuracy: 0.015)
        p.mutedSources = [1]; let onlyFirst = try await export(p)
        XCTAssertEqual(onlyFirst.a440, 0.25, accuracy: 0.02); XCTAssertLessThan(onlyFirst.a1000, 0.005)
        p.mutedSources = []; p.sourceGains = [1: -6.0206]; let gained = try await export(p)
        XCTAssertEqual(gained.a440, 0.25, accuracy: 0.02); XCTAssertEqual(gained.a1000, 0.05, accuracy: 0.01)
    }
}
