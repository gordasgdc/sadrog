// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AppKit
import os
import SadrogCore

let overlayLog = Logger(subsystem: "dev.gordas.sadrog", category: "overlay")

/// Converts a global logical rect (ScreenCaptureKit: origin top-left of the primary display) to AppKit window coordinates.
func appKitRect(fromGlobal r: CGRect) -> CGRect {
    let h = NSScreen.screens.first?.frame.height ?? 0
    return CGRect(x: r.minX, y: h - r.maxY, width: r.width, height: r.height)
}

/// Temporary red frame that identifies a monitor/window. A guide only: the window is not shareable (excluded from any capture,
/// and the capture filter also excludes this application), ignores the mouse and does not touch the display configuration.
@MainActor
final class RedFrame {
    static let shared = RedFrame()
    private var window: NSWindow?
    private var hide: Task<Void, Never>?
    private var generation = 0
    var isVisible: Bool { window != nil }

    /// Shows the frame for `seconds`, then closes it. A newer `show` or an explicit `close` wins: a cancelled timer never closes a newer frame
    /// (before: the cancelled sleep returned at once and closed the frame that had just replaced it).
    func show(globalFrame: CGRect, seconds: Double = 2.0, reason: String = "") {
        overlayLog.notice("RedFrame show \(Int(globalFrame.width), privacy: .public)x\(Int(globalFrame.height), privacy: .public) at \(Int(globalFrame.minX), privacy: .public),\(Int(globalFrame.minY), privacy: .public) reason=\(reason, privacy: .public)")
        close()
        generation += 1; let g = generation
        let w = NSWindow(contentRect: appKitRect(fromGlobal: globalFrame), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = .clear; w.hasShadow = false; w.ignoresMouseEvents = true
        w.level = .screenSaver; w.sharingType = .none; w.isReleasedWhenClosed = false
        w.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        // no system open/close animation: measured 2026-10-29, the default animation kept the frame on screen ~200 ms after close
        // (shrinking to ~98 % and fading) — that was the 688×442 layer seen right after Record. Close must be immediate.
        w.animationBehavior = .none
        let v = NSView(frame: NSRect(origin: .zero, size: globalFrame.size)); v.wantsLayer = true
        v.layer?.borderColor = NSColor.systemRed.cgColor; v.layer?.borderWidth = 8
        w.contentView = v; w.orderFrontRegardless(); window = w
        hide = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9))
            guard !Task.isCancelled, let self, self.generation == g else { return }
            self.close()
        }
    }
    func close() { if window != nil { overlayLog.notice("RedFrame close") }; hide?.cancel(); window?.orderOut(nil); window = nil }
}

/// Full-display overlay to drag a region. Returns the rectangle in display-local logical points (origin top-left); Esc cancels.
@MainActor
final class RegionPicker {
    private var window: NSWindow?
    func pick(on display: SourceInfo, completion: @escaping (CGRect?) -> Void) {
        let w = PickerWindow(contentRect: appKitRect(fromGlobal: display.frame), styleMask: .borderless, backing: .buffered, defer: false)
        w.isOpaque = false; w.backgroundColor = NSColor.black.withAlphaComponent(0.25); w.level = .screenSaver; w.sharingType = .none; w.isReleasedWhenClosed = false
        let v = PickerView(frame: NSRect(origin: .zero, size: display.frame.size))
        v.done = { [weak self] rect in self?.window?.orderOut(nil); self?.window = nil; completion(rect) }
        w.contentView = v; w.makeKeyAndOrderFront(nil); w.makeFirstResponder(v); NSCursor.crosshair.push(); window = w
        NSApp.activate(ignoringOtherApps: true)
    }
}
private final class PickerWindow: NSWindow { override var canBecomeKey: Bool { true } }
private final class PickerView: NSView {
    var done: ((CGRect?) -> Void)?
    private var a: CGPoint?, b: CGPoint?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    private var rect: CGRect? { guard let a, let b else { return nil }; return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y)) }
    override func mouseDown(with e: NSEvent) { a = convert(e.locationInWindow, from: nil); b = a; needsDisplay = true }
    override func mouseDragged(with e: NSEvent) { b = convert(e.locationInWindow, from: nil); needsDisplay = true }   // any direction
    override func mouseUp(with e: NSEvent) { NSCursor.pop(); let r = rect; done?(r.map { $0.width >= 16 && $0.height >= 16 ? $0 : nil } ?? nil) }
    override func keyDown(with e: NSEvent) { if e.keyCode == 53 { NSCursor.pop(); done?(nil) } else { super.keyDown(with: e) } }
    override func draw(_ dirty: NSRect) {
        guard let r = rect else { return }
        NSColor.clear.setFill(); r.fill(using: .copy)
        NSColor.systemRed.setStroke(); let p = NSBezierPath(rect: r); p.lineWidth = 2; p.stroke()
        let t = "\(Int(r.width))×\(Int(r.height)) pt" as NSString
        t.draw(at: CGPoint(x: r.minX + 6, y: max(2, r.minY - 20)), withAttributes: [.foregroundColor: NSColor.white, .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)])
    }
}

/// Large circular countdown on each captured monitor, same tick on all of them. Non-activating, ignores the mouse, never shareable
/// (`sharingType = .none`; the capture filter also excludes this application) and closed with no animation before the first recorded frame.
@MainActor
final class CountdownOverlay {
    static let shared = CountdownOverlay()
    private var windows: [(NSWindow, NSTextField)] = []
    var isVisible: Bool { !windows.isEmpty }

    func show(_ n: Int, on frames: [CGRect]) {
        if windows.count != frames.count { close(); for f in frames { windows.append(make(for: f)) } }
        for (w, t) in windows { t.stringValue = "\(n)"; w.orderFrontRegardless() }
    }
    func close() { windows.forEach { $0.0.orderOut(nil) }; windows.removeAll() }

    private func make(for display: CGRect) -> (NSWindow, NSTextField) {
        let d = max(160, min(300, min(display.width, display.height) * 0.22))
        let rect = CGRect(x: display.midX - d / 2, y: display.midY - d / 2, width: d, height: d)
        let p = NSPanel(contentRect: appKitRect(fromGlobal: rect), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.ignoresMouseEvents = true
        p.level = .screenSaver; p.sharingType = .none; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]; p.animationBehavior = .none
        let v = NSView(frame: NSRect(origin: .zero, size: rect.size)); v.wantsLayer = true
        v.layer?.cornerRadius = d / 2; v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        v.layer?.borderColor = NSColor.white.withAlphaComponent(0.85).cgColor; v.layer?.borderWidth = 3
        let t = NSTextField(labelWithString: ""); t.font = .systemFont(ofSize: d * 0.55, weight: .semibold); t.textColor = .white; t.alignment = .center
        t.frame = NSRect(x: 0, y: (d - d * 0.66) / 2, width: d, height: d * 0.66); t.isBezeled = false; t.drawsBackground = false
        v.addSubview(t); p.contentView = v
        return (p, t)
    }
}
