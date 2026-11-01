// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import SadrogCore

/// Controls shared by the floating panel, the menu bar and the window: they all call the SAME RecorderModel / RecordFlow.
enum CaptureControlText {
    static func clock(_ t: TimeInterval) -> String { let s = max(0, Int(t)); return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) }
    @MainActor static func state(_ m: RecorderModel) -> String {
        switch m.phase {
        case .idle: return T("În repaus")
        case .preparing: return m.preparingCameras ? T("Se pregătesc camerele…") : T("Pregătire…")
        case .countdown(let n): return L10n.f("Începe în %d s", n)
        case .starting: return T("Pornește…")
        case .recording: return T("Înregistrează")
        case .paused: return T("În pauză")
        case .stopping: return T("Se salvează…")
        }
    }
}

/// Compact, movable panel shown from the countdown to the end of the recording. It belongs to SADROG, whose windows are excluded from every
/// screen capture filter (verified separately before it is declared working); it never appears in the recorded files by design.
struct CaptureControlView: View {
    @ObservedObject var m: RecorderModel
    var body: some View {
        HStack(spacing: 10) {
            DragGrip().frame(width: 14, height: 30).help(T("Trage pentru a muta panoul"))
            Circle().fill(m.phase == .recording ? Theme.C.record : (m.phase == .paused ? Theme.C.warn : Theme.C.textFaint)).frame(width: 9, height: 9)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(CaptureControlText.state(m)).font(Theme.F.smallMedium).foregroundStyle(Theme.C.text)
                Text(CaptureControlText.clock(m.elapsed)).font(Theme.F.monoSmall).foregroundStyle(Theme.C.textDim)
            }.frame(minWidth: 96, alignment: .leading).background(DragGrip(showsDots: false))
            switch m.phase {
            case .preparing, .countdown:
                Button(T("Anulează")) { m.cancelStart() }.buttonStyle(.gloss(.secondary, compact: true)).help(T("Anulează pornirea; nu se înregistrează nimic"))
            case .recording, .paused:
                IconButton(symbol: m.phase == .paused ? "play.fill" : "pause.fill", label: m.phase == .paused ? T("Reia toate sursele") : T("Pauză pentru toate sursele")) { m.togglePause() }
                IconButton(symbol: "stop.fill", label: T("Oprește și salvează")) { Task { await m.toggle() } }
            default: EmptyView()
            }
            IconButton(symbol: "eye.slash", label: T("Ascunde panoul (rechemare din meniul SADROG din bara de meniuri)")) { ControlPanel.shared.hidden = true }
        }
        .padding(.leading, 6).padding(.trailing, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.C.bg1.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.C.line, lineWidth: 1))
        .appTheme()
    }
}

/// A grip that moves the window by following the pointer (not through `isMovableByWindowBackground`, which SwiftUI content swallows).
/// It accepts the first click, so it works while another app is active, and it is the only draggable area next to the status text.
struct DragGrip: NSViewRepresentable {
    var showsDots = true
    final class V: NSView {
        var showsDots = true
        private var grab: NSPoint = .zero
        override var mouseDownCanMoveWindow: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        // The window follows the pointer itself (origin = pointer − grab point), so it needs no WindowServer drag session and works the same with real and posted events.
        override func mouseDown(with event: NSEvent) { grab = event.locationInWindow }
        override func mouseDragged(with event: NSEvent) {
            guard let w = window else { return }
            let p = Self.screenPoint(of: event)
            w.setFrameOrigin(NSPoint(x: p.x - grab.x, y: p.y - grab.y))
        }
        /// The pointer in AppKit screen coordinates, from the event itself (its global position), so it does not depend on where the window was when the event was built.
        static func screenPoint(of e: NSEvent) -> NSPoint {
            guard let cg = e.cgEvent, let primary = NSScreen.screens.first else { return NSEvent.mouseLocation }
            return NSPoint(x: cg.location.x, y: primary.frame.height - cg.location.y)
        }
        override func mouseUp(with event: NSEvent) { ControlPanel.shared.settle() }
        override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
        override func draw(_ dirtyRect: NSRect) {
            guard showsDots else { return }
            NSColor.tertiaryLabelColor.setFill()
            for row in 0..<3 { for col in 0..<2 {
                NSBezierPath(ovalIn: NSRect(x: bounds.midX - 5 + CGFloat(col) * 6, y: bounds.midY - 8 + CGFloat(row) * 6, width: 3, height: 3)).fill()
            } }
        }
    }
    func makeNSView(context: Context) -> V { let v = V(); v.showsDots = showsDots; return v }
    func updateNSView(_ v: V, context: Context) {}
}

