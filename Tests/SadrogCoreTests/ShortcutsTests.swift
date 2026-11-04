import XCTest
@testable import SadrogCore

final class ShortcutsTests: XCTestCase {
    func testDefaultsHaveNoConflictsAndUniqueIDs() {
        XCTAssertEqual(Set(Commands.all.map(\.id)).count, Commands.all.count)
        XCTAssertTrue(ShortcutMap().conflicts.isEmpty, "\(ShortcutMap().conflicts)")
        for d in Commands.all { if let c = d.defaultCombo { XCTAssertFalse(Commands.reserved.contains(c), d.id) } }
    }
    func testAssignConflictReplaceRemoveReset() {
        var m = ShortcutMap()
        XCTAssertEqual(m.set("tool.blade", KeyCombo("a")), .conflict(["tool.select"]))
        XCTAssertEqual(m.combo("tool.blade"), KeyCombo("b"))                // refused: unchanged
        XCTAssertEqual(m.set("tool.blade", KeyCombo("a"), replacing: true), .ok)
        XCTAssertEqual(m.combo("tool.blade"), KeyCombo("a")); XCTAssertNil(m.combo("tool.select"))
        XCTAssertTrue(m.conflicts.isEmpty)
        XCTAssertEqual(m.set("tool.blade", KeyCombo("c", command: true)), .reserved)
        XCTAssertEqual(m.set("edit.undo", KeyCombo("y", command: true)), .locked)
        m.reset("tool.blade"); m.reset("tool.select")
        XCTAssertEqual(m.combo("tool.blade"), KeyCombo("b")); XCTAssertEqual(m.combo("tool.select"), KeyCombo("a"))
        XCTAssertFalse(m.isCustomised("tool.blade"))
        m.remove("tool.volume"); XCTAssertNil(m.combo("tool.volume")); XCTAssertTrue(m.isCustomised("tool.volume"))
        m.resetAll(); XCTAssertEqual(m, ShortcutMap())
    }
    func testPersistenceRoundTripAndDisplay() {
        var m = ShortcutMap(); _ = m.set("timeline.split", KeyCombo("j", command: true, shift: true)); m.remove("tool.snap")
        let back = ShortcutMap.decoded(m.encoded())
        XCTAssertEqual(back, m); XCTAssertEqual(back.combo("timeline.split")?.display, "⇧⌘J"); XCTAssertNil(back.combo("tool.snap"))
        XCTAssertEqual(KeyCombo("space").display, "Space"); XCTAssertEqual(KeyCombo("1", option: true, control: true).display, "⌃⌥1")
        XCTAssertEqual(ShortcutMap.decoded(Data("garbage".utf8)), ShortcutMap())
    }
    func testPlainKeysAreFlaggedSoTheyNeverActWhileTyping() {
        XCTAssertTrue(Commands.def("tool.blade")!.defaultCombo!.isPlain)
        XCTAssertTrue(Commands.def("play.toggle")!.defaultCombo!.isPlain)
        XCTAssertFalse(Commands.def("timeline.split")!.defaultCombo!.isPlain)
        XCTAssertFalse(Commands.def("timeline.marker")!.defaultCombo!.isPlain)
    }
}
