// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

final class PanelPlacementTests: XCTestCase {
    let size = CGSize(width: 260, height: 52)
    let a = CGRect(x: 0, y: 0, width: 1440, height: 875)
    let b = CGRect(x: 1440, y: 100, width: 1920, height: 1055)

    func testDefaultIsTopRightOfFirstScreen() {
        let f = PanelPlacement.resolve(saved: nil, size: size, screens: [a, b])
        XCTAssertEqual(f.size, size)
        XCTAssertTrue(a.contains(f)); XCTAssertEqual(f.maxX, a.maxX - 40, accuracy: 0.5)
    }
    func testValidSavedPositionIsKeptExactly() {
        let s = CGRect(x: 300, y: 400, width: 260, height: 52)
        XCTAssertEqual(PanelPlacement.resolve(saved: s, size: size, screens: [a, b]), s)
    }
    func testPositionOnSecondScreenIsKeptWhileItExists() {
        let s = CGRect(x: 2000, y: 500, width: 260, height: 52)
        XCTAssertEqual(PanelPlacement.resolve(saved: s, size: size, screens: [a, b]), s)
    }
    func testRecoversWhenTheMonitorDisappeared() {
        let s = CGRect(x: 2000, y: 500, width: 260, height: 52)
        let f = PanelPlacement.resolve(saved: s, size: size, screens: [a])
        XCTAssertTrue(a.contains(f))
    }
    func testPartlyOffScreenIsPulledFullyInside() {
        let s = CGRect(x: 1350, y: 860, width: 260, height: 52)
        let f = PanelPlacement.resolve(saved: s, size: size, screens: [a])
        XCTAssertTrue(a.contains(f)); XCTAssertEqual(f.size, size)
    }
    func testNoScreensStillReturnsAFrame() {
        XCTAssertEqual(PanelPlacement.resolve(saved: nil, size: size, screens: []).size, size)
    }
    func testBarelyVisibleCountsAsLost() {
        let s = CGRect(x: 1430, y: 860, width: 260, height: 52)   // 10 px visible
        let f = PanelPlacement.resolve(saved: s, size: size, screens: [a])
        XCTAssertTrue(a.contains(f))
    }
}
