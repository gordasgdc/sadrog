import XCTest
@testable import SadrogCore

final class AddRecordingTests: XCTestCase {
    private func journal() -> SessionJournal { SessionJournal(id: "s1", state: .finished, startedAt: Date(), mediaFile: "capture.mov", width: 1280, height: 720, fps: 30) }
    func testAddedSessionJoinsTheEndAsOneUndoStepAndKeepsTheRestUntouched() throws {
        var base = SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 8)])
        var l = Layer(kind: .video, media: "/o.mov", start: 2, duration: 3); l.track = nil; base.layers = [l]
        base.canvas = DocumentFormat(width: 1920, height: 1080, fps: 24)
        let e = ProjectEditor(project: base), before = e.project
        let ids = try XCTUnwrap(e.addRecordingSession(media: "/rec/capture.mov", duration: 5, journal: journal()))
        XCTAssertEqual(e.project.clips.count, 2); XCTAssertEqual(e.project.clips[1].media, "/rec/capture.mov"); XCTAssertEqual(e.project.clipSpans[1].start, 8, accuracy: 1e-9)
        XCTAssertEqual(ids.first, e.project.clips[1].id); XCTAssertEqual(e.project.clips[0], before.clips[0]); XCTAssertEqual(e.project.layers, before.layers)
        XCTAssertEqual(e.project.canvas, before.canvas, "the project's own canvas is kept"); XCTAssertTrue(e.project.library.contains("/rec/capture.mov"))
        e.undo(); XCTAssertEqual(e.project, before, "one undo removes the whole addition; no file is touched")
        e.redo(); XCTAssertEqual(e.project.clips.count, 2)
    }
    func testNothingAddedWhenTooShort() {
        let e = ProjectEditor(project: SadrogProject(name: "t")); XCTAssertNil(e.addRecordingSession(media: "/x.mov", duration: 0.01, journal: journal())); XCTAssertTrue(e.project.clips.isEmpty)
    }
    func testCameraAndExtraScreenFilesAreAddedShiftedOnFreeRowsSeparatelyEditable() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("addrec-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for f in ["capture.mov", "camera.mov"] { FileManager.default.createFile(atPath: dir.appendingPathComponent(f).path, contents: Data()) }
        var m = SourcesManifest(video: VideoSourceSpec(mode: .display, sourceID: 1, title: "M"), sourcePixels: [1280, 720], outputPixels: [1280, 720], scale: 1, audioTracks: [])
        m.videoFiles = [.init(id: "cam", kind: .camera, name: "Cam", file: "camera.mov", width: 640, height: 480, frames: 100, firstFrameOffsetSeconds: 0, durationSeconds: 6)]
        try m.write(to: dir)
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 10)]))
        e.addRecordingSession(media: dir.appendingPathComponent("capture.mov").path, duration: 6, journal: journal())
        let cam = try XCTUnwrap(e.project.layers.first { $0.media.hasSuffix("camera.mov") })
        XCTAssertEqual(cam.start, 10, accuracy: 1e-6); XCTAssertNotNil(cam.crop, "camera = presenter circle, not printed over the screen"); XCTAssertEqual(e.project.clips.count, 2)
    }
}
