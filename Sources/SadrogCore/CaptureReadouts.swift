// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import AVFoundation

/// Peak level of a source in dBFS, with the thresholds the capture panel states. Pure functions: the same numbers are used for the bar, the readout and the tests.
/// The value is the digital PEAK of the samples (not RMS, not loudness); 0 dBFS is full scale.
public enum AudioLevelMath {
    public static let floorDB: Float = -60          // the bar starts here; anything below reads "< −60 dBFS"
    public static let okLimit: Float = -18          // up to here: comfortable
    public static let hotLimit: Float = -3          // above okLimit: high; above this: close to clipping
    public static let clipPeak: Float = 0.999       // linear peak at or above this = digital full scale: clipping
    public enum Zone: Equatable, Sendable { case silent, ok, high, hot, clip }

    public static func dbfs(peak: Float) -> Float { peak > 0 ? max(-120, 20 * log10(peak)) : -120 }
    public static func zone(peak: Float) -> Zone {
        if peak >= clipPeak { return .clip }
        let d = dbfs(peak: peak)
        if d < floorDB { return .silent }
        if d <= okLimit { return .ok }
        return d <= hotLimit ? .high : .hot
    }
    /// 0…1 position on the bar (linear in dB between the floor and 0 dBFS).
    public static func position(peak: Float) -> Float { min(1, max(0, (dbfs(peak: peak) - floorDB) / -floorDB)) }
    /// "−12 dBFS", "< −60 dBFS" for silence, "0 dBFS" at full scale. The minus sign is U+2212.
    public static func readout(peak: Float) -> String {
        let d = dbfs(peak: peak)
        if d < floorDB { return "< −60 dBFS" }
        let r = Int(d.rounded())
        return r == 0 ? "0 dBFS" : "−\(abs(r)) dBFS"
    }
}

/// What the meter shows: the peak held for a short time (so it can be read) and a clipping flag that stays until the user clears it.
public struct MeterReading: Equatable, Sendable {
    public var heldPeak: Float = 0
    public var clipped = false
    private var heldAt: Date = .distantPast
    public init() {}
    public static let holdSeconds: TimeInterval = 1.5
    /// `peak` = the largest sample peak since the previous call (0 when nothing arrived).
    public mutating func update(peak: Float, now: Date = Date()) {
        if peak >= heldPeak || now.timeIntervalSince(heldAt) > Self.holdSeconds { heldPeak = peak; heldAt = now }
        if peak >= AudioLevelMath.clipPeak { clipped = true }
    }
    public mutating func clearClip() { clipped = false }
    public mutating func reset() { self = MeterReading() }
}

/// The four sizes the capture panel keeps apart for a screen, so none is mistaken for another:
/// logical (points), macOS internal render (backing pixels), the physical panel as macOS reports it, and the size of the file that will be recorded.
public struct SizeBreakdown: Equatable, Sendable {
    public var logicalW: Int, logicalH: Int          // points; 0 when not applicable
    public var scale: Double
    public var renderW: Int, renderH: Int            // backing store = points × scale
    public var panelW: Int, panelH: Int              // 0 = not reported
    public var fileW: Int, fileH: Int
    public init(logicalW: Int, logicalH: Int, scale: Double, renderW: Int, renderH: Int, panelW: Int, panelH: Int, fileW: Int, fileH: Int) {
        self.logicalW = logicalW; self.logicalH = logicalH; self.scale = scale; self.renderW = renderW; self.renderH = renderH
        self.panelW = panelW; self.panelH = panelH; self.fileW = fileW; self.fileH = fileH
    }
    /// The render is larger than the physical panel (a scaled/HiDPI mode): the file is NOT a measure of the panel.
    public var renderExceedsPanel: Bool { panelW > 0 && renderW > panelW }
    public var fileExceedsPanel: Bool { panelW > 0 && fileW > panelW }
    public var fileIsRender: Bool { fileW == renderW && fileH == renderH }

    public static func make(source s: SourceInfo, sourcePixels: (w: Int, h: Int), file: (w: Int, h: Int)) -> SizeBreakdown {
        let lw = s.kind == .display ? Int(s.pointsWidth.rounded()) : s.width, lh = s.kind == .display ? Int(s.pointsHeight.rounded()) : s.height
        return SizeBreakdown(logicalW: lw, logicalH: lh, scale: s.scale, renderW: sourcePixels.w, renderH: sourcePixels.h,
                             panelW: s.kind == .display ? s.panelWidth : 0, panelH: s.kind == .display ? s.panelHeight : 0, fileW: file.w, fileH: file.h)
    }
}

/// State of an on-demand camera preview. `gate` decides, from what macOS reports, whether it may start at all.
public enum CameraPreviewState: Equatable, Sendable {
    case off, loading, live, denied, restricted, absent, failed(String)
    /// nil = the preview may start (or, for "not determined", ask first). Never opens anything.
    public static func gate(auth: AVAuthorizationStatus, present: Bool) -> CameraPreviewState? {
        if !present { return .absent }
        switch auth { case .denied: return .denied; case .restricted: return .restricted; default: return nil }
    }
    public var isRunning: Bool { self == .loading || self == .live }
}
