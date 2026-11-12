// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import XCTest
import AVFoundation
@testable import SadrogCore

/// The MP4 container and the mono option are really written (not only announced), and the hardware-encoder answer is stable.
final class ExportContainerTests: XCTestCase {
    func testMP4MonoExportIsAnMP4FileWithOneChannel() async throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: SyntheticTwoTrackTests.dir), "external test storage not available")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: SyntheticTwoTrackTests.source), "synthetic two-track source not generated yet (run SyntheticTwoTrackTests first)")
        let p = SadrogProject(name: "t", clips: [Clip(media: SyntheticTwoTrackTests.source, sourceStart: 0, duration: 2)])
        var s = ExportSettings(); s.container = .mp4; s.audioMono = true
        let built = try await CompositionBuilder.buildFull(p)
        let out = URL(fileURLWithPath: "\(SyntheticTwoTrackTests.dir)/container-\(UUID().uuidString).mp4"); defer { try? FileManager.default.removeItem(at: out) }
        try await CompressedWriter.write(built, project: p, to: out, settings: s, range: nil, progress: nil)
        let head = try FileHandle(forReadingFrom: out).read(upToCount: 12) ?? Data()
        XCTAssertEqual(String(decoding: head[4..<8], as: UTF8.self), "ftyp")
        XCTAssertNotEqual(String(decoding: head[8..<12], as: UTF8.self), "qt  ", "an MP4 brand, not QuickTime")
        let a = AVURLAsset(url: out), at = try await a.loadTracks(withMediaType: .audio)
        XCTAssertEqual(at.count, 1)
        let fd = try await at[0].load(.formatDescriptions)
        XCTAssertEqual(fd.first?.audioStreamBasicDescription?.mChannelsPerFrame, 1)
        let v = try await a.loadTracks(withMediaType: .video); XCTAssertEqual(v.count, 1)
        let d = try await a.load(.duration).seconds; XCTAssertEqual(d, 2, accuracy: 0.1)
    }
    func testHardwareAnswerIsCachedAndTrueForCommonSizesOnAppleSilicon() throws {
        let a = HardwareEncoder.available(.h264, width: 1920, height: 1080), b = HardwareEncoder.available(.h264, width: 1920, height: 1080)
        XCTAssertEqual(a, b)
        #if arch(arm64)
        XCTAssertTrue(a, "Apple silicon has a hardware H.264 encoder at Full HD"); XCTAssertTrue(HardwareEncoder.available(.hevc, width: 3840, height: 2160))
        #endif
    }
}
