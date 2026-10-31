// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation
import CoreMedia
import VideoToolbox

public struct AudioTrackFormat: Sendable, Equatable {
    public var id: String, channels: Int
    public init(id: String, channels: Int) { self.id = id; self.channels = channels }
}

public struct RecordingSettings: Sendable {
    public var width: Int, height: Int, fps: Int
    public var videoBitrate: Int
    public var hevc: Bool
    public var fragmentSeconds: Double
    public var withAudio: Bool
    /// Separate audio tracks (id, channel count), in file order. Empty + `withAudio` = one stereo track "system".
    public var audioTracks: [AudioTrackFormat]
    public init(width: Int, height: Int, fps: Int = 60, videoBitrate: Int = 20_000_000, hevc: Bool = true, fragmentSeconds: Double = 10, withAudio: Bool = true, audioTracks: [AudioTrackFormat] = []) {
        self.width = width; self.height = height; self.fps = fps; self.videoBitrate = videoBitrate
        self.hevc = hevc; self.fragmentSeconds = fragmentSeconds; self.withAudio = withAudio; self.audioTracks = audioTracks
    }
    var effectiveTracks: [AudioTrackFormat] { !audioTracks.isEmpty ? audioTracks : (withAudio ? [AudioTrackFormat(id: "system", channels: 2)] : []) }
}

public struct RecordingCounters: Sendable, Equatable {
    public var videoWritten = 0, videoDroppedBackpressure = 0, appendFailures = 0
    public var audioWritten = 0, audioDropped = 0
    public var audioWrittenByTrack: [String: Int] = [:], audioDroppedByTrack: [String: Int] = [:]
}

