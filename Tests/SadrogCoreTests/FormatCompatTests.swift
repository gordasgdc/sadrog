// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
@testable import SadrogCore

/// Format 13 (locked lanes, names) must open every earlier format unchanged, and a project saved by this build must open again identically.
final class FormatCompatTests: XCTestCase {
    static let id1 = "1836A1A2-E44E-455B-BBFF-ACA2019A18CD", id2 = "2936A1A2-E44E-455B-BBFF-ACA2019A18CD", id3 = "3A36A1A2-E44E-455B-BBFF-ACA2019A18CD"
    /// One representative document per earlier format step, written the way those builds wrote them (keys added later are absent).
    static let docs: [(format: Int, json: String)] = [
        (2, #"{"formatVersion":2,"name":"f2","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5,"zoom":{"startScale":1,"endScale":1.4,"centerX":0.5,"centerY":0.5}}],"texts":[{"id":"\#(id2)","text":"Titlu","start":0,"duration":2,"font":"Helvetica","size":0.06,"x":0.5,"y":0.8}]}"#),
        (3, #"{"formatVersion":3,"name":"f3","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5,"transform":{"x":0.1,"y":0,"scale":1.2,"opacity":1,"rotation":0}}],"layers":[{"id":"\#(id2)","kind":"video","media":"/c.mov","start":1,"sourceStart":0,"duration":3,"transform":{"x":0,"y":0,"scale":0.4,"opacity":1,"rotation":0}}],"library":["/x.mov","/c.mov"]}"#),
        (4, #"{"formatVersion":4,"name":"f4","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5}],"hiddenLanes":["v2"],"mutedLanes":["a2"]}"#),
        (5, #"{"formatVersion":5,"name":"f5","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5}],"callouts":[{"id":"\#(id3)","start":1,"duration":2,"x":0.1,"y":0.1,"w":0.3,"h":0.3,"dim":0.5,"blur":0,"corner":0.1}]}"#),
        (8, #"{"formatVersion":8,"name":"f8","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5}],"mutedSources":[1],"sourceGains":{"0":-6,"2":3}}"#),
        (10, #"{"formatVersion":10,"name":"f10","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5,"audio":{"gainDB":-3,"fadeIn":0.5,"fadeOut":0,"muted":false}}],"masterGainDB":-2}"#),
        (12, #"{"formatVersion":12,"name":"f12","clips":[{"id":"\#(id1)","media":"/x.mov","sourceStart":0,"duration":5,"crop":{"zoom":1.5,"offsetX":0.2,"offsetY":0},"rectCrop":{"left":0.1,"right":0,"top":0,"bottom":0}}],"layers":[{"id":"\#(id2)","kind":"audio","media":"/m.m4a","start":0,"sourceStart":0,"duration":4,"track":1,"transform":{"x":0,"y":0,"scale":1,"opacity":1,"rotation":0}}]}"#),
    ]
    func testEveryEarlierFormatOpensWithNeutralNewFields() throws {
        for (f, j) in Self.docs {
            let p = try JSONDecoder().decode(SadrogProject.self, from: Data(j.utf8))
            XCTAssertEqual(p.formatVersion, f, "format \(f) is read as written")
            XCTAssertTrue(p.lockedLanes.isEmpty, "format \(f): nothing locked"); XCTAssertEqual(p.clips.count, 1); XCTAssertNil(p.clips[0].label)
        }
    }
    func testEarlierContentSurvivesTheJump() throws {
        func load(_ f: Int) throws -> SadrogProject { try JSONDecoder().decode(SadrogProject.self, from: Data(Self.docs.first { $0.format == f }!.json.utf8)) }
        XCTAssertEqual(try load(2).texts[0].text, "Titlu"); XCTAssertEqual(try load(3).layers[0].transform.scale, 0.4); XCTAssertEqual(try load(3).library.count, 2)
        XCTAssertEqual(try load(4).hiddenLanes, [.v2]); XCTAssertEqual(try load(4).mutedLanes, [.a2])
        XCTAssertNil(try load(5).callouts[0].clipID); XCTAssertEqual(try load(8).sourceGains[0], -6); XCTAssertEqual(try load(8).mutedSources, [1])
        XCTAssertEqual(try load(10).clips[0].audio?.gainDB, -3); XCTAssertEqual(try load(10).masterGainDB, -2)
        XCTAssertEqual(try load(12).layers[0].row, 1); XCTAssertEqual(try load(12).clips[0].rectCrop?.left, 0.1); XCTAssertEqual(try load(12).clips[0].crop?.zoom, 1.5); XCTAssertEqual(try load(2).clips[0].endTransform?.scale, 1.4)
    }
    func testSavedByThisBuildReopensIdenticallyAndEditsRoundTrip() throws {
        for (_, j) in Self.docs {
            let old = try JSONDecoder().decode(SadrogProject.self, from: Data(j.utf8))
            let e = ProjectEditor(project: old); e.rename(old.clips[0].id, to: "Nume"); e.setLock(.t, true)
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("compat-\(UUID().uuidString).sadrogproj")
            defer { try? FileManager.default.removeItem(at: dir) }
            try ProjectStore.save(e.project, to: dir)
            let back = try ProjectStore.load(from: dir)
            XCTAssertEqual(back.formatVersion, SadrogProject.currentFormat); XCTAssertEqual(back.clips[0].label, "Nume"); XCTAssertEqual(back.lockedLanes, [.t])
            var a = back, b = e.project; a.formatVersion = 0; b.formatVersion = 0; XCTAssertEqual(a, b, "reopened = saved")
        }
    }
    /// Demos from build 72 on are written by format-13 builds; only earlier builds count as "earlier format".
    static func isBeforeFormat13(_ rel: String) -> Bool {
        guard let r = rel.range(of: #"-b(\d+)"#, options: .regularExpression), let n = Int(rel[r].dropFirst(2)) else { return true }
        return n < 72
    }
    /// Real projects written by earlier builds (demos b48…b70 and sessions of the audio evidence), when the external disk has them.
    func testRealEarlierProjectsOpen() throws {
        let root = "\(TestRoot.path)"
        let fm = FileManager.default
        var found = 0
        for sub in ["builds/intermediar/demo", "evidence/editor_audio_2026-10-29/sessions"] {
            guard let en = fm.enumerator(atPath: "\(root)/\(sub)") else { continue }
            for case let rel as String in en where rel.hasSuffix("project.sadrogproj/project.json") && Self.isBeforeFormat13(rel) {
                let p = try JSONDecoder().decode(SadrogProject.self, from: Data(contentsOf: URL(fileURLWithPath: "\(root)/\(sub)/\(rel)")))
                guard p.formatVersion <= 12 else { found += 1; continue }                  // an old session re-saved by a newer build is still read (decode above); only untouched ones must be ≤ 12
                XCTAssertTrue(p.lockedLanes.isEmpty); found += 1
            }
        }
        try XCTSkipUnless(found > 0, "no real earlier projects on disk")
        XCTAssertGreaterThanOrEqual(found, 5)
    }
}
