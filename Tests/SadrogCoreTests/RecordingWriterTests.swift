import XCTest
import AVFoundation
import CoreVideo
@testable import SadrogCore

final class RecordingWriterTests: XCTestCase {
    func makeFrame(_ i: Int, w: Int, h: Int, duration: Double = 1.0 / 30) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        memset(CVPixelBufferGetBaseAddress(pb!), Int32(i * 7 % 255), CVPixelBufferGetBytesPerRow(pb!) * h)
        CVPixelBufferUnlockBaseAddress(pb!, [])
        var fd: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb!, formatDescriptionOut: &fd)
        var t = CMSampleTimingInfo(duration: CMTime(seconds: duration, preferredTimescale: 600), presentationTimeStamp: CMTime(value: Int64(i), timescale: 30), decodeTimeStamp: .invalid)
        var sb: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb!, formatDescription: fd!, sampleTiming: &t, sampleBufferOut: &sb)
        return sb!
    }

    func testWriteFragmentedAndJournal() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = try RecordingWriter(destination: Destination(url: root), settings: RecordingSettings(width: 640, height: 360, fps: 30, withAudio: false))
        XCTAssertEqual(SessionJournal.unfinished(under: root).count, 1)
        for i in 0..<60 {
            let before = w.counters.videoWritten
            var tries = 0
            while w.counters.videoWritten == before && tries < 2000 { w.appendVideo(makeFrame(i, w: 640, h: 360)); tries += 1; if w.counters.videoWritten == before { try await Task.sleep(nanoseconds: 2_000_000) } }
        }
        XCTAssertEqual(w.counters.videoWritten, 60)
        try await w.finish()
        XCTAssertEqual(SessionJournal.unfinished(under: root).count, 0)
        XCTAssertEqual(try SessionJournal.read(from: w.folder).state, .finished)
        let asset = AVURLAsset(url: w.mediaURL)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(tracks.count, 1)
        let dur = try await asset.load(.duration).seconds
        XCTAssertGreaterThan(dur, 1.5)
    }

    func testJournalRoundTrip() throws {
        let f = FileManager.default.temporaryDirectory.appendingPathComponent("sadrog-j-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: f) }
        let j = SessionJournal(id: "a", state: .recording, startedAt: Date(timeIntervalSince1970: 1_700_000_000), mediaFile: "capture.mov", fragmentSeconds: 10, width: 1, height: 2, fps: 3, note: "")
        try j.write(to: f)
        XCTAssertEqual(try SessionJournal.read(from: f), j)
    }
}
