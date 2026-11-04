// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// The plan the export sheet shows must equal the file the exporter writes: sizes (landscape/portrait/4:3/square/UHD/small), In–Out duration,
/// first and last picture and sound position. Sources are synthetic ffmpeg files under the SADROG synthetic folder; skipped when absent.
final class ExportPlanTests: XCTestCase {
    let syn = "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/synthetic/"
    func tmp() -> URL { URL(fileURLWithPath: "/Volumes/CristiGordas/TESTE/GDC_PROJECTS/SADROG/temp/plan-\(UUID().uuidString).mov") }

    func testScaledRuleIsPure() {
        XCTAssertEqual(ExportPlan.scaled(width: 3840, height: 2160, longSideCap: 1920).w, 1920); XCTAssertEqual(ExportPlan.scaled(width: 3840, height: 2160, longSideCap: 1920).h, 1080)
        XCTAssertEqual(ExportPlan.scaled(width: 1080, height: 1920, longSideCap: 1280).w, 720); XCTAssertEqual(ExportPlan.scaled(width: 1600, height: 1200, longSideCap: 1280).h, 960)
        XCTAssertEqual(ExportPlan.scaled(width: 640, height: 360, longSideCap: 1280).w, 640, "never enlarged"); XCTAssertEqual(ExportPlan.scaled(width: 1000, height: 1000, longSideCap: nil).h, 1000)
    }
    func testSummaryDescribesTheRangeNotTheWholeProject() {
        var p = SadrogProject(name: "t", clips: [Clip(media: "/x.mov", sourceStart: 0, duration: 14)]); p.rangeIn = 1; p.rangeOut = 12
        let on = ExportPlan.video(p, renderSize: CGSize(width: 1920, height: 1080), longSideCap: nil, passthrough: false, onlyRange: true)
        let off = ExportPlan.video(p, renderSize: CGSize(width: 1920, height: 1080), longSideCap: nil, passthrough: false, onlyRange: false)
        XCTAssertEqual(on.duration, 11, accuracy: 0.001); XCTAssertEqual(on.range, 1...12); XCTAssertEqual(off.duration, 14, accuracy: 0.001); XCTAssertNil(off.range)
        XCTAssertEqual(ExportPlan.archive(p).container, "SADROG (.sadrogproj)"); XCTAssertEqual(ExportPlan.archive(p).fileExtension, "sadrogproj")
    }

    func testPlanSizeEqualsExportedSizeForEverySourceAndPreset() async throws {
        let sources = ["hd", "portrait", "p43", "uhd", "small", "square", "w1366"].map { syn + "preset/\($0).mov" }
        try XCTSkipUnless(sources.allSatisfy { FileManager.default.fileExists(atPath: $0) }, "synthetic sources not available")
        for path in sources {
            let size = try await AVURLAsset(url: URL(fileURLWithPath: path)).loadTracks(withMediaType: .video).first!.load(.naturalSize)
            for (cap, preset) in [(1280 as Int?, AVAssetExportPreset1280x720), (1920, AVAssetExportPreset1920x1080), (nil, AVAssetExportPresetHighestQuality)] {
                let p = SadrogProject(name: "t", clips: [Clip(media: path, sourceStart: 0, duration: 1)])
                let plan = ExportPlan.video(p, renderSize: size, longSideCap: cap, passthrough: false, onlyRange: false)
                let out = tmp(); defer { try? FileManager.default.removeItem(at: out) }
                try await ProjectExporter.export(p, to: out, mode: .reencode(preset: preset))
                let real = try await AVURLAsset(url: out).loadTracks(withMediaType: .video).first!.load(.naturalSize)
                XCTAssertEqual(Int(real.width), plan.width, "\(URL(fileURLWithPath: path).lastPathComponent) cap \(String(describing: cap)): width")
                XCTAssertEqual(Int(real.height), plan.height, "\(URL(fileURLWithPath: path).lastPathComponent) cap \(String(describing: cap)): height")
            }
        }
    }

