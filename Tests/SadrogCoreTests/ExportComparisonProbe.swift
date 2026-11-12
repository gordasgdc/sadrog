// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// Measurement probe, not a regression test: exports ONE slice of a given recording with every compressed built-in preset at the SAME size and frame rate,
/// through the product path, and prints size, average rate and time. Runs only when asked:
/// SADROG_COMPARE_SRC=<movie> SADROG_COMPARE_OUT=<folder> [SADROG_COMPARE_START=s] [SADROG_COMPARE_DUR=s] swift test --filter ExportComparisonProbe
final class ExportComparisonProbe: XCTestCase {
    func testComparePresetsOnOneSlice() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let src = env["SADROG_COMPARE_SRC"], let outDir = env["SADROG_COMPARE_OUT"] else { throw XCTSkip("SADROG_COMPARE_SRC / SADROG_COMPARE_OUT not set") }
        let start = Double(env["SADROG_COMPARE_START"] ?? "0") ?? 0, dur = Double(env["SADROG_COMPARE_DUR"] ?? "60") ?? 60
        try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
        let a = AVURLAsset(url: URL(fileURLWithPath: src)); let vs = try await a.loadTracks(withMediaType: .video); let v = try XCTUnwrap(vs.first)
        let size = try await v.load(.naturalSize), fps = Double(try await v.load(.nominalFrameRate))
        let p0 = SadrogProject(name: "compare", clips: [Clip(media: src, sourceStart: start, duration: dur)])
        var cases: [(String, ExportSettings)] = ExportPreset.builtIns.filter { ["tutorial", "hevc-compact", "document"].contains($0.id) }.map { ($0.id, $0.settings()) }
        for q in [ExportSettings.QualityStep.compact, .balanced] { var s = ExportPreset.builtIns[0].settings(); s.quality = q.value; cases.append(("h264-\(q.rawValue)", s)) }
        var r3 = ExportPreset.builtIns[0].settings(); r3.videoMbps = 3; cases.append(("h264-3mbps", r3))
        var k1 = ExportPreset.builtIns[0].settings(); k1.keyframeSeconds = 1; k1.videoMbps = 16; cases.append(("old-like-16mbps-key1s", k1))
        if env["SADROG_COMPARE_PERSON"] != nil { cases = [("person-off", ExportPreset.builtIns[0].settings()), ("person-blur", ExportPreset.builtIns[0].settings()), ("person-remove", ExportPreset.builtIns[0].settings())] }
        for (name, var s) in cases {
            var p = p0
            if name == "person-blur" { var a = PictureAdjust(); a.background = .blur; p.clips[0].picture = a }
            if name == "person-remove" { var a = PictureAdjust(); a.background = .remove; p.clips[0].picture = a }

            s.size = .document; s.fps = nil; s.onlyRange = false
            let pl = ExportPlan.video(p, documentSize: size, documentFPS: fps, settings: s, copyPossible: false)
            let out = URL(fileURLWithPath: "\(outDir)/\(name).\(pl.fileExtension)"); try? FileManager.default.removeItem(at: out)
            let t0 = Date()
            try await ProjectExporter.export(p, to: out, settings: s, documentSize: size, documentFPS: fps)
            let el = Date().timeIntervalSince(t0), bytes = (try FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int) ?? 0
            print(String(format: "COMPARE %@ | %dx%d %.0f fps | %.2f MB | %.2f Mb/s | %.1f s (%.1fx) | hardware %@", name, pl.width, pl.height, pl.fps, Double(bytes) / 1e6, Double(bytes) * 8 / dur / 1e6, el, dur / el, String(describing: pl.hardware)))
        }
    }
}
