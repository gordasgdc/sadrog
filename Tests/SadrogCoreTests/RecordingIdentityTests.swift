// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Sound settings belong to a RECORDING (its media path + track index in that file), never to "source 0" of the project.
final class RecordingIdentityTests: XCTestCase {
    private let a = "/rec/A.mov", b = "/rec/B.mov"
    private func project() -> SadrogProject {
        SadrogProject(name: "t", clips: [Clip(media: a, sourceStart: 0, duration: 4), Clip(media: b, sourceStart: 0, duration: 4)])
    }

    func testSettingsStayOnTheirRecording() {
        let ed = ProjectEditor(project: project())
        ed.setSourceGain(0, dB: -6, media: a); ed.setSourceMuted(1, true, media: b); ed.setSourceGain(0, dB: 3, media: b)
        XCTAssertEqual(ed.project.gain(ofSource: 0, media: a), -6); XCTAssertEqual(ed.project.gain(ofSource: 0, media: b), 3)
        XCTAssertTrue(ed.project.isMuted(source: 1, media: b)); XCTAssertFalse(ed.project.isMuted(source: 1, media: a))
        XCTAssertFalse(ed.project.isMuted(source: 0, media: a), "source 0 of A is not muted because source 1 of B is")
        ed.undo(); ed.undo(); ed.undo()
        XCTAssertTrue(ed.project.recordings.isEmpty)
    }

    func testReorderAndCopyKeepTheAssociation() {
        let ed = ProjectEditor(project: project())
        ed.setSourceGain(0, dB: -9, media: b)
        let ids = ed.project.clips.map(\.id)
        ed.move(clip: ids[1], toIndex: 0)                           // B now first on the timeline
        XCTAssertEqual(ed.project.gain(ofSource: 0, media: b), -9)
        XCTAssertEqual(ed.project.gain(ofSource: 0, media: a), 0)
        XCTAssertEqual(ed.project.primaryMedia, b)
    }

