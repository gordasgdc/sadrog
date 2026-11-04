// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Archive = project + copies of its media in one folder; originals untouched; moved archives still find their media.
final class ProjectArchiveTests: XCTestCase {
    let root = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/archive-\(UUID().uuidString)")
    override func setUpWithError() throws { try FileManager.default.createDirectory(at: root.appendingPathComponent("src/rec"), withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    func fixture() throws -> SadrogProject {
        let a = root.appendingPathComponent("src/rec/a.mov"), b = root.appendingPathComponent("src/b.mov")
        try Data(repeating: 1, count: 3000).write(to: a); try Data(repeating: 2, count: 2000).write(to: b)
        try Data("{}".utf8).write(to: root.appendingPathComponent("src/rec/\(SourcesManifest.fileName)"))
        var p = SadrogProject(name: "Demo", clips: [Clip(media: a.path, sourceStart: 0, duration: 3)], library: [a.path, b.path])
        p.layers = [Layer(kind: .video, media: b.path, start: 0, duration: 1)]
        return p
    }
    func testCopiesMediaRewritesPathsAndLeavesOriginals() throws {
        let p = try fixture(); let out = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let r = try ProjectArchive.create(p, in: out)
        XCTAssertEqual(r.copied, 2); XCTAssertEqual(r.bytes, 5000); XCTAssertTrue(r.missing.isEmpty); XCTAssertEqual(r.folder.lastPathComponent, "Demo.sadrogproj")
        let q = try ProjectStore.load(from: r.folder)
        XCTAssertTrue(q.archived); XCTAssertTrue(q.clips[0].media.hasPrefix(r.folder.path + "/Media/")); XCTAssertTrue(FileManager.default.fileExists(atPath: q.clips[0].media))
        XCTAssertEqual(q.layers[0].media, q.library[1]); XCTAssertTrue(ProjectStore.missingMedia(q).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: URL(fileURLWithPath: q.clips[0].media).deletingLastPathComponent().appendingPathComponent(SourcesManifest.fileName).path), "sources.json travels with its recording")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.clips[0].media)); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: p.clips[0].media)).count, 3000)
        XCTAssertThrowsError(try ProjectArchive.create(p, in: out), "never overwrites an existing archive")
    }
    func archive(_ p: SadrogProject, to name: String) throws -> URL {
        let out = root.appendingPathComponent(name); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        return try ProjectArchive.create(p, in: out).folder
    }
    func testMovedArchiveFindsItsMedia() throws {
        let r = try archive(try fixture(), to: "out")
        let moved = root.appendingPathComponent("moved/Demo.sadrogproj"); try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: r, to: moved)
        let q = try ProjectStore.load(from: moved)
        XCTAssertTrue(q.clips[0].media.hasPrefix(moved.path), "paths follow the moved folder"); XCTAssertEqual(ProjectStore.missingMedia(q), [])
    }
    func testCopyOfArchiveIsIndependentOfTheOriginal() throws {
        let fm = FileManager.default, a = try archive(try fixture(), to: "A")
        let b = root.appendingPathComponent("B/Demo.sadrogproj"); try fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: a, to: b)
        let qa = try ProjectStore.load(from: a), qb = try ProjectStore.load(from: b)
        XCTAssertTrue(qa.clips[0].media.hasPrefix(a.path)); XCTAssertTrue(qb.clips[0].media.hasPrefix(b.path), "B uses exclusively B's media")
        XCTAssertTrue(qb.layers.allSatisfy { $0.media.hasPrefix(b.path) }); XCTAssertTrue(qb.library.allSatisfy { $0.hasPrefix(b.path) })
        // A becomes unavailable (moved away): B is untouched
        try fm.moveItem(at: a, to: root.appendingPathComponent("A-gone"))
        let qb2 = try ProjectStore.load(from: b); XCTAssertEqual(ProjectStore.missingMedia(qb2), []); XCTAssertEqual(qb2, qb)
        // saving B keeps it self-contained (relative on disk) and reloads the same
        try ProjectStore.save(qb2, to: b); XCTAssertEqual(try ProjectStore.load(from: b), qb2)
        let raw = try String(contentsOf: b.appendingPathComponent(ProjectStore.fileName), encoding: .utf8)
        XCTAssertFalse(raw.contains(a.path)); XCTAssertFalse(raw.contains(root.path), "no absolute path of any archive on disk")
    }
    func testOrdinaryProjectIsNotTreatedAsArchive() throws {
        let p = try fixture(); let f = root.appendingPathComponent("plain.sadrogproj")
        try ProjectStore.save(p, to: f); let q = try ProjectStore.load(from: f)
        XCTAssertFalse(q.archived); XCTAssertEqual(q.clips[0].media, p.clips[0].media, "media stays where it was recorded")
    }
    func testIdenticalFilenamesInDifferentDirectoriesStaySeparate() throws {
        let d1 = root.appendingPathComponent("src/one"), d2 = root.appendingPathComponent("src/two")
        for d in [d1, d2] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data(repeating: 7, count: 100).write(to: d1.appendingPathComponent("clip.mov")); try Data(repeating: 9, count: 200).write(to: d2.appendingPathComponent("clip.mov"))
        let p = SadrogProject(name: "Same", clips: [Clip(media: d1.appendingPathComponent("clip.mov").path, sourceStart: 0, duration: 1), Clip(media: d2.appendingPathComponent("clip.mov").path, sourceStart: 0, duration: 1)], library: [])
        let q = try ProjectStore.load(from: try archive(p, to: "out"))
        XCTAssertNotEqual(q.clips[0].media, q.clips[1].media)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: q.clips[0].media)).count, 100); XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: q.clips[1].media)).count, 200)
    }
    func testMissingMediaAbortsWithoutAnyArchive() throws {
        var p = try fixture(); p.library.append("/nonexistent/lost.mov")
        let out = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        XCTAssertThrowsError(try ProjectArchive.create(p, in: out)) { XCTAssertEqual($0 as? ProjectArchive.ArchiveError, .missing(["/nonexistent/lost.mov"])) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "nothing, not even a partial folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.clips[0].media), "originals untouched")
    }
    func testCancellationLeavesNoPartialArchive() async throws {
        let p = try fixture(); let out = root.appendingPathComponent("out"); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let t = Task { () throws -> URL in
            withUnsafeCurrentTask { $0?.cancel() }
            return try ProjectArchive.create(p, in: out).folder
        }
        do { _ = try await t.value; XCTFail("must be cancelled") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), [], "cancelled: no folder, no .partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: p.clips[0].media))
    }
}
