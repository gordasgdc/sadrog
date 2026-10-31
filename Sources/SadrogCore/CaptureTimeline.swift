// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import CoreMedia
import Foundation

/// One clock for every file of a session (screens, cameras, audio), on the host clock all capture APIs stamp with.
/// - `origin` = the first frame of the primary screen: the common start. Samples before it are dropped (a camera prepared during the
///   countdown therefore starts at the common start with real frames — no invented offset).
/// - Pause/resume are moments on the same clock: samples inside a pause are dropped and later ones are shifted back by the paused time,
///   identically for every writer, so all files stay aligned. Thread-safe (writers run on their own queues).
public final class CaptureTimeline: @unchecked Sendable {
    private let lock = NSLock()
    private var _origin: CMTime?
    private var pauses: [(start: CMTime, end: CMTime?)] = []
    public init() {}

    public static func now() -> CMTime { CMClockGetTime(CMClockGetHostTimeClock()) }

    /// Sets the common start once (the first call wins) and returns it.
    @discardableResult public func setOrigin(_ t: CMTime) -> CMTime { lock.withLock { if _origin == nil { _origin = t }; return _origin! } }
    public var origin: CMTime? { lock.withLock { _origin } }
    public var isPaused: Bool { lock.withLock { pauses.last.map { $0.end == nil } ?? false } }
    /// Total time paused so far (closed pauses), seconds.
    public var pausedSeconds: Double { lock.withLock { pauses.reduce(0.0) { $0 + (($1.end ?? $1.start) - $1.start).seconds } } }

    public func pause(at t: CMTime = CaptureTimeline.now()) { lock.withLock { if pauses.last.map({ $0.end != nil }) ?? true { pauses.append((t, nil)) } } }
    public func resume(at t: CMTime = CaptureTimeline.now()) { lock.withLock { if let i = pauses.indices.last, pauses[i].end == nil { pauses[i].end = max(t, pauses[i].start) } } }

    /// Session time for a sample stamped `t`, or nil when it must be dropped (before the start, or inside a pause).
    public func map(_ t: CMTime) -> CMTime? {
        lock.withLock {
            guard let o = _origin, CMTimeCompare(t, o) >= 0 else { return nil }
            var shift = CMTime.zero
            for p in pauses where CMTimeCompare(t, p.start) >= 0 {
                guard let e = p.end, CMTimeCompare(t, e) >= 0 else { return nil }
                shift = shift + (e - p.start)
            }
            return t - shift
        }
    }
}

extension CMSampleBuffer {
    /// The same sample(s) moved by `delta` (every timing entry), or nil if the copy fails.
    func shifted(by delta: CMTime) -> CMSampleBuffer? {
        if delta == .zero { return self }
        var count: CMItemCount = 0
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        var timing = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(), count: max(count, 1))
        CMSampleBufferGetSampleTimingInfoArray(self, entryCount: count, arrayToFill: &timing, entriesNeededOut: &count)
        for i in timing.indices {
            if timing[i].presentationTimeStamp.isValid { timing[i].presentationTimeStamp = timing[i].presentationTimeStamp - delta }
            if timing[i].decodeTimeStamp.isValid { timing[i].decodeTimeStamp = timing[i].decodeTimeStamp - delta }
        }
        var out: CMSampleBuffer?
        guard CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: self, sampleTimingEntryCount: count, sampleTimingArray: &timing, sampleBufferOut: &out) == 0 else { return nil }
        return out
    }
}
