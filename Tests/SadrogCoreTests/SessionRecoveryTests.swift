import XCTest
@testable import SadrogCore

final class SessionRecoveryTests: XCTestCase {
    func folder(media: Data?) throws -> URL {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-r-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        if let m = media { try m.write(to: f.appendingPathComponent("capture.mov")) }
        try SessionJournal(id: "x", state: .recording, startedAt: Date(), mediaFile: "capture.mov", fragmentSeconds: 10, width: 1, height: 1, fps: 30, note: "").write(to: f)
        return f
    }
    func testGarbageMediaIsUnreadableAndMarkedFailed() async throws {
        let f = try folder(media: Data(repeating: 7, count: 4096)); defer { try? FileManager.default.removeItem(at: f) }
        let (j, r) = try await SessionRecovery.resolve(folder: f)
        guard case .unreadable = r else { return XCTFail() }
        XCTAssertEqual(j.state, .failed)
        XCTAssertEqual(SessionJournal.unfinished(under: f.deletingLastPathComponent()).filter { $0.folder == f }.count, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.appendingPathComponent("capture.mov").path), "media must never be deleted")
    }
    func testMissingMediaIsUnreadable() async throws {
        let f = try folder(media: nil); defer { try? FileManager.default.removeItem(at: f) }
        let r = await SessionRecovery.inspect(folder: f)
        guard case .unreadable = r else { return XCTFail() }
    }
}
