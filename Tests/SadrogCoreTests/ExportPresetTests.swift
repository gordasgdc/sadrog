import XCTest
@testable import SadrogCore

final class ExportPresetTests: XCTestCase {
    private func store() -> ExportPresetStore { ExportPresetStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-preset-\(UUID().uuidString).json")) }
    func testBuiltInsRoundTripToSettings() {
        for p in ExportPreset.builtIns { XCTAssertEqual(ExportPreset(id: p.id, name: p.name, settings: p.settings()).settings(), p.settings()) }
        XCTAssertEqual(ExportPreset.builtIns.first { $0.id == "compact720" }!.settings().size, .longSide(1280))
        XCTAssertEqual(ExportPreset.builtIns.first { $0.id == "fast" }!.settings().mode, .copy)
    }
    func testPersonalPresetsSurviveReloadAndDefault() {
        var st = store(); var s = ExportSettings(); s.mode = .master; s.proRes = .p4444; s.fps = 30
        let p = st.save(name: "Master 30", settings: s)!
        st.setDefault(p.id)
        let again = ExportPresetStore(url: st.url)
        XCTAssertEqual(again.personal.map(\.name), ["Master 30"]); XCTAssertEqual(again.defaultSettings.proRes, .p4444); XCTAssertEqual(again.defaultSettings.fps, 30)
        XCTAssertEqual(again.matching(s)?.id, p.id)
        var st2 = again; st2.delete(id: p.id)
        XCTAssertNil(st2.defaultID); XCTAssertEqual(st2.defaultSettings, ExportSettings())
    }
    func testRejectsEmptyAndBuiltInNamesAndReplacesSameName() {
        var st = store()
        XCTAssertNil(st.save(name: "  ", settings: ExportSettings())); XCTAssertNil(st.save(name: ExportPreset.builtIns[0].name, settings: ExportSettings()))
        st.save(name: "A", settings: ExportSettings()); var s = ExportSettings(); s.mode = .copy; st.save(name: "A", settings: s)
        XCTAssertEqual(st.personal.count, 1); XCTAssertEqual(st.personal[0].settings().mode, .copy)
    }
    func testCorruptFileMeansNoPersonalPresets() throws {
        let st = store(); try Data("not json".utf8).write(to: st.url)
        XCTAssertTrue(st.personal.isEmpty); XCTAssertEqual(st.defaultSettings, ExportSettings())
    }
    func testEstimateOnlyForProcessedVideoAndScalesWithSize() {
        let p = SadrogProject(name: "t")
        var s = ExportSettings(); s.mode = .compressed
        var a = ExportPlan.video(p, documentSize: CGSize(width: 1920, height: 1080), documentFPS: 30, settings: s, copyPossible: true); a.duration = 60
        var b = a; b.width = 1280; b.height = 720
        XCTAssertGreaterThan(ExportEstimate.bytes(a, settings: s)!, ExportEstimate.bytes(b, settings: s)!)
        s.mode = .copy; XCTAssertNil(ExportEstimate.bytes(a, settings: s))
        s.mode = .master; a.duration = 60; XCTAssertGreaterThan(ExportEstimate.bytes(a, settings: s)!, 1_000_000_000)
    }
}
