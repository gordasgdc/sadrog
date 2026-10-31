// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

final class MontageTests: XCTestCase {
    func testSnapToNearestWithinThreshold() {
        XCTAssertEqual(Snapping.snap(4.93, to: [0, 5, 9], threshold: 0.1).point, 5)
        XCTAssertEqual(Snapping.snap(4.93, to: [0, 5, 9], threshold: 0.1).value, 5)
        XCTAssertNil(Snapping.snap(4.5, to: [0, 5, 9], threshold: 0.1).point)
        XCTAssertEqual(Snapping.snap(4.5, to: [0, 5, 9], threshold: 0.1).value, 4.5)
    }
    func testSnapBlockUsesEitherEdgeAndKeepsLength() {
        let a = Snapping.snapBlock(start: 3.95, duration: 2, to: [4, 10], threshold: 0.1)       // start edge lands on 4
        XCTAssertEqual(a.start, 4, accuracy: 1e-9); XCTAssertEqual(a.point, 4)
        let b = Snapping.snapBlock(start: 7.96, duration: 2, to: [4, 10], threshold: 0.1)       // end edge lands on 10
        XCTAssertEqual(b.start, 8, accuracy: 1e-9); XCTAssertEqual(b.point, 10)
        XCTAssertNil(Snapping.snapBlock(start: 6, duration: 1, to: [4, 10], threshold: 0.1).point)
    }
    func testSnapPointsExcludeTheDraggedItemAndIncludePlayhead() {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/a", sourceStart: 0, duration: 4), Clip(media: "/a", sourceStart: 0, duration: 3)])
        let l = Layer(kind: .video, media: "/b", start: 5, duration: 2); p.layers = [l, Layer(kind: .audio, media: "/c", start: 8, duration: 1)]
        let pts = Set(Snapping.points(of: p, playhead: 2.5, excluding: l.id))
        XCTAssertTrue(pts.isSuperset(of: [0, 2.5, 4, 7, 8, 9])); XCTAssertFalse(pts.contains(5))
    }
    func testViewerFitAndZoomGeometry() {
        let area = CGRect(x: 0, y: 0, width: 800, height: 400), r = CGSize(width: 1280, height: 720)
        let fit = ViewerFrame.frame(render: r, area: area, zoom: nil)
        XCTAssertEqual(fit.height, 400, accuracy: 1e-6); XCTAssertEqual(fit.midX, 400, accuracy: 1e-6)
        let z = ViewerFrame.frame(render: r, area: area, zoom: 1)                                  // 100% = pixel size, larger than the area
        XCTAssertEqual(z.width, 1280); XCTAssertEqual(z.midX, 400, accuracy: 1e-6)
        let far = ViewerFrame.frame(render: r, area: area, zoom: 1, pan: CGSize(width: 9999, height: 9999))
        XCTAssertEqual(far.minX, 0, accuracy: 1e-6); XCTAssertEqual(far.minY, 0, accuracy: 1e-6)    // pan stops when the frame edge meets the area edge
        let small = ViewerFrame.frame(render: r, area: area, zoom: 0.25, pan: CGSize(width: 50, height: 50))
        XCTAssertEqual(small.midX, 400, accuracy: 1e-6)                                            // smaller than the area: always centred
        XCTAssertEqual(ViewerFrame.displayedZoom(render: r, area: area, zoom: nil), 400.0 / 720.0, accuracy: 1e-9)
    }
    func testLaneFlagsRenameUndoAndPersistence() throws {
        let e = ProjectEditor(project: SadrogProject(name: "Vechi", clips: [Clip(media: "/a", sourceStart: 0, duration: 4)]))
        e.setLane(.v2, off: true); e.setLane(.a2, off: true); e.rename("  Prezentare produs ")
        XCTAssertEqual(e.project.hiddenLanes, [.v2]); XCTAssertEqual(e.project.mutedLanes, [.a2]); XCTAssertEqual(e.project.name, "Prezentare produs")
        e.rename("   "); XCTAssertEqual(e.project.name, "Prezentare produs")                       // empty name refused
        let f = URL(fileURLWithPath: "\(TestRoot.path)/temp/lanes-\(UUID().uuidString).sadrogproj"); defer { try? FileManager.default.removeItem(at: f) }
        try ProjectStore.save(e.project, to: f)
        let back = try ProjectStore.load(from: f)
        XCTAssertEqual(back, e.project); XCTAssertEqual(back.name, "Prezentare produs")
        e.undo(); XCTAssertEqual(e.project.name, "Vechi")
        e.undo(); e.undo(); XCTAssertTrue(e.project.hiddenLanes.isEmpty && e.project.mutedLanes.isEmpty)
    }
    func testHiddenOverlayAndHiddenMainAreNotRendered() async throws {
        let d = CompositionTests.dir, blue = d + "/blue.mov", red = d + "/red.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue) && FileManager.default.fileExists(atPath: red), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 3)])
        p.layers = [Layer(kind: .video, media: red, start: 0, duration: 3, transform: Transform(scale: 0.5))]
        let helper = CompositionTests()
        p.hiddenLanes = [.v2]
        var url = try await helper.export(p); var c = try await helper.pixel(url, at: 1, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(c.2, 150); XCTAssertLessThan(c.0, 80)                                  // overlay hidden: only blue
        try? FileManager.default.removeItem(at: url)
        p.hiddenLanes = [.v1]
        url = try await helper.export(p); c = try await helper.pixel(url, at: 1, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(c.0, 200)                                                              // main hidden: overlay centre still red
        let corner = try await helper.pixel(url, at: 1, x: 0.05, y: 0.05)
        XCTAssertLessThan(corner.0 + corner.1 + corner.2, 60)                                       // and the rest is black, not blue
        try? FileManager.default.removeItem(at: url)
    }
    func testMutedLanesKeepTheirTracksAndGetSilenceFromTheAudioMix() async throws {
        let amb = "\(TestRoot.path)/synthetic/ambient.m4a", cap = "\(TestRoot.path)/synthetic/capture2.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: amb) && FileManager.default.fileExists(atPath: cap), "synthetic media not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: cap, sourceStart: 0, duration: 4)])
        p.layers = [Layer(kind: .audio, media: amb, start: 1, duration: 3)]
        let b0 = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(Set(mixVolumes(b0.audioMix(for: p)).values), [1]); XCTAssertEqual(b0.composition.tracks(withMediaType: .audio).count, 2)
        p.mutedLanes = [.a2]
        let b1 = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(b1.composition.tracks(withMediaType: .audio).count, 2)                      // the track stays: nothing shifts or shortens
        XCTAssertEqual(mixVolumes(b1.audioMix(for: p)).values.sorted(), [0, 1])
        p.mutedLanes = [.a1, .a2]
        let b2 = try await CompositionBuilder.buildFull(p)
        XCTAssertEqual(mixVolumes(b2.audioMix(for: p)).values.sorted(), [0, 0])
        XCTAssertEqual(b1.composition.duration.seconds, 4, accuracy: 0.05)
    }
    func testHiddenOverlayPastTheMainTrackKeepsTheDurationAndShowsBackground() async throws {
        let d = CompositionTests.dir, blue = d + "/blue.mov", red = d + "/red.mov"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: blue) && FileManager.default.fileExists(atPath: red), "synthetic colour clips not available")
        var p = SadrogProject(name: "t", clips: [Clip(media: blue, sourceStart: 0, duration: 2)])
        p.layers = [Layer(kind: .video, media: red, start: 1, duration: 3)]; p.hiddenLanes = [.v2]
        XCTAssertEqual(p.timelineEnd, 4, accuracy: 1e-9)
        let helper = CompositionTests()
        let url = try await helper.export(p); defer { try? FileManager.default.removeItem(at: url) }
        let dur = try await AVURLAsset(url: url).load(.duration).seconds
        XCTAssertEqual(dur, 4, accuracy: 0.1)                                                       // hiding never shortens the project
        let after = try await helper.pixel(url, at: 3, x: 0.5, y: 0.5)
        XCTAssertLessThan(after.0 + after.1 + after.2, 60)                                          // past the main clip and hidden overlay: project background
        let during = try await helper.pixel(url, at: 0.5, x: 0.5, y: 0.5)
        XCTAssertGreaterThan(during.2, 150)
    }

    /// Relinking a missing file moves every use (V1, overlay, library) in one undo step; missing detection covers overlays too.
    func testRelinkMediaMovesEveryUseAndUndoes() {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/gone/a.mov", sourceStart: 0, duration: 2), Clip(media: "/gone/b.mov", sourceStart: 0, duration: 2)])
        p.layers = [Layer(kind: .video, media: "/gone/a.mov", start: 0, duration: 1)]; p.library = ["/gone/a.mov", "/gone/b.mov"]
        XCTAssertEqual(ProjectStore.missingMedia(p), ["/gone/a.mov", "/gone/b.mov"])
        p.layers.append(Layer(kind: .audio, media: "/gone/c.m4a", start: 0, duration: 1))
        XCTAssertTrue(ProjectStore.missingMedia(p).contains("/gone/c.m4a"), "an overlay or audio layer that went missing must be reported")
        let e = ProjectEditor(project: p)
        e.relinkMedia(from: "/gone/a.mov", to: "/now/a.mov")
        XCTAssertEqual(e.project.clips.map(\.media), ["/now/a.mov", "/gone/b.mov"]); XCTAssertEqual(e.project.layers[0].media, "/now/a.mov"); XCTAssertEqual(e.project.library, ["/now/a.mov", "/gone/b.mov"])
        e.relinkMedia(from: "/nothing", to: "/x"); e.undo()
        XCTAssertEqual(e.project.clips[0].media, "/gone/a.mov", "one undo step restores all uses (the no-op relink left no step)")
    }
}
