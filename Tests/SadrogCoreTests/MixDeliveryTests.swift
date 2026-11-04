// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Master volume and audio delivery (full mix + stems). Synthetic tone + copy-free reads of C5; levels and timing MEASURED, not listened to.
final class MixDeliveryTests: XCTestCase {
    let out = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/delivery-\(UUID().uuidString)")
    override func setUp() async throws { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true); try AudioEditTests.makeTone() }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: out) }

    func samples(_ url: URL) async throws -> (x: [Float], dur: Double) {
        let a = AVURLAsset(url: url); let d = try await a.load(.duration).seconds
        let ts = try await a.loadTracks(withMediaType: .audio); let t = try XCTUnwrap(ts.first)
        let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVSampleRateKey: 48000])
        r.add(o); r.startReading(); var x: [Float] = []; var ch = 2
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            if let f = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(f) { ch = Int(asbd.pointee.mChannelsPerFrame) }
            let len = CMBlockBufferGetDataLength(bb); var v = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &v)
            x += stride(from: 0, to: v.count, by: ch).map { v[$0] }
        }
        return (x, d)
    }
    func rms(_ x: ArraySlice<Float>) -> Double { 10 * log10(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, x.count)) + 1e-24) }

    func testMasterModelUndoPersistAndMix() async throws {
        let e = ProjectEditor(project: SadrogProject(name: "m"))
        e.setMasterGain(-3.04); XCTAssertEqual(e.project.masterGainDB, -3.0); e.setMasterGain(0); e.undo(); XCTAssertEqual(e.project.masterGainDB, -3.0)
        XCTAssertEqual(try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project)).masterGainDB, -3.0)
        XCTAssertEqual(try JSONDecoder().decode(SadrogProject.self, from: Data(#"{"formatVersion":9,"name":"o","clips":[]}"#.utf8)).masterGainDB, 0)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5")
        var p = SadrogProject(name: "t", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 0, duration: 3)]); p.sourceGains = [0: -6.0206]; p.masterGainDB = -6.0206
        let b = try await CompositionBuilder.buildFull(p)
        let v = mixVolumes(b.audioMix(for: p)), t0 = b.mainAudio[0]!.trackID, t1 = b.mainAudio[1]!.trackID
        XCTAssertEqual(v[t0]!, 0.25, accuracy: 1e-3, "source × master"); XCTAssertEqual(v[t1]!, 0.5, accuracy: 1e-3)
        let st = mixVolumes(b.audioMix(for: p, selection: .source(0)))
        XCTAssertEqual(st[t0]!, 0.5, accuracy: 1e-3, "stem: source volume, no master"); XCTAssertEqual(st[t1], 0)
    }
    /// A1 = synthetic tone clip? No: A1 needs video; use the blue clip (silent) + tone on A2 starting at 1 s, document 6 s long (title past the end).
    func testDeliveryAlignmentDurationLevelsAndNoOverwrite() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5")
        var p = SadrogProject(name: "Livrare", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 10, duration: 5)])
        var l = Layer(kind: .audio, media: AudioEditTests.tone, start: 1, duration: 3); l.audio = AudioEdit(gainDB: -6, fadeIn: 0.5); p.layers = [l]
        p.texts = [TextOverlay(text: "x", start: 0, duration: 6)]                 // document 6 s: files must cover it all
        p.mutedSources = [1]; p.masterGainDB = -6
        let srcs = RecordingAudio.sources(media: RecordingAudioTests.c5, trackCount: 2)
        let items = AudioDelivery.plan(p, sources: srcs, baseName: "Livrare")
        XCTAssertEqual(items.map(\.fileName), ["Livrare - mix.m4a", "Livrare - A1-1 Sunetul calculatorului.m4a", "Livrare - A2.m4a"], "muted microphone left out")
        let urls = try await AudioDelivery.export(p, items: items, to: out)
        var files: [(x: [Float], dur: Double)] = []
        for u in urls { files.append(try await samples(u)) }
        print("DELIVERY eșantioane:", files.map { $0.x.count }, "durate:", files.map(\.dur))
        guard files.allSatisfy({ $0.x.count >= Int(5.9 * 48000) }) else { return XCTFail("fișiere mai scurte decât documentul: \(files.map { Double($0.x.count) / 48000 })") }
        for (u, f) in zip(urls, files) { XCTAssertEqual(f.dur, 6, accuracy: 0.05, "\(u.lastPathComponent) covers the document") }
        let a2 = files[2].x, w = 2400
        print("DELIVERY A2 0.8–1.7 s:", stride(from: Int(0.8 * 48000), to: Int(1.7 * 48000), by: w).map { String(format: "%.1f", rms(a2[$0..<$0 + w])) }.joined(separator: " "))
        XCTAssertLessThan(rms(a2[0..<Int(0.9 * 48000)]), -90, "A2 stem silent before its start (alignment)")
        let toneRef = 20 * log10(0.25 / sqrt(2.0))
        XCTAssertEqual(rms(a2[Int(2.0 * 48000)..<Int(3.5 * 48000)]), toneRef - 6, accuracy: 0.3, "A2 stem: own −6 dB, no master")
        XCTAssertLessThan(rms(a2[Int(1.0 * 48000)..<Int(1.0 * 48000) + w]), toneRef - 15, "fade-in starts from silence at 1 s")
        XCTAssertLessThan(rms(a2[Int(4.2 * 48000)..<Int(5.8 * 48000)]), -90, "silence after the item")
        // the full mix = (system source + A2) × master: in a window where the system track is silent, the tone is 6 dB lower than in the stem
        let sys = files[1].x
        let quiet = stride(from: Int(2.0 * 48000), to: Int(3.5 * 48000) - w, by: w).filter { rms(sys[$0..<$0 + w]) < -80 }
        XCTAssertFalse(quiet.isEmpty)
        let mixQ = quiet.map { rms(files[0].x[$0..<$0 + w]) }.reduce(0, +) / Double(quiet.count), stQ = quiet.map { rms(a2[$0..<$0 + w]) }.reduce(0, +) / Double(quiet.count)
        print(String(format: "DELIVERY durate %@ | A2 stem %.2f dB | mix în aceleași ferestre %.2f dB", files.map { String(format: "%.3f", $0.dur) }.joined(separator: "/"), stQ, mixQ))
        XCTAssertEqual(mixQ - stQ, -6, accuracy: 0.3, "master −6 dB on the mix only")
        // second run: nothing overwritten
        do { _ = try await AudioDelivery.export(p, items: items, to: out); XCTFail("must refuse") }
        catch AudioDelivery.DeliveryError.exists(let n) { XCTAssertEqual(n.count, 3) }
    }
    func testCancelLeavesNoFiles() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: RecordingAudioTests.c5), "C5")
        let p = SadrogProject(name: "C", clips: [Clip(media: RecordingAudioTests.c5, sourceStart: 0, duration: 60)])
        let items = AudioDelivery.plan(p, sources: RecordingAudio.sources(media: RecordingAudioTests.c5, trackCount: 2), baseName: "C")
        let task = Task { try await AudioDelivery.export(p, items: items, to: out) }
        try await Task.sleep(nanoseconds: 300_000_000); task.cancel()
        do { _ = try await task.value; XCTFail("should be cancelled") } catch {}
        let left = try FileManager.default.contentsOfDirectory(atPath: out.path)
        XCTAssertEqual(left, [], "no partial set left: \(left)")
    }
}
