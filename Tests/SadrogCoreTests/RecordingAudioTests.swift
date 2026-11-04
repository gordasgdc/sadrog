// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Volume of every track in an audio mix (trackID → volume at time 0); empty when there is no mix.
func mixVolumes(_ m: AVAudioMix?) -> [CMPersistentTrackID: Float] {
    var out: [CMPersistentTrackID: Float] = [:]
    for ip in m?.inputParameters ?? [] { var v: Float = 1, e: Float = 1; var r = CMTimeRange(); _ = ip.getVolumeRamp(for: .zero, startVolume: &v, endVolume: &e, timeRange: &r); out[ip.trackID] = v }
    return out
}

/// Every audio track of a recording reaches the editor as its own source, named from sources.json, in sync, mutable on its own.
/// The C4/C5 probe recordings are read-only inputs (never written); tests that need them are skipped when the volume is absent.
final class RecordingAudioTests: XCTestCase {
    /// These expectations are the Romanian source texts; the interface language is pinned so the run does not depend on the Mac's language.
    override func setUp() { super.setUp(); UserDefaults.standard.set("ro", forKey: "sadrog.language") }
    override func tearDown() { UserDefaults.standard.removeObject(forKey: "sadrog.language"); super.tearDown() }
    static let probes = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/evidence/capture_probes"
    static let c5 = probes + "/C5/SADROG-6C7145EC-CD59-44A8-875E-758B8E931335/capture.mov"
    static let c4 = probes + "/C4/SADROG-5EA2BB6B-993F-4EE5-AB6C-E99D881E81ED/capture.mov"
    func need(_ p: String) throws { try XCTSkipUnless(FileManager.default.fileExists(atPath: p), "probe recording not available") }

    // names ---------------------------------------------------------------
    func track(_ i: Int, _ k: AudioSourceKind, _ n: String) -> SourcesManifest.Track {
        .init(index: i, id: "\(i)", kind: k, deviceName: n, deviceUID: nil, channels: [], firstSampleOffsetSeconds: nil)
    }
    func testNamesFollowManifestIndexNotArrayOrder() {
        let m = [track(1, .input, "MacBook Pro Microphone"), track(0, .system, "Sunetul calculatorului")]
        let s = RecordingAudio.sources(manifest: m, trackCount: 2)
        XCTAssertEqual(s.map(\.name), ["Sunetul calculatorului", "MacBook Pro Microphone"])
        XCTAssertEqual(s.map(\.kind), [.system, .input])
    }
    func testMissingManifestAndExtraTracksGetNumberedNames() {
        XCTAssertEqual(RecordingAudio.sources(manifest: nil, trackCount: 2).map(\.name), ["Pista audio 1", "Pista audio 2"])
        let s = RecordingAudio.sources(manifest: [track(0, .system, "Sunetul calculatorului")], trackCount: 2)
        XCTAssertEqual(s.map(\.name), ["Sunetul calculatorului", "Pista audio 2"])
        XCTAssertEqual(RecordingAudio.sources(manifest: [track(5, .input, "X")], trackCount: 1).map(\.name), ["Pista audio 1"])   // index outside the file: ignored
    }
    func testDuplicateNamesAreMadeDistinct() {
        let s = RecordingAudio.sources(manifest: [track(0, .input, "Mic"), track(1, .input, "Mic")], trackCount: 2)
        XCTAssertEqual(s.map(\.name), ["Mic · pista 1", "Mic · pista 2"])
    }
    func testReadsSourcesJsonNextToTheRecording() throws {
        try need(Self.c5)
        let s = RecordingAudio.sources(media: Self.c5, trackCount: 2)
        XCTAssertEqual(s.map(\.name), ["Sunetul calculatorului", "MacBook Pro Microphone"])
        let c4 = RecordingAudio.sources(media: Self.c4, trackCount: 8)
        XCTAssertEqual(c4.first?.name, "MixPre-6 II · canal 1"); XCTAssertEqual(c4.last?.name, "MixPre-6 II · canal 8")
    }

