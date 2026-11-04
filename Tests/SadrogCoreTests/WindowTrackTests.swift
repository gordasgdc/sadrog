// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// „Foreground Window” is the REAL window in front (geometry + owner from the window list), not a rectangle the user drew. Synthetic listings only.
final class WindowTrackTests: XCTestCase {
    private func entry(_ id: Int, pid: Int, name: String, x: Double, y: Double, w: Double, h: Double, layer: Int = 0, alpha: Double = 1) -> [String: Any] {
        ["kCGWindowNumber": id, "kCGWindowOwnerPID": pid, "kCGWindowOwnerName": name, "kCGWindowLayer": layer, "kCGWindowAlpha": alpha,
         "kCGWindowBounds": ["X": x, "Y": y, "Width": w, "Height": h]]
    }
    func testPickTakesTheTopmostOrdinaryWindowThatIsNotOurs() {
        let list = [entry(1, pid: 99, name: "SADROG", x: 0, y: 0, w: 800, h: 600),                 // ours: skipped
                    entry(2, pid: 50, name: "Menubar", x: 0, y: 0, w: 1440, h: 24, layer: 25),     // not an ordinary window
                    entry(3, pid: 51, name: "Ghost", x: 0, y: 0, w: 500, h: 500, alpha: 0),        // invisible
                    entry(4, pid: 52, name: "Tiny", x: 0, y: 0, w: 10, h: 10),
                    entry(5, pid: 60, name: "Safari", x: 100, y: 80, w: 1000, h: 700),
                    entry(6, pid: 61, name: "Notes", x: 0, y: 0, w: 400, h: 400)]
        let w = ForegroundWindow.pick(from: list, excludingPID: 99, pidToBundle: { $0 == 60 ? "com.apple.Safari" : nil })
        XCTAssertEqual(w, ForegroundWindow(windowID: 5, app: "Safari", bundleID: "com.apple.Safari", frame: CGRect(x: 100, y: 80, width: 1000, height: 700)))
        XCTAssertNil(ForegroundWindow.pick(from: [], excludingPID: 1))
    }
    func testNormalizeCutsAtTheCaptureEdge() {
        let frame = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let r = WindowTrack.normalize(CGRect(x: 800, y: 100, width: 400, height: 200), in: frame)!
        XCTAssertEqual(r.minX, 0.8, accuracy: 1e-9); XCTAssertEqual(r.width, 0.2, accuracy: 1e-9); XCTAssertEqual(r.minY, 0.2, accuracy: 1e-9); XCTAssertEqual(r.height, 0.4, accuracy: 1e-9)
        XCTAssertNil(WindowTrack.normalize(CGRect(x: 2000, y: 0, width: 100, height: 100), in: frame), "entirely outside the capture")
    }
    func testRecorderKeepsChangesAndHeartbeatAndHonoursPause() {
        var clock = 0.0, current: ForegroundWindow? = ForegroundWindow(windowID: 5, app: "Safari", frame: CGRect(x: 100, y: 50, width: 500, height: 250))
        let r = WindowRecorder(frame: CGRect(x: 0, y: 0, width: 1000, height: 500), interval: 0, now: { clock }, read: { current })
        r.start()
        r.tick(); clock = 0.25; r.tick()                                   // same window, same place: not repeated
        clock = 0.5; current = ForegroundWindow(windowID: 5, app: "Safari", frame: CGRect(x: 200, y: 50, width: 500, height: 250)); r.tick()      // moved
        clock = 1.0; current = ForegroundWindow(windowID: 7, app: "Notes", frame: CGRect(x: 0, y: 0, width: 300, height: 300)); r.tick()           // other window
        clock = 1.5; r.pause(); clock = 3.5; current = nil; r.resume(); clock = 4.0; r.tick()                       // pause excluded, nothing in front: no sample
        let t = r.stop()
        XCTAssertEqual(t.samples.map(\.windowID), [5, 5, 7]); XCTAssertEqual(t.samples.map(\.t), [0, 0.5, 1.0])
        XCTAssertEqual(t.samples[0].x, 0.1, accuracy: 1e-9); XCTAssertEqual(t.samples[0].app, "Safari")
        XCTAssertFalse(r.isRunning)
    }
    func testLookupGlidesWithinOneWindowAndCutsBetweenWindows() {
        let t = WindowTrack(samples: [WindowSample(t: 0, x: 0.1, y: 0.1, w: 0.4, h: 0.4, app: "A", windowID: 1), WindowSample(t: 2, x: 0.3, y: 0.1, w: 0.4, h: 0.4, app: "A", windowID: 1),
                                      WindowSample(t: 4, x: 0.5, y: 0.5, w: 0.2, h: 0.2, app: "B", windowID: 2)])
        XCTAssertNil(t.window(at: -1))
        XCTAssertEqual(t.window(at: 1)!.rect.minX, 0.2, accuracy: 1e-9, "same window: glide")
        let cut = t.window(at: 3)!; XCTAssertEqual(cut.app, "A"); XCTAssertEqual(cut.rect.minX, 0.3, accuracy: 1e-9, "before the next window starts, the last place holds")
        XCTAssertEqual(t.window(at: 9)!.app, "B"); XCTAssertEqual(t.window(at: 9)!.windowID, 2)
    }
    func testSaveLoadNextToTheMediaAndNoTitleIsStored() throws {
        guard FileManager.default.fileExists(atPath: "/Volumes/CristiGordas/TESTE") else { throw XCTSkip("external storage") }
        let dir = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/win-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let t = WindowTrack(samples: [WindowSample(t: 0, x: 0, y: 0, w: 1, h: 1, app: "Safari", bundleID: "com.apple.Safari", windowID: 3)], syntheticFixture: true)
        try t.save(to: dir)
        XCTAssertEqual(WindowTrack.load(besideMedia: dir.appendingPathComponent("screen.mov").path), t)
        let json = try String(contentsOf: dir.appendingPathComponent(WindowTrack.fileName), encoding: .utf8)
        XCTAssertFalse(json.lowercased().contains("title"), "a window title can hold private text and is never stored")
    }
}

