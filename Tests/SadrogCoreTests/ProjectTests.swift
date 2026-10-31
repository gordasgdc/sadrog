import XCTest
import AVFoundation
@testable import SadrogCore

final class ProjectTests: XCTestCase {
    func proj() -> SadrogProject { SadrogProject(name: "t", clips: [Clip(media: "/x/a.mov", sourceStart: 0, duration: 10)]) }

    func testSplitDeleteUndoRedo() {
        let e = ProjectEditor(project: proj())
        e.split(at: 4)
        XCTAssertEqual(e.project.clips.map(\.duration), [4, 6])
        XCTAssertEqual(e.project.clips[1].sourceStart, 4)
        e.delete(clip: e.project.clips[0].id)
        XCTAssertEqual(e.project.duration, 6)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.duration, 10)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.clips.count, 1)
        XCTAssertFalse(e.undo())
        XCTAssertTrue(e.redo()); XCTAssertTrue(e.redo()); XCTAssertEqual(e.project.duration, 6)
        e.split(at: 1); XCTAssertFalse(e.canRedo, "new edit clears redo")
    }
    func testSplitTooCloseToEdgeIgnored() {
        let e = ProjectEditor(project: proj()); e.split(at: 0.01); e.split(at: 9.99); e.split(at: 11)
        XCTAssertEqual(e.project.clips.count, 1); XCTAssertFalse(e.canUndo)
    }
    func testTrimBounds() {
        let e = ProjectEditor(project: proj()); let id = e.project.clips[0].id
        e.trimStart(clip: id, by: 2); e.trimEnd(clip: id, by: 3)
        XCTAssertEqual(e.project.clips[0].sourceStart, 2); XCTAssertEqual(e.project.clips[0].duration, 5)
        e.trimStart(clip: id, by: 100); XCTAssertGreaterThanOrEqual(e.project.clips[0].duration, ProjectEditor.minClip - 1e-9)
        e.trimStart(clip: id, by: -100); XCTAssertEqual(e.project.clips[0].sourceStart, 0)
    }
    func testMoveReorders() {
        let e = ProjectEditor(project: proj()); e.split(at: 3); let first = e.project.clips[0].id
        e.move(clip: first, toIndex: 1); XCTAssertEqual(e.project.clips[1].id, first)
    }
    func testSaveLoadAndVersionGuard() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("p-\(UUID()).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        let p = proj(); try ProjectStore.save(p, to: f)
        XCTAssertEqual(try ProjectStore.load(from: f), p)
        XCTAssertEqual(ProjectStore.missingMedia(p), ["/x/a.mov"])
        var future = p; future.formatVersion = 99; try ProjectStore.save(future, to: f)
        XCTAssertThrowsError(try ProjectStore.load(from: f)) { XCTAssertEqual($0 as? ProjectStoreError, .unsupportedFormat(99)) }
    }

    /// Full slice on synthetic media: record -> project -> split/delete -> save/reload -> export -> check duration.
    func testCompositionAndExportOfSyntheticRecording() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-e-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: root) }
        let w = try RecordingWriter(destination: Destination(url: root), settings: RecordingSettings(width: 640, height: 360, fps: 30, withAudio: false))
        let rw = RecordingWriterTests()
        for i in 0..<90 {
            let before = w.counters.videoWritten; var tries = 0
            while w.counters.videoWritten == before && tries < 2000 { w.appendVideo(rw.makeFrame(i, w: 640, h: 360)); tries += 1; if w.counters.videoWritten == before { try await Task.sleep(nanoseconds: 2_000_000) } }
        }
        try await w.finish()
        let d = try await AVURLAsset(url: w.mediaURL).load(.duration).seconds
        XCTAssertEqual(d, 3.0, accuracy: 0.1)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: w.mediaURL.path, sourceStart: 0, duration: d)]))
        e.split(at: 1.0); e.delete(clip: e.project.clips[0].id)
        let pf = root.appendingPathComponent("p.sadrogproj"); try ProjectStore.save(e.project, to: pf)
        let reloaded = try ProjectStore.load(from: pf)
        XCTAssertEqual(reloaded.duration, d - 1.0, accuracy: 0.01)
        let comp = try await CompositionBuilder.build(reloaded)
        XCTAssertEqual(comp.duration.seconds, d - 1.0, accuracy: 0.05)
        let out = root.appendingPathComponent("out.mov")
        try await ProjectExporter.export(reloaded, to: out, mode: .passthrough) // synthetic frames lack colour metadata; re-encode is covered by the real-media test
        let od = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(od, d - 1.0, accuracy: 0.1)
        let vt = try await AVURLAsset(url: out).loadTracks(withMediaType: .video)
        XCTAssertEqual(vt.count, 1)
    }
}

/// Optional, uses a real SCK recording: SADROG_REAL_MEDIA=/path/capture.mov
final class RealMediaExportTests: XCTestCase {
    func testReencodeRealRecording() async throws {
        guard let path = ProcessInfo.processInfo.environment["SADROG_REAL_MEDIA"] else { throw XCTSkip("no real media") }
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["SADROG_OUT"]!)
        try? FileManager.default.removeItem(at: out)
        let p = SadrogProject(name: "r", clips: [Clip(media: path, sourceStart: 2, duration: 5)])
        try await ProjectExporter.export(p, to: out, mode: .reencode(preset: AVAssetExportPresetHighestQuality))
        let d = try await AVURLAsset(url: out).load(.duration).seconds
        XCTAssertEqual(d, 5, accuracy: 0.2)
    }
}
