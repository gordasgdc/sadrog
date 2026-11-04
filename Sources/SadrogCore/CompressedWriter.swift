// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import AVFoundation
import CoreMedia

/// Compressed export with EXPLICIT encoder controls (average video bit rate, key-frame distance, AAC bit rate), which the AVAssetExportSession presets cannot express.
/// Same source of frames and sound as every other processed export (video composition + audio mix of the built composition); sample times are rebased to start at zero.
/// Anything left nil keeps a sensible default (video: the encoder's own rate control; audio: 128 kb/s AAC). The file is removed when anything fails or is cancelled.
enum CompressedWriter {
    static func videoSettings(_ s: ExportSettings, width: Int, height: Int) -> [String: Any] {
        var v: [String: Any] = [AVVideoCodecKey: s.codec == .hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height]
        var c: [String: Any] = [:]
        if let m = s.clampedMbps { c[AVVideoAverageBitRateKey] = Int(m * 1_000_000) }
        if let k = s.clampedKeyframe { c[AVVideoMaxKeyFrameIntervalDurationKey] = k }
        if s.codec == .h264 { c[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
        if !c.isEmpty { v[AVVideoCompressionPropertiesKey] = c }
        return v
    }
    static func audioSettings(_ s: ExportSettings) -> [String: Any] {
        [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: (s.clampedAudioKbps ?? 128) * 1000]
    }

    static func write(_ built: BuiltComposition, project q: SadrogProject, to url: URL, settings s: ExportSettings, range: ClosedRange<Double>?, progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: url.path) else { throw CocoaError(.fileWriteFileExists) }      // never deletes a file it did not create
        do { try await run(built, q, url, s, range, progress) } catch { try? fm.removeItem(at: url); throw error }
    }

    private static func run(_ built: BuiltComposition, _ q: SadrogProject, _ url: URL, _ s: ExportSettings, _ range: ClosedRange<Double>?, _ progress: (@Sendable (Double) -> Void)?) async throws {
        let comp = built.composition
        let vcomp = built.videoComposition(for: q) ?? AVMutableVideoComposition(propertiesOf: comp)
        let vTracks = try await comp.loadTracks(withMediaType: .video), aTracks = try await comp.loadTracks(withMediaType: .audio)
        guard !vTracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let tr = range.map { CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 6000), end: CMTime(seconds: $0.upperBound, preferredTimescale: 6000)) }
        let origin = tr?.start ?? .zero
        let total = (range.map { $0.upperBound - $0.lowerBound }) ?? comp.duration.seconds

        let reader = try AVAssetReader(asset: comp)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = vcomp; reader.add(vOut)
        var aOut: AVAssetReaderAudioMixOutput?
        if !aTracks.isEmpty { let o = AVAssetReaderAudioMixOutput(audioTracks: aTracks, audioSettings: LosslessWriter.readPCM); o.audioMix = built.audioMix(for: q); o.audioTimePitchAlgorithm = built.pitch; reader.add(o); aOut = o }
        if let tr { reader.timeRange = tr }

        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let w = Int(vcomp.renderSize.width), h = Int(vcomp.renderSize.height)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings(s, width: w, height: h)); vIn.expectsMediaDataInRealTime = false
        guard writer.canAdd(vIn) else { throw CocoaError(.fileWriteUnknown) }
        writer.add(vIn)
        var aIn: AVAssetWriterInput?
        if aOut != nil {
            let i = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings(s)); i.expectsMediaDataInRealTime = false
            guard writer.canAdd(i) else { throw CocoaError(.fileWriteUnknown) }
            writer.add(i); aIn = i
        }
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { reader.cancelReading(); writer.cancelWriting() } }

        func rebased(_ b: CMSampleBuffer) throws -> CMSampleBuffer {
            var count: CMItemCount = 0; CMSampleBufferGetSampleTimingInfoArray(b, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count)); CMSampleBufferGetSampleTimingInfoArray(b, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
            for i in timing.indices { timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, origin); if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = CMTimeSubtract(timing[i].decodeTimeStamp, origin) } }
            var out: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: b, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out) == noErr, let r = out else { throw CocoaError(.fileWriteUnknown) }
            return r
        }
        // A writer that interleaves two streams keeps one input "not ready" until the other has delivered up to the same time. If a stream is already exhausted
        // but its input is not marked finished, that wait never ends — so each input is finished the moment its stream runs out, and a wait that makes no
        // progress for `stallLimit` is an error instead of an endless loop.
        let stallLimit: TimeInterval = 120
        func wait(_ input: AVAssetWriterInput, _ name: String) async throws {
            let since = Date()
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                if Date().timeIntervalSince(since) > stallLimit {
                    DiagnosticLog("export").error("writer stalled on the \(name) input: status \(writer.status.rawValue), video ready \(vIn.isReadyForMoreMediaData) finished \(vFinished), sound ready \(aIn?.isReadyForMoreMediaData ?? false) finished \(aFinished)")
                    throw CompressedWriterError.stalled
                }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try Task.checkCancellation()
        }
        var vDone = false, aDone = aOut == nil, vFinished = false, aFinished = false
        func finishExhausted() { if vDone && !vFinished { vIn.markAsFinished(); vFinished = true }; if aDone && !aFinished { aIn?.markAsFinished(); aFinished = true } }
        // Video and sound are fed alternately by time, so the writer never has to buffer one stream far ahead of the other.
        var vNext: CMSampleBuffer? = vOut.copyNextSampleBuffer(), aNext: CMSampleBuffer? = aOut?.copyNextSampleBuffer()
        vDone = vNext == nil; aDone = aNext == nil
        finishExhausted()
        while !vDone || !aDone {
            let vt = vNext.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity, at = aNext.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? .infinity
            if !vDone && (aDone || vt <= at), let b = vNext {
                try await wait(vIn, "video")
                guard vIn.append(try rebased(b)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                progress?(min(0.97, max(0, (vt - origin.seconds) / max(total, 0.001))))
                vNext = vOut.copyNextSampleBuffer(); vDone = vNext == nil
                finishExhausted()
            } else if let b = aNext, let ai = aIn {
                try await wait(ai, "sound")
                guard ai.append(try rebased(b)) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                aNext = aOut?.copyNextSampleBuffer(); aDone = aNext == nil
                finishExhausted()
            } else { break }
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        vDone = true; aDone = true; finishExhausted(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        finished = true
        progress?(1)
    }
}

enum CompressedWriterError: LocalizedError {
    case stalled
    var errorDescription: String? { T("Exportul s-a blocat (scrierea fișierului nu mai avansa) și a fost oprit. Încearcă din nou.") }
}
