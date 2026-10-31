// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// The central RO/EN/ES catalog: lookups, placeholders, fallback, and that every key used in the sources is translated in all three.
final class LocalizationTests: XCTestCase {
    func testLookupFormatAndFallback() {
        XCTAssertEqual(L10n.t("Adaugă sursă", .en), "Add source"); XCTAssertEqual(L10n.t("Adaugă sursă", .es), "Añadir fuente")
        XCTAssertEqual(L10n.t("Adaugă sursă", .ro), "Adaugă sursă")
        XCTAssertEqual(L10n.t("text care nu e în catalog", .en), "text care nu e în catalog", "missing key: Romanian, never empty")
        UserDefaults.standard.set("es", forKey: "sadrog.language"); defer { UserDefaults.standard.removeObject(forKey: "sadrog.language") }
        XCTAssertEqual(L10n.f("Începe în %d s", 5), "Empieza en 5 s")
    }
    func testEveryKeyHasEnglishAndSpanish() throws {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/env"); p.arguments = ["python3", "-I", #filePath.replacingOccurrences(of: "Tests/SadrogCoreTests/LocalizationTests.swift", with: "scripts/l10n_check.py")]
        let pipe = Pipe(); p.standardOutput = pipe; try p.run(); p.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        XCTAssertEqual(p.terminationStatus, 0, out)
    }
    /// Every translation keeps exactly the placeholders of the Romanian key (a missing %@ would crash or show wrong values).
    func testPlaceholdersMatchInEveryLanguage() throws {
        let rx = try NSRegularExpression(pattern: "%[+]?[.0-9]*[@dfs%]")
        func ph(_ s: String) -> [String] { rx.matches(in: s, range: NSRange(s.startIndex..., in: s)).map { String(s[Range($0.range, in: s)!]) }.sorted() }
        for (ro, t) in L10nCatalog.entries {
            XCTAssertEqual(ph(ro), ph(t.0), "EN: \(ro)"); XCTAssertEqual(ph(ro), ph(t.1), "ES: \(ro)")
            XCTAssertFalse(t.0.isEmpty || t.1.isEmpty, ro)
        }
    }
}
