// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import AVFoundation
import CoreMedia

import ImageIO
import UniformTypeIdentifiers

/// Processed export written WITHOUT loss: the frames the compositor produces (8-bit RGB, after scaling, effects, titles) become PNG files (lossless) and the mixed sound an
/// uncompressed 32-bit integer PCM WAV. AVFoundation/VideoToolbox on macOS have no lossless video encoder (the encoder list holds only H.264, HEVC, ProRes, JPEG…; Apple Animation, PNG
/// and raw video are refused with "Cannot Encode", measured), so a lossless video FILE is not offered: the result is a folder with `frame_000001.png…` and `audio.wav`.
/// What is preserved: exactly those processed frames and that mix — not the original sources.
/// Describes the sequence next to it, so a folder of PNG files is a film: rate, size, count, the exported interval and how the sound lines up.
/// Frame k (1-based) is shown at `(k-1)/fps` seconds after the start; `audio.wav` starts at that same instant (no offset, no gap).
public struct LosslessManifest: Codable, Equatable, Sendable {
    public var format = "SADROG PNG sequence + WAV 1"
    public var fps: Double; public var width: Int; public var height: Int; public var frameCount: Int
    public var rangeStartSeconds: Double; public var rangeEndSeconds: Double
    public var firstFrameTimeSeconds: Double; public var lastFrameTimeSeconds: Double
    public var framePattern = "frame_%06d.png"; public var pixelFormat = "RGB 8-bit (compositor output, sRGB), PNG"
    public var audioFile: String?; public var audioSampleRate: Int?; public var audioChannels: Int?; public var audioFormat: String?
    public var audioStartOffsetSeconds: Double?; public var audioFrames: Int?
    public var note = "Lossless relative to the processed RGB 8-bit frames and the mixed sound of the project (after scaling, effects, titles); not relative to the original sources."
}

enum LosslessWriter {
    /// The mix is read as 32-bit float and written as 32-bit signed integer PCM (AVAssetWriter refuses floating-point WAVE files; measured). 32-bit integer
    /// keeps more precision than the 24 bits of a float mantissa, so no sample of the processed mix is rounded to fewer bits.
    static let readPCM: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                      AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]
    static let pcm: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                                      AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false]

    /// `folder` must not exist; it is created, and removed again when anything fails or is cancelled (no half-written sequence stays behind).
    static func write(_ built: BuiltComposition, project q: SadrogProject, to folder: URL, range: ClosedRange<Double>?, progress: (@Sendable (Double) -> Void)?) async throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: folder.path) else { throw CocoaError(.fileWriteFileExists) }
        try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        do { try await run(built, q, folder, range, progress) } catch { try? fm.removeItem(at: folder); throw error }
    }
    private static func run(_ built: BuiltComposition, _ q: SadrogProject, _ folder: URL, _ range: ClosedRange<Double>?, _ progress: (@Sendable (Double) -> Void)?) async throws {
        let comp = built.composition
        let vcomp = built.videoComposition(for: q) ?? AVMutableVideoComposition(propertiesOf: comp)
        let mix = built.audioMix(for: q)
        let vTracks = try await comp.loadTracks(withMediaType: .video), aTracks = try await comp.loadTracks(withMediaType: .audio)
        guard !vTracks.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        let tr = range.map { CMTimeRange(start: CMTime(seconds: $0.lowerBound, preferredTimescale: 6000), end: CMTime(seconds: $0.upperBound, preferredTimescale: 6000)) }
        let start = range?.lowerBound ?? 0, total = (range.map { $0.upperBound - $0.lowerBound }) ?? comp.duration.seconds

        let reader = try AVAssetReader(asset: comp)
        let vOut = AVAssetReaderVideoCompositionOutput(videoTracks: vTracks, videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        vOut.videoComposition = vcomp; reader.add(vOut); if let tr { reader.timeRange = tr }
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var n = 0, firstT = 0.0, lastT = 0.0, w0 = 0, h0 = 0
        let cs = CGColorSpaceCreateDeviceRGB()
        while let b = vOut.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let px = CMSampleBufferGetImageBuffer(b) else { continue }
            CVPixelBufferLockBaseAddress(px, .readOnly); defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
            guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(px), width: CVPixelBufferGetWidth(px), height: CVPixelBufferGetHeight(px), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(px),
                                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue), let img = ctx.makeImage() else { throw CocoaError(.fileWriteUnknown) }
            n += 1; let pts = CMSampleBufferGetPresentationTimeStamp(b).seconds; if n == 1 { firstT = pts - start; w0 = img.width; h0 = img.height }; lastT = pts - start
            let url = folder.appendingPathComponent(String(format: "frame_%06d.png", n))
            guard let d = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CocoaError(.fileWriteUnknown) }
            CGImageDestinationAddImage(d, img, nil)
            guard CGImageDestinationFinalize(d) else { throw CocoaError(.fileWriteUnknown) }
            progress?(min(0.95, max(0, (CMSampleBufferGetPresentationTimeStamp(b).seconds - start) / max(total, 0.001))))
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        guard n > 0 else { throw CocoaError(.fileWriteUnknown) }
        var m = LosslessManifest(fps: (vcomp.frameDuration.seconds > 0 ? 1 / vcomp.frameDuration.seconds : 30), width: w0, height: h0, frameCount: n, rangeStartSeconds: start, rangeEndSeconds: start + total,
                                 firstFrameTimeSeconds: firstT, lastFrameTimeSeconds: lastT)
        if !aTracks.isEmpty {
            let a = try await writeAudio(comp, aTracks, mix, tr, folder.appendingPathComponent("audio.wav"))
            m.audioFile = "audio.wav"; m.audioSampleRate = 48000; m.audioChannels = 2; m.audioFormat = "PCM signed 32-bit integer little-endian (WAV)"; m.audioStartOffsetSeconds = 0; m.audioFrames = a
        }
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(m).write(to: folder.appendingPathComponent("sequence.json"), options: .atomic)
        progress?(1)
    }
    /// Writes the mixed sound. Sample times are REBASED to start at zero (the reader hands them out on the composition clock, i.e. starting at In), so the WAV
    /// has no leading gap and its first sample lines up with the first frame. Every append is checked, the reader and the writer state are read, and cancelling
    /// stops the wait for the writer too. Returns the number of audio frames written.
    private static func writeAudio(_ comp: AVAsset, _ tracks: [AVAssetTrack], _ mix: AVAudioMix?, _ tr: CMTimeRange?, _ url: URL) async throws -> Int {
        let reader = try AVAssetReader(asset: comp)
        let out = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: readPCM); out.audioMix = mix; reader.add(out); if let tr { reader.timeRange = tr }
        let writer = try AVAssetWriter(outputURL: url, fileType: .wav)
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: pcm); input.expectsMediaDataInRealTime = false; writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        guard reader.startReading() else { writer.cancelWriting(); throw reader.error ?? CocoaError(.fileReadUnknown) }
        writer.startSession(atSourceTime: .zero)
        var finished = false
        defer { if !finished { reader.cancelReading(); writer.cancelWriting() } }
        let origin = tr?.start ?? .zero
        var frames = 0
        while let b = out.copyNextSampleBuffer() {
            while !input.isReadyForMoreMediaData {
                try Task.checkCancellation()
                if writer.status == .failed { throw writer.error ?? CocoaError(.fileWriteUnknown) }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            try Task.checkCancellation()
            var count: CMItemCount = 0; CMSampleBufferGetSampleTimingInfoArray(b, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
            var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(1, count)); CMSampleBufferGetSampleTimingInfoArray(b, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
            for i in timing.indices { timing[i].presentationTimeStamp = CMTimeSubtract(timing[i].presentationTimeStamp, origin); timing[i].decodeTimeStamp = .invalid }
            var rebased: CMSampleBuffer?
            guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: b, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &rebased) == noErr, let r = rebased else { throw CocoaError(.fileWriteUnknown) }
            guard input.append(r) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
            frames += CMSampleBufferGetNumSamples(b)
        }
        if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadUnknown) }
        try Task.checkCancellation()
        input.markAsFinished(); await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        finished = true
        return frames
    }
}

