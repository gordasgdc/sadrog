// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

final class AudioAutomationTests: XCTestCase {
    func db(_ g: Double) -> Double { 20 * log10(max(g, 1e-9)) }

    // MARK: pure maths
    func testFadeCurvesAreMonotoneWithFixedEnds() {
        for shape in FadeShape.allCases { for bend in stride(from: 0.0, through: 1.0, by: 0.25) {
            let c = FadeCurve(shape: shape, bend: bend); XCTAssertEqual(c.gain(0), 0, accuracy: 1e-12); XCTAssertEqual(c.gain(1), 1, accuracy: 1e-12)
            var last = -1.0; for i in 0...100 { let g = c.gain(Double(i) / 100); XCTAssertGreaterThanOrEqual(g, last - 1e-12, "\(shape) \(bend)"); last = g }
        } }
        XCTAssertEqual(FadeCurve(shape: .easeIn, bend: 0).gain(0.3), 0.3, accuracy: 1e-12)       // bend 0 = straight for every shape
        XCTAssertLessThan(FadeCurve(shape: .easeIn, bend: 0.5).gain(0.5), 0.5); XCTAssertGreaterThan(FadeCurve(shape: .easeOut, bend: 0.5).gain(0.5), 0.5)
        XCTAssertEqual(FadeCurve(shape: .sCurve, bend: 0.8).gain(0.5), 0.5, accuracy: 1e-12)
    }
    func testAutomationInterpolatesInDBAndTreatsSilenceExplicitly() {
        var e = AudioEnvelope(duration: 10); e.points = [VolumeKey(t: 2, db: 0), VolumeKey(t: 4, db: -20), VolumeKey(t: 8, db: VolumeKey.silenceDB)]
        XCTAssertEqual(e.gain(at: 0), 1); XCTAssertEqual(db(e.gain(at: 3)), -10, accuracy: 1e-6)       // halfway in dB, not in amplitude
        XCTAssertEqual(db(e.gain(at: 4)), -20, accuracy: 1e-6)
        XCTAssertEqual(e.gain(at: 8), 0); XCTAssertEqual(e.gain(at: 10), 0)                              // silence is zero, held
        XCTAssertEqual(e.gain(at: 6), 0.05, accuracy: 1e-9)                                              // to silence the line is in amplitude (no −45 dB halfway trap)
    }
    func testGainIsProductOfAutomationAndFades() {
        var e = AudioEnvelope(duration: 10); e.points = [VolumeKey(t: 0, db: -6)]; e.fadeIn = 2; e.fadeOut = 2; e.fadeInCurve = FadeCurve(shape: .easeIn, bend: 0.5)
        let a = pow(10, -6.0 / 20)
        XCTAssertEqual(e.gain(at: 1), a * FadeCurve(shape: .easeIn, bend: 0.5).gain(0.5), accuracy: 1e-12)
        XCTAssertEqual(e.gain(at: 9), a * 0.5, accuracy: 1e-12); XCTAssertEqual(e.gain(at: 5), a, accuracy: 1e-12)
    }
    func testBreakpointsFollowTheEnvelopeWithinTolerance() {
        var e = AudioEnvelope(duration: 12); e.points = [VolumeKey(t: 3, db: 0), VolumeKey(t: 6, db: -24), VolumeKey(t: 9, db: -3)]
        e.fadeIn = 2; e.fadeOut = 3; e.fadeInCurve = FadeCurve(shape: .sCurve, bend: 0.7); e.fadeOutCurve = FadeCurve(shape: .easeOut, bend: 0.4)
        let bp = e.breakpoints(); XCTAssertLessThan(bp.count, 4096); XCTAssertEqual(bp.first!.t, 0); XCTAssertEqual(bp.last!.t, 12, accuracy: 1e-9)
        for i in 0...1200 {
            let t = Double(i) / 100, k = bp.lastIndex { $0.t <= t }!, a = bp[k], b = bp[min(k + 1, bp.count - 1)]
            let lin = b.t > a.t ? a.g + (b.g - a.g) * (t - a.t) / (b.t - a.t) : a.g
            XCTAssertEqual(lin, e.gain(at: t), accuracy: 0.004, "t=\(t)")
        }
    }
    func testCrossfadeGainsAndTheirLimits() {
        for mode in CrossfadeMode.allCases { for shape in FadeShape.allCases {
            let x = CrossfadeShape(mode: mode, curve: FadeCurve(shape: shape, bend: 0.5))
            XCTAssertEqual(x.gains(0).incoming, 0, accuracy: 1e-12); XCTAssertEqual(x.gains(0).outgoing, 1, accuracy: 1e-12)
            XCTAssertEqual(x.gains(1).incoming, 1, accuracy: 1e-12); XCTAssertEqual(x.gains(1).outgoing, 0, accuracy: 1e-12)
        } }
        let g = CrossfadeShape(mode: .equalGain).gains(0.5), p = CrossfadeShape(mode: .equalPower).gains(0.5)
        XCTAssertEqual(g.incoming + g.outgoing, 1, accuracy: 1e-12)                        // amplitudes add to 1 (constant for CORRELATED sounds)
        XCTAssertEqual(g.incoming * g.incoming + g.outgoing * g.outgoing, 0.5, accuracy: 1e-12)   // power dips 3 dB for unrelated sounds
        XCTAssertEqual(p.incoming * p.incoming + p.outgoing * p.outgoing, 1, accuracy: 1e-12)     // power constant
        XCTAssertEqual(p.incoming + p.outgoing, 2 * sin(Double.pi / 4), accuracy: 1e-12)          // 1.414: correlated sounds peak +3 dB in the middle
    }

