import XCTest
import AVFoundation
@testable import SadrogCore

/// The export destination contract: nothing existing is overwritten or deleted without an explicit request; results are written to an operation-owned temporary item and published whole.
final class SafePublishTests: XCTestCase {
    static let root = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG"
    var dir: URL!
    override func setUpWithError() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.root + "/temp"), "external test storage")
        dir = URL(fileURLWithPath: Self.root + "/temp/safepub-\(UUID().uuidString)"); try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { if let dir { try? FileManager.default.removeItem(at: dir) } }
    private var names: [String] { ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() }
    private func foreign(_ n: String = "mine.mov") throws -> URL { let u = dir.appendingPathComponent(n); try Data("DO NOT TOUCH".utf8).write(to: u); return u }
    struct Boom: Error {}

    func testExistingDestinationIsRefusedAndKeptIdentical() async throws {
        let u = try foreign()
        do { try await SafePublish.run(to: u) { t in try Data("new".utf8).write(to: t) }; XCTFail("must refuse") } catch let e as CocoaError { XCTAssertEqual(e.code, .fileWriteFileExists) }
        XCTAssertEqual(try String(contentsOf: u), "DO NOT TOUCH"); XCTAssertEqual(names, ["mine.mov"], "no partial left")
    }
    func testSuccessPublishesWholeAndLeavesNoTemporary() async throws {
        let u = dir.appendingPathComponent("out.mov")
        try await SafePublish.run(to: u) { t in XCTAssertNotEqual(t, u); try Data("ok".utf8).write(to: t) }
        XCTAssertEqual(try String(contentsOf: u), "ok"); XCTAssertEqual(names, ["out.mov"])
    }
    func testFolderResultIsPublishedToo() async throws {
        let u = dir.appendingPathComponent("seq")
        try await SafePublish.run(to: u) { t in try FileManager.default.createDirectory(at: t, withIntermediateDirectories: false); try Data("a".utf8).write(to: t.appendingPathComponent("f.png")) }
        XCTAssertEqual(names, ["seq"]); XCTAssertTrue(FileManager.default.fileExists(atPath: u.appendingPathComponent("f.png").path))
    }
    func testErrorBeforeAndDuringWritingKeepsForeignFileAndLeavesNothing() async throws {
        let u = try foreign()
        do { try await SafePublish.run(to: u, replaceExisting: true) { _ in throw Boom() }; XCTFail() } catch is Boom {}
        do { try await SafePublish.run(to: u, replaceExisting: true) { t in try Data("half".utf8).write(to: t); throw Boom() }; XCTFail() } catch is Boom {}
        XCTAssertEqual(try String(contentsOf: u), "DO NOT TOUCH"); XCTAssertEqual(names, ["mine.mov"])
    }
    func testCancellationLeavesNothingAndKeepsForeignFile() async throws {
        let u = try foreign()
        let t = Task { try await SafePublish.run(to: u, replaceExisting: true) { tmp in try Data("half".utf8).write(to: tmp); try await Task.sleep(nanoseconds: 5_000_000_000) } }
        try await Task.sleep(nanoseconds: 200_000_000); t.cancel()
        do { try await t.value; XCTFail() } catch {}
        XCTAssertEqual(try String(contentsOf: u), "DO NOT TOUCH"); XCTAssertEqual(names, ["mine.mov"])
    }
    func testExplicitReplaceSwapsWholeResult() async throws {
        let u = try foreign()
        try await SafePublish.run(to: u, replaceExisting: true) { t in try Data("fresh".utf8).write(to: t) }
        XCTAssertEqual(try String(contentsOf: u), "fresh"); XCTAssertEqual(names, ["mine.mov"])
    }
    func testRealExportsHonourTheContract() async throws {
        let hd = Self.root + "/synthetic/preset/hd.mov"; try XCTSkipUnless(FileManager.default.fileExists(atPath: hd), "synthetic clip")
        let p = SadrogProject(name: "t", clips: [Clip(media: hd, sourceStart: 0, duration: 1)]); let doc = CGSize(width: 1920, height: 1080)
        let u = try foreign()
        for mode in [ExportSettings.Mode.compressed, .master, .lossless] {
            var s = ExportSettings(); s.mode = mode; if mode == .compressed { s.videoMbps = 4 }
            do { try await ProjectExporter.export(p, to: u, settings: s, documentSize: doc, documentFPS: 30); XCTFail("\(mode) must refuse") } catch let e as CocoaError { XCTAssertEqual(e.code, .fileWriteFileExists) }
        }
        XCTAssertEqual(try String(contentsOf: u), "DO NOT TOUCH"); XCTAssertEqual(names, ["mine.mov"])
        // an error while writing (missing media) next to a foreign file: nothing partial, foreign file intact, no new file
        let bad = SadrogProject(name: "t", clips: [Clip(media: dir.path + "/missing.mov", sourceStart: 0, duration: 1)])
        var s = ExportSettings(); s.videoMbps = 4
        let o = dir.appendingPathComponent("o.mov")
        do { try await ProjectExporter.export(bad, to: o, settings: s, documentSize: doc, documentFPS: 30); XCTFail() } catch {}
        XCTAssertEqual(names, ["mine.mov"])
        // success: exactly the published file
        try await ProjectExporter.export(p, to: o, settings: s, documentSize: doc, documentFPS: 30)
        XCTAssertEqual(names, ["mine.mov", "o.mov"])
    }
    func testCancelledRealExportLeavesNoPartial() async throws {
        let hd = Self.root + "/synthetic/preset/hd.mov"; try XCTSkipUnless(FileManager.default.fileExists(atPath: hd), "synthetic clip")
        let p = SadrogProject(name: "t", clips: [Clip(media: hd, sourceStart: 0, duration: 1.5)]); var s = ExportSettings(); s.videoMbps = 8
        let o = dir.appendingPathComponent("c.mov")
        let t = Task { try await ProjectExporter.export(p, to: o, settings: s, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30) }
        try await Task.sleep(nanoseconds: 120_000_000); t.cancel()
        _ = try? await t.value
        XCTAssertFalse(names.contains { $0.contains("partial") }, "no temporary left: \(names)")
    }
}
