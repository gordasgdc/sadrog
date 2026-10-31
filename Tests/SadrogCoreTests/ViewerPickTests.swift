import XCTest
@testable import SadrogCore

final class ViewerPickTests: XCTestCase {
    private let R = CGSize(width: 1280, height: 720)
    private func fixture() -> (SadrogProject, UUID, UUID, UUID) {
        let screen = Clip(media: "/s.mov", sourceStart: 0, duration: 10)
        var cam = Layer(kind: .video, media: "/cam.mov", start: 0, duration: 10, transform: Transform(x: 0.3, y: 0.25, scale: 0.3))
        cam.crop = CircleCrop()
        var title = TextOverlay(text: "Titlu", start: 0, duration: 5); title.transform = Transform(x: -0.2, y: -0.3)
        var p = SadrogProject(name: "t", clips: [screen]); p.layers = [cam]; p.texts = [title]
        return (p, screen.id, cam.id, title.id)
    }
    private func items(_ p: SadrogProject, at t: Double = 1) -> [ViewerItem] {
        ViewerPick.items(in: p, at: t, render: R, natural: { _ in CGSize(width: 1280, height: 720) }, textSize: { _ in CGSize(width: 300, height: 60) })
    }
    func testFrontToBackOrderAndCircleCornersFallThroughToTheScreen() {
        let (p, s, c, t) = fixture(); let it = items(p)
        XCTAssertEqual(it.map(\.id), [t, c, s])
        let cam = it[1]; let centre = cam.center
        XCTAssertEqual(ViewerPick.hits(it, at: centre).first?.id, c)
        let corner = CGPoint(x: centre.x + cam.size.width / 2 - 2, y: centre.y + cam.size.height / 2 - 2)      // inside the square, outside the circle
        XCTAssertEqual(ViewerPick.hits(it, at: corner).first?.id, s, "outside the camera circle the click reaches the screen")
    }
    func testTitleOnlyInItsTimeAndTransparentOrHiddenItemsDoNotBlock() {
        var (p, s, c, t) = fixture()
        XCTAssertFalse(items(p, at: 6).contains { $0.id == t }, "title ended")
        let pt = items(p)[1].center
        p.layers[0].transform.opacity = 0
        XCTAssertEqual(ViewerPick.hits(items(p), at: pt).first?.id, s, "transparent item does not block")
        p.layers[0].transform.opacity = 1; p.hiddenLanes.insert(.v2)
        XCTAssertFalse(items(p).contains { $0.id == c }); _ = t
    }
    func testRotatedRectangleAndCoveredItemCycling() {
        var (p, s, _, t) = fixture(); p.texts[0].transform = Transform(x: 0, y: 0, rotation: 90)
        let it = items(p)
        let along = CGPoint(x: it[0].center.x, y: it[0].center.y + 100)      // 90°: the 300-wide title now extends 150 vertically
        XCTAssertEqual(ViewerPick.hits(it, at: along).first?.id, t)
        XCTAssertNotEqual(ViewerPick.hits(it, at: CGPoint(x: it[0].center.x + 100, y: it[0].center.y)).first?.id, t)
        let hits = ViewerPick.hits(it, at: along)
        XCTAssertEqual(hits.map(\.id), [t, s]); XCTAssertEqual(ViewerPick.next(after: t, in: hits)?.id, s); XCTAssertEqual(ViewerPick.next(after: s, in: hits)?.id, t)
    }
    func testHigherRowIsInFront() {
        var (p, _, c, _) = fixture()
        var l2 = Layer(kind: .video, media: "/o.mov", start: 0, duration: 10, transform: Transform(x: 0.3, y: 0.25, scale: 0.3)); l2.track = 1; p.layers.append(l2)
        XCTAssertEqual(items(p).filter { $0.lane == .v2 }.map(\.id), [l2.id, c])
    }
}
