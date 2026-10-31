import XCTest
@testable import SadrogCore

final class UserManualTests: XCTestCase {
    func testEachLanguageHasItsOwnStablePDFAddress() {
        let urls = AppLanguage.allCases.map { UserManual.url($0).absoluteString }
        XCTAssertEqual(urls, ["https://gordas.dev/sadrog/manual/SADROG-Manual-RO.pdf", "https://gordas.dev/sadrog/manual/SADROG-Manual-EN.pdf", "https://gordas.dev/sadrog/manual/SADROG-Manual-ES.pdf"])
    }
}