/// The panel never becomes key or main: the app being recorded keeps focus and its menus.
final class CapturePanelWindow: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating panel: non-activating, draggable by its grip, position kept when valid and recovered when the screens change, on every Space.
/// It can be hidden (button on the panel) and recalled from the SADROG menu bar item while a recording is in progress.
@MainActor
final class ControlPanel: ObservableObject {
    static let shared = ControlPanel()
    static let defaultsKey = "sadrog.controlPanel.frame"
    private var panel: NSPanel?
    private var observers: [NSObjectProtocol] = []
    @Published private(set) var isActive = false
    @Published var hidden = false { didSet { if hidden != oldValue { applyVisibility() } } }
    var isVisible: Bool { panel?.isVisible ?? false }
    var frame: CGRect? { panel?.frame }

    func update(for m: RecorderModel) {
        switch m.phase {
        case .countdown, .starting, .recording, .paused, .stopping: isActive = true
        case .preparing: isActive = m.preparingCameras
        case .idle: isActive = false; if hidden { hidden = false }
        }
        if isActive { open(m) }
        applyVisibility()
    }
    private func applyVisibility() {
        if isActive && !hidden { panel?.orderFrontRegardless() } else { panel?.orderOut(nil) }
    }
    private func saved() -> CGRect? { UserDefaults.standard.string(forKey: Self.defaultsKey).map { NSRectFromString($0) } }
    /// After a drag: keep the panel on a screen and remember where it is.
    private var settling = false
    func settle() { settling = true; place(); settling = false; if let f = panel?.frame { UserDefaults.standard.set(NSStringFromRect(f), forKey: Self.defaultsKey) } }
    private func place() {
        guard let p = panel else { return }
        let screens = NSScreen.screens.map(\.visibleFrame)
        let f = PanelPlacement.resolve(saved: settling ? p.frame : (saved() ?? p.frame.nonEmptyOrNil), size: p.frame.size, screens: screens)
        if f != p.frame { p.setFrame(f, display: true) }
    }
    private func open(_ m: RecorderModel) {
        if panel == nil {
            let p = CapturePanelWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 52), styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
            p.isFloatingPanel = true; p.level = .floating; p.isMovableByWindowBackground = false; p.hidesOnDeactivate = false
            p.becomesKeyOnlyIfNeeded = true; p.worksWhenModal = true
            p.backgroundColor = .clear; p.isOpaque = false; p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.title = "SADROG — control"
            p.contentView = NSHostingView(rootView: CaptureControlView(m: m))
            panel = p
            let nc = NotificationCenter.default
            observers.append(nc.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let f = self?.panel?.frame, self?.panel?.isVisible == true { UserDefaults.standard.set(NSStringFromRect(f), forKey: ControlPanel.defaultsKey) } }
            })
            observers.append(nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.place() }
            })
            let size = p.contentView?.fittingSize ?? NSSize(width: 292, height: 52)
            p.setContentSize(size)
        }
        place()
    }
}
private extension CGRect { var nonEmptyOrNil: CGRect? { isEmpty || (origin == .zero) ? nil : self } }

/// Menu bar control: the same actions as the panel and the window.
struct MenuBarControls: View {
    @ObservedObject var m: RecorderModel
    @ObservedObject var panel = ControlPanel.shared
    var body: some View {
        Text("\(CaptureControlText.state(m)) · \(CaptureControlText.clock(m.elapsed))")
        Divider()
        switch m.phase {
        case .idle: Button(T("Înregistrează")) { Task { await m.toggle() } }.disabled(m.blocker != nil).help(m.blocker ?? T("Pornește înregistrarea cu sursele alese."))
        case .preparing, .countdown: Button(T("Anulează pornirea")) { m.cancelStart() }
        case .recording, .paused:
            Button(m.phase == .paused ? T("Reia toate sursele") : T("Pauză (toate sursele)")) { m.togglePause() }
            Button(T("Oprește și salvează")) { Task { await m.toggle() } }
        default: EmptyView()
        }
        if panel.isActive {
            Button(panel.hidden ? T("Arată panoul de control") : T("Ascunde panoul de control")) { panel.hidden.toggle() }
        }
        Divider()
        Button(T("Arată SADROG")) { NSApplication.shared.activate(); NSApplication.shared.windows.first { $0.title == "SADROG" }?.makeKeyAndOrderFront(nil) }
    }
}
