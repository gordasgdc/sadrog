import XCTest
@testable import SadrogCore

final class StorageTests: XCTestCase {
    func testMissingDestinationThrows() {
        let d = Destination(url: URL(fileURLWithPath: "/Volumes/__sadrog_absent__/x"))
        XCTAssertThrowsError(try d.validate()) { XCTAssertEqual($0 as? StorageError, .destinationMissing("/Volumes/__sadrog_absent__/x")) }
    }
    func testInsufficientSpaceThrows() throws {
        let d = Destination(url: FileManager.default.temporaryDirectory)
        XCTAssertThrowsError(try d.validate(requiredBytes: Int64.max)) {
            guard case StorageError.notEnoughSpace = $0 else { return XCTFail("wrong error \($0)") }
        }
    }
    func testValidTempDestination() throws {
        try Destination(url: FileManager.default.temporaryDirectory).validate(requiredBytes: 1)
    }
    /// External volumes report 0 "important usage" capacity although they have room (found in the GUI on 2026-11-12: every export to such a disk was refused).
    func testFreeSpaceOnAnExternalVolumeIsNotZero() throws {
        let ext = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp"
        try XCTSkipUnless(FileManager.default.fileExists(atPath: ext), "external test storage not available")
        XCTAssertGreaterThan(try Destination(url: URL(fileURLWithPath: ext)).availableBytes(), 1_000_000)
        XCTAssertNoThrow(try Destination(url: URL(fileURLWithPath: ext)).validate(requiredBytes: 1_000_000))
    }
    func testStorageErrorsAreReadable() {
        let e = StorageError.notEnoughSpace(requiredBytes: 500_000_000, availableBytes: 1000)
        XCTAssertFalse(e.localizedDescription.contains("StorageError")); XCTAssertTrue(e.localizedDescription.contains("500"))
    }
}
