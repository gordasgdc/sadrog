// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

final class RecordingFinishTests: XCTestCase {
    func testDefaultNameUsesDateAndTime() {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 31; c.hour = 3; c.minute = 7
        let d = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(RecordingFinish.defaultName(for: d, prefix: "Înregistrare", timeZone: .current), "Înregistrare 2026-10-31 03.07")
    }
    func testCleanNameTrimsAndRemovesPathCharacters() {
        XCTAssertEqual(RecordingFinish.cleanName("  Demo / v2: final  ", fallback: "X"), "Demo v2 final")
        XCTAssertEqual(RecordingFinish.cleanName("   ", fallback: "Proiect nou"), "Proiect nou")
        XCTAssertEqual(RecordingFinish.cleanName("///", fallback: "Proiect nou"), "Proiect nou")
    }
    func testFormatFollowsTheRecordingWithEvenSides() {
        let f = RecordingFinish.format(width: 1281, height: 721, fps: 29.97)
        XCTAssertEqual(f.width, 1280); XCTAssertEqual(f.height, 720); XCTAssertEqual(f.fps, 29.97, accuracy: 0.001)
    }
    func testFormatClampsAbsurdValues() {
        let f = RecordingFinish.format(width: 0, height: 0, fps: 0)
        XCTAssertGreaterThanOrEqual(f.width, 2); XCTAssertGreaterThanOrEqual(f.height, 2); XCTAssertEqual(f.fps, 30)
    }

    private func scratch() throws -> URL {
        guard FileManager.default.fileExists(atPath: "/Volumes/CristiGordas/TESTE") else { throw XCTSkip("external storage") }
        let u = URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/finish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true); return u
    }
    func testUnusedTemporaryDocumentIsDiscardedButNeverOneWithContent() throws {
        let root = try scratch(); defer { try? FileManager.default.removeItem(at: root) }
        let f = RecordingFinish.format(width: 1920, height: 1080, fps: 30)
        let empty = try RecordingFinish.createDocument(name: "Gol", format: f, in: root)
        XCTAssertTrue(FileManager.default.fileExists(atPath: empty.appendingPathComponent(RecordingFinish.documentFile).path))
        XCTAssertTrue(RecordingFinish.discardIfUnused(empty, toTrash: false)); XCTAssertFalse(FileManager.default.fileExists(atPath: empty.path), "removed")
        // content in the project keeps it
        let used = try RecordingFinish.createDocument(name: "Plin", format: f, in: root)
        var p = try ProjectStore.load(from: used.appendingPathComponent(RecordingFinish.documentFile)); p.clips = [Clip(media: "/x.mov", sourceStart: 0, duration: 2)]
        try ProjectStore.save(p, to: used.appendingPathComponent(RecordingFinish.documentFile))
        XCTAssertFalse(RecordingFinish.discardIfUnused(used, toTrash: false)); XCTAssertTrue(FileManager.default.fileExists(atPath: used.path))
        // an extra file in the folder (the user's own) keeps it too
        let extra = try RecordingFinish.createDocument(name: "Extra", format: f, in: root)
        try Data("x".utf8).write(to: extra.appendingPathComponent("note.txt"))
        XCTAssertFalse(RecordingFinish.discardIfUnused(extra, toTrash: false)); XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        // not a document at all
        XCTAssertFalse(RecordingFinish.discardIfUnused(root.appendingPathComponent("nu-exista"), toTrash: false))
    }
}
