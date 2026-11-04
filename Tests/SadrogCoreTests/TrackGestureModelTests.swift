import XCTest
@testable import SadrogCore

/// The model behind the on-track gestures of 1.5: fade curvature handle, crossfade X handle, key band filter.
final class TrackGestureModelTests: XCTestCase {
    func testFadeCurvatureHandleRoundTrips() {
        for g in stride(from: 0.08, through: 0.92, by: 0.04) where abs(g - 0.5) > 0.01 {
            let c = FadeCurve.fitting(midGain: g, from: .linear)
            let lo = 0.5 * pow(0.5, 3) // reachable range limited by bend 1 (p = 4)
            XCTAssertEqual(c.midGain, max(lo, min(1 - lo, g)), accuracy: 0.003, "g=\(g)")
            XCTAssertEqual(c.gain(0), 0, accuracy: 1e-12); XCTAssertEqual(c.gain(1), 1, accuracy: 1e-12)
        }
        XCTAssertEqual(FadeCurve.fitting(midGain: 0.5, from: FadeCurve(shape: .easeIn, bend: 0.7)).shape, .linear)
        XCTAssertEqual(FadeCurve.fitting(midGain: 0.2, from: .linear).shape, .easeIn)
        XCTAssertEqual(FadeCurve.fitting(midGain: 0.8, from: .linear).shape, .easeOut)
        // an S curve keeps its shape; the handle only changes its bend
        XCTAssertEqual(FadeCurve.fitting(midGain: 0.7, from: FadeCurve(shape: .sCurve, bend: 0.2)).shape, .sCurve)
    }
    func testCrossfadeHandleKeepsModeAndGains() {
        for mode in [CrossfadeMode.equalGain, .equalPower] {
            let base = CrossfadeShape(mode: mode)
            for g in [0.2, 0.35, 0.65, 0.8] {
                let s = base.fitting(midIncoming: g)
                XCTAssertEqual(s.mode, mode)
                XCTAssertEqual(s.midIncoming, g, accuracy: 0.01, "\(mode) \(g)")
                let a = s.gains(0), b = s.gains(1)
                XCTAssertEqual(a.incoming, 0, accuracy: 1e-9); XCTAssertEqual(b.incoming, 1, accuracy: 1e-9)
                XCTAssertEqual(a.outgoing, 1, accuracy: 1e-9); XCTAssertEqual(b.outgoing, 0, accuracy: 1e-9)
            }
        }
        // equal power at the centre of a straight crossfade: both at cos 45°
        XCTAssertEqual(CrossfadeShape(mode: .equalPower).midIncoming, 0.5.squareRoot() * 1, accuracy: 1e-9)
    }
    func testKeyBandShowsOnlyKeysThatChangeTheProperty() {
        var m = Motion()
        m.keys = [MotionKey(t: 1, transform: Transform(x: 0, y: 0, scale: 1.2, opacity: 1, rotation: 0)),
                  MotionKey(t: 2, transform: Transform(x: 0.1, y: 0, scale: 1.2, opacity: 1, rotation: 0)),
                  MotionKey(t: 3, transform: Transform(x: 0.1, y: 0, scale: 1.0, opacity: 0.5, rotation: 0))]
        let start = Transform.identity
        XCTAssertEqual(m.keyIndices(changing: nil, start: start), [0, 1, 2])
        XCTAssertEqual(m.keyIndices(changing: .scale, start: start), [0, 2])
        XCTAssertEqual(m.keyIndices(changing: .x, start: start), [1])
        XCTAssertEqual(m.keyIndices(changing: .opacity, start: start), [2])
        XCTAssertEqual(m.keyIndices(changing: .rotation, start: start), [])
    }
}