    // project model -------------------------------------------------------
    func testMutedSourcesRoundTripAndOldProjectsDecode() throws {
        let old = #"{"formatVersion":5,"name":"old","clips":[],"mutedLanes":["a2"]}"#
        let p = try JSONDecoder().decode(SadrogProject.self, from: Data(old.utf8))
        XCTAssertTrue(p.mutedSources.isEmpty); XCTAssertEqual(p.mutedLanes, [.a2])
        let e = ProjectEditor(project: p)
        e.setSourceMuted(1, true); XCTAssertEqual(e.project.mutedSources, [1])
        e.setSourceMuted(1, true); XCTAssertEqual(e.project.mutedSources, [1])
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(e.project))
        XCTAssertEqual(back.mutedSources, [1])
        e.undo(); XCTAssertTrue(e.project.mutedSources.isEmpty)
    }

    // composition ---------------------------------------------------------
    func testEveryTrackIsInTheCompositionInSyncAndSameLength() async throws {
        try need(Self.c4)
        let asset = AVURLAsset(url: URL(fileURLWithPath: Self.c4))
        let src = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(src.count, 8)
        let d = try await asset.load(.duration).seconds
        let p = SadrogProject(name: "t", clips: [Clip(media: Self.c4, sourceStart: 0, duration: d)])
        let b = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(b.mainAudio.count, 8)
        XCTAssertEqual(b.composition.duration.seconds, d, accuracy: 0.002)      // length unchanged by the extra tracks
        for k in 0..<8 {
            let t = try XCTUnwrap(b.mainAudio[k])
            let srcStart = try await src[k].load(.timeRange).start.seconds
            let first = try XCTUnwrap(t.segments.first { !$0.isEmpty })
            XCTAssertEqual(first.timeMapping.target.start.seconds, srcStart, accuracy: 0.001, "track \(k) shifted")
        }
    }
    func testCutClipKeepsEachTrackAlignedWithTheVideo() async throws {
        try need(Self.c5)
        // a cut in the middle of the recording: every audio track must take the same source range as the picture
        let p = SadrogProject(name: "t", clips: [Clip(media: Self.c5, sourceStart: 30, duration: 4), Clip(media: Self.c5, sourceStart: 60, duration: 3)])
        let b = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(b.mainAudio.count, 2)
        for k in 0..<2 {
            let segs = try XCTUnwrap(b.mainAudio[k]).segments.filter { !$0.isEmpty }
            XCTAssertEqual(segs.count, 2)
            XCTAssertEqual(segs[0].timeMapping.source.start.seconds, 30, accuracy: 0.001); XCTAssertEqual(segs[0].timeMapping.target.start.seconds, 0, accuracy: 0.001)
            XCTAssertEqual(segs[1].timeMapping.source.start.seconds, 60, accuracy: 0.001); XCTAssertEqual(segs[1].timeMapping.target.start.seconds, 4, accuracy: 0.001)
        }
    }
    func testMixMutesOnlyTheChosenSource() async throws {
        try need(Self.c5)
        var p = SadrogProject(name: "t", clips: [Clip(media: Self.c5, sourceStart: 0, duration: 5)])
        let b = try await CompositionBuilder.buildFull(p)
        let t0 = b.mainAudio[0]!.trackID, t1 = b.mainAudio[1]!.trackID
        XCTAssertEqual(mixVolumes(b.audioMix(for: p)), [t0: 1, t1: 1])         // two sources: always an explicit mix (one mixed track on export)
        p.mutedSources = [1]
        XCTAssertEqual(mixVolumes(b.audioMix(for: p)), [t0: 1, t1: 0])
        p.mutedLanes = [.a1]                                                     // the lane switch still silences every source
        XCTAssertEqual(mixVolumes(b.audioMix(for: p)), [t0: 0, t1: 0])
    }
    /// Exports with the app's DEFAULT quality (HighestQuality): what you hear in the preview must be ONE mixed track in the file, with or without mutes.
    /// The microphone is detected in the gaps between the system beeps (there the system track is digital silence). Measured on the files, not listened to.
    func testExportIsOneMixedTrackAndRespectsSourceMute() async throws {
        try need(Self.c5)
        func samples(_ url: URL) async throws -> [Float] {
            let a = AVURLAsset(url: url); let ts = try await a.loadTracks(withMediaType: .audio)
            XCTAssertEqual(ts.count, 1, "export must contain ONE mixed audio track (\(url.lastPathComponent))"); let t = try XCTUnwrap(ts.first)
            let r = try AVAssetReader(asset: a); let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000])
            r.add(o); r.startReading(); var x: [Float] = []
            while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d); x += d
            }
            return x
        }
        func db(_ x: ArraySlice<Float>) -> Double { 10 * log10(x.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(1, x.count)) + 1e-24) }
        let dir = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp"
        var p = SadrogProject(name: "t", clips: [Clip(media: Self.c5, sourceStart: 10, duration: 4)])
        func export(_ muted: Set<Int>, _ mode: ExportMode = .reencode(preset: AVAssetExportPresetHighestQuality)) async throws -> [Float] {
            p.mutedSources = muted
            let u = URL(fileURLWithPath: "\(dir)/ra-\(UUID().uuidString).mov"); defer { try? FileManager.default.removeItem(at: u) }
            try await ProjectExporter.export(p, to: u, mode: mode); return try await samples(u)
        }
        let all = try await export([]), sys = try await export([1]), mic = try await export([0]), none = try await export([0, 1])
        let w = 4800, n = min(all.count, sys.count)
        let gaps = stride(from: 0, to: n - w, by: w).filter { db(sys[$0..<$0 + w]) < -90 }      // system silent here
        XCTAssertGreaterThan(gaps.count, 10)
        let micInAll = gaps.map { db(all[$0..<$0 + w]) }.reduce(0, +) / Double(gaps.count)
        let micAlone = gaps.map { db(mic[$0..<$0 + w]) }.reduce(0, +) / Double(gaps.count)
        XCTAssertGreaterThan(micInAll, -75, "microphone missing from the unmuted export")
        XCTAssertEqual(micInAll, micAlone, accuracy: 3, "the mix must carry the microphone at its own level")
        XCTAssertGreaterThan(db(sys[0..<n]), db(mic[0..<n]) + 6)                                     // system muted → much quieter (beeps gone)
        XCTAssertLessThan(db(none[...]), -100)
        // "fast" export cannot mix or mute: it must fall back to re-encoding instead of copying separate or muted tracks
        let fast = try await export([0, 1], .passthrough); XCTAssertLessThan(db(fast[...]), -100)
        let fastAll = try await export([], .passthrough); XCTAssertEqual(fastAll.count, all.count, accuracy: 4800)
    }
}
