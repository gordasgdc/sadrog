import XCTest
@testable import SadrogCore

final class MixPeakBoundTests: XCTestCase {
    func testUsesTheLoudestRecordingNotTheFirstNorTheSum() {
        XCTAssertEqual(MixPeakBound.linear(perRecording: [0.2, 0.9, 0.5], dissolves: false, layers: 0, masterLinear: 1), 0.9, accuracy: 1e-12)
    }
    func testDissolvesDoubleTheMainBoundAndLayersAreAdded() {
        XCTAssertEqual(MixPeakBound.linear(perRecording: [0.4], dissolves: true, layers: 0.25, masterLinear: 1), 1.05, accuracy: 1e-12)
    }
    func testMasterAppliesLastAndEmptyIsZero() {
        XCTAssertEqual(MixPeakBound.linear(perRecording: [0.5], dissolves: false, layers: 0.5, masterLinear: 0.5), 0.5, accuracy: 1e-12)
        XCTAssertEqual(MixPeakBound.linear(perRecording: [], dissolves: false, layers: 0, masterLinear: 1), 0)
    }
}