    // MARK: In/Out through the file itself
    func centerColor(_ url: URL, at t: Double) async throws -> (r: Int, g: Int, b: Int) {
        let g = AVAssetImageGenerator(asset: AVURLAsset(url: url)); g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero
        let img = try await g.image(at: CMTime(seconds: t, preferredTimescale: 600)).image
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &px, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: -img.width / 2, y: -img.height / 2, width: img.width, height: img.height))
        return (Int(px[0]), Int(px[1]), Int(px[2]))
    }
    /// RMS per 100 ms window of the first audio track (mono mixdown).
    func rms100(_ url: URL) async throws -> [Double] {
        let a = AVURLAsset(url: url), t = try await a.loadTracks(withMediaType: .audio).first!
        let r = try AVAssetReader(asset: a)
        let o = AVAssetReaderTrackOutput(track: t, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: 48000])
        r.add(o); r.startReading()
        var all: [Int16] = []
        while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
            let n = CMBlockBufferGetDataLength(bb); var d = [Int16](repeating: 0, count: n / 2)
            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: n, destination: &d); all += d
        }
        let w = 4800; return stride(from: 0, to: all.count - w + 1, by: w).map { i in sqrt(all[i..<i + w].reduce(0.0) { $0 + Double($1) * Double($1) } / Double(w)) }
    }
    func isNear(_ c: (r: Int, g: Int, b: Int), _ e: (Int, Int, Int)) -> Bool { abs(c.r - e.0) < 90 && abs(c.g - e.1) < 90 && abs(c.b - e.2) < 90 }

    func testInOutExportMatchesDurationPicturesAndAudioPosition() async throws {
        let src = syn + "inout/colors_beep.mov"; try XCTSkipUnless(FileManager.default.fileExists(atPath: src), "synthetic In/Out source not available")
        // source: 1 s each red, green, blue, yellow, cyan, magenta; a 1 kHz beep during 3–4 s
        var p = SadrogProject(name: "t", clips: [Clip(media: src, sourceStart: 0, duration: 6)]); p.rangeIn = 2; p.rangeOut = 5
        for mode in [ExportMode.reencode(preset: AVAssetExportPresetHighestQuality), .passthrough] {
            let out = tmp(); defer { try? FileManager.default.removeItem(at: out) }
            let plan = ExportPlan.video(p, renderSize: CGSize(width: 320, height: 240), longSideCap: nil, passthrough: mode == .passthrough, onlyRange: true)
            try await ProjectExporter.export(p, to: out, mode: mode, range: p.exportRange)
            let dur = try await AVURLAsset(url: out).load(.duration).seconds
            XCTAssertEqual(dur, plan.duration, accuracy: 0.15, "\(mode): file duration = plan duration (3 s)")
            let first = try await centerColor(out, at: 0.1), last = try await centerColor(out, at: dur - 0.1)
            XCTAssertTrue(isNear(first, (0, 0, 255)), "\(mode): first picture is the source's 2 s (blue): \(first)")
            XCTAssertTrue(isNear(last, (0, 255, 255)), "\(mode): last picture is the source's 4.9 s (cyan): \(last)")
            let r = try await rms100(out), loud = r.indices.filter { r[$0] > 1000 }
            XCTAssertFalse(loud.isEmpty, "\(mode): the beep is present")
            if let a = loud.first, let b = loud.last { XCTAssertEqual(Double(a) / 10, 1.0, accuracy: 0.2, "\(mode): beep starts at 1 s (source 3 s)"); XCTAssertEqual(Double(b + 1) / 10, 2.0, accuracy: 0.2, "\(mode): beep ends at 2 s (source 4 s)") }
        }
    }
}

/// Dates follow the app language, not the system's.
final class L10nDateTests: XCTestCase {
    func testDatesUseTheAppLanguage() {
        let d = Date(timeIntervalSince1970: 1_793_369_100)   // 2026-10-30 14:05 UTC
        let ro = L10n.date(d, .ro), en = L10n.date(d, .en), es = L10n.date(d, .es)
        XCTAssertNotEqual(ro, en); XCTAssertNotEqual(es, en)
        XCTAssertFalse(ro.contains(" at ")); XCTAssertFalse(es.contains(" at "))
        XCTAssertTrue(ro.lowercased().contains("oct"), ro); XCTAssertTrue(en.contains("Oct"), en)
    }
}