/// The consumer: the recorded window drives the clip's zoom/pan. SYNTHETIC fixture (`syntheticFixture = true`): a window that moves, a second one, and a silence.
final class WindowFollowTests: XCTestCase {
    private func s(_ t: Double, _ id: UInt32, _ x: Double, _ y: Double, _ w: Double, _ h: Double, _ app: String = "Safari") -> WindowSample { WindowSample(t: t, x: x, y: y, w: w, h: h, app: app, windowID: id) }
    private var track: WindowTrack {
        WindowTrack(samples: [s(0, 1, 0.1, 0.1, 0.4, 0.4), s(2, 1, 0.1, 0.1, 0.4, 0.4), s(4, 1, 0.5, 0.5, 0.4, 0.4),      // window 1 moves right/down between 2 s and 4 s
                              s(5, 2, 0.0, 0.0, 1.0, 1.0, "Finder"),                                                         // window 2 fills the frame
                              s(6, 2, 0.0, 0.0, 1.0, 1.0, "Finder")], syntheticFixture: true)
    }
    func testZoomFillsTheWindowAndCentresIt() {
        let p = WindowFollow.plan(track, sourceStart: 0, duration: 2, only: 1)!
        XCTAssertEqual(p.start.scale, 0.92 / 0.4, accuracy: 1e-9, "window 40 % wide → ×2.3 with the 92 % fill")
        // window centre (0.3, 0.3) → pan (0.5-0.3)*s, within the legal limit
        XCTAssertEqual(p.start.x, 0.2 * p.start.scale, accuracy: 1e-9); XCTAssertEqual(p.start.y, 0.2 * p.start.scale, accuracy: 1e-9)
    }
    func testFollowsTheWindowWhenItMoves() {
        let p = WindowFollow.plan(track, sourceStart: 0, duration: 4.5, only: 1)!
        let early = p.keys.first { $0.t == 1.5 }!.transform, late = p.keys.first { $0.t == 4.0 }!.transform
        XCTAssertGreaterThan(early.x, late.x, "window moved right → frame pans the other way"); XCTAssertLessThan(late.x, 0)
    }
    func testSourceStartOffsetsTheClock() {
        let a = WindowFollow.plan(track, sourceStart: 0, duration: 2, only: 1)!, b = WindowFollow.plan(track, sourceStart: 4, duration: 1, only: 1)!
        XCTAssertNotEqual(a.start.x, b.start.x, "a clip cut from later in the recording follows the window of THAT time")
    }
    func testWindowFillingTheFrameDoesNotZoom() {
        XCTAssertNil(WindowFollow.plan(track, sourceStart: 5, duration: 1, only: 2), "full-frame window: nothing to follow")
    }
    func testMissingWindowGoesBackToFullFrameAndUnknownIdIsRefused() {
        let t = WindowTrack(samples: [s(1, 1, 0.1, 0.1, 0.4, 0.4)], syntheticFixture: true)
        let p = WindowFollow.plan(t, sourceStart: 0, duration: 8)!
        XCTAssertEqual(p.start, .identity, "before the first reading: full frame")
        XCTAssertEqual(p.keys.first { $0.t == 1.5 }!.transform.scale, 0.92 / 0.4, accuracy: 1e-9)
        XCTAssertEqual(p.keys.first { $0.t == 6.0 }!.transform, .identity, "last reading older than 3 s: back to the full picture, not a stale rectangle")
        XCTAssertNil(WindowFollow.plan(t, sourceStart: 0, duration: 4, only: 99)); XCTAssertNil(WindowFollow.plan(WindowTrack(samples: []), sourceStart: 0, duration: 4))
    }
    func testWindowsSeenListsWhoWasInFront() {
        let w = track.windowsSeen; XCTAssertEqual(w.map(\.windowID), [1, 2]); XCTAssertEqual(w[0].seconds, 5, accuracy: 1e-9); XCTAssertEqual(w[1].app, "Finder")
    }
    func testEditorCommandIsOneUndoStepAndSurvivesTrimAndReopen() throws {
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/a.mov", sourceStart: 0, duration: 4)])); let id = ed.project.clips[0].id
        XCTAssertTrue(ed.followWindow(clip: id, track: track, only: 1))
        let c = ed.project.clips[0]; XCTAssertGreaterThan(c.transform.scale, 2); XCTAssertFalse(c.motion?.keys.isEmpty ?? true)
        ed.trimEnd(clip: id, by: 1)
        XCTAssertEqual(ed.project.clips[0].duration, 3, accuracy: 1e-9); XCTAssertNotNil(ed.project.clips[0].motion)
        ed.undo(); ed.undo(); XCTAssertEqual(ed.project.clips[0].transform, .identity); XCTAssertNil(ed.project.clips[0].motion, "one undo for the follow, one for the trim")
        ed.redo()
        let back = try JSONDecoder().decode(SadrogProject.self, from: JSONEncoder().encode(ed.project))
        XCTAssertEqual(back.clips[0].transform, ed.project.clips[0].transform); XCTAssertEqual(back.clips[0].motion?.keys, ed.project.clips[0].motion?.keys)
        let before = ed.project; XCTAssertFalse(ed.followWindow(clip: id, track: WindowTrack(samples: []), only: nil)); XCTAssertEqual(ed.project, before, "no track: nothing changes")
    }
    func testTrackBelongsToItsRecordingNotToTheFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); defer { try? FileManager.default.removeItem(at: dir) }
        let a = dir.appendingPathComponent("a.mov").path, b = dir.appendingPathComponent("b.mov").path
        let s = [WindowSample(t: 0, x: 0.1, y: 0.1, w: 0.4, h: 0.4, app: "A", windowID: 1)]
        try WindowTrack(samples: s, syntheticFixture: true, mediaFile: "a.mov").save(to: dir)
        XCTAssertNotNil(WindowTrack.load(besideMedia: a)); XCTAssertNil(WindowTrack.load(besideMedia: b), "a sibling file must not borrow another recording's windows")
        try WindowTrack(samples: s, syntheticFixture: true).save(to: dir)     // written before the owner field existed
        XCTAssertNotNil(WindowTrack.load(besideMedia: a)); XCTAssertNotNil(WindowTrack.load(besideMedia: b), "legacy track: one recording per folder, kept for compatibility")
        let back = try JSONDecoder().decode(WindowTrack.self, from: Data(#"{"schema":1,"syntheticFixture":false,"samples":[{"t":0,"x":0,"y":0,"w":1,"h":1,"app":"A","windowID":1}]}"#.utf8))
        XCTAssertNil(back.mediaFile)
        try WindowTrack(samples: s, syntheticFixture: true, mediaFile: "A.MOV").save(to: dir)
        XCTAssertNotNil(WindowTrack.load(besideMedia: a), "owner name compares case-insensitively (APFS)")
    }
}