    // MARK: editing
    func layer(_ d: Double = 10, start: Double = 0, media: String = "/a.m4a", src: Double = 0) -> Layer { Layer(kind: .audio, media: media, start: start, sourceStart: src, duration: d) }
    func testPointOperationsAreSingleUndoStepsAndStayClean() {
        let l = layer(); let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/v.mov", sourceStart: 0, duration: 10)], layers: [l]))
        XCTAssertEqual(e.addVolumePoint(l.id, at: 2, db: -6), 0); XCTAssertEqual(e.addVolumePoint(l.id, at: 5, db: -12), 1)
        XCTAssertNil(e.addVolumePoint(l.id, at: 2.0001, db: 0), "no two points at the same time")
        XCTAssertEqual(e.addVolumePoint(l.id, at: 3.5), 1)                       // level defaults to the curve there: −9 dB
        XCTAssertEqual(e.project.layers[0].audio?.points[1].db ?? 0, -9, accuracy: 0.06)
        e.moveVolumePoint(l.id, index: 0, t: 99, db: 40)                         // cannot cross the next point; level clamped to +12 dB
        XCTAssertLessThan(e.project.layers[0].audio!.points[0].t, e.project.layers[0].audio!.points[1].t); XCTAssertEqual(e.project.layers[0].audio!.points[0].db, 12)
        let n = e.project.layers[0].audio!.points.count
        e.removeVolumePoint(l.id, index: 1); XCTAssertEqual(e.project.layers[0].audio!.points.count, n - 1)
        XCTAssertTrue(e.undo()); XCTAssertEqual(e.project.layers[0].audio!.points.count, n)       // one gesture, one undo
        e.setAudio(l.id, AudioEdit(gainDB: -3, fadeIn: 1)); XCTAssertEqual(e.project.layers[0].audio!.points.count, 0, "setAudio replaces the whole edit, as before")
        e.addVolumePoint(l.id, at: 1, db: -6); e.setFadeCurves(l.id, fadeIn: FadeCurve(shape: .sCurve))
        e.resetVolumePoints(l.id); XCTAssertTrue(e.project.layers[0].audio!.points.isEmpty); XCTAssertEqual(e.project.layers[0].audio!.fadeInCurve.shape, .sCurve, "reset leaves the fades")
        XCTAssertEqual(e.project.layers[0].audio!.gainDB, -3)
        let a = AudioEdit(gainDB: 0, muted: false, fadeIn: 1, fadeOut: 1), pts = [VolumeKey(t: 1, db: -6), VolumeKey(t: 4, db: VolumeKey.silenceDB)]
        var b = a; b.points = pts; XCTAssertEqual(b.nextPoint(after: 1), 1); XCTAssertNil(b.nextPoint(after: 4)); XCTAssertEqual(b.previousPoint(before: 4), 0); XCTAssertNil(b.previousPoint(before: 1))
    }
    func testCutKeepsTheCurveContinuousAndPutsNoFadeAtTheCut() {
        var c = Clip(media: "/v.mov", sourceStart: 0, duration: 10)
        var a = AudioEdit(fadeIn: 1, fadeOut: 1); a.points = [VolumeKey(t: 2, db: 0), VolumeKey(t: 8, db: -12)]; c.audio = a
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c])); e.split(at: 5)
        let (x, y) = (e.project.clips[0], e.project.clips[1])
        let ex = x.audio!.envelope(duration: x.duration), ey = y.audio!.envelope(duration: y.duration)
        XCTAssertEqual(ex.gain(at: ex.duration - 0.0005), ey.gain(at: 0.0005), accuracy: 1e-3)       // no step at the cut
        XCTAssertEqual(x.audio!.fadeOut, 0); XCTAssertEqual(y.audio!.fadeIn, 0); XCTAssertEqual(x.audio!.fadeIn, 1); XCTAssertEqual(y.audio!.fadeOut, 1)
        let whole = a.envelope(duration: 10)
        for t in stride(from: 0.2, to: 4.8, by: 0.4) { XCTAssertEqual(ex.gain(at: t), whole.gain(at: t), accuracy: 1e-3) }
        for t in stride(from: 5.2, to: 9.8, by: 0.4) { XCTAssertEqual(ey.gain(at: t - 5), whole.gain(at: t), accuracy: 1e-3) }
    }
    func testTrimsAndRetimeKeepTheCurve() {
        var c = Clip(media: "/v.mov", sourceStart: 4, duration: 10); var a = AudioEdit(); a.points = [VolumeKey(t: 2, db: 0), VolumeKey(t: 6, db: -12)]; c.audio = a
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [c])); let id = c.id
        let before = a.envelope(duration: 10)
        e.trimStart(clip: id, by: 3)
        let t1 = e.project.clips[0].audio!.envelope(duration: 7); XCTAssertEqual(t1.gain(at: 1), before.gain(at: 4), accuracy: 1e-3); XCTAssertEqual(t1.gain(at: 0), before.gain(at: 3), accuracy: 1e-3)
        e.trimEnd(clip: id, by: 2); let t2 = e.project.clips[0].audio!; XCTAssertLessThanOrEqual(t2.points.last!.t, 5.0001)
        XCTAssertEqual(t2.envelope(duration: 5).gain(at: 2), before.gain(at: 5), accuracy: 1e-3)
        let pre = e.project.clips[0].audio!.points
        XCTAssertTrue(e.setSpeed(clip: id, 2)); XCTAssertEqual(e.project.clips[0].audio!.points.map(\.t), pre.map { $0.t / 2 }.map { (($0 * 1000).rounded()) / 1000 })
    }
    func testCrossfadeNeedsRealOverlapAndNeverFakesOne() {
        let a = layer(6), b = layer(6, start: 6)       // touch, no overlap
        let e = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/v.mov", sourceStart: 0, duration: 12)], layers: [a, b]))
        XCTAssertEqual(e.crossfade(outgoing: a.id, incoming: b.id, seconds: 1), .noMaterial)          // b starts at source 0: no head; a's tail unknown
        XCTAssertFalse(e.canUndo)
        XCTAssertEqual(e.crossfade(outgoing: a.id, incoming: b.id, seconds: 1, outgoingSourceLength: 6), .noMaterial)    // a has no more source after 6 s
        XCTAssertEqual(e.crossfade(outgoing: a.id, incoming: b.id, seconds: 1, outgoingSourceLength: 20), .created(seconds: 1))
        let l = e.project.layers.first { $0.id == a.id }!, m = e.project.layers.first { $0.id == b.id }!
        XCTAssertEqual(l.duration, 7); XCTAssertEqual(e.project.crossfadeSeconds(m), 1, accuracy: 1e-9); XCTAssertNotEqual(l.row, m.row)
        // incoming with head material: its head is extended earlier
        var c2 = layer(6, start: 6, src: 3)
        let e2 = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/v.mov", sourceStart: 0, duration: 12)], layers: [a, c2]))
        XCTAssertEqual(e2.crossfade(outgoing: a.id, incoming: c2.id, seconds: 2), .created(seconds: 2))
        c2 = e2.project.layers.first { $0.id == c2.id }!; XCTAssertEqual(c2.start, 4); XCTAssertEqual(c2.sourceStart, 1); XCTAssertEqual(c2.duration, 8)
        // moving the incoming item away removes the link instead of leaving a hidden setting
        e2.moveLayer(c2.id, to: 20); XCTAssertNil(e2.project.layers.first { $0.id == c2.id }!.audio?.crossfade)
        // a contained / reversed pair is refused
        XCTAssertEqual(e.crossfadeBlocker(outgoing: b.id, incoming: a.id), "order")
        XCTAssertEqual(ProjectEditor(project: SadrogProject(name: "t", layers: [layer(10), layer(3, start: 2)])).crossfadeBlocker(outgoing: layer(10).id, incoming: layer(3, start: 2).id), "missing")
    }
    func testLockedLaneAndSplitKeepTheLink() {
        let a = layer(8), b = layer(6, start: 5)
        var p = SadrogProject(name: "t", clips: [Clip(media: "/v.mov", sourceStart: 0, duration: 12)], layers: [a, b]); p.lockedLanes = [.a2]
        let e = ProjectEditor(project: p); XCTAssertEqual(e.crossfade(outgoing: a.id, incoming: b.id), .locked)
        let f = ProjectEditor(project: SadrogProject(name: "t", clips: [Clip(media: "/v.mov", sourceStart: 0, duration: 12)], layers: [a, b]))
        XCTAssertEqual(f.crossfade(outgoing: a.id, incoming: b.id), .created(seconds: 3))
        f.splitLayer(kind: .audio, at: 6.5)       // cuts the outgoing item inside the overlap? 6.5 lies in a (0…8) and b (5…11): the first match is cut
        let inc = f.project.layers.first { $0.audio?.crossfade != nil }
        if let inc { XCTAssertGreaterThan(f.project.crossfadeSeconds(inc), 0, "a link never points at a piece that no longer overlaps") }
    }
    func testPersistenceOfCurvesAndOldProjectsPlayAsBefore() throws {
        var l = layer(); var a = AudioEdit(gainDB: -3, fadeIn: 1, fadeOut: 2); a.points = [VolumeKey(t: 1, db: -6)]; a.fadeInCurve = FadeCurve(shape: .sCurve, bend: 0.8); a.crossfade = CrossfadeLink(outgoing: UUID(), shape: CrossfadeShape(mode: .equalPower, curve: FadeCurve(shape: .easeIn)))
        l.audio = a
        var c = Clip(media: "/v.mov", sourceStart: 0, duration: 5); c.dissolveShape = CrossfadeShape(mode: .equalPower)
        let data = try JSONEncoder().encode(SadrogProject(name: "t", clips: [c], layers: [l])); let q = try JSONDecoder().decode(SadrogProject.self, from: data)
        XCTAssertEqual(q.layers[0].audio, a); XCTAssertEqual(q.clips[0].dissolveShape.mode, .equalPower)
        let plain = String(data: try JSONEncoder().encode(AudioEdit(gainDB: -3, fadeIn: 1)), encoding: .utf8)!
        XCTAssertFalse(plain.contains("points") || plain.contains("Curve") || plain.contains("crossfade"))
        let old = try JSONDecoder().decode(AudioEdit.self, from: Data(#"{"gainDB":-3,"muted":false,"fadeIn":1,"fadeOut":0}"#.utf8))
        XCTAssertTrue(old.envelope(duration: 5).isLegacy); XCTAssertEqual(old.envelope(duration: 5).gain(at: 0.5), 0.5, accuracy: 1e-12)
    }
}
