// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Two distinct recorded sounds: editing one, or copying / cutting / trimming the clip, never changes the other's gain, switch or chain.
final class SourceSoundIsolationTests: XCTestCase {
    private func fixture() -> (ProjectEditor, Clip.ID) {
        let clip = Clip(media: "/x.mov", sourceStart: 0, duration: 10)
        let ed = ProjectEditor(project: SadrogProject(name: "t", clips: [clip]))
        ed.setSourceGain(0, dB: -6); ed.setSourceMuted(1, true)
        return (ed, clip.id)
    }
    private func snapshot(_ p: SadrogProject) -> ([Int: Double], Set<Int>, Set<Int>) { (p.sourceGains, p.mutedSources, Set(p.sourceEffects.keys)) }
    func testEditingOneSourceLeavesTheOtherUntouched() {
        let (ed, _) = fixture()
        ed.setSourceGain(1, dB: 3)
        XCTAssertEqual(ed.project.gain(ofSource: 0), -6); XCTAssertEqual(ed.project.gain(ofSource: 1), 3)
        XCTAssertTrue(ed.project.mutedSources.contains(1)); XCTAssertFalse(ed.project.mutedSources.contains(0))
        ed.setSourceMuted(0, true); XCTAssertEqual(ed.project.gain(ofSource: 1), 3)
        ed.undo(); ed.undo(); XCTAssertEqual(ed.project.gain(ofSource: 0), -6); XCTAssertEqual(ed.project.gain(ofSource: 1), 0)
    }
    func testCopyCutAndTrimKeepEverySourceSetting() {
        let (ed, clip) = fixture(); let before = snapshot(ed.project)
        ed.split(at: 4); ed.trimEnd(clip: clip, by: 1); _ = ed.duplicate(items: [clip])
        XCTAssertEqual(snapshot(ed.project).0, before.0); XCTAssertEqual(snapshot(ed.project).1, before.1); XCTAssertEqual(snapshot(ed.project).2, before.2)
    }
}
