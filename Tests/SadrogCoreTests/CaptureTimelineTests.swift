// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// One session clock for every file: common start (first primary screen frame), synchronous pause/resume. Synthetic frames, no capture.
final class CaptureTimelineTests: XCTestCase {
    let work = URL(fileURLWithPath: "\(TestRoot.path)/temp/timeline-\(UUID().uuidString)")
    override func setUp() async throws { try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true) }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: work) }
    func s(_ x: Double) -> CMTime { CMTime(seconds: x, preferredTimescale: 600_000) }
    func frame(_ t: CMTime) -> CMSampleBuffer { CameraTests().frame(t) }

    func testMapDropsBeforeStartAndInsidePausesAndShiftsAfter() {
        let tl = CaptureTimeline()
        XCTAssertNil(tl.map(s(10)), "no start yet")
        tl.setOrigin(s(100)); tl.setOrigin(s(200))
        XCTAssertEqual(tl.origin, s(100), "the first start wins")
        XCTAssertNil(tl.map(s(99.9)))
        XCTAssertEqual(tl.map(s(101)), s(101))
        tl.pause(at: s(102)); XCTAssertTrue(tl.isPaused)
        XCTAssertNil(tl.map(s(103)))
        tl.resume(at: s(104.5)); XCTAssertFalse(tl.isPaused)
        XCTAssertEqual(tl.map(s(105))!.seconds, 102.5, accuracy: 1e-9, "shifted back by the 2.5 s pause")
        tl.pause(at: s(106)); tl.resume(at: s(107))
        XCTAssertEqual(tl.map(s(108))!.seconds, 104.5, accuracy: 1e-9)
        XCTAssertEqual(tl.pausedSeconds, 3.5, accuracy: 1e-9)
    }

    /// A camera started during the countdown: its early frames are not recorded; it starts with the screen; a pause cuts both the same way.
    func testPreparedCameraStartsWithTheScreenAndPausesTogether() async throws {
        let tl = CaptureTimeline()
        let screen = try RecordingWriter(destination: Destination(url: work), settings: RecordingSettings(width: 640, height: 360, fps: 30, hevc: false, withAudio: false), timeline: tl)
        let cam = VideoFileWriter(url: work.appendingPathComponent("camera.mov"), timeline: tl)
        let t0 = 5000.0
        // camera warm: frames from t0 − 2 s; screen's first frame at t0 → the common start
        var t = t0 - 2
        while t < t0 { cam.append(frame(s(t))); t += 1.0 / 30; usleep(2_000) }
        XCTAssertEqual(cam.frames, 0, "nothing before the common start")
        for i in 0..<90 {                                                        // 3 s of session, paused between 1.0 and 1.6 s
            let ts = t0 + Double(i) / 30
            if abs(ts - (t0 + 1.0)) < 1e-6 { tl.pause(at: s(ts)) }
            if abs(ts - (t0 + 1.6)) < 1e-6 { tl.resume(at: s(ts)) }
            screen.appendVideo(frame(s(ts))); cam.append(frame(s(ts + 0.004)))    // camera stamps a few ms later
            usleep(20_000)
        }
        XCTAssertEqual(tl.origin, s(t0))
        XCTAssertEqual((cam.firstPTS - tl.origin!).seconds, 0.004, accuracy: 1e-6, "camera starts at the common start (real 4 ms), not 1.24 s later")
        try await screen.finish(); let ok = try await cam.finish(); XCTAssertTrue(ok)
        let a = AVURLAsset(url: screen.mediaURL), b = AVURLAsset(url: cam.url)
        let da = try await a.load(.duration).seconds, db = try await b.load(.duration).seconds
        XCTAssertEqual(da, 2.4, accuracy: 0.07, "3 s minus the 0.6 s pause")
        XCTAssertEqual(db, da, accuracy: 0.07, "both files cut by the same pause")
        XCTAssertEqual(cam.frames, screen.counters.videoWritten, accuracy: 2)
    }

    /// A camera stopped before the primary screen holds its last frame until the session end (probe 2026-10-30: it ended ~0.4 s early).
    func testCameraHeldToTheSessionEnd() async throws {
        let w = VideoFileWriter(url: work.appendingPathComponent("cam.mov"))
        for i in 0..<15 { w.append(frame(s(10 + Double(i) / 30))); usleep(20_000) }
        let ok = try await w.finish(holdUntil: s(11.0)); XCTAssertTrue(ok)
        let d = try await AVURLAsset(url: w.url).load(.duration).seconds
        XCTAssertEqual(d, 1.0, accuracy: 0.05, "first frame at 10.0 s, held to the 11.0 s end")
    }
}
