// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// A2 volume/mute and fades on A1/A2, through the one shared audio mix. Synthetic constant tone (no capture); levels are MEASURED on exports
/// (decoded to float), not listened to.
final class AudioEditTests: XCTestCase {
    static let dir = "\(TestRoot.path)/synthetic/audioedit"
    static var tone: String { dir + "/tone_440_4s.caf" }
    var blue: String { CompositionTests.dir + "/blue.mov" }

    /// 4 s, 440 Hz sine at 0.25 amplitude (−12 dBFS peak), stereo 48 kHz — written once, reused.
    static func makeTone() throws {
        guard !FileManager.default.fileExists(atPath: tone) else { return }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let n = AVAudioFrameCount(48000 * 4), buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n)!; buf.frameLength = n
        for ch in 0..<2 { for i in 0..<Int(n) { buf.floatChannelData![ch][i] = Float(0.25 * sin(2 * .pi * 440 * Double(i) / 48000)) } }
        let f = try AVAudioFile(forWriting: URL(fileURLWithPath: tone), settings: fmt.settings); try f.write(from: buf)
    }
    /// RMS (dBFS) of the first channel in windows of `win` seconds.
    func envelope(_ url: URL, win: Double = 0.05) async throws -> [Double] {
        let a = AVURLAsset(url: url); let ts = try await a.loadTracks(withMediaType: .audio); let t = try XCTUnwrap(ts.first)
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000])
        r.add(o); r.startReading(); var x: [Float] = []; var ch = 2
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            if let d = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(d) { ch = Int(asbd.pointee.mChannelsPerFrame) }
            let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d)
            x += stride(from: 0, to: d.count, by: ch).map { d[$0] }
        }
        let w = Int(48000 * win)
        return stride(from: 0, to: x.count - w, by: w).map { i in 10 * log10(x[i..<i + w].reduce(0.0) { $0 + Double($1 * $1) } / Double(w) + 1e-24) }
    }
    func export(_ p: SadrogProject) async throws -> [Double] {
        let u = URL(fileURLWithPath: "\(TestRoot.path)/temp/ae-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: u) }
        try await ProjectExporter.export(p, to: u); return try await envelope(u)
    }
    func project(_ e: AudioEdit?) -> SadrogProject {
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 4)])
        var l = Layer(kind: .audio, media: Self.tone, start: 0, duration: 4); l.audio = e; p.layers = [l]; return p
    }

    func testModelRulesUndoPersistenceLegacy() throws {
        // legacy layer without "audio" decodes to neutral
        let json = #"{"formatVersion":8,"name":"o","clips":[],"layers":[{"id":"1836A1A2-E44E-455B-BBFF-ACA2019A18CD","kind":"audio","media":"/x.m4a","start":0,"sourceStart":0,"duration":5,"transform":{"x":0,"y":0,"scale":1,"opacity":1,"rotation":0}}]}"#
        let p = try JSONDecoder().decode(SadrogProject.self, from: Data(json.utf8)); XCTAssertNil(p.layers[0].audio)
        let e = ProjectEditor(project: p), id = p.layers[0].id
        e.setAudio(id, AudioEdit(gainDB: -6, fadeIn: 1.234, fadeOut: 9)); XCTAssertEqual(e.project.layers[0].audio, AudioEdit(gainDB: -6, fadeIn: 1.23, fadeOut: 5))
        e.setAudio(id, AudioEdit()); XCTAssertNil(e.project.layers[0].audio, "neutral removes the key")
        e.undo(); XCTAssertEqual(e.project.layers[0].audio?.gainDB, -6)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project)); XCTAssertEqual(back.layers[0].audio?.fadeIn, 1.23)
        // fades meeting after a trim: scaled in proportion, stored values kept
        XCTAssertEqual(AudioEdit(fadeIn: 3, fadeOut: 1).effectiveFades(duration: 2).fadeIn, 1.5, accuracy: 1e-9)
        XCTAssertEqual(AudioEdit(fadeIn: 3, fadeOut: 1).effectiveFades(duration: 2).fadeOut, 0.5, accuracy: 1e-9)
        XCTAssertEqual(AudioEdit(fadeIn: 1, fadeOut: 1).effectiveFades(duration: 4).fadeIn, 1)
        // split: fade-in stays left, fade-out stays right, nothing at the cut
        e.setAudio(id, AudioEdit(fadeIn: 1, fadeOut: 1)); e.splitLayer(kind: .audio, at: 2.5)
        XCTAssertEqual(e.project.layers.map { $0.audio?.fadeIn ?? 0 }, [1, 0]); XCTAssertEqual(e.project.layers.map { $0.audio?.fadeOut ?? 0 }, [0, 1])
        var q = SadrogProject(name: "c", clips: [Clip(media: "/v.mov", sourceStart: 0, duration: 6)]); q.clips[0].audio = AudioEdit(fadeIn: 0.5, fadeOut: 0.5)
        let ec = ProjectEditor(project: q); ec.split(at: 3)
        XCTAssertEqual(ec.project.clips.map { $0.audio?.fadeIn ?? 0 }, [0.5, 0]); XCTAssertEqual(ec.project.clips.map { $0.audio?.fadeOut ?? 0 }, [0, 0.5])
    }
    func testA2LevelMuteAndFadesInExport() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue), "synthetic clips not available"); try Self.makeTone()
        let base = try await export(project(nil))
        let mid = { (e: [Double]) in e[30..<50].reduce(0, +) / 20 }                     // 1.5–2.5 s
        let g6 = try await export(project(AudioEdit(gainDB: -6)))
        print(String(format: "A2 0 dB mid %.2f | −6 dB mid %.2f", mid(base), mid(g6)))
        XCTAssertEqual(mid(g6) - mid(base), -6, accuracy: 0.3)
        let muted = try await export(project(AudioEdit(muted: true))); XCTAssertLessThan(mid(muted), -100)
        let f = try await export(project(AudioEdit(fadeIn: 1, fadeOut: 1)))
        // window k covers [k·0.05, (k+1)·0.05): ramp 0→1 over the first second, 1→0 over the last
        print(String(format: "fade: 0.05 s %.1f | 0.5 s %.1f | 1.0 s %.1f | 2 s %.1f | 3.5 s %.1f | 3.95 s %.1f (ref %.1f)", f[1], f[10], f[20], f[40], f[70], f[78], mid(base)))
        XCTAssertLessThan(f[0], mid(base) - 20, "starts from silence")
        XCTAssertEqual(f[10], mid(base) + 20 * log10(0.525), accuracy: 1.0, "half way up at 0.5 s (linear ramp)")
        XCTAssertEqual(f[40], mid(base), accuracy: 0.3, "full level between the fades")
        XCTAssertEqual(f[70], mid(base) + 20 * log10(0.475), accuracy: 1.0, "half way down at 3.5 s")
        XCTAssertLessThan(f[78], mid(base) - 20, "ends in silence")
    }
    func testFadesAfterTrimAndOnMainClip() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue), "synthetic clips not available"); try Self.makeTone()
        // trimmed to 1 s with 1 s + 1 s fades → effective 0.5 + 0.5 (meet in the middle, no overlap)
        var p = project(AudioEdit(fadeIn: 1, fadeOut: 1)); p.layers[0].duration = 1
        let b = try await CompositionBuilder.buildFull(p)
        let ip = try XCTUnwrap(b.audioMix(for: p)?.inputParameters.first)
        var s: Float = 0, e: Float = 0, r = CMTimeRange()
        XCTAssertTrue(ip.getVolumeRamp(for: CMTime(seconds: 0.25, preferredTimescale: 48000), startVolume: &s, endVolume: &e, timeRange: &r))
        XCTAssertEqual(r.duration.seconds, 0.5, accuracy: 1e-3); XCTAssertEqual(s, 0); XCTAssertEqual(e, 1)
        XCTAssertTrue(ip.getVolumeRamp(for: CMTime(seconds: 0.75, preferredTimescale: 48000), startVolume: &s, endVolume: &e, timeRange: &r))
        XCTAssertEqual(r.start.seconds, 0.5, accuracy: 1e-3); XCTAssertEqual(s, 1); XCTAssertEqual(e, 0)
        // A1: the fades of a main clip apply to every source of the recording, at that source's gain
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5 not available")
        var q = SadrogProject(name: "c", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 10, duration: 3), Clip(media: RecordingAudioTests.c5, sourceStart: 20, duration: 3)])
        q.clips[1].audio = AudioEdit(fadeIn: 0.5); q.sourceGains = [0: -6.0206]
        let bq = try await CompositionBuilder.buildFull(q)
        let p0 = try XCTUnwrap(bq.audioMix(for: q)?.inputParameters.first { $0.trackID == bq.mainAudio[0]!.trackID })
        XCTAssertTrue(p0.getVolumeRamp(for: CMTime(seconds: 3.2, preferredTimescale: 48000), startVolume: &s, endVolume: &e, timeRange: &r))
        XCTAssertEqual(r.start.seconds, 3, accuracy: 1e-3); XCTAssertEqual(e, 0.5, accuracy: 1e-3)
        XCTAssertTrue(p0.getVolumeRamp(for: CMTime(seconds: 1, preferredTimescale: 48000), startVolume: &s, endVolume: &e, timeRange: &r))
        XCTAssertEqual(s, 0.5, accuracy: 1e-3, "first clip: no fade, source gain only")
    }
}
