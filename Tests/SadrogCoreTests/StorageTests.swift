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
}