    func testReopenKeepsRecordingsAndLegacyFilesSplitToEveryRecording() throws {
        let ed = ProjectEditor(project: project())
        ed.setSourceGain(1, dB: -3, media: a); ed.setSourceMuted(0, true, media: b)
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(ed.project))
        XCTAssertEqual(back.recordings, ed.project.recordings); XCTAssertGreaterThanOrEqual(back.formatVersion, 16)
        // a format-15 file has one set for the project: both of its recordings played with it, so both receive it
        let id = UUID().uuidString, id2 = UUID().uuidString
        let old = #"{"formatVersion":15,"name":"o","clips":[{"id":"\#(id)","media":"/rec/A.mov","sourceStart":0,"duration":4},{"id":"\#(id2)","media":"/rec/B.mov","sourceStart":0,"duration":4}],"mutedSources":[1],"sourceGains":{"0":-6}}"#
        let p = try JSONDecoder().decode(SadrogProject.self, from: Data(old.utf8))
        for m in [a, b] { XCTAssertEqual(p.gain(ofSource: 0, media: m), -6); XCTAssertTrue(p.isMuted(source: 1, media: m)) }
    }

    func testMixLevelsFollowTheClipsRecording() async throws {
        // two recordings with DIFFERENT channel order (A: loud,quiet; B: quiet,loud); A gets track 0 at -6 dB, B gets track 0 muted
        let ua = try await SyntheticRecording.make(amplitudes: [0.8, 0.2]), ub = try await SyntheticRecording.make(amplitudes: [0.2, 0.8])
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        var p = SadrogProject(name: "t", clips: [Clip(media: ua.path, sourceStart: 0, duration: 2), Clip(media: ub.path, sourceStart: 0, duration: 2)])
        p.recordings[ua.path] = RecordingSounds(gains: [0: -6.0206]); p.recordings[ub.path] = RecordingSounds(muted: [0])
        let built = try await CompositionBuilder.buildFull(p)
        let mix = built.audioMix(for: p), t0 = built.mainAudio[0]!.trackID, t1 = built.mainAudio[1]!.trackID
        XCTAssertEqual(Double(SyntheticRecording.volume(mix, track: t0, at: 1)), 0.5, accuracy: 0.01, "clip A, source 0")
        XCTAssertEqual(SyntheticRecording.volume(mix, track: t0, at: 3), 0, "clip B, source 0 is muted")
        XCTAssertEqual(SyntheticRecording.volume(mix, track: t1, at: 1), 1, "A source 1 untouched"); XCTAssertEqual(SyntheticRecording.volume(mix, track: t1, at: 3), 1, "B source 1 untouched")
    }

    func testStemOfOneRecordingSilencesTheOther() async throws {
        let ua = try await SyntheticRecording.make(amplitudes: [0.5, 0.5]), ub = try await SyntheticRecording.make(amplitudes: [0.5, 0.5])
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        let p = SadrogProject(name: "t", clips: [Clip(media: ua.path, sourceStart: 0, duration: 2), Clip(media: ub.path, sourceStart: 0, duration: 2)])
        let built = try await CompositionBuilder.buildFull(p)
        let mix = built.audioMix(for: p, selection: .recording(ub.path, 0)), t0 = built.mainAudio[0]!.trackID, t1 = built.mainAudio[1]!.trackID
        XCTAssertEqual(SyntheticRecording.volume(mix, track: t0, at: 1), 0); XCTAssertEqual(SyntheticRecording.volume(mix, track: t0, at: 3), 1)
        XCTAssertEqual(SyntheticRecording.volume(mix, track: t1, at: 3), 0, "other source of B is silent in this stem")
    }

    func testDetachedAudioKeepsItsRecordingsSettings() async throws {
        let ua = try await SyntheticRecording.make(amplitudes: [0.5, 0.5]), ub = try await SyntheticRecording.make(amplitudes: [0.5, 0.5])
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub) }
        var p = SadrogProject(name: "t", clips: [Clip(media: ua.path, sourceStart: 0, duration: 2), Clip(media: ub.path, sourceStart: 0, duration: 2)])
        p.recordings[ub.path] = RecordingSounds(muted: [0])
        let ed = ProjectEditor(project: p)
        let ids = ed.project.clips.map(\.id)
        ed.detachAudio(of: ids[1])
        let built = try await CompositionBuilder.buildFull(ed.project)
        let mix = built.audioMix(for: ed.project)
        let l = try XCTUnwrap(ed.project.layers.first { $0.kind == .audio }), tracks = try XCTUnwrap(built.layerAudio[l.id])
        XCTAssertEqual(l.media, ub.path)
        XCTAssertEqual(SyntheticRecording.volume(mix, track: tracks[0].trackID, at: 3), 0, "detached source 0 of B stays muted")
        XCTAssertEqual(SyntheticRecording.volume(mix, track: tracks[1].trackID, at: 3), 1)
    }

    func testDeliveryPlanNamesEachRecordingsStems() {
        var p = project(); p.recordings[b] = RecordingSounds(muted: [1])
        let rec = [AudioDelivery.Recording(media: a, title: "A", sources: [AudioSourceInfo(index: 0, name: "Mic", kind: nil), AudioSourceInfo(index: 1, name: "Sys", kind: nil)]),
                   AudioDelivery.Recording(media: b, title: "B", sources: [AudioSourceInfo(index: 0, name: "Mic", kind: nil), AudioSourceInfo(index: 1, name: "Sys", kind: nil)])]
        let items = AudioDelivery.plan(p, recordings: rec, baseName: "x")
        XCTAssertEqual(items.count, 4, "mix + A:0 + A:1 + B:0 (B:1 is muted)")
        XCTAssertEqual(Set(items.map(\.fileName)).count, 4, "file names are distinct across recordings")
        XCTAssertTrue(items.contains { $0.selection == .recording(b, 0) }); XCTAssertFalse(items.contains { $0.selection == .recording(b, 1) })
    }

    /// Real stems from two recordings with different channel order: each stem carries its OWN recording's track, measured on the files.
    func testExportedStemsCarryTheirOwnRecordingsChannel() async throws {
        let ua = try await SyntheticRecording.make(amplitudes: [0.8, 0.2]), ub = try await SyntheticRecording.make(amplitudes: [0.2, 0.8])
        let out = URL(fileURLWithPath: "\(SyntheticRecording.root)/idstems-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: ua); try? FileManager.default.removeItem(at: ub); try? FileManager.default.removeItem(at: out) }
        var p = SadrogProject(name: "t", clips: [Clip(media: ua.path, sourceStart: 0, duration: 2), Clip(media: ub.path, sourceStart: 0, duration: 2)])
        p.recordings[ub.path] = RecordingSounds(gains: [1: -6.0206])                       // B's loud channel at half
        let src = [AudioSourceInfo(index: 0, name: "S0", kind: nil), AudioSourceInfo(index: 1, name: "S1", kind: nil)]
        let items = AudioDelivery.plan(p, recordings: [.init(media: ua.path, title: "A", sources: src), .init(media: ub.path, title: "B", sources: src)], baseName: "x")
        let urls = try await AudioDelivery.export(p, items: items, to: out)
        func rms(_ u: URL, from: Double, to: Double) async throws -> Double {
            let a = AVURLAsset(url: u), ts = try await a.loadTracks(withMediaType: .audio), t = try XCTUnwrap(ts.first)
            let r = try AVAssetReader(asset: a); r.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 6000), duration: CMTime(seconds: to - from, preferredTimescale: 6000))
            let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false])
            r.add(o); r.startReading(); var s = 0.0, n = 0
            while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                let len = CMBlockBufferGetDataLength(bb); var d = [Float](repeating: 0, count: len / 4); CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &d)
                for v in d { s += Double(v * v) }; n += d.count
            }
            return (s / Double(max(n, 1))).squareRoot()
        }
        func url(_ tag: String) throws -> URL { try XCTUnwrap(urls.first { $0.lastPathComponent.contains(tag) }) }
        let a0 = try await rms(try url("A1-R1-1"), from: 0.2, to: 1.8), a0b = try await rms(try url("A1-R1-1"), from: 2.2, to: 3.8)
        let b1 = try await rms(try url("A1-R2-2"), from: 2.2, to: 3.8), b1a = try await rms(try url("A1-R2-2"), from: 0.2, to: 1.8)
        // levels are compared with each other (the m4a encode and the mono→stereo placement scale all of them alike)
        XCTAssertGreaterThan(a0, 0.05, "A's stem has A's source 1")
        XCTAssertLessThan(a0b, a0 * 0.05, "B's part is silent in A's stem"); XCTAssertLessThan(b1a, b1 * 0.05, "A's part is silent in B's stem")
        XCTAssertEqual(b1 / a0, 0.5, accuracy: 0.05, "B's 0.8 tone at -6 dB against A's 0.8 tone at 0 dB")
    }
}

/// Sound settings are keyed by media path: every place that rewrites a media path must carry them along, or they silently go neutral.
final class RecordingKeyFollowsMediaTests: XCTestCase {
    private func project() -> SadrogProject {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a/old.mov", sourceStart: 0, duration: 2)])
        p.recordings["/a/old.mov"] = RecordingSounds(muted: [1], gains: [0: -6], effects: [:])
        return p
    }
    func testRelinkCarriesSoundSettings() {
        let e = ProjectEditor(project: project()); e.relinkMedia(from: "/a/old.mov", to: "/b/new.mov")
        XCTAssertEqual(e.project.recording("/b/new.mov").gains[0], -6); XCTAssertTrue(e.project.isMuted(source: 1, media: "/b/new.mov"))
        XCTAssertNil(e.project.recordings["/a/old.mov"])
    }
    func testMapMediaCarriesSoundSettings() {
        var p = project(); p.mapMedia { $0.replacingOccurrences(of: "/a/", with: "Media/01/") }
        XCTAssertEqual(p.recording("Media/01/old.mov").gains[0], -6); XCTAssertNil(p.recordings["/a/old.mov"])
    }
}