public enum ExportError: LocalizedError {
    case copyNeedsProcessing
    public var errorDescription: String? { T("Copierea fără procesare nu e posibilă: proiectul cere procesare. Alege un mod procesat.") }
}

public extension ProjectExporter {
    /// Exports with explicit settings. The document is only read: size and rate are applied to a copy. `.copy` never becomes a lossy export — it throws
    /// `ExportError.copyNeedsProcessing` when the project needs processing.
    static func export(_ p: SadrogProject, to url: URL, settings s: ExportSettings, documentSize: CGSize, documentFPS: Double, effects: EffectPlan? = nil,
                       range: ClosedRange<Double>? = nil, replaceExisting: Bool = false, progress: (@Sendable (Double) -> Void)? = nil) async throws {
        if FileManager.default.fileExists(atPath: url.path) && !replaceExisting { throw CocoaError(.fileWriteFileExists) }
        try await SafePublish.run(to: url, replaceExisting: replaceExisting) { tmp in
            try await exportInto(p, to: tmp, settings: s, documentSize: documentSize, documentFPS: documentFPS, effects: effects, range: range, progress: progress)
        }
    }
    private static func exportInto(_ p: SadrogProject, to url: URL, settings s: ExportSettings, documentSize: CGSize, documentFPS: Double, effects: EffectPlan?,
                                   range: ClosedRange<Double>?, progress: (@Sendable (Double) -> Void)?) async throws {
        try requireProcessed(p, effects)
        let q = s.mode == .copy ? p : s.outputProject(p, documentSize: documentSize, documentFPS: documentFPS)
        let built = try await CompositionBuilder.buildFull(q, fx: effects?.ready ?? [:])
        if s.mode == .lossless { try await LosslessWriter.write(built, project: q, to: url, range: range, progress: progress); return }
        if s.usesAdvancedWriter {
            try await CompressedWriter.write(built, project: q, to: url, settings: s, range: range, progress: progress); return
        }
        let vc = built.videoComposition(for: q), mix = built.audioMix(for: q)
        let preset: String
        switch s.mode {
        case .copy:
            guard vc == nil, mix == nil else { throw ExportError.copyNeedsProcessing }
            preset = AVAssetExportPresetPassthrough
        case .compressed: preset = s.codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : (s.tier == .high ? AVAssetExportPresetHighestQuality : AVAssetExportPresetMediumQuality)
        case .master: preset = s.proRes == .p422 ? AVAssetExportPresetAppleProRes422LPCM : AVAssetExportPresetAppleProRes4444LPCM
        case .lossless: preset = ""
        }
        guard let ex = AVAssetExportSession(asset: built.composition, presetName: preset) else { throw CocoaError(.fileWriteUnknown) }
        if let vc { ex.videoComposition = vc }
        if let mix { ex.audioMix = mix }
        if let range { ex.timeRange = CMTimeRange(start: CMTime(seconds: range.lowerBound, preferredTimescale: 6000), end: CMTime(seconds: range.upperBound, preferredTimescale: 6000)) }
        let watcher = Task { for await st in ex.states(updateInterval: 0.2) { if case .exporting(let pr) = st { progress?(pr.fractionCompleted) } } }
        defer { watcher.cancel() }
        try await ex.export(to: url, as: .mov)
        progress?(1)
    }
}
