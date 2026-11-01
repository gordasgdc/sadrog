import XCTest
import AVFoundation
@testable import SadrogCore

final class CaptureReadoutsTests: XCTestCase {
    func testDbfsAndReadout() {
        XCTAssertEqual(AudioLevelMath.dbfs(peak: 1), 0, accuracy: 1e-5)
        XCTAssertEqual(AudioLevelMath.dbfs(peak: 0.5), -6.0206, accuracy: 1e-3)
        XCTAssertEqual(AudioLevelMath.readout(peak: 0.2512), "−12 dBFS")
        XCTAssertEqual(AudioLevelMath.readout(peak: 0), "< −60 dBFS")
        XCTAssertEqual(AudioLevelMath.readout(peak: 0.0005), "< −60 dBFS")      // −66 dBFS
        XCTAssertEqual(AudioLevelMath.readout(peak: 1), "0 dBFS")
    }
    func testZonesFollowTheStatedThresholds() {
        func p(_ db: Float) -> Float { powf(10, db / 20) }
        XCTAssertEqual(AudioLevelMath.zone(peak: 0), .silent)
        XCTAssertEqual(AudioLevelMath.zone(peak: p(-61)), .silent)
        XCTAssertEqual(AudioLevelMath.zone(peak: p(-40)), .ok)
        XCTAssertEqual(AudioLevelMath.zone(peak: p(-18)), .ok)
        XCTAssertEqual(AudioLevelMath.zone(peak: p(-17.9)), .high)
        XCTAssertEqual(AudioLevelMath.zone(peak: p(-3)), .high)
        XCTAssertEqual(AudioLevelMath.zone(peak: p(-2.9)), .hot)
        XCTAssertEqual(AudioLevelMath.zone(peak: 0.998), .hot)
        XCTAssertEqual(AudioLevelMath.zone(peak: 0.999), .clip)
        XCTAssertEqual(AudioLevelMath.zone(peak: 1.2), .clip)
    }
    func testBarPositionIsLinearInDecibels() {
        XCTAssertEqual(AudioLevelMath.position(peak: 0), 0)
        XCTAssertEqual(AudioLevelMath.position(peak: powf(10, -30 / 20)), 0.5, accuracy: 1e-4)
        XCTAssertEqual(AudioLevelMath.position(peak: 1), 1, accuracy: 1e-6)
        XCTAssertEqual(AudioLevelMath.position(peak: 4), 1)
    }
    func testMeterHoldsThePeakThenFallsAndClipStaysUntilCleared() {
        var r = MeterReading(); let t0 = Date(timeIntervalSince1970: 1000)
        r.update(peak: 0.5, now: t0)
        r.update(peak: 0.1, now: t0.addingTimeInterval(0.5)); XCTAssertEqual(r.heldPeak, 0.5)           // held
        r.update(peak: 0.1, now: t0.addingTimeInterval(1.6)); XCTAssertEqual(r.heldPeak, 0.1)           // released after the hold time
        XCTAssertFalse(r.clipped)
        r.update(peak: 1.0, now: t0.addingTimeInterval(2)); XCTAssertTrue(r.clipped)
        r.update(peak: 0, now: t0.addingTimeInterval(10)); XCTAssertTrue(r.clipped)                       // latched
        r.clearClip(); XCTAssertFalse(r.clipped)
    }
    func testSizeBreakdownKeepsTheFourSizesApart() {
        // a 3840×2160-point mode at 2× on a 3840×2160 panel: the macOS render (7680×4320) is NOT the panel
        var s = SourceInfo(id: 2, kind: .display, title: "BenQ", width: 3840, height: 2160, pointsWidth: 3840, pointsHeight: 2160, scale: 2)
        s.panelWidth = 3840; s.panelHeight = 2160
        let b = SizeBreakdown.make(source: s, sourcePixels: s.pixels, file: s.pixels)
        XCTAssertEqual([b.logicalW, b.logicalH, b.renderW, b.renderH, b.panelW, b.panelH, b.fileW, b.fileH], [3840, 2160, 7680, 4320, 3840, 2160, 7680, 4320])
        XCTAssertTrue(b.renderExceedsPanel); XCTAssertTrue(b.fileExceedsPanel); XCTAssertTrue(b.fileIsRender)
        let capped = SizeBreakdown.make(source: s, sourcePixels: s.pixels, file: (3840, 2160))
        XCTAssertFalse(capped.fileExceedsPanel); XCTAssertFalse(capped.fileIsRender); XCTAssertTrue(capped.renderExceedsPanel)
        var w = SourceInfo(id: 9, kind: .window, title: "w", width: 800, height: 600, scale: 2)
        w.panelWidth = 0
        let bw = SizeBreakdown.make(source: w, sourcePixels: w.pixels, file: w.pixels)
        XCTAssertEqual([bw.logicalW, bw.renderW, bw.panelW], [800, 1600, 0]); XCTAssertFalse(bw.renderExceedsPanel)
    }
    func testPreviewGateNeverStartsWhenItMustNot() {
        XCTAssertEqual(CameraPreviewState.gate(auth: .authorized, present: false), .absent)
        XCTAssertEqual(CameraPreviewState.gate(auth: .denied, present: true), .denied)
        XCTAssertEqual(CameraPreviewState.gate(auth: .restricted, present: true), .restricted)
        XCTAssertNil(CameraPreviewState.gate(auth: .authorized, present: true))
        XCTAssertNil(CameraPreviewState.gate(auth: .notDetermined, present: true))   // the caller asks first, after the user's click
        XCTAssertTrue(CameraPreviewState.loading.isRunning); XCTAssertFalse(CameraPreviewState.denied.isRunning)
    }
    func testPreviewRefusesWithoutAccess() throws {
        if CameraCapture.authorization == .authorized { throw XCTSkip("camera access granted on this host: the refusal path is not reachable") }
        XCTAssertThrowsError(try CameraPreviewSession(uid: "no-such-camera", format: nil))
    }
}