/// Fragmented QuickTime writer. Probe P2: a fragmented file survives kill -9 (~91% kept), an unfragmented one does not.
/// Not thread-safe: feed it from one serial queue.
public final class RecordingWriter {
    public let folder: URL
    public let mediaURL: URL
    public private(set) var counters = RecordingCounters()
    public private(set) var journal: SessionJournal
    private let writer: AVAssetWriter
    private let video: AVAssetWriterInput
    private var audio: [String: AVAssetWriterInput] = [:]
    public private(set) var audioOrder: [String] = []
    /// First appended sample of each audio track, seconds after the first video frame (shared host clock).
    public private(set) var firstAudioOffset: [String: Double] = [:]
    private var started = false
    private var sessionStart = CMTime.invalid
    /// Latest end (PTS + duration) seen on any track; the session is closed there so a still screen keeps its last frame for the whole recording.
    private var lastEnd = CMTime.invalid
    private var lastVideo: CMSampleBuffer?
    private let frameDuration: CMTime
    /// Shared session clock (common start + pauses); nil = host times as they are (tests, legacy).
    public let timeline: CaptureTimeline?
    /// End of the last written sample on any track, session time (the other files are held until here).
    public var lastEndTime: CMTime { lastEnd }
    /// Video durations are ignored: ScreenCaptureKit stamps a still-screen frame with the (long) time until the next one.
    /// Audio length from the sample count and rate (device-reported buffer durations are not trusted).
    static func audioDuration(_ sb: CMSampleBuffer) -> CMTime {
        if let fd = CMSampleBufferGetFormatDescription(sb), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd)?.pointee, asbd.mSampleRate > 0 {
            return CMTime(value: CMTimeValue(CMSampleBufferGetNumSamples(sb)), timescale: CMTimeScale(asbd.mSampleRate))
        }
        return CMSampleBufferGetDuration(sb)
    }
    private func noteEnd(_ sb: CMSampleBuffer, video isVideo: Bool = false) {
        var d = isVideo ? frameDuration : Self.audioDuration(sb); if !d.isValid || d.isIndefinite { d = .zero }
        let e = CMSampleBufferGetPresentationTimeStamp(sb) + d
        if !lastEnd.isValid || CMTimeCompare(e, lastEnd) > 0 { lastEnd = e }
    }

    public init(destination: Destination, settings: RecordingSettings, id: String = UUID().uuidString, now: Date = Date(), timeline: CaptureTimeline? = nil) throws {
        self.timeline = timeline
        try destination.validate(requiredBytes: 1_000_000_000)
        frameDuration = CMTime(value: 1, timescale: CMTimeScale(max(settings.fps, 1)))
        folder = destination.url.appendingPathComponent("SADROG-\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        mediaURL = folder.appendingPathComponent("capture.mov")
        writer = try AVAssetWriter(url: mediaURL, fileType: .mov)
        if settings.fragmentSeconds > 0 { writer.movieFragmentInterval = CMTime(seconds: settings.fragmentSeconds, preferredTimescale: 600) }
        var comp: [String: Any] = [AVVideoAverageBitRateKey: settings.videoBitrate,
                                   AVVideoExpectedSourceFrameRateKey: settings.fps,
                                   AVVideoMaxKeyFrameIntervalKey: settings.fps * 2]
        if settings.hevc { comp[AVVideoProfileLevelKey] = kVTProfileLevel_HEVC_Main_AutoLevel as String }
        video = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: settings.hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264,
            AVVideoWidthKey: settings.width, AVVideoHeightKey: settings.height, AVVideoCompressionPropertiesKey: comp])
        video.expectsMediaDataInRealTime = true
        writer.add(video)
        for t in settings.effectiveTracks {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: max(1, t.channels), AVEncoderBitRateKey: 64_000 * max(1, min(t.channels, 2))])
            a.expectsMediaDataInRealTime = true
            writer.add(a); audio[t.id] = a; audioOrder.append(t.id)
        }
        journal = SessionJournal(id: id, state: .recording, startedAt: now, mediaFile: "capture.mov", fragmentSeconds: settings.fragmentSeconds,
                                 width: settings.width, height: settings.height, fps: settings.fps, note: "")
        try journal.write(to: folder)
    }

    /// Places a sample on the session clock: nil = not recorded (before the start / paused), else the (shifted) sample and its time.
    private func onTimeline(_ raw: CMSampleBuffer, isVideo: Bool) -> (CMSampleBuffer, CMTime)? {
        let host = CMSampleBufferGetPresentationTimeStamp(raw)
        guard let tl = timeline else { return (raw, host) }
        if isVideo, !started { tl.setOrigin(host) }                                   // the primary screen's first frame is the common start
        guard let t = tl.map(host) else { return nil }
        if t == host { return (raw, host) }
        return raw.shifted(by: host - t).map { ($0, t) }
    }

    public func appendVideo(_ raw: CMSampleBuffer) {
        guard let (sb, pts) = onTimeline(raw, isVideo: true) else { return }
        if !started {
            guard writer.startWriting() else { counters.appendFailures += 1; return }
            writer.startSession(atSourceTime: pts); sessionStart = pts; started = true
        }
        noteEnd(sb, video: true)
        guard video.isReadyForMoreMediaData else { counters.videoDroppedBackpressure += 1; return }
        if video.append(sb) { counters.videoWritten += 1; lastVideo = sb } else { counters.appendFailures += 1 }
    }

    public func appendAudio(_ raw: CMSampleBuffer, track: String = "system") {
        guard let input = audio[track] else { return }
        guard started, let (sb, _) = onTimeline(raw, isVideo: false) else { if !started { counters.audioDropped += 1; counters.audioDroppedByTrack[track, default: 0] += 1 }; return }
        guard started, CMTimeCompare(CMSampleBufferGetPresentationTimeStamp(sb), sessionStart) >= 0, input.isReadyForMoreMediaData else {
            counters.audioDropped += 1; counters.audioDroppedByTrack[track, default: 0] += 1; return }
        if input.append(sb) { noteEnd(sb); if firstAudioOffset[track] == nil { firstAudioOffset[track] = (CMSampleBufferGetPresentationTimeStamp(sb) - sessionStart).seconds }; counters.audioWritten += 1; counters.audioWrittenByTrack[track, default: 0] += 1 } else { counters.audioDropped += 1; counters.audioDroppedByTrack[track, default: 0] += 1 }
    }

    /// Host-clock time of the first screen frame (start of capture.mov); other files (camera.mov) are placed against it.
    public var sessionStartTime: CMTime { sessionStart }
    public var failureDescription: String? { writer.status == .failed ? writer.error?.localizedDescription : nil }

    /// SCK sends no frames while the screen is still: repeat the last frame at the very end so the video track lasts as long as the audio.
    private func holdLastFrame() {
        guard let lv = lastVideo, lastEnd.isValid else { return }
        let target = lastEnd - frameDuration
        let lvPTS = CMSampleBufferGetPresentationTimeStamp(lv)
        guard CMTimeCompare(target - lvPTS, CMTime(value: 1, timescale: 4)) > 0 else { return }
        var t = CMSampleTimingInfo(duration: frameDuration, presentationTimeStamp: target, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: lv, sampleTimingEntryCount: 1, sampleTimingArray: &t, sampleBufferOut: &copy) == 0, let c = copy else { return }
        var tries = 0
        while !video.isReadyForMoreMediaData && tries < 200 { Thread.sleep(forTimeInterval: 0.005); tries += 1 }
        if video.isReadyForMoreMediaData, video.append(c) { counters.videoWritten += 1 }
    }

    public func finish() async throws {
        if started {
            try? "lastEnd=\(lastEnd.seconds) sessionStart=\(sessionStart.seconds) lastVideoPTS=\(lastVideo.map { CMSampleBufferGetPresentationTimeStamp($0).seconds } ?? -1)\n".write(to: folder.appendingPathComponent("writer_debug.txt"), atomically: true, encoding: .utf8)
            holdLastFrame()
            video.markAsFinished(); audio.values.forEach { $0.markAsFinished() }
            await writer.finishWriting()
        } else { writer.cancelWriting() }
        let ok = writer.status == .completed
        journal.state = ok ? .finished : .failed
        journal.note = ok ? "" : (writer.error?.localizedDescription ?? "no frames written")
        try journal.write(to: folder)
        if !ok { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }
}
