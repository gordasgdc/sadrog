// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AVKit
import SadrogCore

func tc(_ t: Double, fps: Double) -> String {
    let t = max(0, t); let f = max(1, Int(fps.rounded())); let total = Int((t * Double(f)).rounded(.down))
    return String(format: "%02d:%02d:%02d:%02d", total / f / 3600, total / f / 60 % 60, total / f % 60, total % f)
}
private func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { max(lo, min(hi, v)) }

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView { let v = AVPlayerView(); v.player = player; v.controlsStyle = .none; v.allowsVideoFrameAnalysis = false; return v }
    func updateNSView(_ v: AVPlayerView, context: Context) { v.player = player }
}

/// Thin separator that doubles as a resize handle (hit area wider than the drawn line).
struct ResizeHandle: View {
    var vertical: Bool                       // true = vertical bar resizing horizontally
    var onDrag: (CGFloat) -> Void            // delta since drag start
    var onEnd: () -> Void = {}
    @State private var last: CGFloat = 0
    var body: some View {
        Rectangle().fill(Theme.C.line).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
            .padding(vertical ? .horizontal : .vertical, 3).background(Color.clear).contentShape(Rectangle())
            .onHover { inside in if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { v in let p = vertical ? v.translation.width : v.translation.height; onDrag(p - last); last = p }
                .onEnded { _ in last = 0; onEnd() })
            .accessibilityLabel(vertical ? T("Redimensionează panoul") : T("Redimensionează timeline-ul"))
    }
}

/// Reports whether the window's first responder is an editable text view (a text field's field editor, a title editor) — observed by KVO, so
/// the editor knows text is being edited as soon as a field takes focus, before any key is typed.
struct TextFocusWatcher: NSViewRepresentable {
    var changed: (Bool) -> Void
    final class Probe: NSView {
        var changed: (Bool) -> Void = { _ in }
        private var obs: NSKeyValueObservation?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow(); obs = nil
            guard let w = window else { return }
            obs = w.observe(\.firstResponder, options: [.initial, .new]) { [weak self] w, _ in
                let editing = (w.firstResponder as? NSTextView)?.isEditable == true
                DispatchQueue.main.async { self?.changed(editing) }
            }
        }
    }
    func makeNSView(context: Context) -> Probe { let v = Probe(); v.changed = changed; return v }
    func updateNSView(_ v: Probe, context: Context) { v.changed = changed }
}

/// Gives the editor a workable window on first open (reference 1440×900 pt content, clamped to the screen); never shrinks a larger window.
struct WindowSizer: NSViewRepresentable {
    var width: CGFloat = 1440, height: CGFloat = 900
    final class Probe: NSView {
        var width: CGFloat = 1440, height: CGFloat = 900; private var done = false
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard !done, window != nil else { return }; done = true
            DispatchQueue.main.async { [weak self] in self?.fit() }
        }
        private func fit() {
            guard let w = window, let vis = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
            // dev/verification only: SADROG_CONTENT_SIZE=900x620 forces an exact content size (to check the minimum layout)
            if let e = ProcessInfo.processInfo.environment["SADROG_CONTENT_SIZE"]?.split(separator: "x").compactMap({ Double($0) }), e.count == 2 { w.setContentSize(NSSize(width: e[0], height: e[1])); return }
            let cw = min(width, vis.width), ch = min(height, vis.height - 28)
            let cur = w.contentRect(forFrameRect: w.frame)
            guard cur.width < cw || cur.height < ch else { return }
            var f = w.frameRect(forContentRect: NSRect(x: 0, y: 0, width: max(cur.width, cw), height: max(cur.height, ch)))
            f.origin = NSPoint(x: min(max(vis.minX, w.frame.minX), vis.maxX - f.width), y: max(vis.minY, min(w.frame.maxY, vis.maxY) - f.height))
            w.setFrame(f, display: true, animate: false)
        }
    }
    func makeNSView(context: Context) -> Probe { let v = Probe(); v.width = width; v.height = height; return v }
    func updateNSView(_ v: Probe, context: Context) {}
}

struct EditorView: View {
    @ObservedObject var m: EditorModel
    var addRecording: () -> Void = {}
    var close: () -> Void
    @State private var libW: CGFloat?
    @State private var inspW: CGFloat?
    @State private var tlH: CGFloat?
    /// Side panels can be hidden and brought back; selection and sizes live elsewhere, so nothing is lost.
    @AppStorage("editor.showLibrary") private var showLib = true
    @AppStorage("editor.showInspector") private var showInsp = true

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Rectangle().fill(Theme.C.line).frame(height: 1)
            GeometryReader { g in
                let th = clamp(tlH ?? g.size.height * 0.38, 230, max(230, g.size.height - 250))
                let lw = clamp(libW ?? g.size.width * 0.18, 176, min(360, g.size.width * 0.3)), iw = clamp(inspW ?? g.size.width * 0.21, 320, min(420, g.size.width * 0.34))
                // Wide window: the inspector spans the full height beside both viewer and timeline, so its sections stay reachable.
                // Narrow window: it shares the top row (the timeline toolbar needs the full width there; the inspector scrolls and has its category switch).
                let full = g.size.width >= 1180
                let viewer = HStack(spacing: 0) {
                    if showLib {
                        LibraryPanel(m: m).frame(width: lw)
                        ResizeHandle(vertical: true) { libW = clamp(lw + $0, 176, 360) }
                    }
                    VStack(spacing: 0) { stage; transport }.frame(minWidth: 240)
                }
                let handle = ResizeHandle(vertical: false) { tlH = clamp(th - $0, 230, max(230, g.size.height - 250)) }
                if full {
                    HStack(spacing: 0) {
                        VStack(spacing: 0) { viewer; handle; TimelinePanel(m: m).frame(height: th) }
                        if showInsp {
                            ResizeHandle(vertical: true) { inspW = clamp(iw - $0, 320, 420) }
                            InspectorPanel(m: m).frame(width: iw)
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            viewer
                            if showInsp {
                                ResizeHandle(vertical: true) { inspW = clamp(iw - $0, 320, 420) }
                                InspectorPanel(m: m).frame(width: iw)
                            }
                        }
                        handle
                        TimelinePanel(m: m).frame(height: th)
                    }
                }
            }
            statusBar
        }
        .background(Theme.C.bg0).foregroundStyle(Theme.C.text)
        .sheet(isPresented: $m.showExport) { ExportSheet(m: m) }
        .background(WindowSizer())
        .background(TextFocusWatcher { m.textEditing = $0 })
        .background(shortcuts)
    }

    private var shortcuts: some View {
        Group {
            Button("") { if m.tool == .blade { m.tool = .select } }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut(.escape, modifiers: []))
            Button("") { m.tool = .select }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("v", modifiers: []))
            Button("") { m.step(frames: -1) }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut(.leftArrow, modifiers: []))
            Button("") { m.step(frames: 1) }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut(.rightArrow, modifiers: []))
            Button("") { m.addMarkerHere() }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("m", modifiers: []))
            Button("") { m.setIn() }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("i", modifiers: []))
            Button("") { m.setOut() }.keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("o", modifiers: []))
        }.opacity(0).frame(width: 0, height: 0).accessibilityHidden(true)
    }

    private var topBar: some View {
        ZStack {
            HStack(spacing: Theme.S.md) {
                Button { m.closeAllPluginWindows(); close() } label: { Label(T("Înregistrări"), systemImage: "chevron.left") }.buttonStyle(.gloss(.ghost, compact: true)).help(T("Înapoi la pregătirea capturii"))
                LogoMark(small: true).frame(width: 24, height: 14).foregroundStyle(Theme.C.textDim)
                IconButton(symbol: "sidebar.left", label: showLib ? T("Ascunde biblioteca (⌃⌘S)") : T("Arată biblioteca (⌃⌘S)")) { showLib.toggle() }
                Spacer()
                Menu {
                    Button { addRecording() } label: { Label(T("Înregistrare nouă în acest proiect…"), systemImage: "record.circle") }
                    Button { m.importMaterials() } label: { Label(T("Importă video sau sunet…"), systemImage: "square.and.arrow.down") }
                } label: { Label(T("Adaugă"), systemImage: "plus") }
                    .menuStyle(.borderlessButton).fixedSize().help(T("Adaugă o înregistrare nouă sau importă un fișier existent")).accessibilityLabel(T("Adaugă înregistrare sau fișier"))
                IconButton(symbol: "sidebar.right", label: showInsp ? T("Ascunde inspectorul (⌥⌘I)") : T("Arată inspectorul (⌥⌘I)")) { showInsp.toggle() }
                Button { m.openExport() } label: { Label(T("Exportă"), systemImage: "square.and.arrow.up") }
                    .buttonStyle(.gloss(.primary)).disabled(m.project.clips.isEmpty || !m.missing.isEmpty)
            }
            VStack(spacing: 1) {
                ProjectNameField(name: m.project.name) { m.rename($0) }
                HStack(spacing: 5) { Circle().fill(Theme.C.ok).frame(width: 6, height: 6); Text(T("Salvat automat")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim) }
            }.frame(maxWidth: 360)
        }.padding(.horizontal, Theme.S.lg).frame(height: 50).background(Theme.C.bg3)
    }

    private var stage: some View {
        ZStack {
            Theme.C.stage
            if m.missing.isEmpty {
                GeometryReader { g in
                    let fr = m.viewerFrame
                    ZStack(alignment: .topLeading) {
                        PlayerSurface(player: m.player).frame(width: fr.width, height: fr.height).position(x: fr.midX, y: fr.midY)
                        if m.drawTool == nil { PickLayer(m: m, frame: fr) }
                        ViewerOverlay(m: m, frame: fr)
                        if m.drawTool == nil { CalloutOverlay(m: m, frame: fr) }
                        if let t = m.drawTool { DrawLayer(m: m, frame: fr, tool: t).id(t) }
                    }.coordinateSpace(name: "viewer").frame(width: g.size.width, height: g.size.height).clipped()
                    .background(ScrollPan { dx, dy in m.panView(dx: dx, dy: dy) })
                    .onAppear { m.stageSize = g.size }.onChange(of: g.size) { m.stageSize = $0; if let z = m.viewZoom { m.setViewZoom(z) } }
                }
            } else { EmptyState(symbol: "exclamationmark.triangle", title: T("Lipsește fișierul media"), detail: m.missing.joined(separator: "\n")) }
        }
    }

    /// Transport: one row when the viewer is wide; two rows (controls, then time + view tools) when narrow, so nothing is hidden at the minimum window size.
    private var transport: some View {
        ViewThatFits(in: .horizontal) {
            ZStack {
                transportControls
                HStack { timecodeField; Spacer(minLength: 0); transportDuration; transportViewTools }.padding(.horizontal, Theme.S.md)
            }.frame(minWidth: 700, maxHeight: .infinity).frame(height: 44)
            VStack(spacing: 4) {
                transportControls
                HStack(spacing: 6) { timecodeField; transportDuration; Spacer(minLength: 0); transportViewTools }.padding(.horizontal, Theme.S.md)
            }.frame(height: 76)
        }.background(Theme.C.bg1).overlay(alignment: .top) { Rectangle().fill(Theme.C.line).frame(height: 1) }
    }
    private var transportControls: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "backward.end.fill", label: T("La clipul anterior")) { m.jump(next: false) }
            IconButton(symbol: "backward.frame.fill", label: T("Un cadru înapoi"), shortcutHint: "←") { m.step(frames: -1) }
            Button { m.togglePlay() } label: { Image(systemName: m.playing ? "pause.fill" : "play.fill").font(Theme.F.iconLarge).frame(width: 34, height: 24) }
                .buttonStyle(.gloss(.secondary, compact: true)).keyboardShortcut(m.textEditing ? nil : KeyboardShortcut(.space, modifiers: [])).help(m.playing ? T("Pauză (Spațiu)") : T("Redă (Spațiu)")).accessibilityLabel(m.playing ? T("Pauză") : T("Redă"))
            IconButton(symbol: "forward.frame.fill", label: T("Un cadru înainte"), shortcutHint: "→") { m.step(frames: 1) }
            IconButton(symbol: "forward.end.fill", label: T("La clipul următor")) { m.jump(next: true) }
        }
    }
    private var timecodeField: some View {
        Text(tc(m.time, fps: m.fps)).font(Theme.F.mono).padding(.horizontal, 8).frame(width: 104, height: 24).fieldSurface().accessibilityLabel(T("Poziția cursorului"))
    }
    private var transportDuration: some View {
        Text(tc(m.project.timelineEnd, fps: m.fps)).font(Theme.F.mono).foregroundStyle(Theme.C.textFaint).frame(width: 104, alignment: .trailing).accessibilityLabel(T("Durata proiectului")).padding(.trailing, 6)
    }
    private var transportViewTools: some View {
        HStack(spacing: 4) {
            IconButton(symbol: "squareshape.split.2x2.dotted", label: m.alignOn ? T("Aliniere pe canvas activă: ghidaje galbene la margini, centru și alte elemente (⌘ în timpul tragerii o ocolește)") : T("Aliniere pe canvas oprită"), active: m.alignOn) { m.alignOn.toggle() }
            IconButton(symbol: "minus.magnifyingglass", label: T("Micșorează previzualizarea"), shortcutHint: "⌘−") { m.stepView(false) }
            viewMenu
            IconButton(symbol: "plus.magnifyingglass", label: T("Mărește previzualizarea"), shortcutHint: "⌘+") { m.stepView(true) }
        }
    }

    /// "Potrivire" and magnification of the viewer only; the clip's own scale/position live in the inspector.
    private var viewMenu: some View {
        Menu {
            Button(T("Potrivire în fereastră")) { m.fitView() }
            Divider()
            Toggle(T("Aliniere pe canvas (ghidaje)"), isOn: $m.alignOn)
            Divider()
            ForEach(ViewerFrame.steps, id: \.self) { z in Button("\(Int(z * 100))%") { m.setViewZoom(z) } }
        } label: {
            HStack(spacing: 4) {
                Text(m.viewZoom == nil ? T("Potrivire") : "\(Int((m.displayedZoom * 100).rounded()))%").font(Theme.F.body).lineLimit(1).fixedSize()
                Image(systemName: "chevron.down").font(Theme.F.glyph)
            }.padding(.horizontal, 8).frame(height: 24).fieldSurface()
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(T("Potrivire și zoom pentru previzualizare (nu schimbă clipul și nici exportul)")).accessibilityLabel(T("Zoom previzualizare"))
    }

    private var statusBar: some View {
        HStack {
            Circle().fill(Theme.C.ok).frame(width: 7, height: 7); Text(T("Proiect salvat")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim)
            if !m.message.isEmpty { Text("· \(m.message)").font(Theme.F.caption).foregroundStyle(Theme.C.textDim).lineLimit(1) }
            Spacer()
            Text(L10n.f("Durată totală: %@", "\(tc(m.project.timelineEnd, fps: m.fps))")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).monospacedDigit()
        }.padding(.horizontal, Theme.S.md).frame(height: 26).background(Theme.C.bg3).overlay(alignment: .top) { Rectangle().fill(Theme.C.line).frame(height: 1) }
    }
}

/// Project title, editable in place: Return or leaving the field saves it (as one undo step); Esc restores the saved name.
struct ProjectNameField: View {
    var name: String
    var commit: (String) -> Void
    @State private var text = ""
    @State private var hover = false
    @FocusState private var focused: Bool
    var body: some View {
        TextField(T("Nume proiect"), text: $text)
            .textFieldStyle(.plain).multilineTextAlignment(.center).font(Theme.F.heading).lineLimit(1)
            .focused($focused).padding(.horizontal, 8).frame(height: 22).frame(maxWidth: 320)
            .background(RoundedRectangle(cornerRadius: 5).fill(focused ? Theme.C.bg0 : (hover ? Theme.C.bg0.opacity(0.6) : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(focused ? Theme.C.sel : .clear, lineWidth: 1))
            .onHover { hover = $0 }
            .onAppear { text = name }.onChange(of: name) { if !focused { text = $0 } }
            .onSubmit { save(); focused = false }.onChange(of: focused) { if !$0 { save() } }
            .onExitCommand { text = name; focused = false }
            .help(T("Numele proiectului — clic pentru a-l redenumi")).accessibilityLabel(T("Numele proiectului"))
    }
    private func save() {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { text = name } else if t != name { commit(t); text = t }
    }
}

/// Delivers trackpad/wheel scrolling over the viewer as pan (only used while the frame is magnified beyond the stage).
struct ScrollPan: NSViewRepresentable {
    var onScroll: (CGFloat, CGFloat) -> Void
    func makeNSView(context: Context) -> Probe { let v = Probe(); v.onScroll = onScroll; return v }
    func updateNSView(_ v: Probe, context: Context) { v.onScroll = onScroll }
    final class Probe: NSView {
        var onScroll: ((CGFloat, CGFloat) -> Void)?
        private var monitor: Any?
        override func viewDidMoveToWindow() {
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] e in
                guard let self, e.window == self.window, self.bounds.contains(self.convert(e.locationInWindow, from: nil)) else { return e }
                self.onScroll?(e.scrollingDeltaX, e.scrollingDeltaY); return e
            }
        }
        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }
}

/// Direct manipulation of the selected video item in the viewer: outline, corner handles (uniform scale about the centre), body drag.
/// Pure UI over the same `Transform` values as the inspector (live while dragging, one undo step on release); it is not part of the composition, so it never reaches the export.
/// Drawing layer of the selection tools. A drag defines the selection from the pressed corner to the opposite one in ANY direction (rectangle, ellipse) or follows the
/// mouse (freehand); the gesture is turned into frame fractions through the displayed frame, so it stays correct when the preview is zoomed or panned.
/// Escape cancels the stroke in progress (a second Escape leaves the tool). Releasing creates the selection as one undo step.
struct DrawLayer: View {
    @ObservedObject var m: EditorModel
    let frame: CGRect
    let tool: DrawTool
    @State private var a: CGPoint?
    @State private var b: CGPoint = .zero
    @State private var path: [CGPoint] = []
    @State private var monitor: Any?
    private func frac(_ p: CGPoint) -> CGPoint { CGPoint(x: max(0, min(1, (p.x - frame.minX) / frame.width)), y: max(0, min(1, (p.y - frame.minY) / frame.height))) }
    private var box: CGRect? { a.map { CGRect(x: min($0.x, b.x), y: min($0.y, b.y), width: abs($0.x - b.x), height: abs($0.y - b.y)) } }
    private func cancelStroke() { a = nil; path = [] }
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.001).contentShape(Rectangle())
                .help(T("Trage în imagine pentru a desena zona evidențiată; Esc anulează."))
                .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("viewer"))
                    .onChanged { v in
                        if a == nil { a = v.startLocation; path = [v.startLocation] }
                        b = v.location
                        if tool == .freehand, let l = path.last, hypot(v.location.x - l.x, v.location.y - l.y) >= 3 { path.append(v.location) }
                    }
                    .onEnded { v in
                        defer { cancelStroke() }
                        guard let s = a else { return }
                        if tool == .freehand { m.commitDrawn(.freehand, box: .zero, points: (path + [v.location]).map { let f = frac($0); return CalloutPoint(x: Double(f.x), y: Double(f.y)) }) }
                        else if tool == .line || tool == .arrow {
                            let p0 = frac(s), p1 = frac(v.location)
                            m.commitDrawn(tool, box: .zero, points: [CalloutPoint(x: Double(p0.x), y: Double(p0.y)), CalloutPoint(x: Double(p1.x), y: Double(p1.y))])
                        } else {
                            let p0 = frac(s), p1 = frac(v.location)
                            m.commitDrawn(tool, box: CGRect(x: min(p0.x, p1.x), y: min(p0.y, p1.y), width: abs(p0.x - p1.x), height: abs(p0.y - p1.y)), points: [])
                        }
                    })
                .onHover { if $0 { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                .accessibilityLabel(T("Zonă de desenare a selecției")).accessibilityHint(T("Trage în previzualizare pentru a defini selecția; Escape anulează"))
            if a != nil {
                if tool == .freehand {
                    Path { p in for (i, q) in path.enumerated() { if i == 0 { p.move(to: q) } else { p.addLine(to: q) } } }.stroke(Theme.C.sel, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)).allowsHitTesting(false)
                } else if tool == .line || tool == .arrow, let s = a {
                    Path { p in p.move(to: s); p.addLine(to: b) }.stroke(Theme.C.sel, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                } else if let r = box {
                    (tool == .ellipse ? AnyShape(Ellipse()) : AnyShape(Rectangle())).stroke(Theme.C.sel, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])).frame(width: r.width, height: r.height).position(x: r.midX, y: r.midY).allowsHitTesting(false)
                }
            }
        }
        .onAppear { monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53 else { return e }
            if a != nil { cancelStroke() } else { m.drawTool = nil }
            return nil
        } }
        .onDisappear { if let mo = monitor { NSEvent.removeMonitor(mo); monitor = nil } }
    }
}

/// Region handles for the selected callout. The region lives in frame coordinates (fractions of the output frame), so it does not depend on the viewer zoom.
/// Edges and centre snap to the frame edges, centre and thirds while the magnet is on; the guides are drawn while dragging.
struct CalloutOverlay: View {
    @ObservedObject var m: EditorModel
    let frame: CGRect
    @State private var start: Callout?
    @State private var guideX: [Double] = []
    @State private var guideY: [Double] = []
    private let hs: CGFloat = 9
    private static let anchors: [Double] = [0, 1.0 / 3, 0.5, 2.0 / 3, 1]

    /// Snaps the given positions (any of them) to the nearest anchor within ~6 viewer points; returns the correction and the anchors hit.
    private func snap(_ vals: [Double], span: CGFloat) -> (delta: Double, hit: [Double]) {
        guard m.alignOn else { return (0, []) }
        let th = Double(6 / span); var best: (d: Double, a: Double)?
        for v in vals { for a in Self.anchors where abs(a - v) <= th && (best == nil || abs(a - v) < abs(best!.d)) { best = (a - v, a) } }
        guard let b = best else { return (0, []) }
        return (b.d, [b.a])
    }
    @State private var lensStart: CGPoint?
    private func finish() { m.commitCallout(); start = nil; guideX = []; guideY = [] }
    /// Outline of the selection inside its box (rounded rectangle, ellipse or the freehand polygon), plus the box itself when the shape is not a rectangle.
    @ViewBuilder private func outline(_ c: Callout) -> some View {
        GeometryReader { g in
            switch c.shape {
            case .ellipse: Ellipse().strokeBorder(Theme.C.sel, lineWidth: 1.5); Rectangle().strokeBorder(Theme.C.sel.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .freehand:
                Path { p in for (i, q) in c.points.enumerated() { let pt = CGPoint(x: q.x * g.size.width, y: q.y * g.size.height); if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) } }; p.closeSubpath() }.stroke(Theme.C.sel, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                Rectangle().strokeBorder(Theme.C.sel.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .line, .arrow:
                if c.points.count >= 2 { Path { p in p.move(to: CGPoint(x: c.points[0].x * g.size.width, y: c.points[0].y * g.size.height)); p.addLine(to: CGPoint(x: c.points[1].x * g.size.width, y: c.points[1].y * g.size.height)) }.stroke(Theme.C.sel.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
                Rectangle().strokeBorder(Theme.C.sel.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            case .rect: RoundedRectangle(cornerRadius: c.corner * min(g.size.width, g.size.height)).strokeBorder(Theme.C.sel, lineWidth: 1.5)
            }
        }
    }

    var body: some View {
        if let c = m.selectedCallout, m.time >= c.start, m.time < c.end, !m.isOff(.c) {
            let W = frame.width, H = frame.height
            let rect = CGRect(x: frame.minX + c.x * W, y: frame.minY + c.y * H, width: c.w * W, height: c.h * H)
            ZStack(alignment: .topLeading) {
                ForEach(guideX, id: \.self) { a in Rectangle().fill(Theme.C.sel.opacity(0.9)).frame(width: 1, height: H).position(x: frame.minX + a * W, y: frame.midY).allowsHitTesting(false) }
                ForEach(guideY, id: \.self) { a in Rectangle().fill(Theme.C.sel.opacity(0.9)).frame(width: W, height: 1).position(x: frame.midX, y: frame.minY + a * H).allowsHitTesting(false) }
                Color.white.opacity(0.001).overlay(outline(c)).contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .gesture(SpatialTapGesture(coordinateSpace: .named("viewer")).onEnded { v in
                        let k = frame.width / max(1, m.renderSize.width); m.pick(canvas: CGPoint(x: (v.location.x - frame.minX) / k, y: (v.location.y - frame.minY) / k), cycle: false) })
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            let b = start ?? c; start = b
                            var nx = b.x + Double(v.translation.width / W), ny = b.y + Double(v.translation.height / H)
                            let sx = snap([nx, nx + b.w / 2, nx + b.w], span: W), sy = snap([ny, ny + b.h / 2, ny + b.h], span: H)
                            nx += sx.delta; ny += sy.delta; guideX = sx.hit; guideY = sy.hit
                            m.liveCallout { $0.x = nx; $0.y = ny }
                        }
                        .onEnded { _ in finish() })
                    .onHover { if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .accessibilityLabel(T("Regiunea evidențiată")).accessibilityHint(T("Trage pentru a muta regiunea"))
                    .position(x: rect.midX, y: rect.midY)
                // eight handles: sx/sy = -1 left/top, 0 none, 1 right/bottom
                ForEach(Array([(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)].enumerated()), id: \.offset) { _, d in
                    let sx = d.0, sy = d.1
                    Rectangle().fill(Theme.C.sel).frame(width: hs, height: hs).overlay(Rectangle().strokeBorder(Theme.C.bg0, lineWidth: 1))
                        .padding(5).contentShape(Rectangle())
                        .help(T("Mâner de formă: trage pentru a schimba zona evidențiată."))
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                            .onChanged { v in
                                let b = start ?? c; start = b
                                var l = b.x, t = b.y, r = b.x + b.w, bt = b.y + b.h
                                let dx = Double(v.translation.width / W), dy = Double(v.translation.height / H)
                                var hx: [Double] = [], hy: [Double] = []
                                if sx < 0 { l += dx; let s = snap([l], span: W); l += s.delta; hx = s.hit } else if sx > 0 { r += dx; let s = snap([r], span: W); r += s.delta; hx = s.hit }
                                if sy < 0 { t += dy; let s = snap([t], span: H); t += s.delta; hy = s.hit } else if sy > 0 { bt += dy; let s = snap([bt], span: H); bt += s.delta; hy = s.hit }
                                l = max(0, min(l, r - Callout.minSide)); r = min(1, max(r, l + Callout.minSide)); t = max(0, min(t, bt - Callout.minSide)); bt = min(1, max(bt, t + Callout.minSide))
                                guideX = hx; guideY = hy
                                m.liveCallout { $0.w = r - l; $0.h = bt - t; $0.x = l; $0.y = t }
                            }
                            .onEnded { _ in finish() })
                        .onHover { if $0 { (sx == 0 ? NSCursor.resizeUpDown : (sy == 0 ? NSCursor.resizeLeftRight : NSCursor.crosshair)).push() } else { NSCursor.pop() } }
                        .accessibilityLabel(T("Mâner de redimensionare a regiunii"))
                        .position(x: rect.midX + CGFloat(sx) * rect.width / 2, y: rect.midY + CGFloat(sy) * rect.height / 2)
                }
                if c.isLens {       // the magnified area: where the whole selection is shown; drag it anywhere in the frame
                    let b = c.displayBox, dr = CGRect(x: frame.minX + b.minX * W, y: frame.minY + b.minY * H, width: b.width * W, height: b.height * H)
                    ZStack(alignment: .topLeading) {
                        Rectangle().strokeBorder(Theme.C.warn, style: StrokeStyle(lineWidth: 2, dash: [6, 3]))
                        Text(L10n.f("Lupă %@×", String(format: "%.1f", c.lensEffective))).font(Theme.F.small).foregroundStyle(Theme.C.bg0).padding(.horizontal, 5).padding(.vertical, 1).background(Theme.C.warn).offset(x: 0, y: -16)
                    }
                    .frame(width: dr.width, height: dr.height).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            let o = lensStart ?? CGPoint(x: b.minX, y: b.minY); lensStart = o
                            m.liveCallout { $0.lensX = Double(o.x) + Double(v.translation.width / W); $0.lensY = Double(o.y) + Double(v.translation.height / H) }
                        }
                        .onEnded { _ in lensStart = nil; m.commitCallout() })
                    .onHover { if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .accessibilityLabel(T("Zona mărită (lupă)")).accessibilityHint(T("Trage pentru a muta zona mărită"))
                    .position(x: dr.midX, y: dr.midY)
                }
            }.frame(width: frame.maxX, height: frame.maxY, alignment: .topLeading)
        }
    }
}

struct ViewerOverlay: View {
    @ObservedObject var m: EditorModel
    let frame: CGRect
    @State private var start: Transform?
    @State private var guideX: [Double] = []      // canvas pixels; drawn only while a move actually aligns, never exported
    @State private var guideY: [Double] = []
    @State private var startDist: CGFloat = 1
    @State private var cropStart: (crop: RectCrop, t: Transform)?   // crop handles: the state when the drag began
    @State private var startCrop: CircleCrop?      // ⌥-drag: framing of the picture inside a presenter circle
    private let hs: CGFloat = 9

    private var lane: TrackLane { m.selectedText != nil ? .t : (m.selectedLayer != nil ? .v2 : .v1) }
    private func live(_ id: UUID, _ b: Transform, x: Double? = nil, y: Double? = nil, scale: Double? = nil, rotation: Double? = nil) {
        m.liveTransform(id, Transform(x: x ?? b.x, y: y ?? b.y, scale: scale ?? b.scale, opacity: b.opacity, rotation: rotation ?? b.rotation))
    }
    private func finish(_ id: UUID) { if let t = m.selectedTransform { m.commitTransform(id, t) }; start = nil; guideX = []; guideY = [] }

    var body: some View {
        ZStack(alignment: .topLeading) {
            let k = frame.width / max(1, m.renderSize.width)
            ForEach(guideX, id: \.self) { gx in Rectangle().fill(Theme.C.sel.opacity(0.9)).frame(width: 1, height: frame.height).position(x: frame.minX + CGFloat(gx) * k, y: frame.midY).allowsHitTesting(false) }
            ForEach(guideY, id: \.self) { gy in Rectangle().fill(Theme.C.sel.opacity(0.9)).frame(width: frame.width, height: 1).position(x: frame.midX, y: frame.minY + CGFloat(gy) * k).allowsHitTesting(false) }
            item
        }.frame(width: frame.maxX, height: frame.maxY, alignment: .topLeading)
    }

    /// Direct crop: eight handles on the picture's edges and corners. The opposite sides stay put and the kept pixels do not move on the canvas;
    /// one drag = one undo step. Drag outward to give back what was cut.
    @State private var framingBase: CircleCrop?
    @State private var framingDist: CGFloat = 1
    /// Framing mode: the circle (side `w` on screen) stays; the whole camera rectangle is the draggable picture, its corners scale it.
    /// The rectangle and handles are editing guides only (the compositor draws the faded picture in the preview, never in an export).
    @ViewBuilder private func framingLayer(w: CGFloat, centre: CGPoint) -> some View {
        if let crop = m.selectedCrop, let n = m.selectedMedia.flatMap({ m.media[$0]?.size }), n.width > 0 {
            let side = min(n.width, n.height) / CGFloat(crop.zoom), perPx = w / side
            let win = crop.window(in: n)
            let rw = n.width * perPx, rh = n.height * perPx
            let cx = w / 2 + (n.width / 2 - win.midX) * perPx, cy = w / 2 + (n.height / 2 - win.midY) * perPx       // rectangle centre in the circle's local space
            ZStack {
                Rectangle().fill(Color.white.opacity(0.001)).frame(width: rw, height: rh)
                    .overlay(Rectangle().strokeBorder(Theme.C.sel, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            if framingBase == nil { framingBase = crop }
                            m.framingPan(from: framingBase ?? crop, by: CGSize(width: v.translation.width / perPx, height: v.translation.height / perPx))
                        }
                        .onEnded { _ in framingBase = nil; m.commitCrop() })
                    .onHover { if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .accessibilityLabel(T("Imaginea camerei în cerc")).accessibilityHint(T("Trage pentru a alege ce apare în cerc; cercul rămâne pe loc"))
                    .position(x: cx, y: cy)
                Circle().strokeBorder(Theme.C.sel, lineWidth: 2).frame(width: w, height: w).allowsHitTesting(false)
                ForEach(0..<4, id: \.self) { i in
                    let sx: CGFloat = i % 2 == 0 ? -1 : 1, sy: CGFloat = i < 2 ? -1 : 1
                    Rectangle().fill(Theme.C.sel).frame(width: 9, height: 9).overlay(Rectangle().strokeBorder(Theme.C.bg0, lineWidth: 1))
                        .padding(6).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                            .onChanged { v in
                                // scaling about the circle's centre: the ratio of the pointer's distance from it
                                let cc = centre
                                if framingBase == nil { framingBase = crop; framingDist = max(8, hypot(v.startLocation.x - cc.x, v.startLocation.y - cc.y)) }
                                let r = hypot(v.location.x - cc.x, v.location.y - cc.y) / framingDist
                                m.framingZoom(from: framingBase ?? crop, to: (framingBase ?? crop).zoom * Double(r))
                            }
                            .onEnded { _ in framingBase = nil; m.commitCrop() })
                        .onHover { if $0 { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                        .accessibilityLabel(T("Mâner de scalare a imaginii")).accessibilityHint(T("Trage pentru a mări sau micșora imaginea în cerc"))
                        .position(x: cx + sx * rw / 2, y: cy + sy * rh / 2)
                }
            }.frame(width: w, height: w)
        }
    }
    @ViewBuilder private func cropLayer(id: UUID, w: CGFloat, h: CGFloat, k: CGFloat, R: CGSize) -> some View {
        if let n0 = m.selectedMedia.flatMap({ m.media[$0]?.size }), n0.width > 0 {
            let spots: [(CGFloat, CGFloat)] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
            Path { p in
                for f: CGFloat in [1.0 / 3, 2.0 / 3] { p.move(to: CGPoint(x: w * f, y: 0)); p.addLine(to: CGPoint(x: w * f, y: h)); p.move(to: CGPoint(x: 0, y: h * f)); p.addLine(to: CGPoint(x: w, y: h * f)) }
            }.stroke(Color.white.opacity(0.28), lineWidth: 0.5).allowsHitTesting(false)
            Rectangle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5).frame(width: w, height: h).allowsHitTesting(false)
            ForEach(spots.indices, id: \.self) { i in
                let (sx, sy) = spots[i]
                let edgeH = sy == 0, edgeV = sx == 0
                RoundedRectangle(cornerRadius: 2).fill(Color.white).frame(width: edgeV ? 24 : (edgeH ? 6 : 11), height: edgeH ? 24 : (edgeV ? 6 : 11))
                    .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.45), lineWidth: 0.7))
                    .padding(7).contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                        .onChanged { v in cropDrag(v.translation, sx: sx, sy: sy, n0: n0, k: k, R: R) }
                        .onEnded { _ in cropStart = nil; m.commitRectCrop() })
                    .onHover { if $0 { (edgeH ? NSCursor.resizeLeftRight : (edgeV ? NSCursor.resizeUpDown : NSCursor.crosshair)).push() } else { NSCursor.pop() } }
                    .accessibilityLabel(T("Mâner de decupare"))
                    .position(x: w / 2 + sx * w / 2, y: h / 2 + sy * h / 2)
            }
        }
    }
    private func cropDrag(_ tr: CGSize, sx: CGFloat, sy: CGFloat, n0: CGSize, k: CGFloat, R: CGSize) {
        if cropStart == nil, let t = m.selectedTransform { cropStart = (m.selectedRectCrop ?? RectCrop(), t) }
        guard let st = cropStart else { return }
        let w0 = st.crop.window(of: n0), f0 = min(R.width / w0.width, R.height / w0.height)
        let sp = Double(f0 * k) * st.t.scale                       // screen points per source pixel
        let a = st.t.rotation * .pi / 180
        let lx = Double(tr.width) * cos(a) + Double(tr.height) * sin(a), ly = -Double(tr.width) * sin(a) + Double(tr.height) * cos(a)    // drag in the picture's own axes
        let dx = lx / sp / Double(n0.width), dy = ly / sp / Double(n0.height)
        var c = st.crop
        if sx < 0 { c.left = max(0, c.left + dx) } else if sx > 0 { c.right = max(0, c.right - dx) }
        if sy < 0 { c.top = max(0, c.top + dy) } else if sy > 0 { c.bottom = max(0, c.bottom - dy) }
        c.normalize()
        m.liveRectCrop(c, transform: RectCrop.placement(from: st.crop, to: c, st.t, natural: n0, render: R))
    }

    @ViewBuilder private var item: some View {
        if let id = m.selection, let e = m.selectedTransform, let t = m.displayTransform, let nat = m.selectedNatural,
           m.time >= m.selectedStart, m.time < m.selectedStart + m.selectedDuration, !m.isOff(lane) {      // a hidden lane draws nothing, so no frame to grab
            let R = m.renderSize; let k = frame.width / R.width
            let s = (nat.fit ? min(R.width / nat.size.width, R.height / nat.size.height) : 1) * t.scale * k
            let w = nat.size.width * s, h = nat.size.height * s
            let c = CGPoint(x: frame.minX + (R.width / 2 + t.x * R.width) * k, y: frame.minY + (R.height / 2 + t.y * R.height) * k)
            let cropMode = m.cropEditing && m.selectedVideoID != nil && m.selectedCrop == nil && !m.selectedAnimated
            ZStack {
                Color.white.opacity(0.001).overlay {
                    if m.selectedCrop != nil { Circle().strokeBorder(Theme.C.sel, lineWidth: 1) } else { Rectangle().strokeBorder(Theme.C.sel, lineWidth: 1) }
                }.contentShape(m.selectedCrop != nil ? AnyShape(Circle()) : AnyShape(Rectangle()))
                    .gesture(SpatialTapGesture(coordinateSpace: .named("viewer")).onEnded { v in m.pick(canvas: CGPoint(x: (v.location.x - frame.minX) / k, y: (v.location.y - frame.minY) / k), cycle: true) })
                    .gesture(DragGesture(minimumDistance: 2, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            // ⌥ + drag on a presenter circle moves the PICTURE inside it; the circle stays where it is
                            if let crop = startCrop ?? m.selectedCrop, startCrop != nil || NSEvent.modifierFlags.contains(.option),
                               let n = m.selectedMedia.flatMap({ m.media[$0]?.size }), n.width > 0 {
                                if startCrop == nil { startCrop = crop }
                                let side = Double(min(n.width, n.height)) / crop.zoom, perPx = Double(w) / side
                                let fx = (Double(n.width) - side) / 2 * perPx, fy = (Double(n.height) - side) / 2 * perPx
                                var c = crop
                                if fx > 0.5 { c.offsetX = crop.offsetX - Double(v.translation.width) / fx }
                                if fy > 0.5 { c.offsetY = crop.offsetY - Double(v.translation.height) / fy }
                                m.liveCrop(c); return
                            }
                            let b = start ?? e; start = b
                            var nx = b.x + Double(v.translation.width / frame.width), ny = b.y + Double(v.translation.height / frame.height)
                            // canvas alignment: edges/centre to the canvas and to the other visible items, 6 screen points whatever the zoom
                            if m.alignOn && !NSEvent.modifierFlags.contains(.command) {
                                let box = m.canvasBox(natural: nat.size, fit: nat.fit, Transform(x: nx, y: ny, scale: t.scale, rotation: t.rotation))
                                let r = CanvasAlign.snap(moving: box, others: m.otherCanvasBoxes(excluding: id), canvas: R, threshold: Double(6 / max(k, 0.0001)))
                                nx += r.dx / Double(R.width); ny += r.dy / Double(R.height); guideX = r.guidesX; guideY = r.guidesY
                            } else { guideX = []; guideY = [] }
                            live(id, b, x: nx, y: ny)
                        }
                        .onEnded { _ in if startCrop != nil { startCrop = nil; m.commitCrop() } else { finish(id) } })
                    .onHover { if $0 { NSCursor.openHand.push() } else { NSCursor.pop() } }
                    .accessibilityLabel(T("Cadrul elementului selectat")).accessibilityHint(m.selectedCrop != nil ? T("Trage pentru a muta cercul; cu Option apăsat muți imaginea în cerc") : T("Trage pentru a muta")).help(m.selectedCrop != nil ? T("Trage pentru a muta cercul; cu Option apăsat muți imaginea în cerc. Pentru încadrare fină folosește „Încadrează imaginea în cerc” din inspector.") : T("Trage pentru a muta elementul; mânerele din colțuri scalează, cel de sus rotește."))
                if m.circleFraming, m.selectedCrop != nil { framingLayer(w: w, centre: c) } else if cropMode { cropLayer(id: id, w: w, h: h, k: k, R: R) } else {
                ForEach(0..<4, id: \.self) { i in
                    let sx: CGFloat = i % 2 == 0 ? -1 : 1, sy: CGFloat = i < 2 ? -1 : 1
                    Rectangle().fill(Theme.C.sel).frame(width: hs, height: hs).overlay(Rectangle().strokeBorder(Theme.C.bg0, lineWidth: 1))
                        .padding(5).contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                            .onChanged { v in
                                if t.rotation != 0 {
                                    // a rotated frame scales about its centre
                                    if start == nil { start = e; startDist = max(4, hypot(v.startLocation.x - c.x, v.startLocation.y - c.y)) }
                                    let b = start ?? e, r = max(0.05, hypot(v.location.x - c.x, v.location.y - c.y) / startDist)
                                    live(id, b, scale: b.scale * Double(r)); return
                                }
                                // the opposite corner stays fixed; the item scales uniformly towards the pointer
                                let o = CGPoint(x: c.x - sx * w / 2, y: c.y - sy * h / 2)
                                if start == nil { start = e; startDist = max(4, hypot(v.startLocation.x - o.x, v.startLocation.y - o.y)) }
                                let b = start ?? e, r = max(0.05, hypot(v.location.x - o.x, v.location.y - o.y) / startDist)
                                let c0 = CGPoint(x: frame.minX + (R.width / 2 + b.x * R.width) * k, y: frame.minY + (R.height / 2 + b.y * R.height) * k)
                                // `c`, `w`, `h` track the live value, so derive the fixed corner from the start state instead
                                let ratio = b.scale == 0 ? 1 : b.scale / t.scale
                                let oS = CGPoint(x: c0.x - sx * (w * ratio) / 2, y: c0.y - sy * (h * ratio) / 2)
                                let nc = CGPoint(x: oS.x + (c0.x - oS.x) * r, y: oS.y + (c0.y - oS.y) * r)
                                live(id, b, x: Double((nc.x - frame.minX) / k / R.width - 0.5), y: Double((nc.y - frame.minY) / k / R.height - 0.5), scale: b.scale * Double(r))
                            }
                            .onEnded { _ in finish(id) })
                        .onHover { if $0 { NSCursor.crosshair.push() } else { NSCursor.pop() } }
                        .accessibilityLabel(T("Mâner de redimensionare")).help(T("Mâner de redimensionare: trage pentru a scala elementul; colțul opus rămâne pe loc."))
                        .position(x: w / 2 + sx * w / 2, y: h / 2 + sy * h / 2)       // after the gesture: the hit area is the handle, not the whole frame
                }
                Rectangle().fill(Theme.C.sel).frame(width: 1, height: 14).position(x: w / 2, y: -7).allowsHitTesting(false)
                Circle().fill(Theme.C.sel).frame(width: 11, height: 11).overlay(Circle().strokeBorder(Theme.C.bg0, lineWidth: 1)).padding(5).contentShape(Circle())
                    .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("viewer"))
                        .onChanged { v in
                            let b = start ?? e; start = b
                            var ang = atan2(v.location.x - c.x, -(v.location.y - c.y)) * 180 / .pi
                            if m.alignOn { for q in stride(from: -180.0, through: 180, by: 45) where abs(ang - q) < 4 { ang = q } }
                            live(id, b, rotation: Double(ang))
                        }
                        .onEnded { _ in finish(id) })
                    .onHover { if $0 { NSCursor.pointingHand.push() } else { NSCursor.pop() } }
                    .accessibilityLabel(T("Mâner de rotație")).accessibilityHint(T("Trage pentru a roti; se lipește la 45°")).help(T("Mâner de rotație: trage pentru a roti elementul; se lipește la 45°."))
                    .position(x: w / 2, y: -21)
                }
            }.frame(width: w, height: h).rotationEffect(.degrees(t.rotation)).position(c)
        }
    }
}

struct EmptyState: View {
    let symbol: String, title: String, detail: String
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 24, weight: .light)).foregroundStyle(Theme.C.textFaint)
            Text(title).font(Theme.F.heading).foregroundStyle(Theme.C.text)
            Text(detail).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).multilineTextAlignment(.center)
        }.padding()
    }
}

// MARK: library
struct LibraryPanel: View {
    @ObservedObject var m: EditorModel
    @State private var picked: String?
    private var items: [(name: String, duration: Double, path: String)] {
        var l = m.materials.filter { m.search.isEmpty || $0.name.localizedCaseInsensitiveContains(m.search) }
        switch m.libraryFilter {
        case .all: break
        case .video: l = l.filter { m.media[$0.path]?.hasVideo != false }
        case .audio: l = l.filter { m.media[$0.path]?.hasVideo == false }
        case .missing: l = l.filter { !m.fileExists($0.path) }
        }
        switch m.librarySort {
        case .added: break
        case .name: l.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .duration: l.sort { $0.duration > $1.duration }
        }
        return l
    }
    private func filterTitle(_ f: LibraryFilter) -> String { switch f { case .all: return T("Toate"); case .video: return T("Video"); case .audio: return T("Doar sunet"); case .missing: return T("Lipsă") } }
    private func sortTitle(_ s: LibrarySort) -> String { switch s { case .added: return T("Ordinea importului"); case .name: return T("Nume"); case .duration: return T("Durată") } }
    private func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
    /// The selected material: facts about the file and the ways to place it. Appears only with a selection (no permanent instructions).
    @ViewBuilder private func details(_ p: String) -> some View {
        let info = m.media[p], gone = !m.fileExists(p)
        let v = info?.hasVideo != false, a = info?.hasAudio != false
        VStack(alignment: .leading, spacing: 6) {
            HairlineDivider()
            Text(URL(fileURLWithPath: p).lastPathComponent).font(Theme.F.heading).lineLimit(1).truncationMode(.middle)
            if gone {
                Text(T("Fișierul nu mai este la locul lui.")).font(Theme.F.caption).foregroundStyle(Theme.C.warn)
                Button { m.relink(p) } label: { Label(T("Relegă fișierul…"), systemImage: "link").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.primary, compact: true))
            } else {
                InfoRow(label: T("Tip"), value: v ? T("Video") : T("Doar sunet"))
                InfoRow(label: T("Durată"), value: timecode(info?.duration ?? 0, frames: true))
                if v, let z = info?.size, z.width > 0 { InfoRow(label: T("Rezoluție"), value: "\(Int(z.width))×\(Int(z.height)) · \(String(format: "%g", info?.fps ?? 0)) fps") }
                Button { add(p, .main) } label: { Label(T("În secvență"), systemImage: "plus.rectangle").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).disabled(!v)
                HStack(spacing: 6) {
                    Button { add(p, .overlay) } label: { Label(T("V2"), systemImage: "square.2.layers.3d").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).disabled(!v).help(T("Adaugă ca suprapunere video la cursor"))
                    Button { add(p, .audio) } label: { Label(T("A2"), systemImage: "waveform").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).disabled(!a).help(T("Adaugă ca sunet separat la cursor"))
                }
            }
        }
    }
    private func add(_ path: String, _ lane: Lane) {
        switch lane { case .main: m.addToMain(path); case .overlay: m.addAsOverlay(path); case .audio: m.addAsAudio(path); case .text, .callout: break }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.S.md) {
            HStack {
                Text(T("Materiale")).font(Theme.F.heading).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                ViewThatFits(in: .horizontal) {
                    Button { m.importMaterials() } label: { Label(T("Importă"), systemImage: "square.and.arrow.down").lineLimit(1).fixedSize() }.buttonStyle(.gloss(.secondary, compact: true)).help(T("Importă video sau sunet în bibliotecă"))
                    IconButton(symbol: "square.and.arrow.down", label: T("Importă video sau sunet în bibliotecă")) { m.importMaterials() }
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(Theme.F.small).foregroundStyle(Theme.C.textFaint)
                TextField(T("Caută materiale…"), text: $m.search).textFieldStyle(.plain).font(Theme.F.body)
                Menu {
                    Section(T("Filtru")) { ForEach(LibraryFilter.allCases, id: \.self) { f in Button { m.libraryFilter = f } label: { if m.libraryFilter == f { Label(filterTitle(f), systemImage: "checkmark") } else { Text(filterTitle(f)) } } } }
                    Section(T("Sortare")) { ForEach(LibrarySort.allCases, id: \.self) { o in Button { m.librarySort = o } label: { if m.librarySort == o { Label(sortTitle(o), systemImage: "checkmark") } else { Text(sortTitle(o)) } } } }
                } label: { Image(systemName: "line.3.horizontal.decrease").font(Theme.F.iconSmall).foregroundStyle(m.libraryFilter == .all && m.librarySort == .added ? Theme.C.textDim : Theme.C.accent) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help(T("Filtre și sortare")).accessibilityLabel(T("Filtre și sortare"))
            }.padding(.horizontal, 8).frame(height: 26).fieldSurface()
            ScrollView {
                if items.isEmpty { Text(T("Niciun material găsit.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).frame(maxWidth: .infinity).padding(.top, 20) }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 88), spacing: 10, alignment: .top)], alignment: .leading, spacing: 14) {
                    ForEach(items, id: \.path) { it in
                        let info = m.media[it.path]
                        MaterialCell(name: it.name, duration: it.duration, poster: info?.poster, audioOnly: info?.hasVideo == false, selected: picked == it.path, missing: !m.fileExists(it.path))
                            .onTapGesture(count: 2) { add(it.path, info?.hasVideo == false ? .audio : .main) }
                            .onTapGesture { picked = it.path }
                            .contextMenu {
                                if !m.fileExists(it.path) { Button(T("Relegă fișierul…")) { m.relink(it.path) }; Divider() }
                                Button(T("Adaugă la secvența principală")) { add(it.path, .main) }.disabled(info?.hasVideo == false)
                                Button(T("Adaugă ca suprapunere (V2)")) { add(it.path, .overlay) }.disabled(info?.hasVideo == false)
                                Button(T("Adaugă ca sunet separat (A2)")) { add(it.path, .audio) }.disabled(info?.hasAudio == false)
                                Divider()
                                Button(T("Arată în Finder")) { reveal(it.path) }.disabled(!m.fileExists(it.path))
                            }.help(it.path)
                            .onDrag { m.libraryDrag = [it.path]; return libraryProvider(it.path) }
                    }
                }
            }
            if let p = picked { details(p) }
        }.padding(Theme.S.md).frame(maxHeight: .infinity, alignment: .top).background(Theme.C.bg1)
            .onDrop(of: [.fileURL], delegate: LibraryDropDelegate(m: m))
    }
}
struct MaterialCell: View {
    let name: String, duration: Double, poster: NSImage?; var audioOnly = false; var selected = false; var missing = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5, style: .continuous)
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .bottomLeading) {
                if let poster { Image(nsImage: poster).resizable().scaledToFill() } else { Theme.C.clipAudio; Image(systemName: "waveform").font(Theme.F.iconLarge).foregroundStyle(Theme.C.wave).frame(maxWidth: .infinity, maxHeight: .infinity) }
                Image(systemName: audioOnly ? "waveform" : "film").font(Theme.F.glyph).foregroundStyle(.white).padding(4).background(RoundedRectangle(cornerRadius: 3).fill(.black.opacity(0.62))).padding(4)
                if missing { Rectangle().fill(.black.opacity(0.55)); Label(T("Lipsă"), systemImage: "exclamationmark.triangle.fill").font(Theme.F.label).foregroundStyle(Theme.C.warn).frame(maxWidth: .infinity, maxHeight: .infinity) }
            }.aspectRatio(16 / 9, contentMode: .fit).clipShape(shape).overlay(Edge.outline(shape, Color.black.opacity(0.5)))
                .overlay { if selected { shape.strokeBorder(Theme.C.sel, lineWidth: 2) } }
            Text(name).font(Theme.F.caption).lineLimit(1).truncationMode(.middle)
            Text(timecode(duration)).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).monospacedDigit()
        }.contentShape(Rectangle())
    }
}

// MARK: inspector
struct InspectorGroup<Content: View>: View {
    let title: String; @State private var open = true
    var action: (symbol: String, label: String, disabled: Bool, run: () -> Void)?
    @ViewBuilder var content: Content
    init(_ t: String, action: (symbol: String, label: String, disabled: Bool, run: () -> Void)? = nil, @ViewBuilder _ c: () -> Content) { title = t; self.action = action; content = c() }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Button { open.toggle() } label: {
                    HStack(spacing: 6) { Image(systemName: "chevron.down").font(Theme.F.glyph).foregroundStyle(Theme.C.textDim).rotationEffect(.degrees(open ? 0 : -90)).frame(width: 10); Text(title).font(Theme.F.heading); Spacer() }
                        .frame(height: 32).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityLabel(title).accessibilityValue(open ? "extins" : T("restrâns"))
                if let a = action { IconButton(symbol: a.symbol, label: a.label, action: a.run).disabled(a.disabled).help(a.label) }
            }
            if open { VStack(alignment: .leading, spacing: 4) { content }.padding(.bottom, 12) }
            Rectangle().fill(Theme.C.line.opacity(0.7)).frame(height: 1)
        }
    }
}

/// Read-only value: plain text, deliberately NOT drawn as an input field (only editable values get the field surface).
struct InfoRow: View {
    let label: String, value: String
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(Theme.F.body).foregroundStyle(Theme.C.textDim).frame(width: 84, alignment: .leading).lineLimit(1)
            Text(value).font(Theme.F.mono).foregroundStyle(Theme.C.text).lineLimit(1).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .trailing)
        }.frame(height: 22)
    }
}

/// Slim slider for the inspector: 2.5 pt track, 11 pt handle with a hairline border and a soft shadow, a muted fill (the accent is kept for focus and the pressed state),
/// and a 22 pt tall hit area so the fine drawing stays easy to grab. States: normal, hover, pressed, focus (arrow keys adjust), disabled. `editing` reports gesture start/end
/// so the caller records ONE undo step per gesture.
struct FineSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>; let label: String
    var editing: (Bool) -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hover = false
    @State private var pressed = false
    @FocusState private var focused: Bool
    private let handle: CGFloat = 11
    var body: some View {
        GeometryReader { g in
            let span = max(1, g.size.width - handle), lo = range.lowerBound, hi = range.upperBound
            let t = hi > lo ? max(0, min(1, (value - lo) / (hi - lo))) : 0, x = handle / 2 + CGFloat(t) * span
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.C.line).frame(height: 2.5)
                Capsule().fill(pressed || focused ? Theme.C.accent : Theme.C.textFaint).frame(width: x, height: 2.5)
                Circle().fill(pressed ? Color(white: 0.86) : (hover ? Color.white : Color(white: 0.94))).frame(width: handle, height: handle)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 0.75))
                    .overlay(Circle().strokeBorder(Theme.C.accent.opacity(focused ? 0.9 : 0), lineWidth: 1.5).padding(-2))
                    .shadow(color: .black.opacity(0.35), radius: pressed ? 1 : 1.5, y: 0.5)
                    .offset(x: x - handle / 2)
            }
            .frame(height: g.size.height).contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                if !pressed { pressed = true; editing(true) }
                let q = max(0, min(1, Double((v.location.x - handle / 2) / span))); value = lo + q * (hi - lo)
            }.onEnded { _ in pressed = false; editing(false) })
        }
        .frame(height: 22).opacity(enabled ? 1 : 0.4)
        .onHover { hover = $0 }
        .focusable().focused($focused)
        .onMoveCommand { d in
            let step = (range.upperBound - range.lowerBound) / 100
            switch d { case .left, .down: editing(true); value = max(range.lowerBound, value - step); editing(false)
                       case .right, .up: editing(true); value = min(range.upperBound, value + step); editing(false)
                       default: break }
        }
        .accessibilityElement().accessibilityLabel(label).accessibilityValue(Text(value.formatted(.number.precision(.fractionLength(0...2)))))
        .accessibilityAdjustableAction { d in
            let step = (range.upperBound - range.lowerBound) / 100
            editing(true); value = max(range.lowerBound, min(range.upperBound, value + (d == .increment ? step : -step))); editing(false)
        }
    }
}

/// Editable numeric property: label, slider and a number field (ScrubField: click to type, drag to adjust), all bound to the same value.
/// One gesture or one typed entry = one undo step.
struct NumberRow: View {
    let label: String, unit: String; let range: ClosedRange<Double>
    let value: Binding<Double>; var commit: () -> Void; var decimals = 0
    private var field: some View { ScrubField(label: label, unit: unit, range: range, value: value, decimals: decimals, boxWidth: 66, commit: commit) }
    private var slider: some View { FineSlider(value: value, range: range, label: label) { if !$0 { commit() } } }
    var body: some View {
        // one row when the slider gets at least 110 pt; otherwise label + field on top and a full-width slider below (same fonts)
        // a label longer than the 70 pt column (e.g. "Fade la început", "Fundido de entrada") would be cut with an ellipsis: those go straight to the stacked layout
        let stacked = VStack(spacing: 2) {
            HStack(spacing: 8) { Text(label).font(Theme.F.body).lineLimit(1); Spacer(minLength: 4); field }.frame(height: 26)
            slider
        }
        if label.count > 10 { stacked } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { Text(label).font(Theme.F.body).frame(width: 70, alignment: .leading).lineLimit(1); slider.frame(minWidth: 110); field }.frame(height: 28)
                stacked
            }
        }
    }
}

struct TitleFonts {
    static let list: [(name: String, value: String)] = [("Helvetica Neue", "Helvetica Neue"), ("Helvetica Neue Bold", "HelveticaNeue-Bold"), ("Arial", "ArialMT"), ("Arial Bold", "Arial-BoldMT"),
        ("Avenir Next Bold", "AvenirNext-Bold"), ("Futura", "Futura-Medium"), ("Georgia", "Georgia"), ("Georgia Bold", "Georgia-Bold"), ("Times New Roman", "TimesNewRomanPSMT"), ("Menlo", "Menlo-Regular"), ("Impact", "Impact")]
    static let swatches: [TextColor] = [.white, .black, TextColor(hex: "#FFD60A")!, TextColor(hex: "#FF453A")!, TextColor(hex: "#64D2FF")!]
}

/// Text properties of the selected title. The text field commits on Return or when it loses focus (one undo step); every other control is one step per change.
struct TitleGroup: View {
    @ObservedObject var m: EditorModel
    let t: TextOverlay
    @State private var draft = ""
    @State private var hex = ""
    @FocusState private var focused: Bool
    @FocusState private var hexFocused: Bool
    private func commitText() { if draft != t.text { m.updateTitle { $0.text = draft } } }
    private func commitHex() { if let c = TextColor(hex: hex), c != t.color { m.updateTitle { $0.color = c } }; hex = t.color.hex }
    var body: some View {
        InspectorGroup(T("Text")) {
            // several lines: Return starts a new line; the text applies (one undo step) when the field loses focus
            TextEditor(text: $draft).scrollContentBackground(.hidden).font(Theme.F.body).padding(.horizontal, 5).padding(.vertical, 4).frame(minHeight: 56, maxHeight: 96).fieldSurface(focused: focused)
                .focused($focused).onChange(of: focused) { _, f in if !f { commitText() } }
                .accessibilityLabel(T("Textul titlului")).help(T("Enter începe un rând nou; textul se aplică la ieșirea din câmp"))
            HStack(spacing: 8) {
                Text(T("Font")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { t.font }, set: { v in m.updateTitle { $0.font = v } })) {
                    ForEach(TitleFonts.list, id: \.value) { Text($0.name).tag($0.value) }
                    if !TitleFonts.list.contains(where: { $0.value == t.font }) { Text(t.font).tag(t.font) }
                }.labelsHidden().pickerStyle(.menu).accessibilityLabel(T("Font"))
            }.frame(height: 28)
            NumberRow(label: T("Mărime"), unit: "%", range: 2...40, value: Binding(get: { (m.selectedText?.size ?? 0.08) * 100 }, set: { v in m.liveTitle { $0.size = v / 100 } }), commit: { m.commitTitle() })
            HStack(spacing: 6) {
                Text(T("Culoare")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                TextField("#RRGGBB", text: $hex).textFieldStyle(.plain).font(Theme.F.mono).padding(.horizontal, 6).frame(width: 74, height: 24).fieldSurface(focused: hexFocused)
                    .focused($hexFocused).onSubmit { commitHex(); hexFocused = false }.onChange(of: hexFocused) { _, f in if !f { commitHex() } }.accessibilityLabel(T("Culoarea textului, hexazecimal"))
                ForEach(0..<TitleFonts.swatches.count, id: \.self) { i in
                    let c = TitleFonts.swatches[i]
                    Button { m.updateTitle { $0.color = c } } label: {
                        Circle().fill(Color(red: c.r, green: c.g, blue: c.b)).frame(width: 16, height: 16).overlay(Circle().strokeBorder(t.color == c ? Theme.C.sel : Color.white.opacity(0.35), lineWidth: t.color == c ? 2 : 1))
                    }.buttonStyle(.plain).accessibilityLabel("Culoare \(c.hex)")
                }
            }.frame(height: 28)
            HStack(spacing: 8) {
                Text(T("Aliniere")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { t.align }, set: { v in m.updateTitle { $0.align = v } })) {
                    Image(systemName: "text.alignleft").tag(TextAlign.leading); Image(systemName: "text.aligncenter").tag(TextAlign.center); Image(systemName: "text.alignright").tag(TextAlign.trailing)
                }.labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Aliniere"))
            }.frame(height: 28)
            HStack(spacing: 6) {
                Text(T("Stil")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                Button { m.updateTitle { $0.bold.toggle() } } label: { Image(systemName: "bold") }.buttonStyle(ToolButtonStyle(active: t.bold)).help(T("Aldin")).accessibilityLabel(T("Aldin")).accessibilityValue(t.bold ? T("activ") : T("oprit"))
                Button { m.updateTitle { $0.italic.toggle() } } label: { Image(systemName: "italic") }.buttonStyle(ToolButtonStyle(active: t.italic)).help(T("Cursiv")).accessibilityLabel(T("Cursiv")).accessibilityValue(t.italic ? T("activ") : T("oprit"))
                Button { m.updateTitle { $0.shadow.toggle() } } label: { Image(systemName: "shadow") }.buttonStyle(ToolButtonStyle(active: t.shadow)).help(T("Umbră")).accessibilityLabel(T("Umbră")).accessibilityValue(t.shadow ? T("activ") : T("oprit"))
                Button { m.updateTitle { $0.box = $0.box == nil ? TextColor(r: 0, g: 0, b: 0, a: 0.55) : nil } } label: { Image(systemName: "rectangle.fill") }.buttonStyle(ToolButtonStyle(active: t.box != nil)).help(T("Fundal în spatele textului")).accessibilityLabel(T("Fundal text")).accessibilityValue(t.box != nil ? T("activ") : T("oprit"))
                Button { m.updateTitle { $0.underline.toggle() } } label: { Image(systemName: "underline") }.buttonStyle(ToolButtonStyle(active: t.underline)).help(T("Subliniat")).accessibilityLabel(T("Subliniat")).accessibilityValue(t.underline ? T("activ") : T("oprit"))
                Button { m.updateTitle { $0.outline = $0.outline == nil ? TextColor(r: 0, g: 0, b: 0, a: 1) : nil } } label: { Image(systemName: "textformat") }.buttonStyle(ToolButtonStyle(active: t.outline != nil)).help(T("Contur în jurul literelor")).accessibilityLabel(T("Contur text")).accessibilityValue(t.outline != nil ? T("activ") : T("oprit"))
                Spacer(minLength: 0)
            }.frame(height: 30)
            HStack(spacing: 8) {
                Text(T("Apariție")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { t.anim?.appear ?? .none }, set: { v in m.setTextAnimation(TextAnimation(appear: v, disappear: t.anim?.disappear ?? .none, seconds: t.anim?.seconds ?? 0.5)) })) {
                    Text(T("Fără")).tag(TextIn.none); Text(T("Fade")).tag(TextIn.fade); Text(T("Alunecare")).tag(TextIn.slide); Text(T("Zoom")).tag(TextIn.pop)
                }.labelsHidden().pickerStyle(.menu).accessibilityLabel(T("Apariția titlului"))
            }.frame(height: 28)
            HStack(spacing: 8) {
                Text(T("Dispariție")).font(Theme.F.body).frame(width: 70, alignment: .leading)
                Picker("", selection: Binding(get: { t.anim?.disappear ?? .none }, set: { v in m.setTextAnimation(TextAnimation(appear: t.anim?.appear ?? .none, disappear: v, seconds: t.anim?.seconds ?? 0.5)) })) {
                    Text(T("Fără")).tag(TextOut.none); Text(T("Fade")).tag(TextOut.fade); Text(T("Alunecare")).tag(TextOut.slide); Text(T("Micșorare")).tag(TextOut.shrink)
                }.labelsHidden().pickerStyle(.menu).accessibilityLabel(T("Dispariția titlului"))
            }.frame(height: 28)
            if let an = t.anim {
                NumberRow(label: T("Durata tranziției"), unit: "s", range: 0.1...3, value: Binding(get: { an.seconds }, set: { v in m.setTextAnimation(TextAnimation(appear: an.appear, disappear: an.disappear, seconds: v)) }), commit: {}, decimals: 1)
            }
            if let box = t.box {
                NumberRow(label: T("Opacitate fundal"), unit: "%", range: 5...100, value: Binding(get: { (m.selectedText?.box ?? box).a * 100 }, set: { v in m.liveTitle { if var b = $0.box { b.a = v / 100; $0.box = b } } }), commit: { m.commitTitle() })
            }
            if t.text.contains("\n") {
                NumberRow(label: T("Spațiu între rânduri"), unit: "%", range: 60...300, value: Binding(get: { (m.selectedText?.lineSpacing ?? 1) * 100 }, set: { v in m.liveTitle { $0.lineSpacing = v / 100 } }), commit: { m.commitTitle() })
            }
        }.onAppear { draft = t.text; hex = t.color.hex }
            .onChange(of: t.text) { _, v in if !focused { draft = v } }.onChange(of: t.color) { _, v in if !hexFocused { hex = v.hex } }
    }
}

/// Keyframes between the first and last state, the easing of every segment, and visual fades. The keyframe under the playhead is edited with the same
/// fields as the start/end states (Poziție, Scară, Opacitate, Rotație).
struct MotionControls: View {
    @ObservedObject var m: EditorModel
    var body: some View {
        let mo = m.selectedMotion ?? Motion(), dur = m.selectedDuration
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(T("Mișcare")).font(Theme.F.body).lineLimit(1).frame(minWidth: 70, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Picker("", selection: Binding(get: { mo.easing }, set: { v in m.setMotion { $0.easing = v } })) {
                    Text(T("Lin")).tag(Easing.smooth); Text(T("Liniar")).tag(Easing.linear); Text(T("Intrare")).tag(Easing.easeIn); Text(T("Ieșire")).tag(Easing.easeOut)
                }.labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Curba mișcării")).help(T("Cum trece mișcarea de la o stare la alta: lin, liniar, accelerat la început sau încetinit la sfârșit"))
            }
            HStack(spacing: 6) {
                Button { m.addKeyHere() } label: { Label(T("Cheie la cursor"), systemImage: "diamond") }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize().disabled(m.keyTimeHere == nil)
                    .help(m.keyTimeHere == nil ? T("Mută cursorul în interiorul elementului (nu pe margini)") : T("Adaugă o stare intermediară la cursor; apoi o editezi cu câmpurile de transformare"))
                Spacer(minLength: 0)
            }
            if !mo.keys.isEmpty {
                FlowChips(count: mo.keys.count) { i in
                    let on = m.editingKey == i
                    HStack(spacing: 2) {
                        Button { m.showKey(i) } label: { Text(String(format: "%.1f s", mo.keys[i].t)).font(Theme.F.monoSmall).padding(.horizontal, 6).frame(height: 22) }
                            .buttonStyle(.plain).background(Capsule().fill(on ? Theme.C.accent : Theme.C.bg0)).foregroundStyle(on ? Theme.C.accentInk : Theme.C.text)
                            .accessibilityLabel(L10n.f("Cheia de la %@ s", String(format: "%.1f", mo.keys[i].t))).accessibilityValue(on ? T("editată") : "")
                        Button { m.removeKey(i) } label: { Image(systemName: "xmark").font(Theme.F.iconSmall).frame(width: 18, height: 22) }.buttonStyle(.plain).foregroundStyle(Theme.C.textFaint).accessibilityLabel(T("Șterge cheia"))
                    }
                }
            }
            NumberRow(label: T("Fade la început"), unit: "s", range: 0...max(0.1, dur / 2), value: Binding(get: { mo.fadeIn }, set: { v in m.liveMotion { $0.fadeIn = v } }), commit: { m.commitMotion() }, decimals: 1)
            NumberRow(label: T("Fade la sfârșit"), unit: "s", range: 0...max(0.1, dur / 2), value: Binding(get: { mo.fadeOut }, set: { v in m.liveMotion { $0.fadeOut = v } }), commit: { m.commitMotion() }, decimals: 1)
        }
    }
}
/// Wrapping row of small items (keyframe chips).
struct FlowChips<Content: View>: View {
    let count: Int; @ViewBuilder let content: (Int) -> Content
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) { ForEach(0..<count, id: \.self) { content($0) }; Spacer(minLength: 0) }
            VStack(alignment: .leading, spacing: 4) { ForEach(0..<count, id: \.self) { content($0) } }
        }
    }
}

/// Properties of the selected callout: region (as % of the output frame), what happens outside it, and its place in the project.
struct CalloutGroup: View {
    @ObservedObject var m: EditorModel
    let c: Callout
    private func bind(_ kp: WritableKeyPath<Callout, Double>, _ k: Double) -> Binding<Double> {
        Binding(get: { (m.selectedCallout?[keyPath: kp] ?? 0) * k }, set: { v in m.liveCallout { $0[keyPath: kp] = v / k } })
    }
    var body: some View {
        let done = { m.commitCallout() }
        InspectorGroup(T("Selecție")) {
            Picker("", selection: Binding(get: { c.shape }, set: { v in
                if v == .freehand && c.points.count < 3 { m.drawTool = .freehand }
                else if v == .line || v == .arrow { m.updateCallout { $0.setStroke(v, from: CalloutPoint(x: $0.x, y: $0.y), to: CalloutPoint(x: $0.x + $0.w, y: $0.y + $0.h)) } }
                else { m.updateCallout { if $0.shape == .line || $0.shape == .arrow { $0.points = []; if $0.dim == 0 { $0.dim = 0.6 } }; $0.shape = v } }
            })) { Text(T("Dreptunghi")).tag(CalloutShape.rect); Text(T("Elipsă")).tag(CalloutShape.ellipse); Text(T("Liber")).tag(CalloutShape.freehand)
                Text(T("Linie")).tag(CalloutShape.line); Text(T("Săgeată")).tag(CalloutShape.arrow) }
                .labelsHidden().pickerStyle(.menu).accessibilityLabel(T("Forma selecției"))
            ViewThatFits(in: .horizontal) {
            HStack(spacing: 6) {
                Button { m.makeCircle() } label: { Label(T("Cerc"), systemImage: "circle").lineLimit(1).frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).help(T("Elipsa devine cerc (lățime = înălțime în pixeli)"))
                Button { m.drawTool = c.shape == .freehand ? .freehand : (c.shape == .ellipse ? .ellipse : (c.shape == .line ? .line : (c.shape == .arrow ? .arrow : (c.isFrameOnly ? .frame : .rect)))) } label: { Label(T("Redesenează"), systemImage: "pencil.and.outline").lineLimit(1).frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).help(T("Desenezi din nou selecția direct în previzualizare"))
            }
            HStack(spacing: 6) {
                Button { m.makeCircle() } label: { Image(systemName: "circle").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).help(T("Elipsa devine cerc (lățime = înălțime în pixeli)"))
                Button { m.drawTool = c.shape == .freehand ? .freehand : (c.shape == .ellipse ? .ellipse : (c.shape == .line ? .line : (c.shape == .arrow ? .arrow : (c.isFrameOnly ? .frame : .rect)))) } label: { Image(systemName: "pencil.and.outline").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).help(T("Desenezi din nou selecția direct în previzualizare"))
            }
            }
            NumberRow(label: T("Margine moale"), unit: "%", range: 0...100, value: bind(\.feather, 100), commit: done)
        }
        InspectorGroup(T("Țintă")) {
            let ov = m.overlays(at: c.start)
            let state = c.layerID != nil ? T("Legat de suprapunere") : (c.clipID != nil ? T("Legat de clip") : T("Independent"))
            let detail = c.layerID != nil ? T("Legat de suprapunere: se mută, se taie, se copiază și se șterge odată cu ea; efectul acționează doar în imaginea ei.")
                : (c.clipID != nil ? T("Legat de clipul de sub el: se mută, se taie și se șterge odată cu el.") : T("Independent: rămâne la timpul lui și acționează asupra a tot ce e dedesubt."))
            HStack(spacing: 8) {
                Text(state).font(Theme.F.body).lineLimit(1).truncationMode(.tail).help(detail)
                Spacer(minLength: 4)
                Menu {
                    if c.clipID != nil || c.layerID != nil {
                        Button(T("Fă-l independent")) { if c.layerID != nil { m.bindSelectedCallout(toLayer: nil) } else { m.updateCallout { $0.clipID = nil } } }
                    }
                    if c.clipID == nil, let id = m.project.clipID(at: c.start) { Button(T("Leagă de clip")) { m.updateCallout { $0.layerID = nil; $0.clipID = id } } }
                    if !ov.isEmpty {
                        Divider()
                        ForEach(ov, id: \.id) { l in Button { m.bindSelectedCallout(toLayer: l.id) } label: { if c.layerID == l.id { Label(m.layerName(l), systemImage: "checkmark") } else { Text(m.layerName(l)) } } }
                    }
                } label: { Text(T("Schimbă ținta")).lineLimit(1) }.menuStyle(.button).buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
            }.accessibilityElement(children: .combine).accessibilityLabel(detail)
        }
        InspectorGroup(T("Casetă")) {
            NumberRow(label: "X", unit: "%", range: 0...100, value: bind(\.x, 100), commit: done, decimals: 1)
            NumberRow(label: "Y", unit: "%", range: 0...100, value: bind(\.y, 100), commit: done, decimals: 1)
            NumberRow(label: T("Lățime"), unit: "%", range: 2...100, value: bind(\.w, 100), commit: done, decimals: 1)
            NumberRow(label: T("Înălțime"), unit: "%", range: 2...100, value: bind(\.h, 100), commit: done, decimals: 1)
            if c.shape == .rect { NumberRow(label: T("Colțuri"), unit: "%", range: 0...50, value: bind(\.corner, 100), commit: done) }
        }
        if c.shape == .line || c.shape == .arrow {
            InspectorGroup(c.shape == .arrow ? T("Săgeată") : T("Linie")) {
                NumberRow(label: T("Grosime"), unit: "%", range: 10...300, value: bind(\.lineWidth, 100), commit: done)
                HStack(spacing: 6) {
                    Text(T("Culoare")).font(Theme.F.body).frame(width: 90, alignment: .leading)
                    ForEach(0..<TitleFonts.swatches.count, id: \.self) { i in
                        let sw = TitleFonts.swatches[i]
                        Button { m.updateCallout { $0.outlineColor = sw } } label: {
                            Circle().fill(Color(red: sw.r, green: sw.g, blue: sw.b)).frame(width: 16, height: 16).overlay(Circle().strokeBorder(c.outlineColor == sw ? Theme.C.sel : Color.white.opacity(0.35), lineWidth: c.outlineColor == sw ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel("Culoare \(sw.hex)")
                    }
                }.frame(height: 28)
            }
        } else {
        InspectorGroup(T("Efect")) {
            if c.shape == .rect || c.shape == .ellipse {
                Picker("", selection: Binding(get: { c.isFrameOnly }, set: { v in m.updateCallout { if v { $0.makeFrameOnly() } else { $0.makeSpotlight() } } })) { Text(T("Evidențiere")).tag(false); Text(T("Doar cadru")).tag(true) }
                    .labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Tipul selecției"))
            }
            if !c.isLens { Picker("", selection: Binding(get: { c.invert }, set: { v in m.updateCallout { $0.invert = v } })) { Text(T("În exterior")).tag(false); Text(T("În interior")).tag(true) }
                .labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Unde se aplică efectul")) }
            NumberRow(label: T("Întunecare"), unit: "%", range: 0...100, value: bind(\.dim, 100), commit: done)
            NumberRow(label: T("Estompare"), unit: "%", range: 0...100, value: bind(\.blur, 100), commit: done)
            if !c.isLens { NumberRow(label: T("Mărire în selecție"), unit: "%", range: 0...400, value: bind(\.magnify, 100), commit: done).help(T("Mărește imaginea DOAR în interiorul formei selecției, din centrul ei; suprafața selecției rămâne la fel de mare. Pentru a mări întreaga zonă selectată folosește „Lupă”.")) }
            NumberRow(label: T("Contur"), unit: "%", range: 0...100, value: bind(\.outline, 100), commit: done)
            if c.outline > 0 {
                HStack(spacing: 6) {
                    Text(T("Culoare contur")).font(Theme.F.body).frame(width: 90, alignment: .leading)
                    ForEach(0..<TitleFonts.swatches.count, id: \.self) { i in
                        let sw = TitleFonts.swatches[i]
                        Button { m.updateCallout { $0.outlineColor = sw } } label: {
                            Circle().fill(Color(red: sw.r, green: sw.g, blue: sw.b)).frame(width: 16, height: 16).overlay(Circle().strokeBorder(c.outlineColor == sw ? Theme.C.sel : Color.white.opacity(0.35), lineWidth: c.outlineColor == sw ? 2 : 1))
                        }.buttonStyle(.plain).accessibilityLabel("Culoare \(sw.hex)")
                    }
                }.frame(height: 28)
            }
            NumberRow(label: T("Umbră"), unit: "%", range: 0...100, value: bind(\.shadow, 100), commit: done)
            if c.clipID != nil {
                Toggle(T("Aplică și peste suprapuneri (prezentator)"), isOn: Binding(get: { c.overlays }, set: { v in m.updateCallout { $0.overlays = v } })).toggleStyle(.checkbox).font(Theme.F.body)
                    .help(T("Implicit efectul acționează doar asupra imaginii clipului; camera și celelalte straturi rămân neatinse."))
            }
            Text(c.invert ? T("Efectul se aplică în interiorul selecției (de ex. estompare pentru a ascunde o informație); exteriorul rămâne neschimbat.") : T("Efectul se aplică în exteriorul selecției (evidențiere); interiorul rămâne neschimbat. Aceeași imagine în previzualizare și în export.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
        }
        }
        if c.shape == .rect || c.shape == .ellipse || c.shape == .freehand {
        InspectorGroup(T("Lupă (zonă mărită)")) {
            Toggle(T("Afișează zona selectată mărită"), isOn: Binding(get: { c.isLens }, set: { on in m.updateCallout { if on { if $0.dim == 0 && $0.outline == 0 { $0.outline = 0.35 }; $0.lens = $0.lens > 0 ? $0.lens : 2 } else { $0.lens = 0 } } }))
                .toggleStyle(.switch).controlSize(.mini).font(Theme.F.body)
                .help(T("Caseta „Casetă” devine zona-sursă: ÎNTREGUL ei conținut apare mărit într-o zonă separată, pe care o poți muta oriunde în cadru. Imaginea e aceeași, în mișcare, la același moment."))
            if c.isLens {
                NumberRow(label: T("Factor de mărire"), unit: "%", range: 125...800, value: Binding(get: { c.lens * 100 }, set: { v in m.liveCallout { $0.lens = v / 100 } }), commit: done)
                let b = c.displayBox
                NumberRow(label: T("Zona mărită: X"), unit: "%", range: 0...100, value: Binding(get: { b.minX * 100 }, set: { v in m.liveCallout { $0.lensX = v / 100; if $0.lensY == nil { $0.lensY = b.minY } } }), commit: done, decimals: 1)
                NumberRow(label: T("Zona mărită: Y"), unit: "%", range: 0...100, value: Binding(get: { b.minY * 100 }, set: { v in m.liveCallout { $0.lensY = v / 100; if $0.lensX == nil { $0.lensX = b.minX } } }), commit: done, decimals: 1)
                Button { m.updateCallout { $0.lensX = nil; $0.lensY = nil } } label: { Label(T("Centrează pe zona-sursă"), systemImage: "scope").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true)).disabled(c.lensX == nil && c.lensY == nil)
                if c.lensEffective < c.lens - 0.001 {
                    Text(L10n.f("Factorul e limitat la %@× ca zona mărită să încapă în cadru; micșorează zona-sursă pentru un factor mai mare.", String(format: "%.2f", c.lensEffective))).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true)
                }
            }
            Text(T("Lupa mărește întreaga zonă-sursă (nu doar centrul) într-o zonă separată, cu aceleași proporții. Întunecarea, estomparea, conturul și umbra acționează în jurul zonei mărite.")).font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
        }
        }
        InspectorGroup(T("Poziție în proiect")) {
            let hi = max(30, m.project.timelineEnd + 30)
            NumberRow(label: T("Început"), unit: "s", range: 0...hi, value: Binding(get: { m.selectedCallout?.start ?? 0 }, set: { v in m.liveCallout { $0.start = max(0, v) } }), commit: done, decimals: 2)
            NumberRow(label: T("Durată"), unit: "s", range: 0.1...120, value: Binding(get: { m.selectedCallout?.duration ?? 1 }, set: { v in m.liveCallout { $0.duration = max(0.1, v) } }), commit: done, decimals: 2)
            InfoRow(label: T("Sfârșit"), value: tc(c.end, fps: m.fps))
        }
        InspectorGroup(T("Zoom de cadru (tot cadrul)")) {
            Button { m.zoomFrameToCallout() } label: { Label(T("Zoom cadru către zonă"), systemImage: "plus.magnifyingglass").frame(maxWidth: .infinity) }.buttonStyle(.gloss(.secondary, compact: true))
                .help(T("Animă clipul principal spre o stare finală care umple cadrul cu caseta selecției"))
            Text(T("Mărește TOT cadrul spre zonă (animația clipului, același mecanism ca zoomul existent). Pentru a mări doar zona selectată, într-o zonă separată, folosește „Lupă” mai sus.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint)
        }
    }
}

/// Edit-document format in the inspector (no selection): preset, width/height (click to type, drag to adjust), aspect, frame rate.
/// Each change is one undo step and rebuilds preview/export at the new canvas. "Ca sursa" keeps the legacy behaviour.
struct DocumentGroup: View {
    @ObservedObject var m: EditorModel
    @State private var w: Double = 1920
    @State private var h: Double = 1080
    private func sync() { w = Double(m.project.canvas?.width ?? Int(m.renderSize.width)); h = Double(m.project.canvas?.height ?? Int(m.renderSize.height)) }
    private var fps: Double { m.project.canvas?.fps ?? m.fps.rounded() }
    private func apply(w: Double? = nil, h: Double? = nil, fps: Double? = nil) {
        m.setCanvas(DocumentFormat(width: Int(w ?? self.w), height: Int(h ?? self.h), fps: fps ?? self.fps)); sync()
    }
    var body: some View {
        InspectorGroup(T("Document")) {
            HStack(spacing: 8) {
                Text(T("Preset")).font(Theme.F.body).foregroundStyle(Theme.C.textDim).frame(width: 70, alignment: .leading)
                Picker(T("Preset"), selection: Binding(get: { m.project.canvas.map { $0.preset?.id ?? "custom" } ?? "source" }, set: { id in
                    if id == "source" { m.setCanvas(nil); sync() } else if let p = DocumentFormat.presets.first(where: { $0.id == id }) { apply(w: Double(p.width), h: Double(p.height)) }
                })) {
                    Text(T("Ca sursa")).tag("source")
                    Divider()
                    ForEach(DocumentFormat.presets) { p in Text(verbatim: "\(p.name) · \(p.width)×\(p.height)").tag(p.id) }
                    if m.project.canvas != nil && m.project.canvas?.preset == nil { Text(T("Personalizat")).tag("custom") }
                }.labelsHidden().controlSize(.small)
            }.frame(height: 28)
            HStack(spacing: 8) {
                Text(T("Mărime")).font(Theme.F.body).foregroundStyle(Theme.C.textDim).frame(width: 70, alignment: .leading)
                ScrubField(label: T("Lățime document"), unit: "", range: 16...8192, value: $w, width: 44, step: 2, perPoint: 4) { apply() }
                Text("×").foregroundStyle(Theme.C.textFaint)
                ScrubField(label: T("Înălțime document"), unit: "px", range: 16...8192, value: $h, width: 44, step: 2, perPoint: 4) { apply() }
                Spacer(minLength: 0)
            }.frame(height: 28)
            HStack(spacing: 8) {
                Text(T("Cadre/s")).font(Theme.F.body).foregroundStyle(Theme.C.textDim).lineLimit(1).frame(minWidth: 70, alignment: .leading).fixedSize(horizontal: true, vertical: false)
                Picker(T("Cadre pe secundă"), selection: Binding(get: { fps }, set: { apply(fps: $0) })) {
                    ForEach(Array(Set(DocumentFormat.frameRates + [fps])).sorted(), id: \.self) { Text($0.formatted(.number.precision(.fractionLength(0...2)))).tag($0) }
                }.labelsHidden().controlSize(.small).fixedSize()
                Spacer()
            }.frame(height: 28)
            if m.project.canvas == nil {
                // legacy project: "same as source" shows the file's NOMINAL rate; the capture setting is offered, never applied silently
                VStack(alignment: .leading, spacing: 4) {
                    Text(T("Ca sursa: cadența nominală a fișierului (o captură de ecran are cadență variabilă).")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                    if let c = m.captureSetting {
                        Button { m.setCanvas(c) } label: { Text(verbatim: L10n.f("Aplică setarea capturii: %@×%@ · %@ cadre/s", "\(c.width)", "\(c.height)", "\(Int(c.fps))")) }
                            .buttonStyle(.gloss(.secondary, compact: true)).help(T("Documentul preia mărimea și cadența configurate la înregistrare; durata și sincronizarea nu se schimbă"))
                    }
                }.padding(.vertical, 2)
            }
            InfoRow(label: T("Proporții"), value: m.project.canvas?.aspect ?? DocumentFormat(width: Int(m.renderSize.width), height: Int(m.renderSize.height)).aspect)
        }
        .onAppear(perform: sync).onChange(of: m.project.canvas) { _, _ in sync() }.onChange(of: m.renderSize) { _, _ in if m.project.canvas == nil { sync() } }
    }
}

/// Fade-in / fade-out of the selected sound item (A1 clip or A2 item), in seconds. Each is limited to the item's duration minus the other
/// (no overlap while editing); if a later trim makes them meet, both are scaled in proportion (see AudioEdit.effectiveFades).
struct FadeGroup: View {
    @ObservedObject var m: EditorModel
    let id: UUID
    var body: some View {
        let e = m.audioEdit(id), d = m.selectedAudioDuration
        InspectorGroup(T("Fade"), action: ("arrow.counterclockwise", T("Fără fade"), e.fadeIn == 0 && e.fadeOut == 0, { var v = m.audioEdit(id); v.fadeIn = 0; v.fadeOut = 0; m.commitAudio(id, v) })) {
            NumberRow(label: T("Fade-in"), unit: "s", range: 0...max(0.01, d - e.fadeOut),
                      value: Binding(get: { m.audioEdit(id).fadeIn }, set: { var v = m.audioEdit(id); v.fadeIn = $0; m.liveAudioEdit(id, v) }),
                      commit: { m.commitAudio(id) }, decimals: 2)
            NumberRow(label: T("Fade-out"), unit: "s", range: 0...max(0.01, d - e.fadeIn),
                      value: Binding(get: { m.audioEdit(id).fadeOut }, set: { var v = m.audioEdit(id); v.fadeOut = $0; m.liveAudioEdit(id, v) }),
                      commit: { m.commitAudio(id) }, decimals: 2)
            let f = e.effectiveFades(duration: d)
            if abs(f.fadeIn - e.fadeIn) > 0.005 || abs(f.fadeOut - e.fadeOut) > 0.005 {
                Text(verbatim: String(format: T("Clipul e mai scurt decât fade-urile: se aplică %.2f s + %.2f s (proporțional)."), f.fadeIn, f.fadeOut)).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum InspCat: Hashable { case image, sound, info
    var title: String { switch self { case .image: return T("Imagine"); case .sound: return T("Sunet"); case .info: return T("Timp și sursă") } }
}

struct InspectorPanel: View {
    @ObservedObject var m: EditorModel
    @State private var cat: InspCat = .image
    @State private var jump: InspCat?
    /// The categories this selection really has (a category with nothing in it is not offered).
    private var categories: [InspCat] {
        guard m.selection != nil, m.selectedCallout == nil, m.selectedText == nil, m.selectedMedia != nil else { return [] }
        var out: [InspCat] = []
        if m.selectedTransform != nil { out.append(.image) }
        if m.selectedLayer?.kind == .audio || (m.selectedClip.flatMap { m.media[$0.media]?.hasAudio } == true) { out.append(.sound) }
        out.append(.info)
        return out
    }
    private func bind(_ kp: WritableKeyPath<Transform, Double>, _ k: Double) -> Binding<Double> {
        Binding(get: { (m.selectedTransform?[keyPath: kp] ?? 0) * k },
                set: { v in
                    guard let id = m.selection, var t = m.selectedTransform else { return }
                    t[keyPath: kp] = v / k; m.liveTransform(id, Transform(x: t.x, y: t.y, scale: t.scale, opacity: t.opacity, rotation: t.rotation))
                })
    }
    private func commit() { if let id = m.selection, let t = m.selectedTransform { m.commitTransform(id, t) } }
    private var title: String {
        if m.selectedClip != nil { return T("Clip video") }
        if m.selectedText != nil { return T("Titlu") }
        if m.selectedCallout != nil { return T("Evidențiere locală") }
        if let l = m.selectedLayer { return l.kind == .video ? T("Suprapunere video") : T("Sunet separat") }
        return T("Proiect")
    }
    private var resetValue: Transform { m.selectedText != nil ? Transform(y: 0.35) : .identity }
    private var transformTitle: String { m.selectedAnimated ? (m.editingEnd ? T("Transformare — stare finală") : T("Transformare — stare inițială")) : T("Transformare") }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: m.selection == nil ? "square.stack.3d.up" : (m.selectedText != nil ? "textformat" : (m.selectedCallout != nil ? "viewfinder" : (m.selectedLayer?.kind == .audio ? "waveform" : "film")))).font(Theme.F.icon).foregroundStyle(Theme.C.textDim)
                Text(title).font(Theme.F.heading)
                Spacer()
            }.padding(.horizontal, Theme.S.md).frame(height: 40).overlay(alignment: .bottom) { Rectangle().fill(Theme.C.line).frame(height: 1) }
            if categories.count > 1 {
                Picker("", selection: Binding(get: { cat }, set: { cat = $0; jump = $0 })) { ForEach(categories, id: \.self) { Text($0.title).tag($0) } }
                    .labelsHidden().pickerStyle(.segmented).padding(.horizontal, Theme.S.md).padding(.vertical, 8).accessibilityLabel(T("Categorii"))
                    .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.line.opacity(0.7)).frame(height: 1) }
            }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let c = m.selectedCallout { CalloutGroup(m: m, c: c).id(c.id) }
                    if m.selection != nil, m.selectedMedia != nil || m.selectedText != nil {
                        let media = m.selectedMedia; let start = m.selectedStart, dur = m.selectedDuration
                        if let t = m.selectedText { TitleGroup(m: m, t: t).id(t.id) }
                        Color.clear.frame(height: 0).id(InspCat.image)
                        if m.selectedTransform != nil {
                            InspectorGroup(transformTitle, action: ("arrow.counterclockwise", T("Resetează transformarea"), m.selectedTransform == resetValue, { if let id = m.selection { m.liveTransform(id, resetValue); m.commitTransform(id, resetValue) } })) {
                                let w = Double(m.renderSize.width), h = Double(m.renderSize.height)
                                NumberRow(label: T("Poziție X"), unit: "px", range: -w...w, value: bind(\.x, w), commit: commit).help(T("Față de centrul cadrului; pozitiv = spre dreapta"))
                                NumberRow(label: T("Poziție Y"), unit: "px", range: -h...h, value: bind(\.y, h), commit: commit).help(T("Față de centrul cadrului; negativ = în sus"))
                                NumberRow(label: T("Scară"), unit: "%", range: 5...300, value: bind(\.scale, 100), commit: commit)
                                NumberRow(label: T("Rotație"), unit: "°", range: -180...180, value: bind(\.rotation, 1), commit: commit).help(T("Pozitiv = în sensul acelor de ceasornic"))
                                NumberRow(label: T("Opacitate"), unit: "%", range: 0...100, value: bind(\.opacity, 100), commit: commit)
                            }
                            InspectorGroup(T("Animație")) {
                                Toggle(T("Animat între două stări"), isOn: Binding(get: { m.selectedAnimated }, set: { m.setAnimated($0) })).toggleStyle(.switch).controlSize(.small).font(Theme.F.body)
                                    .accessibilityHint(T("Poziția, scara, opacitatea și rotația trec lin de la starea inițială la cea finală"))
                                if m.selectedAnimated {
                                    Picker("", selection: Binding(get: { m.editingEnd }, set: { m.showState(end: $0) })) { Text(T("Început")).tag(false); Text(T("Sfârșit")).tag(true) }
                                        .labelsHidden().pickerStyle(.segmented).accessibilityLabel(T("Starea editată"))
                                        .help(T("Starea editată; cursorul sare la începutul sau sfârșitul elementului. Mișcarea e lină pe toată durata."))

                                } else {
                                    Button { m.presetSlowZoom() } label: { Label(T("Zoom lent (+20%)"), systemImage: "plus.magnifyingglass") }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                                        .help(T("Pornește animația cu un zoom simplu; apoi poți muta sau redimensiona starea finală"))
                                }
                                MotionControls(m: m)
                            }
                        }
                        if m.selectedVideoID != nil, let md = m.selectedMedia, m.media[md]?.hasVideo == true { RectCropGroup(m: m); PresenterGroup(m: m) }
                        if let c = m.selectedClip, m.project.clips.first?.id != c.id {
                            InspectorGroup(T("Tranziție")) {
                                let room = m.maxDissolve(of: c.id)
                                NumberRow(label: T("Dizolvare"), unit: "s", range: 0...max(0.1, room), value: Binding(get: { c.dissolve }, set: { v in m.setDissolve(c.id, v) }), commit: {}, decimals: 1)
                                    .disabled(room < 0.1)
                                Text(room < 0.1 ? T("Prea puțin material în clipuri pentru o dizolvare.") : T("Se suprapune cu clipul dinainte; sunetul se amestecă la fel, iar linia timpului se scurtează."))
                                    .font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        if let c = m.selectedClip, m.selectedMouseTrack != nil {
                            InspectorGroup(T("Cursor")) {
                                let fx = c.mouseFX ?? MouseFX(highlight: false, clickRing: false)
                                Toggle(T("Evidențiază cursorul"), isOn: Binding(get: { fx.highlight }, set: { v in var n = fx; n.highlight = v; m.setMouseFX(c.id, n) })).toggleStyle(.switch).controlSize(.small).font(Theme.F.body)
                                Toggle(T("Cerc la clic"), isOn: Binding(get: { fx.clickRing }, set: { v in var n = fx; n.clickRing = v; m.setMouseFX(c.id, n) })).toggleStyle(.switch).controlSize(.small).font(Theme.F.body)
                                Button { m.followMouse(c.id, scale: 1.8) } label: { Label(T("Zoom care urmărește cursorul"), systemImage: "scope") }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                                    .help(T("Mărește cadrul (×1,8) și îl mută după cursor; rezultatul sunt chei obișnuite, pe care le poți edita la Animație"))
                            }
                        }
                        if let c = m.selectedClip, let wt = m.selectedWindowTrack {
                            InspectorGroup(T("Fereastră din prim-plan")) {
                                let seen = wt.windowsSeen
                                Picker(T("Fereastră"), selection: $m.followWindowChoice) {
                                    Text(T("Cea din față, pe rând")).tag(UInt32(0))
                                    ForEach(seen, id: \.windowID) { Text($0.app.isEmpty ? T("Fără nume") : $0.app).tag($0.windowID) }
                                }.labelsHidden().font(Theme.F.body)
                                Button { m.followWindow(c.id) } label: { Label(T("Zoom pe fereastră"), systemImage: "macwindow") }.buttonStyle(.gloss(.secondary, compact: true)).fixedSize()
                                    .help(T("Mărește cadrul pe fereastra înregistrată și o urmărește; rezultatul sunt chei obișnuite, pe care le poți edita la Animație"))
                                Text(T("Fereastra vine din metadatele înregistrate, nu dintr-o zonă desenată. Fără citire recentă, cadrul revine la imaginea întreagă.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        else if let c = m.selectedClip, !c.held {
                            InspectorGroup(T("Fereastră din prim-plan")) {
                                Text(T("Această înregistrare nu are metadate de fereastră (citirea ferestrei era oprită sau fișierul nu îi aparține). Nu se poate urmări nicio fereastră; poți încadra manual la Animație.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Color.clear.frame(height: 0).id(InspCat.sound)
                        if let id = m.selection, let l = m.selectedLayer, l.kind == .audio, l.linkedClip != nil {
                            InspectorGroup(T("Legat de imagine")) {
                                let inSync = m.detachedAudioInSyncFlag(id)
                                Text(m.hasLinkedPart(id) ? (inSync ? T("Sunet detașat din clip, încă sincron cu imaginea. Îl poți muta, tăia sau șterge separat.") : T("Sunet detașat din clip și mutat sau tăiat: nu mai este sincron cu imaginea.")) : T("Imaginea de care era legat a fost ștearsă; sunetul rămâne independent."))
                                    .font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    Button(T("Selectează imaginea")) { m.selectLinkedPart(of: id) }.disabled(!m.hasLinkedPart(id))
                                    Button(T("Reatașează")) { m.reattachAudio(id) }.disabled(!m.hasLinkedPart(id) || !inSync)
                                }.controlSize(.small)
                            }
                        }
                        if let id = m.selection, m.selectedLayer?.kind == .audio {
                            // A2 item: the same controls as a recording source (volume in dB, reset, mute) plus its fades
                            InspectorGroup(T("Sunet"), action: ("arrow.counterclockwise", T("Volum la 0 dB (neutru)"), m.audioEdit(id).gainDB == 0, { var e = m.audioEdit(id); e.gainDB = 0; m.commitAudio(id, e) })) {
                                Toggle(T("Sunet activ"), isOn: Binding(get: { !m.audioEdit(id).muted }, set: { on in var e = m.audioEdit(id); e.muted = !on; m.commitAudio(id, e) }))
                                    .toggleStyle(.switch).controlSize(.mini).font(Theme.F.body).frame(height: 24).help(T("Oprit = mut în previzualizare și export; volumul și fade-urile se păstrează"))
                                NumberRow(label: T("Volum"), unit: "dB", range: SadrogProject.gainRange,
                                          value: Binding(get: { m.audioEdit(id).gainDB }, set: { var e = m.audioEdit(id); e.gainDB = $0; m.liveAudioEdit(id, e) }),
                                          commit: { m.commitAudio(id) }, decimals: 1)
                                    .disabled(m.audioEdit(id).muted).opacity(m.audioEdit(id).muted ? 0.45 : 1)
                            }
                            FadeGroup(m: m, id: id)
                        }
                        if let id = m.selection, let c = m.selectedClip, m.media[c.media]?.hasAudio == true {
                            InspectorGroup(T("Sunet și imagine")) {
                                Text(c.audioDetached ? T("Sunetul acestui clip este un element separat pe A2; imaginea rămâne aici.") : T("Sunetul este legat de imagine: se mută, taie și șterge împreună."))
                                    .font(Theme.F.caption).foregroundStyle(Theme.C.textDim).fixedSize(horizontal: false, vertical: true)
                                HStack(spacing: 6) {
                                    if c.audioDetached {
                                        Button(T("Reatașează sunetul")) { m.reattachAudio(id) }
                                        Button(T("Selectează sunetul")) { m.selectLinkedPart(of: id) }.disabled(!m.hasLinkedPart(id))
                                    } else { Button(T("Detașează sunetul")) { m.detachAudio(id) } }
                                }.controlSize(.small)
                            }
                            if !c.audioDetached { FadeGroup(m: m, id: id) }
                        }
                        if m.selectedClip != nil || m.selectedLayer?.keepsSource == true, !m.mainSources.isEmpty {
                            // the clip's linked sound: every recorded source with its own switch (same state as the A1 lane headers)
                            InspectorGroup(T("Sunet")) {
                                if m.recordingsInUse.count > 1 {      // several recordings: say which file these switches belong to
                                    Text(L10n.f("Înregistrare: %@", m.recordingTitle(m.shownMedia))).font(Theme.F.small).foregroundStyle(Theme.C.textDim).lineLimit(1).truncationMode(.middle)
                                }
                                ForEach(m.mainSources, id: \.index) { src in
                                  if let f = m.focusedSource, f != src.index {
                                    HStack(spacing: 6) {                // another source is focused: this one stays a one-line summary with its own switch
                                        Image(systemName: src.kind == .system ? "desktopcomputer" : (src.kind == .input ? "mic" : "waveform")).font(Theme.F.iconSmall).foregroundStyle(Theme.C.textFaint).frame(width: 14)
                                        Text(src.name).font(Theme.F.small).foregroundStyle(Theme.C.textDim).lineLimit(1).opacity(m.isSourceMuted(src.index) ? 0.5 : 1)
                                        Spacer(minLength: 4)
                                        Button { m.focusSource(src.index) } label: { Text(T("Alege")).font(Theme.F.small) }.buttonStyle(.plain).foregroundStyle(Theme.C.sel)
                                        Toggle("", isOn: Binding(get: { !m.isSourceMuted(src.index) }, set: { on in if on == m.isSourceMuted(src.index) { m.toggleSource(src.index) } })).toggleStyle(.switch).controlSize(.mini).labelsHidden()
                                            .accessibilityLabel(L10n.f("Sunet sursa %@", "\(src.name)"))
                                    }.frame(height: 24).disabled(m.isOff(m.selectedLayer?.keepsSource == true ? .a2 : .a1))
                                  } else {
                                    VStack(alignment: .leading, spacing: 2) {
                                        if m.focusedSource == src.index {
                                            InfoRow(label: T("Pistă în fișier"), value: "\(src.index + 1) · " + (src.kind == .system ? T("sunet sistem") : (src.kind == .input ? T("microfon") : T("sursă audio"))))
                                        }
                                        HStack(spacing: 6) {
                                            Image(systemName: src.kind == .system ? "desktopcomputer" : (src.kind == .input ? "mic" : "waveform")).font(Theme.F.iconSmall).foregroundStyle(Theme.C.textFaint).frame(width: 14)
                                            Text(src.name).font(Theme.F.body).lineLimit(1).truncationMode(.tail).opacity(m.isSourceMuted(src.index) ? 0.5 : 1)
                                            Spacer(minLength: 4)
                                            Button { m.resetSourceGain(src.index) } label: { Image(systemName: "arrow.counterclockwise").font(Theme.F.iconSmall).frame(width: 24, height: 22).contentShape(Rectangle()) }
                                                .buttonStyle(.plain).foregroundStyle(Theme.C.textDim).disabled(m.sourceGain(src.index) == 0).opacity(m.sourceGain(src.index) == 0 ? 0.35 : 1)
                                                .help(T("Volum la 0 dB (neutru)")).accessibilityLabel(L10n.f("Resetează volumul sursei %@", "\(src.name)"))
                                            Toggle("", isOn: Binding(get: { !m.isSourceMuted(src.index) }, set: { on in if on == m.isSourceMuted(src.index) { m.toggleSource(src.index) } }))
                                                .toggleStyle(.switch).controlSize(.mini).labelsHidden().help(m.isSourceMuted(src.index) ? T("Sursă mută — activeaz-o") : T("Activă — oprește-o (mute)")).accessibilityLabel(L10n.f("Sunet sursa %@", "\(src.name)"))
                                        }.frame(height: 24)
                                        NumberRow(label: T("Volum"), unit: "dB", range: SadrogProject.gainRange,
                                                  value: Binding(get: { m.displayGain(src.index) }, set: { m.liveSourceGain(src.index, $0) }),
                                                  commit: { m.commitSourceGain(src.index) }, decimals: 1)
                                            .disabled(m.isSourceMuted(src.index)).opacity(m.isSourceMuted(src.index) ? 0.45 : 1)
                                        EffectsRow(m: m, k: src.index)
                                    }.disabled(m.isOff(m.selectedLayer?.keepsSource == true ? .a2 : .a1)).padding(.bottom, 4)
                                  }
                                }
                                if let pk = m.estimatedMixPeakDB {
                                    HStack(spacing: 6) {
                                        Image(systemName: pk > 0 ? "exclamationmark.triangle.fill" : "waveform.path.ecg").font(Theme.F.iconSmall).foregroundStyle(pk > 0 ? Theme.C.warn : Theme.C.textFaint)
                                        Text(verbatim: String(format: T("Estimare conservatoare a vârfului: %+.1f dBFS"), pk)).font(Theme.F.caption).foregroundStyle(pk > 0 ? Theme.C.warn : Theme.C.textDim)
                                    if m.estimatedPeakRecordings.count > 1 { Text(verbatim: String(format: T("din cea mai tare dintre %d înregistrări"), m.estimatedPeakRecordings.count)).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
                                    }.help(T("Estimare conservatoare, NU vârful măsurat al mixului: suma vârfurilor maxime ale surselor active (inclusiv A2), cu volumele lor. Poate avertiza chiar dacă vârfurile nu coincid în timp. Peste 0 dBFS poate apărea tăiere (clipping); SADROG nu normalizează și nu limitează automat."))
                                }
                                if m.isOff(.a1) { Text(T("Pista A1 e mută; sursele se pot porni după ce o activezi.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
                            }
                        }
                        Color.clear.frame(height: 0).id(InspCat.info)
                        InspectorGroup(T("Timp")) {
                            if m.selectedText != nil {
                                let hi = max(30, m.project.timelineEnd + 30)
                                NumberRow(label: T("Început"), unit: "s", range: 0...hi, value: Binding(get: { m.selectedText?.start ?? 0 }, set: { v in m.liveTitle { $0.start = max(0, v) } }), commit: { m.commitTitle() }, decimals: 2)
                                NumberRow(label: T("Durată"), unit: "s", range: 0.1...120, value: Binding(get: { m.selectedText?.duration ?? 1 }, set: { v in m.liveTitle { $0.duration = max(0.1, v) } }), commit: { m.commitTitle() }, decimals: 2)
                                InfoRow(label: T("Sfârșit"), value: tc(start + dur, fps: m.fps))
                            } else {
                                InfoRow(label: T("Început"), value: tc(start, fps: m.fps)); InfoRow(label: T("Durată"), value: tc(dur, fps: m.fps)); InfoRow(label: T("Sfârșit"), value: tc(start + dur, fps: m.fps))
                            }
                        }
                        if let media {
                            InspectorGroup(T("Sursă")) {
                                InfoRow(label: T("Fișier"), value: URL(fileURLWithPath: media).lastPathComponent)
                                if let i = m.media[media], i.hasVideo { InfoRow(label: T("Cadru"), value: "\(Int(i.size.width))×\(Int(i.size.height))"); InfoRow(label: T("Cadre/s"), value: String(format: "%.0f", i.fps)) }
                            }
                        }
                    } else if m.selectedCallout == nil {
                        DocumentGroup(m: m)
                        InspectorGroup(T("Mix"), action: ("arrow.counterclockwise", T("Volum general la 0 dB"), m.project.masterGainDB == 0, { m.commitMasterGain(0) })) {
                            NumberRow(label: T("Volum mix"), unit: "dB", range: SadrogProject.gainRange, value: Binding(get: { m.masterDisplay }, set: { m.liveMasterGain($0) }), commit: { m.commitMasterGain() }, decimals: 1)
                                .help(T("Se aplică după volumele și fade-urile surselor, la previzualizare, la exportul video și la fișierul „mix” — nu la fișierele surselor separate."))
                            if let pk = m.estimatedMixPeakDB {
                                HStack(spacing: 6) {
                                    Image(systemName: pk > 0 ? "exclamationmark.triangle.fill" : "waveform.path.ecg").font(Theme.F.iconSmall).foregroundStyle(pk > 0 ? Theme.C.warn : Theme.C.textFaint)
                                    Text(verbatim: String(format: T("Estimare conservatoare a vârfului: %+.1f dBFS"), pk)).font(Theme.F.caption).foregroundStyle(pk > 0 ? Theme.C.warn : Theme.C.textDim)
                                    if m.estimatedPeakRecordings.count > 1 { Text(verbatim: String(format: T("din cea mai tare dintre %d înregistrări"), m.estimatedPeakRecordings.count)).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint) }
                                }.help(T("Suma vârfurilor maxime ale surselor active (inclusiv A2), cu volumele lor și volumul general. Poate avertiza chiar dacă vârfurile nu coincid. Fără limitare sau normalizare automată."))
                            }
                        }
                        InspectorGroup(T("Proiect")) {
                            InfoRow(label: T("Durată"), value: tc(m.project.timelineEnd, fps: m.fps))
                            InfoRow(label: T("Clipuri"), value: "\(m.project.clips.count)"); InfoRow(label: T("Alte piste"), value: "\(m.project.layers.count)"); InfoRow(label: T("Titluri"), value: "\(m.project.texts.count)")

                        }
                        Text(T("Selectează un element în timeline pentru a-i vedea proprietățile.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).padding(.top, Theme.S.md)
                    }
                }.padding(.horizontal, Theme.S.md)
            }
            .onChange(of: jump) { _, j in if let j { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(j, anchor: .top) }; jump = nil } }
            .onChange(of: m.selection) { _, _ in cat = .image; proxy.scrollTo(InspCat.image, anchor: .top) }
            .onChange(of: m.focusedSource) { _, k in if k != nil { cat = .sound; jump = .sound } }      // choosing a sound in the A1 header opens the Sound section for it
            }
        }.frame(maxHeight: .infinity, alignment: .top).background(Theme.C.bg1)
    }
}

// MARK: timeline
struct ScrollOffsetKey: PreferenceKey { static var defaultValue: CGFloat = 0; static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() } }

struct TimelinePanel: View {
    @ObservedObject var m: EditorModel
    private let rulerH: CGFloat = 42, markerH: CGFloat = 15, gap: CGFloat = 3
    /// Vertical scroll of the lanes: the ruler (and the header corner) are drawn at this offset, so they stay pinned on top while the lanes
    /// scroll under them; horizontally the ruler lives in the same content as the clips, so it can never drift from them.
    @State private var vOff: CGFloat = 0
    @State private var vPos = ScrollPosition(edge: .top)
    @State private var viewportH: CGFloat = 400
    /// Heights while a separator is being dragged (committed once, at the end) and the lane being dragged by its grip.
    @State private var liveHeights: [TrackLane: CGFloat] = [:]
    @State private var resizeStart: (lane: TrackLane, h: CGFloat)?
    /// Height of ONE track (V2 / A2 row) while its separator is dragged, keyed like `TimelineLayout.rowHeights`; committed once at the end.
    @State private var liveRows: [String: CGFloat] = [:]
    @State private var rowResizeStart: (key: String, h: CGFloat)?
    @State private var laneDrag: (lane: TrackLane, y: CGFloat, cancel: Bool)?
    @State private var rowDrag: (lane: TrackLane, from: Int, y: CGFloat, cancel: Bool)?
    /// Height of one audio source row: readable by default; compact is an explicit choice. Many sources scroll, they are not squeezed.
    @AppStorage("timeline.compactSources") private var compactSources = false
    private var sourceRowH: CGFloat { compactSources ? 22 : 36 }
    /// Lane-header column; wider when A1 lists named sources ("Sunetul calculatorului", "MixPre-6 II · canal 1"), so their names stay readable.
    private var headerW: CGFloat { m.mainSources.count > 1 ? 236 : 184 }
    private let edgeHit: CGFloat = 7
    private enum Drag { case scrub, trim(UUID, ClipEdge, Lane), move(UUID, Lane), pending(UUID, Lane), blade, marquee, none }
    @State private var drag: Drag?
    /// Rectangle selection (content coordinates): `a` is where the button went down, `b` the pointer; `base` is the selection kept when ⇧/⌘ was held.
    @State private var marquee: (a: CGPoint, b: CGPoint)?
    @State private var marqueeBase: [UUID] = []
    @State private var marqueeScreen = CGPoint.zero      // the pointer relative to the visible area, for the edge autoscroll
    @State private var marqueeTimer: Timer?
    @State private var marqueeKeys: Any?
    @State private var marqueeCancelled = false
    @State private var hPos = ScrollPosition()
    @State private var hoverItem: UUID?
    @State private var scrollOffset: CGFloat = 0
    @State private var autoScrollUntil = Date.distantPast

    /// Keeps the playhead in view by paging the timeline (never by changing scale or time): when it passes 92 % of the visible width, or is left of the view
    /// (restart, jump, play from outside), the view jumps once so the playhead sits at 12 % — no per-frame nudging.
    private func follow(_ proxy: ScrollViewProxy, pps: CGFloat, viewW: CGFloat, force: Bool = false) {
        guard m.followPlayhead, m.zoom > 1.01 else { return }
        let px = CGFloat(m.time) * pps
        guard force || px > scrollOffset + viewW * 0.92 || px < scrollOffset + 2 else { return }
        autoScrollUntil = Date().addingTimeInterval(0.6)
        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("playhead", anchor: UnitPoint(x: 0.12, y: 0.5)) }
    }

    /// Vertical geometry of the five lanes: T titles, V2 overlay, V1 main video, A1 linked sound, A2 independent audio.
    struct Geo {
        var t: CGFloat, v2: CGFloat, v1: CGFloat, a1: CGFloat, a2: CGFloat, c: CGFloat; var ruler: CGFloat, gap: CGFloat; var nV2 = 1, nA2 = 1, nC = 1, nT = 1
        /// Display order top → bottom, as lane indices (0 T, 1 V2, 2 V1, 3 A1, 4 A2, 5 C); comes from the project layout.
        var order: [Int] = Geo.defaultOrder
        /// Heights of the single tracks (V2 = lane 1, A2 = lane 4), top → bottom, when the user gave some; their sum is the lane's height. Absent = equal rows.
        var slotH: [Int: [CGFloat]] = [:]
        static let defaultOrder = [0, 5, 1, 2, 3, 4]
        static let laneOf: [TrackLane] = [.t, .v2, .v1, .a1, .a2, .c]
        static func index(_ l: TrackLane) -> Int { laneOf.firstIndex(of: l) ?? 0 }
        func rows(_ l: Int) -> Int { l == 0 ? nT : l == 1 ? nV2 : (l == 4 ? nA2 : (l == 5 ? nC : 1)) }
        /// Row slot (0 = top) of the lane under y.
        func slot(_ l: Int, at py: CGFloat) -> Int {
            let n = rows(l); guard n > 1 else { return 0 }
            var top = y(l)
            for s in 0..<n { top += rowHeight(l, slot: s); if py < top { return s } }
            return n - 1
        }
        /// Height / top of the track in display slot `s` (0 = top) of lane `l` — the ONE source for drawing, hit-testing and drop marks.
        func rowHeight(_ l: Int, slot s: Int) -> CGFloat {
            if let a = slotH[l], s >= 0, s < a.count { return a[s] }
            return heights[l] / CGFloat(max(1, rows(l)))
        }
        func rowTop(_ l: Int, slot s: Int) -> CGFloat { y(l) + (0..<max(0, s)).reduce(0) { $0 + rowHeight(l, slot: $1) } }
        mutating func setHeight(_ l: Int, _ h: CGFloat) { switch l { case 0: t = h; case 1: v2 = h; case 2: v1 = h; case 3: a1 = h; case 4: a2 = h; default: c = h } }
        var heights: [CGFloat] { [t, v2, v1, a1, a2, c] }
        /// Display order top → bottom (T, C, V2, V1, A1, A2): the effect lane sits right under the titles, in the order it is composited. Lane identities (the indices
        /// below and `TrackLane` in the project) do not depend on it, so existing projects are unaffected.
        func y(_ l: Int) -> CGFloat { let pos = order.firstIndex(of: l) ?? l; return ruler + order.prefix(pos).map { heights[$0] }.reduce(0, +) + CGFloat(pos) * gap }
        var total: CGFloat { ruler + heights.reduce(0, +) + 5 * gap }
        /// 0..5 for the lane under y, nil in the ruler.
        func lane(at py: CGFloat) -> Int? { guard py >= ruler else { return nil }; for l in order.reversed() where py >= y(l) { return l }; return 0 }
    }
    /// The automatic geometry with the project's lane order and the heights the user gave (a lane never goes below what its content needs; the others are not squeezed).
    private func laidOut(_ auto: Geo, nSrc: Int, needC: CGFloat, needL: CGFloat) -> Geo {
        let layout = m.project.layout; var geo = auto; geo.order = layout.displayOrder.map { Geo.index($0) }
        geo.t = pickH(layout, .t, auto.t, need: 20 * CGFloat(auto.nT)); geo.v2 = pickH(layout, .v2, auto.v2, need: max(CGFloat(auto.nV2) * 22, CGFloat(auto.nV2) * needL)); geo.v1 = pickH(layout, .v1, auto.v1, need: max(30, needC))
        geo.a1 = pickH(layout, .a1, auto.a1, need: CGFloat(max(1, nSrc)) * 20); geo.a2 = pickH(layout, .a2, auto.a2, need: CGFloat(auto.nA2) * 20); geo.c = pickH(layout, .c, auto.c, need: max(20, CGFloat(auto.nC) * 20))
        // single tracks of V2 / A2 with a height of their own: those tracks take it, the others keep the equal share of the lane's automatic height
        for (li, lane, minRow) in [(1, TrackLane.v2, max(22, needL)), (4, TrackLane.a2, 20)] {
            let n = geo.rows(li); guard n > 1 else { continue }
            let explicit: [CGFloat?] = (0..<n).map { liveRows[SadrogProject.rowKey(lane, $0)] ?? layout.rowHeight(lane, $0).map { CGFloat($0) } }
            guard explicit.contains(where: { $0 != nil }) else { continue }
            let share = geo.heights[li] / CGFloat(n)
            let hs = (0..<n).map { slot -> CGFloat in let row = lane == .v2 ? n - 1 - slot : slot; return max(minRow, explicit[row] ?? share) }
            geo.slotH[li] = hs; geo.setHeight(li, hs.reduce(0, +))
        }
        return geo
    }
    /// Height of a lane: the user's (live while dragging) but never below what its content needs; otherwise the automatic one.
    private func pickH(_ layout: TimelineLayout, _ l: TrackLane, _ a: CGFloat, need: CGFloat) -> CGFloat {
        (liveHeights[l] ?? layout.height(l).map { CGFloat($0) }).map { max($0, need) } ?? a
    }
    /// Lane under y, or nil on the (pinned) ruler band.
    private func laneHit(_ y: CGFloat, _ geo: Geo) -> Int? { (y >= vOff && y < vOff + rulerH) ? nil : geo.lane(at: y) }
    /// Maps a pointer position over the lanes to a drop destination and time. nil destination = a lane that takes no materials. The edge strip of V2 (top) and A2 (bottom) is the new-track zone.
    private func locate(_ pt: CGPoint, pps: CGFloat, geo: Geo) -> (DropDestination?, Double)? {
        guard pps > 0, let l = laneHit(pt.y, geo) else { return nil }
        let t = max(0, Double(pt.x / pps)), rel = pt.y - geo.y(l), strip: CGFloat = 10
        switch l {
        case 2: return (.main, t)
        case 1: return rel < strip ? (.overlay(row: m.project.rowCount(.v2)), t) : (.overlay(row: geo.rows(1) - 1 - geo.slot(1, at: pt.y)), t)
        case 4: return rel > geo.heights[4] - strip ? (.audio(row: m.project.rowCount(.a2)), t) : (.audio(row: geo.slot(4, at: pt.y)), t)
        default: return (nil, t)
        }
    }
    /// The live drop mark: the span the material would take (library drags) or an insertion line (Finder files), green when allowed, red with the reason when refused.
    @ViewBuilder private func dropMark(pps: CGFloat, geo: Geo) -> some View {
        if let tid = m.effectDropTarget, let it = items.first(where: { $0.id == tid }) {
            let l = it.lane == .main ? 2 : 1
            let slot = l == 1 ? geo.rows(1) - 1 - it.row : 0, rh = geo.rowHeight(l, slot: slot), top = geo.rowTop(l, slot: slot)
            RoundedRectangle(cornerRadius: 3).stroke(Theme.C.sel, lineWidth: 2).background(Theme.C.sel.opacity(0.18)).frame(width: max(4, CGFloat(it.dur) * pps), height: rh)
                .offset(x: CGFloat(it.start) * pps, y: top)
            Text(T("Efectul va acționa asupra acestui element")).font(Theme.F.small).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.C.bg2, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Theme.C.sel).offset(x: CGFloat(it.start) * pps + 4, y: top + 2)
        }
        if let h = m.dropHover {
            let ok = h.destination != nil && h.plan?.isValid != false
            let tint = ok ? Theme.C.sel : Theme.C.warn
            let (l, rowSlot): (Int, Int?) = {
                switch h.destination { case .main?: return (2, nil)
                case .overlay(let r)?: return (1, r >= m.project.rowCount(.v2) ? -1 : geo.rows(1) - 1 - r)
                case .audio(let r)?: return (4, r >= m.project.rowCount(.a2) ? -1 : r)
                case nil: return (0, nil) }
            }()
            let rh = geo.rowHeight(l, slot: max(0, rowSlot ?? 0))
            let w = max(3, CGFloat(h.plan.map { $0.end - $0.start } ?? 0) * pps)
            let y: CGFloat = rowSlot == -1 ? (l == 1 ? geo.y(1) - 2 : geo.y(4) + geo.heights[4] - 8) : geo.rowTop(l, slot: rowSlot ?? 0)
            let height: CGFloat = rowSlot == -1 ? 10 : rh
            if h.destination == nil { Text(h.note).font(Theme.F.small).padding(6).background(Theme.C.bg2, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(Theme.C.warn).offset(x: CGFloat(h.time) * pps, y: geo.y(0) + 4) }
            else {
                RoundedRectangle(cornerRadius: 3).fill(tint.opacity(0.28)).overlay(RoundedRectangle(cornerRadius: 3).stroke(tint, lineWidth: 1.5))
                    .frame(width: w, height: height).offset(x: CGFloat(h.time) * pps, y: y)
                if !h.note.isEmpty { Text(h.note).font(Theme.F.small).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.C.bg2, in: RoundedRectangle(cornerRadius: 4)).foregroundStyle(tint).offset(x: CGFloat(h.time) * pps + 4, y: y + height + 2) }
                if let g = h.plan?.guide { Rectangle().fill(Theme.C.sel).frame(width: 1, height: geo.total).offset(x: CGFloat(g) * pps) }
            }
        }
    }
    private func laneKind(_ l: Int) -> Lane { l == 0 ? .text : (l == 1 ? .overlay : (l == 4 ? .audio : (l == 5 ? .callout : .main))) }

    var body: some View {
        VStack(spacing: 0) {
            tools
            Rectangle().fill(Theme.C.line).frame(height: 1)
            GeometryReader { g in
                let viewW = max(100, g.size.width - headerW)
                let contentW = viewW * CGFloat(max(1, m.zoom))
                let pps = contentW / CGFloat(max(m.project.timelineEnd, 0.001))
                let avail = max(0, g.size.height - rulerH - 5 * gap - (m.zoom > 1.01 ? 12 : 4))
                let nSrc = m.mainSources.count, a1 = nSrc > 1 ? CGFloat(nSrc) * sourceRowH : clamp(avail * 0.17, 20, 70)
                // V2 holds one row per overlay track (several cameras / screens at once); a single row keeps the former height
                let depth = m.attachedDepth, needC = Self.tileNeed(depth.clips), needL = Self.tileNeed(depth.layers)
                let nV2 = m.overlayRows, v2 = max(nV2 > 1 ? CGFloat(nV2) * max(sourceRowH, 30) : clamp(avail * 0.19, 24, 90), CGFloat(nV2) * needL)
                let nA2 = m.audioRows, nC = m.calloutRowCount, nT = m.textRowCount
                let auto = Geo(t: nT > 1 ? CGFloat(nT) * 22 : clamp(avail * 0.11, 20, 40), v2: v2, v1: max(clamp(avail * 0.26, 30, 120), needC), a1: a1, a2: nA2 > 1 ? CGFloat(nA2) * max(sourceRowH, 30) : clamp(avail * 0.17, 20, 70), c: nC > 1 ? CGFloat(nC) * 22 : clamp(avail * 0.10, 20, 40), ruler: rulerH, gap: gap, nV2: nV2, nA2: nA2, nC: nC, nT: nT)
                let geo = laidOut(auto, nSrc: nSrc, needC: needC, needL: needL)
                // a recording with many sounds (e.g. 8 input channels) makes A1 taller than the panel: the lanes then scroll vertically, headers and content together
                ScrollView(.vertical, showsIndicators: geo.total > g.size.height) {
                HStack(spacing: 0) {
                    headers(geo).frame(width: headerW)
                        .overlay(alignment: .top) { Theme.C.bg1.frame(height: rulerH).overlay(alignment: .bottom) { Rectangle().fill(Theme.C.line).frame(height: 1) }.offset(y: vOff) }
                    Rectangle().fill(Theme.C.line).frame(width: 1)
                    ScrollViewReader { proxy in
                        ScrollView(.horizontal, showsIndicators: m.zoom > 1.01) {
                            content(pps: pps, width: contentW, geo: geo).frame(width: contentW, height: max(g.size.height, geo.total), alignment: .topLeading)
                                .overlay(alignment: .topLeading) { dropMark(pps: pps, geo: geo).allowsHitTesting(false) }
                                .onDrop(of: [.fileURL], delegate: TimelineDropDelegate(m: m, pps: pps, locate: { locate($0, pps: pps, geo: geo) }))
                                .background(GeometryReader { r in Color.clear.preference(key: ScrollOffsetKey.self, value: -r.frame(in: .named("tlscroll")).minX) })
                        }
                        .scrollPosition($hPos)
                        .coordinateSpace(name: "tlscroll")
                        .onPreferenceChange(ScrollOffsetKey.self) { off in
                            // a change we did not cause, during playback = the user scrolled: stop following (no fight with the gesture)
                            if abs(off - scrollOffset) > 0.5, Date() > autoScrollUntil, m.playing, m.followPlayhead { m.followPlayhead = false }
                            scrollOffset = off
                        }
                        .onChange(of: m.time) { _, _ in follow(proxy, pps: pps, viewW: viewW) }
                        .onChange(of: m.playing) { _, p in if p { m.followPlayhead = true; follow(proxy, pps: pps, viewW: viewW) } }
                        .onChange(of: m.followPlayhead) { _, on in if on { follow(proxy, pps: pps, viewW: viewW, force: true) } }
                    }
                }.frame(height: max(g.size.height, geo.total))
                }.scrollBounceBehavior(.basedOnSize, axes: .vertical)
                .scrollPosition($vPos)
                .onScrollGeometryChange(for: CGFloat.self, of: { $0.contentOffset.y }) { _, y in vOff = max(0, y) }
                .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { viewportH = $0 }
            }
        }.background(Theme.C.bg0)
    }

    private var tools: some View {
        HStack(spacing: 10) {
            ControlGroup2 {
                Button { m.tool = .select } label: { Image(systemName: "cursorarrow") }.buttonStyle(ToolButtonStyle(active: m.tool == .select)).help(T("Selectare (A)")).accessibilityLabel(T("Unealta Selectare")).keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("a", modifiers: []))
                Button { m.tool = .blade } label: { Image(systemName: "scissors") }.buttonStyle(ToolButtonStyle(active: m.tool == .blade)).help(T("Foarfecă (B): clic pe o pistă taie în punctul indicat; Esc revine la Selectare")).accessibilityLabel(T("Unealta Foarfecă")).keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("b", modifiers: []))
            }
            ControlGroup2 {
            Button { m.followPlayhead.toggle() } label: { Image(systemName: "scope") }.buttonStyle(ToolButtonStyle(active: m.followPlayhead)).help(m.followPlayhead ? T("Urmărire cursor activă: timeline-ul se deplasează la redare ca să-l păstreze vizibil. Clic oprește.") : T("Urmărire oprită (ai derulat manual). Clic: revii la cursor și reiei urmărirea.")).accessibilityLabel(T("Urmărire cursor")).accessibilityValue(m.followPlayhead ? T("activă") : T("oprită"))
            Button { m.snapOn.toggle() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.buttonStyle(ToolButtonStyle(active: m.snapOn)).help(m.snapOn ? T("Magnetism în timeline activ: clipurile se lipesc de margini și de cursor (S). Alinierea pe canvas e separată, în bara previzualizării.") : T("Magnetism în timeline oprit (S)")).accessibilityLabel(T("Magnetism")).accessibilityValue(m.snapOn ? "activ" : "oprit").keyboardShortcut(m.textEditing ? nil : KeyboardShortcut("s", modifiers: []))
            }
            ControlGroup2 {
            Button { m.addTitle() } label: { Image(systemName: "textformat") }.buttonStyle(ToolButtonStyle()).help(T("Adaugă un titlu la cursor (pista T)")).accessibilityLabel(T("Adaugă titlu"))
            Button { m.addCallout() } label: { Image(systemName: "viewfinder") }.buttonStyle(ToolButtonStyle()).help(T("Adaugă o evidențiere locală la cursor (pista C)")).accessibilityLabel(T("Adaugă evidențiere"))
            }
            ControlGroup2 {
                Button { m.drawTool = m.drawTool == .frame ? nil : .frame } label: { Image(systemName: "rectangle") }.buttonStyle(ToolButtonStyle(active: m.drawTool == .frame)).help(T("Cadru dreptunghiular: doar conturul, fără întunecare; trage în previzualizare (Esc anulează)")).accessibilityLabel(T("Cadru dreptunghiular"))
                Button { m.drawTool = m.drawTool == .rect ? nil : .rect } label: { Image(systemName: "rectangle.dashed") }.buttonStyle(ToolButtonStyle(active: m.drawTool == .rect)).help(T("Selecție dreptunghiulară: trage în previzualizare, în orice direcție (Esc anulează)")).accessibilityLabel(T("Selecție dreptunghiulară"))
                Button { m.drawTool = m.drawTool == .ellipse ? nil : .ellipse } label: { Image(systemName: "circle.dashed") }.buttonStyle(ToolButtonStyle(active: m.drawTool == .ellipse)).help(T("Selecție eliptică: trage în previzualizare (Esc anulează)")).accessibilityLabel(T("Selecție eliptică"))
                Button { m.drawTool = m.drawTool == .line ? nil : .line } label: { Image(systemName: "line.diagonal") }.buttonStyle(ToolButtonStyle(active: m.drawTool == .line)).help(T("Linie: trage în previzualizare (Esc anulează)")).accessibilityLabel(T("Linie"))
                Button { m.drawTool = m.drawTool == .arrow ? nil : .arrow } label: { Image(systemName: "arrow.up.right") }.buttonStyle(ToolButtonStyle(active: m.drawTool == .arrow)).help(T("Săgeată: trage în previzualizare, de la coadă spre vârf (Esc anulează)")).accessibilityLabel(T("Săgeată"))
                Button { m.drawTool = m.drawTool == .freehand ? nil : .freehand } label: { Image(systemName: "scribble") }.buttonStyle(ToolButtonStyle(active: m.drawTool == .freehand)).help(T("Contur liber: desenează cu mouse-ul în previzualizare (Esc anulează)")).accessibilityLabel(T("Contur liber"))
            }
            ControlGroup2 {
            Button { m.split() } label: { Image(systemName: "rectangle.split.2x1") }.buttonStyle(ToolButtonStyle()).help(T("Taie la cursor (⌘K)")).accessibilityLabel(T("Taie la cursor")).keyboardShortcut("k", modifiers: .command)
            Button { m.freezeHere() } label: { Image(systemName: "snowflake") }.buttonStyle(ToolButtonStyle()).help(T("Îngheață cadrul de la cursor (⌥F)")).accessibilityLabel(T("Îngheață cadrul"))
            Button { m.deleteSelected() } label: { Image(systemName: "trash") }.buttonStyle(ToolButtonStyle()).help(T("Șterge elementul selectat (⌫)")).accessibilityLabel(T("Șterge elementul selectat")).disabled(m.selection == nil)
            }
            if m.tool == .blade { Text(T("Foarfecă activă — clic taie · Esc revine")).font(Theme.F.caption).foregroundStyle(Theme.C.sel).padding(.leading, 8) }
            Spacer()
            ControlGroup2 {
            Button { m.undo() } label: { Image(systemName: "arrow.uturn.backward") }.buttonStyle(ToolButtonStyle()).help(T("Anulează (⌘Z)")).accessibilityLabel(T("Anulează ultima modificare")).disabled(!m.canUndo)
            Button { m.redo() } label: { Image(systemName: "arrow.uturn.forward") }.buttonStyle(ToolButtonStyle()).help(T("Refă (⇧⌘Z)")).accessibilityLabel(T("Refă modificarea")).disabled(!m.canRedo)
            }
            ControlGroup2 {
            Button { m.zoom = max(1, m.zoom / 1.5) } label: { Image(systemName: "minus") }.buttonStyle(ToolButtonStyle()).help(T("Micșorează scara timeline-ului")).accessibilityLabel(T("Micșorează timeline-ul"))
            FineSlider(value: Binding(get: { log2(m.zoom) }, set: { m.zoom = pow(2, $0) }), range: 0...4, label: T("Scara timeline-ului")) { _ in }.frame(width: 110)
            Button { m.zoom = min(16, m.zoom * 1.5) } label: { Image(systemName: "plus") }.buttonStyle(ToolButtonStyle()).help(T("Mărește scara timeline-ului")).accessibilityLabel(T("Mărește timeline-ul"))
            Button { m.zoom = 1 } label: { Image(systemName: "arrow.left.and.right") }.buttonStyle(ToolButtonStyle()).help(T("Potrivește tot proiectul în fereastră")).accessibilityLabel(T("Potrivește proiectul"))
            }
        }.padding(.horizontal, Theme.S.sm).frame(height: 38).background(Theme.C.bg3)
    }

    private func headers(_ geo: Geo) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear.frame(height: rulerH)
            ForEach(Array(geo.order.enumerated()), id: \.element) { pos, l in
                if pos > 0 { Color.clear.frame(height: gap) }
                laneHeader(l, geo).frame(height: geo.heights[l])
                    .overlay(alignment: .topLeading) { laneGrip(l, geo) }
                    .overlay(alignment: .bottom) { if !(l == 1 || l == 4) || geo.rows(l) < 2 { resizeHandle(l, geo) } }      // V2 / A2 with several tracks: each track has its own separator
                    .opacity(laneDrag?.lane == Geo.laneOf[l] ? 0.45 : 1)
            }
            Spacer(minLength: 0)
        }.background(Theme.C.bg1).coordinateSpace(name: "lanes")
            .overlay(alignment: .topLeading) { reorderIndicator(geo) }
            .overlay(alignment: .topLeading) { rowIndicator(geo) }
    }
    @ViewBuilder private func laneHeader(_ l: Int, _ geo: Geo) -> some View {
        switch l {
        case 0: header("T", T("Titluri"), .t).contextMenu { laneLayoutMenu(.t, geo.t) }
        case 5: header("C", T("Evidențiere"), .c).contextMenu { laneLayoutMenu(.c, geo.c) }
        case 1: layerHeader("V2", T("Suprapus"), .v2, height: geo.v2, n: geo.nV2, geo: geo)
        case 2: header("V1", T("Video"), .v1).contextMenu { laneLayoutMenu(.v1, geo.v1) }
        case 3: if m.mainSources.count > 1 { sourcesHeader(geo).contextMenu { laneLayoutMenu(.a1, geo.a1) } } else { header("A1", T("Sunet"), .a1).contextMenu { laneLayoutMenu(.a1, geo.a1) } }
        default: layerHeader("A2", T("Audio"), .a2, height: geo.a2, n: geo.nA2, geo: geo)
        }
    }
    /// Commands equivalent to the gestures: taller, compact, reset, move. Also in the lane's context menu.
    @ViewBuilder private func laneLayoutMenu(_ lane: TrackLane, _ h: CGFloat) -> some View {
        let order = m.project.layout.displayOrder, pos = order.firstIndex(of: lane) ?? 0
        Divider()
        Button(T("Mărește înălțimea pistei")) { m.setLaneHeight(lane, Double(h) * 1.4) }.disabled(Double(h) >= TimelineLayout.heightRange.upperBound)
        Button(T("Compactează pista")) { m.setLaneHeight(lane, Double(h) / 1.4) }
        Button(T("Resetează înălțimea pistei")) { m.setLaneHeight(lane, nil) }.disabled(m.project.layout.height(lane) == nil)
        Button(T("Mută pista mai sus")) { m.moveLane(lane, to: pos - 1) }.disabled(pos == 0)
        Button(T("Mută pista mai jos")) { m.moveLane(lane, to: pos + 1) }.disabled(pos >= order.count - 1)
        Button(T("Resetează aspectul pistelor")) { m.resetLaneLayout() }.disabled(m.project.layout.isDefault)
    }
    /// Separator under a lane header: drag = continuous height (live, committed once as one undo step), double-click = automatic height.
    private func resizeHandle(_ l: Int, _ geo: Geo) -> some View {
        let lane = Geo.laneOf[l]
        return Rectangle().fill(Color.clear).frame(height: 8).contentShape(Rectangle()).pointerStyle(.rowResize)
            .overlay { Rectangle().fill(Theme.C.line).frame(height: 1).opacity(liveHeights[lane] != nil ? 0 : 0.0) }
            .overlay(alignment: .bottom) { if liveHeights[lane] != nil { Rectangle().fill(Theme.C.sel).frame(height: 2) } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes")).onChanged { v in
                if resizeStart?.lane != lane { resizeStart = (lane, geo.heights[l]) }
                let base = resizeStart?.h ?? geo.heights[l]
                liveHeights[lane] = max(CGFloat(TimelineLayout.heightRange.lowerBound), min(CGFloat(TimelineLayout.heightRange.upperBound), base + v.location.y - v.startLocation.y))
            }.onEnded { _ in
                if let h = liveHeights[lane] { m.setLaneHeight(lane, Double(h)) }
                liveHeights[lane] = nil; resizeStart = nil
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { m.setLaneHeight(lane, nil) })
            .help(T("Trage ca să schimbi înălțimea pistei; dublu-clic = înălțime automată"))
            .accessibilityElement().accessibilityLabel(L10n.f("Înălțimea pistei %@", lane.rawValue.uppercased())).accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { d in
                let cur = Double(geo.heights[l]); m.setLaneHeight(lane, d == .increment ? cur * 1.25 : cur / 1.25)
            }
    }
    /// Separator under ONE track of V2 / A2: drag = that track's height (live, one undo step at the end), double-click = back to the automatic height.
    private func rowResizeHandle(_ lane: TrackLane, row: Int, height: CGFloat) -> some View {
        let key = SadrogProject.rowKey(lane, row)
        return Rectangle().fill(Color.clear).frame(height: 8).contentShape(Rectangle()).pointerStyle(.rowResize)
            .overlay(alignment: .bottom) { if liveRows[key] != nil { Rectangle().fill(Theme.C.sel).frame(height: 2) } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("lanes")).onChanged { v in
                if rowResizeStart?.key != key { rowResizeStart = (key, height) }
                let base = rowResizeStart?.h ?? height
                liveRows[key] = max(CGFloat(TimelineLayout.heightRange.lowerBound), min(CGFloat(TimelineLayout.heightRange.upperBound), base + v.location.y - v.startLocation.y))
            }.onEnded { _ in
                if let h = liveRows[key] { m.setRowHeight(lane, row, Double(h)) }
                liveRows[key] = nil; rowResizeStart = nil
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded { m.setRowHeight(lane, row, nil) })
            .help(T("Trage ca să schimbi înălțimea acestei piste; dublu-clic = înălțime automată"))
            .accessibilityElement().accessibilityLabel(L10n.f("Înălțimea pistei %@", m.trackName(lane, row))).accessibilityAddTraits(.isButton)
            .accessibilityAdjustableAction { d in m.setRowHeight(lane, row, Double(d == .increment ? height * 1.25 : height / 1.25)) }
    }
    /// Grip at the left edge of a header: drag the lane to another position. Distinct from lock/mute (right) and the resize separator (bottom).
    private func laneGrip(_ l: Int, _ geo: Geo) -> some View {
        let lane = Geo.laneOf[l]
        return Image(systemName: "line.3.horizontal").font(.system(size: 8)).foregroundStyle(Theme.C.textFaint).frame(width: 12, height: min(geo.heights[l] - 8, 26))
            .contentShape(Rectangle()).pointerStyle(.grabIdle)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("lanes")).onChanged { v in
                laneDrag = (lane, v.location.y, v.location.x > headerW + 40)
                let rel = v.location.y - vOff
                if rel < rulerH + 18 { vPos.scrollTo(y: max(0, vOff - 14)) } else if rel > viewportH - 18 { vPos.scrollTo(y: vOff + 14) }
            }.onEnded { v in
                defer { laneDrag = nil }
                guard v.location.x <= headerW + 40 else { return }
                let to = dropIndex(lane, y: v.location.y, geo: geo)
                if to != (m.project.layout.displayOrder.firstIndex(of: lane) ?? to) { m.moveLane(lane, to: to) }
            })
            .help(T("Trage ca să muți pista mai sus sau mai jos; scoate cursorul în afara antetului ca să renunți"))
            .accessibilityLabel(L10n.f("Mută pista %@", lane.rawValue.uppercased()))
    }
    /// Final index of `lane` if dropped with the pointer at content y.
    private func dropIndex(_ lane: TrackLane, y: CGFloat, geo: Geo) -> Int {
        geo.order.filter { Geo.laneOf[$0] != lane }.filter { y > geo.y($0) + geo.heights[$0] / 2 }.count
    }
    @ViewBuilder private func reorderIndicator(_ geo: Geo) -> some View {
        if let d = laneDrag {
            let others = geo.order.filter { Geo.laneOf[$0] != d.lane }, idx = dropIndex(d.lane, y: d.y, geo: geo)
            let y = idx < others.count ? geo.y(others[idx]) - gap / 2 : (others.last.map { geo.y($0) + geo.heights[$0] + gap / 2 } ?? geo.ruler)
            VStack(alignment: .leading, spacing: 2) {
                if d.cancel { Text(T("Renunță: pista rămâne unde era")).font(Theme.F.small).foregroundStyle(Theme.C.warn).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.C.bg2, in: RoundedRectangle(cornerRadius: 4)) }
                else { Rectangle().fill(Theme.C.sel).frame(height: 3).shadow(color: Theme.C.sel.opacity(0.6), radius: 3) }
            }.frame(width: headerW).offset(y: y - 1).allowsHitTesting(false)
        }
    }
    /// A1 when the recording carries several sounds: the lane switch (all sources) on top of one row per source, each with its own name and mute.
    private func sourcesHeader(_ geo: Geo) -> some View {
        let srcs = m.mainSources, laneOff = m.isOff(.a1), rowH = geo.a1 / CGFloat(max(1, srcs.count))
        return HStack(alignment: .top, spacing: 0) {
            VStack(spacing: 2) {
                Text(T("A1")).font(Theme.F.monoSmall).foregroundStyle(Theme.C.textFaint)
                Button { m.toggle(.a1) } label: {
                    Image(systemName: laneOff ? "speaker.slash.fill" : "speaker.wave.2.fill").font(Theme.F.iconSmall).frame(width: 24, height: 24)
                        .foregroundStyle(laneOff ? Theme.C.sel : Theme.C.textDim).contentShape(Rectangle())
                }.buttonStyle(.plain).help(laneOff ? T("Activează sunetul întregii piste A1 (acum mută)") : T("Oprește toate sursele pistei A1 în previzualizare și export"))
                    .accessibilityLabel(T("Sunet pista A1")).accessibilityValue(laneOff ? "mut" : "activ")
                Button { compactSources.toggle() } label: {
                    Image(systemName: compactSources ? "arrow.up.and.down" : "arrow.down.right.and.arrow.up.left").font(Theme.F.iconSmall).frame(width: 24, height: 22)
                        .foregroundStyle(Theme.C.textFaint).contentShape(Rectangle())
                }.buttonStyle(.plain).help(compactSources ? T("Rânduri audio normale") : T("Rânduri audio compacte"))
                    .accessibilityLabel(T("Înălțimea rândurilor audio")).accessibilityValue(compactSources ? "compacte" : "normale")
            }.frame(width: 26).padding(.leading, Theme.S.sm).padding(.top, 3)
            VStack(spacing: 0) {
                ForEach(srcs, id: \.index) { src in
                    let off = laneOff || m.isSourceMuted(src.index)
                    HStack(spacing: 4) {
                        Button { m.focusSource(src.index) } label: {
                            HStack(spacing: 4) {
                                Image(systemName: src.kind == .system ? "desktopcomputer" : (src.kind == .input ? "mic" : "waveform")).font(Theme.F.iconSmall).foregroundStyle(m.focusedSource == src.index ? Theme.C.sel : Theme.C.textFaint).frame(width: 12)
                                Text(src.name).font(Theme.F.small).lineLimit(1).truncationMode(.tail).opacity(off ? 0.5 : 1).help(src.name)
                                Spacer(minLength: 0)
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityLabel(L10n.f("Alege sursa %@ în inspector", "\(src.name)")).accessibilityValue(m.focusedSource == src.index ? T("aleasă") : "")
                        if let st = m.fxState(src.index) {          // the source has active effects: their processing state
                            if case .ready = st { Image(systemName: "slider.vertical.3").font(Theme.F.iconSmall).foregroundStyle(Theme.C.ok).help(L10n.f("Efecte procesate: %@", "\(m.project.activeEffects(ofSource: src.index).map(\.name).joined(separator: " › "))")).accessibilityLabel(T("Efecte procesate")) }
                            else { FxStatusBadge(state: st) }
                        }
                        Button { m.toggleSource(src.index) } label: {
                            Image(systemName: m.isSourceMuted(src.index) ? "speaker.slash.fill" : "speaker.wave.1.fill").font(Theme.F.iconSmall).frame(width: 24, height: min(24, rowH))
                                .foregroundStyle(m.isSourceMuted(src.index) ? Theme.C.sel : Theme.C.textDim).contentShape(Rectangle())
                        }.buttonStyle(.plain).disabled(laneOff)
                            .help(m.isSourceMuted(src.index) ? L10n.f("Activează sursa „%@” (acum mută)", "\(src.name)") : L10n.f("Oprește doar sursa „%@” în previzualizare și export", "\(src.name)"))
                            .accessibilityLabel(L10n.f("Sunet sursa %@", "\(src.name)")).accessibilityValue(m.isSourceMuted(src.index) ? T("mut") : T("activ"))
                    }.frame(height: rowH).overlay(alignment: .bottom) { if src.index != srcs.last?.index { Rectangle().fill(Theme.C.line.opacity(0.6)).frame(height: 1) } }
                }
            }.padding(.trailing, 4)
        }.foregroundStyle(Theme.C.textDim).frame(height: geo.a1, alignment: .top)
    }
    /// V2 / A2: one labelled header row per track; the first carries the lane's lock and visibility/mute switches. Right-click a track for its commands.
    private func layerHeader(_ id: String, _ t: String, _ lane: TrackLane, height: CGFloat, n: Int, geo: Geo) -> some View {
        return VStack(spacing: 0) {
            ForEach(0..<max(1, n), id: \.self) { slot in
                let row = lane == .v2 ? n - 1 - slot : slot, rowH = geo.rowHeight(lane == .v2 ? 1 : 4, slot: slot)
                Group {
                    if slot == 0 { header(id, n > 1 ? m.trackName(lane, row) : t, lane) }
                    else {
                        HStack(spacing: 6) {
                            Text(id).font(Theme.F.monoSmall).foregroundStyle(Theme.C.textFaint).frame(width: 18, alignment: .leading)
                            Text(m.trackName(lane, row)).font(Theme.F.body).lineLimit(1).truncationMode(.tail).opacity(m.isOff(lane) ? 0.55 : 1)
                            Spacer(minLength: 0)
                        }.foregroundStyle(Theme.C.textDim).padding(.leading, Theme.S.md).padding(.trailing, 6).overlay(alignment: .top) { Rectangle().fill(Theme.C.line.opacity(0.6)).frame(height: 1) }
                    }
                }.frame(height: rowH).contentShape(Rectangle())
                    .overlay(alignment: .bottom) { if n > 1 { rowResizeHandle(lane, row: row, height: rowH) } }
                    .overlay(alignment: .trailing) { if n > 1 { rowGrip(lane, row: row, rows: n, height: height, geo: geo).padding(.trailing, slot == 0 ? 56 : 6) } }
                    .opacity(rowDrag?.lane == lane && rowDrag?.from == row ? 0.45 : 1)
                    .contextMenu { trackMenu(lane, row: row, rows: n, height: height) }
                    .accessibilityElement(children: .contain).accessibilityLabel(L10n.f("Pista %@", m.trackName(lane, row)))
            }
        }
    }
    /// Where a row dragged by its grip would land (`to` is nil when it cannot: outside the lane or a locked lane) and why not.
    private func rowTarget(_ lane: TrackLane, rows n: Int, height: CGFloat, y: CGFloat, geo: Geo) -> (to: Int?, slot: Int, reason: String?) {
        let li = lane == .v2 ? 1 : 4, top = geo.y(li), rel = y - top, slot = geo.slot(li, at: y)
        let row = lane == .v2 ? n - 1 - slot : slot
        if m.isLocked(lane) { return (nil, slot, L10n.f("Pista %@ e blocată — deblochează-o ca să o muți", lane == .v2 ? "V2" : "A2")) }
        if rel < -4 || rel > height + 4 { return (nil, slot, L10n.f("Pistele %@ se mută doar în interiorul benzii %@", lane == .v2 ? "V2" : "A2", lane == .v2 ? "V2" : "A2")) }
        return (row, slot, nil)
    }
    private func rowGrip(_ lane: TrackLane, row: Int, rows n: Int, height: CGFloat, geo: Geo) -> some View {
        Image(systemName: "line.3.horizontal").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.C.textDim).frame(width: 24, height: max(24, min(height, 36)))
            .background(RoundedRectangle(cornerRadius: 4).fill(Theme.C.text.opacity(0.06)))
            .contentShape(Rectangle()).pointerStyle(.grabIdle)
            .gesture(DragGesture(minimumDistance: 3, coordinateSpace: .named("lanes")).onChanged { v in
                rowDrag = (lane, row, v.location.y, v.location.x > headerW + 40)
                let rel = v.location.y - vOff
                if rel < rulerH + 18 { vPos.scrollTo(y: max(0, vOff - 14)) } else if rel > viewportH - 18 { vPos.scrollTo(y: vOff + 14) }
            }.onEnded { v in
                defer { rowDrag = nil }
                guard v.location.x <= headerW + 40, let to = rowTarget(lane, rows: n, height: height, y: v.location.y, geo: geo).to, to != row else { return }
                m.moveTrackRow(lane, from: row, to: to)
            })
            .help(lane == .v2 ? T("Trage ca să muți pista; ordinea de suprapunere a imaginilor se schimbă (rândul de sus e în față)") : T("Trage ca să muți pista; doar organizare, sunetul mixat nu se schimbă"))
            .accessibilityLabel(L10n.f("Mută pista %@", m.trackName(lane, row)))
    }
    @ViewBuilder private func rowIndicator(_ geo: Geo) -> some View {
        if let d = rowDrag {
            let lane = d.lane, n = m.project.rowCount(lane), h = lane == .v2 ? geo.v2 : geo.a2, t = rowTarget(lane, rows: n, height: h, y: d.y, geo: geo)
            let li = lane == .v2 ? 1 : 4
            // the line goes on the edge of the slot the track would take: above it when moving up, below when moving down
            let fromSlot = lane == .v2 ? n - 1 - d.from : d.from
            let y = geo.rowTop(li, slot: t.slot >= fromSlot ? t.slot + 1 : t.slot)
            VStack(alignment: .leading, spacing: 2) {
                if d.cancel { Text(T("Renunță: pista rămâne unde era")).font(Theme.F.small).foregroundStyle(Theme.C.warn).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.C.bg2, in: RoundedRectangle(cornerRadius: 4)) }
                else if let why = t.reason { Text(why).font(Theme.F.small).foregroundStyle(Theme.C.warn).lineLimit(2).padding(.horizontal, 6).padding(.vertical, 2).background(Theme.C.bg2, in: RoundedRectangle(cornerRadius: 4)) }
                else { Rectangle().fill(Theme.C.sel).frame(height: 3).shadow(color: Theme.C.sel.opacity(0.6), radius: 3) }
            }.frame(width: headerW).offset(y: y - 1).allowsHitTesting(false)
        }
    }
    @ViewBuilder private func trackMenu(_ lane: TrackLane, row: Int, rows n: Int, height: CGFloat) -> some View {
        Button(T("Redenumește pista…")) { m.renameTrack(lane, row) }
        Button(T("Adaugă o pistă")) { m.addTrack(lane) }
        Button(T("Elimină pista (goală)")) { m.removeTrack(lane, row) }.disabled(n < 2)
        if n > 1 {
            Divider()
            let cur = m.project.layout.rowHeight(lane, row) ?? Double(height) / Double(n)
            Button(T("Mărește această pistă")) { m.setRowHeight(lane, row, cur * 1.4) }.disabled(cur >= TimelineLayout.heightRange.upperBound)
            Button(T("Compactează această pistă")) { m.setRowHeight(lane, row, cur / 1.4) }
            Button(T("Resetează înălțimea acestei piste")) { m.setRowHeight(lane, row, nil) }.disabled(m.project.layout.rowHeight(lane, row) == nil)
            Divider()
            Button(lane == .v2 ? T("Urcă pista (în față)") : T("Urcă pista")) { m.swapTracks(lane, row, lane == .v2 ? row + 1 : row - 1) }.disabled(lane == .v2 ? row >= n - 1 : row == 0)
            Button(lane == .v2 ? T("Coboară pista (în spate)") : T("Coboară pista")) { m.swapTracks(lane, row, lane == .v2 ? row - 1 : row + 1) }.disabled(lane == .v2 ? row == 0 : row >= n - 1)
        }
        laneLayoutMenu(lane, height)
    }
    private func header(_ id: String, _ t: String, _ lane: TrackLane) -> some View {
        let off = m.isOff(lane), v = lane.isVideo
        return HStack(spacing: 6) {
            Text(id).font(Theme.F.monoSmall).foregroundStyle(Theme.C.textFaint).frame(width: 18, alignment: .leading)
            Text(t).font(Theme.F.body).lineLimit(1).truncationMode(.tail).layoutPriority(1).opacity(off ? 0.55 : 1).help(t)
            Spacer(minLength: 0)
            Button { m.toggleLock(lane) } label: {
                Image(systemName: m.isLocked(lane) ? "lock.fill" : "lock.open").font(Theme.F.small).frame(width: 22, height: 24)
                    .foregroundStyle(m.isLocked(lane) ? Theme.C.sel : Theme.C.textFaint).contentShape(Rectangle())
            }.buttonStyle(.plain).help(m.isLocked(lane) ? L10n.f("Deblochează pista %@", "\(id)") : L10n.f("Blochează pista %@ (nu se mai poate edita)", "\(id)"))
                .accessibilityLabel(L10n.f("Blocare pista %@", "\(id)")).accessibilityValue(m.isLocked(lane) ? T("blocată") : T("deblocată"))
            Button { m.toggle(lane) } label: {
                Image(systemName: v ? (off ? "eye.slash" : "eye") : (off ? "speaker.slash.fill" : "speaker.wave.2.fill")).font(Theme.F.small).frame(width: 24, height: 24)
                    .foregroundStyle(off ? Theme.C.sel : Theme.C.textDim).contentShape(Rectangle())
            }.buttonStyle(.plain)
                .help(v ? (off ? L10n.f("Arată pista %@ (acum ascunsă în previzualizare și export)", "\(id)") : L10n.f("Ascunde pista %@ din previzualizare și export", "\(id)")) : (off ? L10n.f("Activează sunetul pistei %@ (acum mut)", "\(id)") : L10n.f("Oprește sunetul pistei %@ în previzualizare și export", "\(id)")))
                .accessibilityLabel(v ? L10n.f("Vizibilitate pista %@", "\(id)") : L10n.f("Sunet pista %@", "\(id)")).accessibilityValue(v ? (off ? T("ascunsă") : T("vizibilă")) : (off ? T("mut") : T("activ")))
        }.foregroundStyle(Theme.C.textDim).padding(.leading, Theme.S.md).padding(.trailing, 6).frame(maxWidth: .infinity, alignment: .leading)
    }

    // items ------------------------------------------------------------
    private struct Item { var id: UUID; var lane: Lane; var start: Double; var dur: Double; var row = 0; var attached = false }
    private var items: [Item] {
        var out: [Item] = []
        for sp in m.project.clipSpans { out.append(Item(id: sp.id, lane: .main, start: sp.start, dur: sp.end - sp.start)) }
        for l in m.project.layers { out.append(Item(id: l.id, lane: l.kind == .video ? .overlay : .audio, start: l.start, dur: l.duration, row: l.row)) }
        let trow = m.project.textRows()
        for t in m.project.texts { out.append(Item(id: t.id, lane: .text, start: t.start, dur: t.duration, row: trow[t.id] ?? 0)) }
        let crow = m.project.globalCalloutRows(), arow = m.project.attachedCalloutRows()
        for c in m.project.callouts { let at = m.project.isAttached(c); out.append(Item(id: c.id, lane: .callout, start: c.start, dur: c.duration, row: (at ? arow[c.id] : crow[c.id]) ?? 0, attached: at)) }
        return out
    }
    /// Hover text of a timeline item: what it is and what dragging does (the real gestures: move, trim at the edges, blade tool cuts).
    private func itemHelp(_ it: Item) -> String {
        if m.tool == .blade { return T("Unealta Lamă: clic taie elementul în punctul indicat.") }
        switch it.lane {
        case .main: return T("Clip de pe pista principală: trage pentru a-l muta între clipuri; trage marginile pentru a-l tăia; clic dreapta pentru mai multe comenzi.")
        case .overlay: return T("Element video suprapus: trage pentru a-l muta (și pe altă pistă); trage marginile pentru a-l tăia; clic dreapta pentru mai multe comenzi.")
        case .audio: return T("Element de sunet: trage pentru a-l muta (și pe altă pistă); trage marginile pentru a-l tăia; clic dreapta pentru mai multe comenzi.")
        case .text: return T("Titlu: trage pentru a-l muta în timp; titlurile care se suprapun stau pe rânduri separate; trage marginile pentru durată.")
        case .callout: return T("Evidențiere: trage pentru a o muta în timp; trage marginile pentru durată; forma se editează în vizor.")
        }
    }
    private func item(_ id: UUID) -> Item? { items.first { $0.id == id } }
    private func rect(_ it: Item, pps: CGFloat) -> (x: CGFloat, w: CGFloat) {
        var s = it.start
        if let mp = m.movePreview, it.lane != .main, mp.id == it.id || m.groupMoving.contains(it.id) { s += mp.delta }
        return (CGFloat(s) * pps, CGFloat(it.dur) * pps)
    }
    private func lanes(of lane: Lane) -> [Int] { lane == .text ? [0] : (lane == .overlay ? [1] : (lane == .audio ? [4] : (lane == .callout ? [5] : [2, 3]))) }

    private func content(pps: CGFloat, width: CGFloat, geo: Geo) -> some View {
        ZStack(alignment: .topLeading) {
            Theme.C.bg0
            Ruler(total: m.project.timelineEnd, pps: pps, rangeIn: m.project.rangeIn, rangeOut: m.project.rangeOut, markerLane: markerH).frame(width: width, height: rulerH).background(Theme.C.bg0)
                .overlay(alignment: .bottomLeading) {
                    let ms = m.project.markers.sorted { $0.time < $1.time }
                    // Explicit leading ZStack: bare children of an overlay are centred, which shifted each flag by half its width difference.
                    ZStack(alignment: .bottomLeading) {
                        ForEach(Array(ms.enumerated()), id: \.element.id) { i, mk in
                            let x = CGFloat(mk.time) * pps, room = i + 1 < ms.count ? CGFloat(ms[i + 1].time) * pps - x - 16 : 140
                            MarkerFlag(m: m, marker: mk, room: min(140, room)).frame(height: markerH).offset(x: x - 5)
                        }
                    }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                }
                .overlay(alignment: .bottom) { Rectangle().fill(Theme.C.line.opacity(0.7)).frame(height: 1) }
                .offset(y: vOff).zIndex(5)
            ForEach(0..<6, id: \.self) { l in
                Rectangle().fill(Theme.C.bg1.opacity(0.55)).frame(width: width, height: geo.heights[l]).offset(y: geo.y(l)).allowsHitTesting(false)
            }
            ForEach(items, id: \.id) { it in
                let r = rect(it, pps: pps); let sel = m.isSelected(it.id), hov = hoverItem == it.id, ed = m.trimPreview?.clip == it.id || { if case .move(let i, _)? = drag { return i == it.id }; return false }()
                switch it.lane {
                case .main:
                    if let c = m.project.clips.first(where: { $0.id == it.id }) {
                        VideoClipFace(media: c.media, sourceStart: c.sourceStart, duration: c.duration, w: r.w, h: geo.v1, pps: pps, held: c.held, selected: sel, hover: hov, editing: ed, linked: true, scaled: !c.transform.isIdentity, title: c.label)
                            .opacity(m.isOff(.v1) ? 0.35 : 1).offset(x: r.x, y: geo.y(2)).contextMenu { menu(it.id) }.help(itemHelp(it)).accessibilityAddTraits(.isButton).accessibilityAction { m.select(it.id) }
                        let srcs = m.mainSources
                        Group {
                            if c.held || m.media[c.media]?.hasAudio == false {
                                // a freeze frame or a recording without audio tracks: no sound clip is drawn (nothing fictitious on A1)
                                EmptyView()
                            } else if c.audioDetached {
                                // the sound was detached: this slot only says so (dashed outline + link mark); the sound lives on A2
                                RoundedRectangle(cornerRadius: 4).stroke(sel || hov ? Theme.C.sel : Theme.C.line, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                                    .overlay(alignment: .leading) { Label(T("Sunet detașat → A2"), systemImage: "link").font(Theme.F.small).labelStyle(.titleAndIcon).foregroundStyle(Theme.C.textFaint).lineLimit(1).padding(.leading, 6) }
                                    .frame(width: max(2, r.w - 1), height: geo.a1 - 1)
                            } else if srcs.count > 1 {
                                let fd = m.audioEdit(c.id).effectiveFades(duration: c.duration)
                                MultiAudioClipFace(rows: srcs.map { s in (m.media[c.media]?.trackPeaks.indices.contains(s.index) == true ? m.media[c.media]!.trackPeaks[s.index] : [], m.isSourceMuted(s.index)) },
                                                   from: c.sourceStart, to: c.sourceStart + c.duration, w: r.w, h: geo.a1, selected: sel, hover: hov, editing: ed,
                                                   fadeIn: CGFloat(fd.fadeIn) * pps, fadeOut: CGFloat(fd.fadeOut) * pps)
                            } else {
                                let fd = m.audioEdit(c.id).effectiveFades(duration: c.duration)
                                AudioClipFace(peaks: m.media[c.media]?.peaks ?? [], from: c.sourceStart, to: c.sourceStart + c.duration, w: r.w, h: geo.a1, selected: sel, hover: hov, editing: ed,
                                              fadeIn: CGFloat(fd.fadeIn) * pps, fadeOut: CGFloat(fd.fadeOut) * pps)
                            }
                        }
                            .overlay(alignment: .topLeading) { if (sel || hov || m.liveAudio[c.id] != nil), m.media[c.media]?.hasAudio != false { FadeHandles(m: m, id: c.id, duration: c.duration, pps: pps, width: max(2, r.w - 1)) } }
                            .opacity(m.isOff(.a1) ? 0.35 : 1).offset(x: r.x, y: geo.y(3)).contextMenu { menu(it.id) }.help(itemHelp(it)).accessibilityAddTraits(.isButton).accessibilityAction { m.select(it.id) }
                    }
                case .overlay:
                    if let l = m.project.layers.first(where: { $0.id == it.id }) {
                        let rowH = geo.rowHeight(1, slot: m.slot(.v2, l.row))
                        VideoClipFace(media: l.media, sourceStart: l.sourceStart, duration: l.duration, w: r.w, h: rowH, pps: pps, selected: sel, hover: hov, editing: ed, linked: false, scaled: !l.transform.isIdentity)
                            .opacity(m.isOff(.v2) ? 0.35 : 1).offset(x: r.x, y: geo.rowTop(1, slot: m.slot(.v2, l.row))).contextMenu { menu(it.id) }.help(itemHelp(it)).accessibilityAddTraits(.isButton).accessibilityAction { m.select(it.id) }
                    }
                case .text:
                    if let t = m.project.texts.first(where: { $0.id == it.id }) {
                        TitleFace(text: t.text, w: r.w, h: geo.t / CGFloat(max(1, geo.nT)), selected: sel, hover: hov, editing: ed, animated: t.endTransform != nil)
                            .opacity(m.isOff(.t) ? 0.35 : 1).offset(x: r.x, y: geo.y(0) + CGFloat(it.row) * geo.t / CGFloat(max(1, geo.nT))).contextMenu { menu(it.id) }.help(itemHelp(it)).accessibilityAddTraits(.isButton).accessibilityAction { m.select(it.id) }
                    }
                case .callout:
                    if !it.attached, let c = m.project.callouts.first(where: { $0.id == it.id }) {
                        CalloutFace(w: r.w, h: geo.c / CGFloat(max(1, geo.nC)), selected: sel, hover: hov, editing: ed, dim: c.dim, blur: c.blur)
                            .opacity(m.isOff(.c) ? 0.35 : 1).offset(x: r.x, y: geo.y(5) + CGFloat(it.row) * geo.c / CGFloat(max(1, geo.nC))).contextMenu { menu(it.id) }.help(itemHelp(it)).accessibilityAddTraits(.isButton).accessibilityAction { m.select(it.id) }
                    }
                case .audio:
                    if let l = m.project.layers.first(where: { $0.id == it.id }) {
                        let ae = m.audioEdit(l.id), fd = ae.effectiveFades(duration: l.duration)
                        let rowA = geo.rowHeight(4, slot: l.row)
                        AudioClipFace(peaks: m.media[l.media]?.peaks ?? [], from: l.sourceStart, to: l.sourceStart + l.duration, w: r.w, h: rowA, selected: sel, hover: hov, editing: ed,
                                      label: (l.linkedClip != nil ? "⇄ " : "") + (ae.muted ? "mut · " : "") + (l.label ?? URL(fileURLWithPath: l.media).lastPathComponent) + (ae.gainDB != 0 ? String(format: "  %+.1f dB", ae.gainDB) : ""),
                                      fadeIn: CGFloat(fd.fadeIn) * pps, fadeOut: CGFloat(fd.fadeOut) * pps, dim: ae.muted)
                            .overlay(alignment: .topLeading) { if sel || hov || m.liveAudio[l.id] != nil { FadeHandles(m: m, id: l.id, duration: l.duration, pps: pps, width: max(2, r.w - 1)) } }
                            .opacity(m.isOff(.a2) ? 0.35 : 1).offset(x: r.x, y: geo.rowTop(4, slot: l.row)).contextMenu { menu(it.id) }.help(itemHelp(it)).accessibilityAddTraits(.isButton).accessibilityAction { m.select(it.id) }
                    }
                }
            }
            if let rp = m.rowPreview, m.project.layers.contains(where: { $0.id == rp.id }) {
                let isV = m.project.layers.first { $0.id == rp.id }?.kind == .video, li = isV ? 1 : 4
                let isNew = rp.row >= m.project.rowCount(isV ? .v2 : .a2)
                let sl = isNew ? (isV ? -1 : m.project.rowCount(.a2)) : (isV ? m.slot(.v2, rp.row) : rp.row), rh = isNew ? 24 : geo.rowHeight(li, slot: sl)
                let top = isNew ? (isV ? geo.y(li) - rh : geo.y(li) + geo.heights[li]) : geo.rowTop(li, slot: sl)
                RoundedRectangle(cornerRadius: 4).stroke(rp.free ? Theme.C.sel : Theme.C.warn, style: StrokeStyle(lineWidth: 2, dash: rp.free ? [] : [5, 3]))
                    .background((rp.free ? Theme.C.sel : Theme.C.warn).opacity(0.12)).frame(width: width, height: rh).offset(y: top).allowsHitTesting(false).zIndex(2)
                    .overlay(alignment: .leading) { if isNew { Text(T("Pistă nouă")).font(Theme.F.small).foregroundStyle(Theme.C.sel).padding(.leading, 8).allowsHitTesting(false) } }
            }
            // effects that belong to a clip or an overlay live INSIDE its tile: one band per effect over exactly its interval, stacked from the tile's bottom edge in start order
            ForEach(items.filter(\.attached), id: \.id) { it in
                if let c = m.project.callouts.first(where: { $0.id == it.id }), let b = bandRect(it, pps: pps, geo: geo) {
                    let strong = m.isSelected(c.id) || hoverItem == c.id || m.isSelected(c.clipID ?? c.layerID ?? c.id)
                    CalloutFace(w: b.width, h: b.height, target: targetName(c), selected: m.isSelected(c.id), hover: hoverItem == c.id || strong, editing: false, dim: c.dim, blur: c.blur)
                        .opacity(m.isOff(.c) ? 0.35 : 1).offset(x: b.minX, y: b.minY).contextMenu { menu(c.id) }
                        .accessibilityElement().accessibilityLabel(T("Efect în clip")).accessibilityAddTraits(.isButton).accessibilityAction { m.select(c.id) }.zIndex(3)
                }
            }
            if let h = m.hoverCut, m.tool == .blade {
                Rectangle().fill(Theme.C.text.opacity(0.9)).frame(width: 1, height: geo.total - rulerH).offset(x: CGFloat(h) * pps, y: rulerH).allowsHitTesting(false)
                Image(systemName: "scissors").font(Theme.F.small).foregroundStyle(Theme.C.bg0).padding(3).background(Circle().fill(Theme.C.text)).offset(x: CGFloat(h) * pps - 10, y: rulerH - 14).allowsHitTesting(false)
            }
            if let tp = m.trimPreview, let it = item(tp.clip) {
                let r = rect(it, pps: pps); let ex = (tp.edge == .start ? r.x : r.x + r.w) + CGFloat(tp.delta) * pps
                Rectangle().fill(Theme.C.sel).frame(width: 2, height: geo.total - rulerH).offset(x: ex - 1, y: rulerH).allowsHitTesting(false)
                Text(String(format: "%+.2f s", tp.delta)).font(Theme.F.monoSmall).foregroundStyle(Theme.C.bg0).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.C.sel)).offset(x: ex + 6, y: rulerH + 4).allowsHitTesting(false)
            }
            if m.movePreview != nil, m.selectionHasMainClips, !m.groupMoving.isEmpty {       // mixed selection with V1 clips: where the block lands, or why it cannot
                if let pl = m.mixedPlan {
                    let w = m.project.clips.filter { m.selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.duration }
                    RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.C.sel, style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                        .frame(width: CGFloat(w) * pps, height: geo.v1).offset(x: CGFloat(pl.blockStart) * pps, y: geo.y(2)).allowsHitTesting(false)
                    Text(T("Aici ajunge blocul de clipuri")).font(Theme.F.smallMedium).foregroundStyle(Theme.C.bg0).padding(.horizontal, 5).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.C.sel)).offset(x: CGFloat(pl.blockStart) * pps + 4, y: geo.y(2) + 4).allowsHitTesting(false)
                } else if let r = m.mixedRefusal, !m.moveRefusalText(r).isEmpty {
                    Text(m.moveRefusalText(r)).font(Theme.F.smallMedium).foregroundStyle(Theme.C.bg0).padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.C.warn)).frame(maxWidth: 420, alignment: .leading).offset(x: CGFloat(m.time) * pps + 8, y: rulerH + 28).allowsHitTesting(false)
                }
            }
            if let mp = m.movePreview, abs(mp.delta) > 0.001 {
                Text(String(format: "%+.2f s", mp.delta)).font(Theme.F.monoSmall).foregroundStyle(Theme.C.bg0).padding(.horizontal, 5).padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.C.sel)).offset(x: CGFloat(m.time) * pps + 8, y: rulerH + 4).allowsHitTesting(false)
            }
            if let mq = marquee, hypot(mq.b.x - mq.a.x, mq.b.y - mq.a.y) >= 4 {
                let r = CGRect(x: min(mq.a.x, mq.b.x), y: min(mq.a.y, mq.b.y), width: abs(mq.b.x - mq.a.x), height: abs(mq.b.y - mq.a.y))
                Rectangle().fill(Theme.C.sel.opacity(0.14)).overlay(Rectangle().strokeBorder(Theme.C.sel, style: StrokeStyle(lineWidth: 1, dash: [4, 2])))
                    .frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY).allowsHitTesting(false).zIndex(8)
            }
            if let g = m.snapGuide {
                Rectangle().fill(Theme.C.sel).frame(width: 1.5, height: geo.total - rulerH).offset(x: CGFloat(g) * pps - 0.75, y: rulerH).allowsHitTesting(false)
                Text(T("Magnet")).font(Theme.F.smallMedium).foregroundStyle(Theme.C.bg0).padding(.horizontal, 4).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 3).fill(Theme.C.sel)).offset(x: CGFloat(g) * pps + 4, y: geo.total - 16).allowsHitTesting(false)
            }
            HStack(spacing: 0) { Color.clear.frame(width: max(0, CGFloat(m.time) * pps), height: 1); Color.clear.frame(width: 1, height: 1).id("playhead") }.allowsHitTesting(false)      // scroll target for the follow logic
            let px = CGFloat(m.time) * pps
            Rectangle().fill(Theme.C.playhead).frame(width: 1.5, height: geo.total).offset(x: px - 0.75).allowsHitTesting(false).zIndex(6)
            Triangle().fill(Theme.C.playhead).frame(width: 11, height: 8).offset(x: px - 5.5, y: vOff + rulerH - 9).allowsHitTesting(false).zIndex(7)
        }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let p):
                let inLane = laneHit(p.y, geo) != nil
                hoverItem = inLane ? itemAt(p, pps: pps, geo: geo)?.id : nil
                m.hoverCut = (m.tool == .blade && inLane) ? min(m.project.timelineEnd, max(0, Double(p.x / pps))) : nil
                if m.tool == .select, inLane, edge(at: p, pps: pps, geo: geo) != nil { NSCursor.resizeLeftRight.set() } else if m.tool == .blade, inLane { NSCursor.crosshair.set() } else { NSCursor.arrow.set() }
            case .ended: hoverItem = nil; m.hoverCut = nil; NSCursor.arrow.set()
            }
        }
        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { v in
                let inLane = laneHit(v.startLocation.y, geo) != nil
                if drag == nil {
                    EditCommand.endTextEditing()     // a click on the timeline leaves a text field (title…) so ⌘D/⌘C/⌘V reach the clips, not the field
                    if m.tool == .select, inLane, let e = edge(at: v.startLocation, pps: pps, geo: geo) { drag = .trim(e.id, e.edge, e.lane); m.select(e.id) }
                    else if m.tool == .blade && inLane { drag = Drag.blade }
                    else if m.tool == .select, inLane, let it = itemAt(v.startLocation, pps: pps, geo: geo) {
                        let mods = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags       // the flags of THIS click (hardware state can miss synthetic or very quick clicks)
                        if mods.contains(.shift) || mods.contains(.command) { m.toggleSelect(it.id); drag = Drag.none }   // ⇧/⌘-click: add to / remove from the selection, no drag
                        else { drag = .pending(it.id, it.lane); if !m.isSelected(it.id) || m.extra.isEmpty { m.select(it.id) } }
                    }
                    else if m.tool == .select, inLane { startMarquee(at: v.startLocation, pps: pps, geo: geo, width: width) }
                    else { drag = .scrub }
                }
                let raw = Double((v.location.x - v.startLocation.x) / pps)
                switch drag {
                case .scrub?: scrub(to: v.location.x, pps: pps)
                case .marquee?: updateMarquee(to: v.location, pps: pps, geo: geo)
                case .pending(let id, let lane)? where abs(v.location.x - v.startLocation.x) >= 4:
                    let grp = m.groupMoveIDs(primary: id)
                    if !grp.isEmpty && m.anyLocked(grp) { m.message = T("Nu se poate muta: o pistă a selecției este blocată."); drag = Drag.none; break }
                    drag = .move(id, lane); m.groupMoving = Set(grp)
                    if lane == .callout { m.effectDropTarget = effectTarget(at: v.location, pps: pps, geo: geo) }
                    let s = snappedMove(id, lane, raw, pps); m.movePreview = (id, grp.isEmpty ? s.dx : m.groupClamp(grp, s.dx)); m.snapGuide = s.guide
                    if grp.isEmpty { updateRowPreview(id, lane, dx: s.dx, y: v.location.y, geo: geo) }
                case .move(let id, let lane)?:
                    if lane == .callout { m.effectDropTarget = effectTarget(at: v.location, pps: pps, geo: geo) }
                    let s = snappedMove(id, lane, raw, pps); m.movePreview = (id, m.groupMoving.isEmpty ? s.dx : m.groupClamp(Array(m.groupMoving), s.dx)); m.snapGuide = s.guide
                    if m.groupMoving.isEmpty { updateRowPreview(id, lane, dx: s.dx, y: v.location.y, geo: geo) }
                case .trim(let id, let edge, _)?: let s = snappedTrim(id, edge, raw, pps); m.trimPreview = (id, edge, s.dx); m.snapGuide = s.guide
                default: break
                }
            }
            .onEnded { v in
                let raw = Double((v.location.x - v.startLocation.x) / pps)
                m.snapGuide = nil
                var dx = raw
                switch drag {
                case .trim(let id, let edge, _)?: dx = snappedTrim(id, edge, raw, pps).dx
                case .move(let id, let lane)?: dx = snappedMove(id, lane, raw, pps).dx
                default: break
                }
                switch drag {
                case .trim(let id, let edge, let lane)?:
                    m.trimPreview = nil
                    if abs(dx) > 0.02 { if lane == .main { m.trim(clip: id, edge: edge, by: dx) } else if lane == .text { m.trimTitle(id, edge: edge, by: dx) } else if lane == .callout { m.trimCallout(id, edge: edge, by: dx) } else { m.trimLayer(id, edge: edge, by: dx) } }
                case .move(let id, let lane)?:
                    m.movePreview = nil
                    if lane == .callout, let tgt = m.effectDropTarget {
                        m.effectDropTarget = nil; m.rowPreview = nil; m.groupMoving = []
                        if let c = m.project.callouts.first(where: { $0.id == id }), (c.clipID ?? c.layerID) == tgt, let it = item(id) { if abs(dx) > 0.02 { m.moveCallout(id, to: max(0, it.start + dx)) } }       // same target: a plain move by the drag distance
                        else { m.dropEffect(id, on: tgt, at: Double(v.location.x / pps)) }
                        drag = nil; return
                    }
                    m.effectDropTarget = nil
                    let grp = Array(m.groupMoving); m.groupMoving = []
                    let rp = m.rowPreview; m.rowPreview = nil
                    if grp.isEmpty, let rp, rp.id == id, let l = m.project.layers.first(where: { $0.id == id }), rp.row != l.row {
                        if rp.free { m.placeLayer(id, start: max(0, l.start + dx), row: rp.row) } else { m.message = T("Nu se poate muta acolo: se suprapune cu alt element de pe pista aceea.") }
                    }
                    else if !grp.isEmpty { if abs(dx) > 0.02 { m.commitGroupMove(grp, dx: dx) } }
                    else if lane == .main && !m.extra.isEmpty { dropMainBlock(id, dx: dx) }
                    else if lane == .main { dropMain(id, dx: dx, pps: pps) } else if let it = item(id), abs(dx) > 0.02 { if lane == .text { m.moveTitle(id, to: max(0, it.start + dx)) } else if lane == .callout { m.moveCallout(id, to: max(0, it.start + dx)) } else { m.moveLayer(id, to: max(0, it.start + dx)) } }
                case .pending(let id, _)?: if !m.extra.isEmpty { m.select(id) }; m.seek(max(0, min(m.project.timelineEnd, Double(v.location.x / pps))))
                case .marquee?:
                    let moved = hypot(v.location.x - v.startLocation.x, v.location.y - v.startLocation.y) >= 4
                    if !moved && !marqueeCancelled { if marqueeBase.isEmpty { m.select(nil) }; m.seek(max(0, min(m.project.timelineEnd, Double(v.location.x / pps)))) }      // a click in free space empties the selection
                    endMarquee()
                case .blade?:
                    if abs(v.location.x - v.startLocation.x) < 4, let l = laneHit(v.startLocation.y, geo) { m.splitAt(min(m.project.timelineEnd, max(0, Double(v.location.x / pps))), lane: laneKind(l)) }
                default: break
                }
                m.rowPreview = nil
                drag = nil
            })
    }

    // MARK: rectangle selection
    /// Every rectangle an item occupies in the timeline (a main-track clip: its picture and its sound row).
    private func frames(_ it: Item, pps: CGFloat, geo: Geo) -> [CGRect] {
        let r = rect(it, pps: pps)
        switch it.lane {
        case .main: return [CGRect(x: r.x, y: geo.y(2), width: r.w, height: geo.v1), CGRect(x: r.x, y: geo.y(3), width: r.w, height: geo.a1)]
        case .overlay: let sl = m.slot(.v2, it.row); return [CGRect(x: r.x, y: geo.rowTop(1, slot: sl), width: r.w, height: geo.rowHeight(1, slot: sl))]
        case .audio: return [CGRect(x: r.x, y: geo.rowTop(4, slot: it.row), width: r.w, height: geo.rowHeight(4, slot: it.row))]
        case .text: let h = geo.t / CGFloat(max(1, geo.nT)); return [CGRect(x: r.x, y: geo.y(0) + CGFloat(it.row) * h, width: r.w, height: h)]
        case .callout:
            if it.attached { return bandRect(it, pps: pps, geo: geo).map { [$0] } ?? [] }
            let h = geo.c / CGFloat(max(1, geo.nC)); return [CGRect(x: r.x, y: geo.y(5) + CGFloat(it.row) * h, width: r.w, height: h)]
        }
    }
    private func marqueeHits(_ box: CGRect, pps: CGFloat, geo: Geo) -> [UUID] {
        items.filter { it in frames(it, pps: pps, geo: geo).contains { $0.width >= 0 && $0.intersects(box) } }.map(\.id)
    }
    private func startMarquee(at p: CGPoint, pps: CGFloat, geo: Geo, width: CGFloat) {
        let mods = NSApp.currentEvent?.modifierFlags ?? NSEvent.modifierFlags
        marqueeBase = (mods.contains(.shift) || mods.contains(.command)) ? m.selectedIDs : []
        marquee = (p, p); marqueeCancelled = false; drag = .marquee
        marqueeKeys = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            if e.keyCode == 53, marquee != nil {          // Esc: cancel the gesture, restore the selection it started from
                marqueeCancelled = true; m.setSelection(marqueeBase); marquee = nil; return nil
            }
            return e
        }
        marqueeTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { _ in
            Task { @MainActor in autoscrollMarquee(pps: pps, geo: geo, width: width) }
        }
    }
    private func updateMarquee(to p: CGPoint, pps: CGFloat, geo: Geo) {
        guard !marqueeCancelled, let a = marquee?.a else { return }
        marquee = (a, p); marqueeScreen = CGPoint(x: p.x - scrollOffset, y: p.y - vOff)
        applyMarquee(pps: pps, geo: geo)
    }
    private func applyMarquee(pps: CGFloat, geo: Geo) {
        guard let mq = marquee, hypot(mq.b.x - mq.a.x, mq.b.y - mq.a.y) >= 4 else { return }
        let box = CGRect(x: min(mq.a.x, mq.b.x), y: min(mq.a.y, mq.b.y), width: abs(mq.b.x - mq.a.x), height: abs(mq.b.y - mq.a.y))
        let hits = marqueeHits(box, pps: pps, geo: geo)
        var ids = marqueeBase; for h in hits where !ids.contains(h) { ids.append(h) }
        if ids != m.selectedIDs { m.setSelection(ids) }
    }
    /// Near the edge of the visible area the timeline scrolls (sideways and up/down) while the rectangle keeps growing under the stationary pointer.
    private func autoscrollMarquee(pps: CGFloat, geo: Geo, width: CGFloat) {
        guard let mq = marquee, !marqueeCancelled else { return }
        let viewW = width / CGFloat(max(1, m.zoom)), edge: CGFloat = 28
        var dx: CGFloat = 0, dy: CGFloat = 0
        if marqueeScreen.x < edge { dx = -max(4, (edge - marqueeScreen.x) / 2) } else if marqueeScreen.x > viewW - edge { dx = max(4, (marqueeScreen.x - (viewW - edge)) / 2) }
        if marqueeScreen.y < rulerH + edge { dy = -max(4, (rulerH + edge - marqueeScreen.y) / 2) } else if marqueeScreen.y > viewportH - edge { dy = max(4, (marqueeScreen.y - (viewportH - edge)) / 2) }
        if m.zoom <= 1.01 { dx = 0 }
        if dy != 0 && geo.total <= viewportH { dy = 0 }
        guard dx != 0 || dy != 0 else { return }
        let nx = max(0, min(max(0, width - viewW), scrollOffset + dx)), ny = max(0, min(max(0, geo.total - viewportH), vOff + dy))
        let rdx = nx - scrollOffset, rdy = ny - vOff
        if rdx != 0 { hPos.scrollTo(x: nx); scrollOffset = nx }
        if rdy != 0 { vPos.scrollTo(y: ny); vOff = ny }
        marquee = (mq.a, CGPoint(x: marqueeScreen.x + scrollOffset, y: marqueeScreen.y + vOff))
        applyMarquee(pps: pps, geo: geo)
    }
    private func endMarquee() {
        marqueeTimer?.invalidate(); marqueeTimer = nil
        if let k = marqueeKeys { NSEvent.removeMonitor(k); marqueeKeys = nil }
        marquee = nil; marqueeBase = []; marqueeCancelled = false
    }

    /// Reorders a main-track clip: it lands before/after the neighbours its centre has crossed.
    /// A dragged main-track clip that belongs to a selection of main-track clips only: the whole block moves by the number of positions the dragged clip crosses.
    private func dropMainBlock(_ id: UUID, dx: Double) {
        guard abs(dx) > 0.05, let i = m.project.clips.firstIndex(where: { $0.id == id }), let it = item(id) else { return }
        let centre = it.start + it.dur / 2 + dx; var j = 0
        for (k, sp) in m.project.clipSpans.enumerated() where centre >= (sp.start + sp.end) / 2 { j = k }
        if j != i { m.commitBlockMove(by: j - i) }
    }
    private func dropMain(_ id: UUID, dx: Double, pps: CGFloat) {
        guard abs(dx) > 0.05, let i = m.project.clips.firstIndex(where: { $0.id == id }) else { return }
        let it = item(id)!; let centre = it.start + it.dur / 2 + dx
        var idx = 0
        for sp in m.project.clipSpans where sp.id != id { if (sp.start + sp.end) / 2 < centre { idx += 1 } }
        if idx != i { m.moveMain(id, by: idx - i) }
    }

    @ViewBuilder private func menu(_ id: UUID) -> some View {
        Button(T("Copiază")) { if !m.isSelected(id) { m.select(id) }; m.copySelection() }
        Button(T("Taie")) { if !m.isSelected(id) { m.select(id) }; m.cutSelection() }
        Button(T("Lipește")) { m.pasteClipboard() }.disabled(!m.canPaste)
        Button(T("Duplică")) { if !m.isSelected(id) { m.select(id) }; m.duplicateSelection() }
        if item(id)?.lane == .main || item(id)?.lane == .overlay || item(id)?.lane == .audio { Button(T("Redenumește…")) { m.select(id); m.promptRename() } }
        Divider()
        Button(T("Taie la cursor")) { m.select(id); m.split() }
        if m.selectedIDs.count > 1 { Button(T("Taie elementele selectate la cursor")) { m.splitSelected() } }
        if item(id)?.lane == .main {
            Button(T("Început = cursor")) { m.select(id); m.trimStartToPlayhead() }
            Button(T("Sfârșit = cursor")) { m.select(id); m.trimEndToPlayhead() }
            Button(T("Mută pe pistă video (V2)")) { m.moveToOverlay(id) }.disabled(!m.canMoveToOverlay(id))
        }
        if m.canDetachAudio(id) || m.canReattachAudio(id) || m.hasLinkedPart(id) {
            Divider()
            if m.canDetachAudio(id) { Button(T("Detașează sunetul")) { m.detachAudio(id) } }
            if m.canReattachAudio(id) { Button(T("Reatașează sunetul")) { m.reattachAudio(id) } }
            if m.hasLinkedPart(id) { Button(item(id)?.lane == .main ? T("Selectează doar sunetul detașat") : T("Selectează imaginea legată")) { m.selectLinkedPart(of: id) } }
        }
        if let l = m.project.layers.first(where: { $0.id == id }) {
            Divider()
            if l.kind == .video {
                Button(T("Mută pe pista de deasupra (în față)")) { m.moveLayerRow(id, by: 1) }
                Button(T("Mută pe pista de dedesubt")) { m.moveLayerRow(id, by: -1) }.disabled(l.row == 0)
            } else {
                Button(T("Mută pe pista de deasupra")) { m.moveLayerRow(id, by: -1) }.disabled(l.row == 0)
                Button(T("Mută pe pista de dedesubt")) { m.moveLayerRow(id, by: 1) }
            }
        }
        Divider()
        Button(T("Șterge"), role: .destructive) { m.select(id); m.deleteSelected() }
    }

    private func scrub(to x: CGFloat, pps: CGFloat) {
        var t = max(0, min(m.project.timelineEnd, Double(x / pps)))
        if m.snapOn { let s = Snapping.snap(t, to: Snapping.points(of: m.project, playhead: -1), threshold: 8 / Double(pps)); t = s.value; m.snapGuide = s.point } else { m.snapGuide = nil }
        m.seek(t)
    }
    /// Layer moves snap by either edge; main-track clips reorder by index, so they have nothing to snap to.
    private func snappedMove(_ id: UUID, _ lane: Lane, _ dx: Double, _ pps: CGFloat) -> (dx: Double, guide: Double?) {
        guard m.snapOn, lane != .main, let it = item(id) else { return (dx, nil) }
        let s = Snapping.snapBlock(start: max(0, it.start + dx), duration: it.dur, to: Snapping.points(of: m.project, playhead: m.time, excluding: id), threshold: 8 / Double(pps))
        return (s.start - it.start, s.point)
    }
    private func snappedTrim(_ id: UUID, _ edge: ClipEdge, _ dx: Double, _ pps: CGFloat) -> (dx: Double, guide: Double?) {
        guard m.snapOn, let it = item(id) else { return (dx, nil) }
        let base = edge == .start ? it.start : it.start + it.dur
        let s = Snapping.snap(base + dx, to: Snapping.points(of: m.project, playhead: m.time, excluding: id), threshold: 8 / Double(pps))
        return (s.value - base, s.point)
    }
    /// While a V2/A2 item is dragged: the track under the pointer and whether the item fits there (nothing overlapping). Outside the item's own lane the row is kept.
    private func updateRowPreview(_ id: UUID, _ lane: Lane, dx: Double, y: CGFloat, geo: Geo) {
        guard lane == .overlay || lane == .audio, let l = m.project.layers.first(where: { $0.id == id }) else { m.rowPreview = nil; return }
        let li = lane == .overlay ? 1 : 4
        let inLane = y >= geo.y(li) && y < geo.y(li) + geo.heights[li]
        // past the outer edge of the lane (above V2, below A2): a NEW track at the end of the stack; the preview band says so
        let beyond = lane == .overlay ? y < geo.y(li) - 6 : y > geo.y(li) + geo.heights[li] + 6
        let row = beyond ? m.project.rowCount(lane == .overlay ? .v2 : .a2) : (inLane ? (rowAt(lane, li, y, geo) ?? 0) : l.row)
        var probe = l; probe.start = max(0, l.start + dx); probe.track = row == 0 ? nil : row
        let free = !m.project.layers.contains { $0.id != id && $0.kind == l.kind && $0.row == row && $0.start < probe.end - 1e-6 && probe.start < $0.end - 1e-6 }
        m.rowPreview = (id, row, free)
    }
    /// The data row under y for a multi-row lane (nil for single-row lanes, which match by time only).
    private func rowAt(_ kind: Lane, _ l: Int, _ y: CGFloat, _ geo: Geo) -> Int? {
        guard geo.rows(l) > 1 else { return nil }
        let s = geo.slot(l, at: y)
        return kind == .overlay ? geo.rows(l) - 1 - s : s
    }
    /// The clip or overlay under the pointer while an effect is dragged (V1 / V2 only).
    private func effectTarget(at p: CGPoint, pps: CGFloat, geo: Geo) -> UUID? {
        guard let l = geo.lane(at: p.y), l == 1 || l == 2, let it = itemAt(p, pps: pps, geo: geo) else { return nil }
        let isVideoOverlay = it.lane == .overlay; return it.lane == .main || isVideoOverlay ? it.id : nil
    }
    /// Band of an attached effect inside the tile of its clip / overlay (nil when its target is gone).
    static let bandRowH: CGFloat = 18, tileHeader: CGFloat = 17, tileMinPicture: CGFloat = 10
    /// Tile height that keeps the name strip, a sliver of picture and `rows` full bands.
    static func tileNeed(_ rows: Int) -> CGFloat { rows == 0 ? 0 : tileHeader + tileMinPicture + CGFloat(rows) * bandRowH }
    private func bandRect(_ it: Item, pps: CGFloat, geo: Geo) -> CGRect? {
        guard it.attached, let c = m.project.callouts.first(where: { $0.id == it.id }) else { return nil }
        let r = rect(it, pps: pps); var bottom: CGFloat
        if let cid = c.clipID, m.project.clipSpans.contains(where: { $0.id == cid }) { bottom = geo.y(2) + geo.v1 }
        else if let lid = c.layerID, let l = m.project.layers.first(where: { $0.id == lid }) { let sl = m.slot(.v2, l.row); bottom = geo.rowTop(1, slot: sl) + geo.rowHeight(1, slot: sl) }
        else { return nil }
        return CGRect(x: r.x, y: bottom - Self.bandRowH * CGFloat(it.row + 1) - 1, width: max(4, r.w), height: Self.bandRowH - 2)
    }
    private func targetName(_ c: Callout) -> String {
        if let id = c.clipID, let cl = m.project.clips.first(where: { $0.id == id }) { return URL(fileURLWithPath: cl.media).deletingPathExtension().lastPathComponent }
        if let id = c.layerID, let l = m.project.layers.first(where: { $0.id == id }) { return l.label ?? URL(fileURLWithPath: l.media).deletingPathExtension().lastPathComponent }
        return ""
    }
    private func bandHit(_ p: CGPoint, pps: CGFloat, geo: Geo, slop: CGFloat = 0) -> (item: Item, rect: CGRect)? {
        for it in items.reversed() where it.attached { if let b = bandRect(it, pps: pps, geo: geo), b.insetBy(dx: -slop, dy: 0).contains(p) { return (it, b) } }
        return nil
    }
    private func itemAt(_ p: CGPoint, pps: CGFloat, geo: Geo) -> (id: UUID, lane: Lane)? {
        if let b = bandHit(p, pps: pps, geo: geo) { return (b.item.id, .callout) }
        guard let l = geo.lane(at: p.y) else { return nil }; let kind = laneKind(l); let t = Double(p.x / pps)
        let want = rowAt(kind, l, p.y, geo)
        return items.last { $0.lane == kind && !$0.attached && (want == nil || $0.row == want) && t >= $0.start && t < $0.start + $0.dur }.map { ($0.id, $0.lane) }
    }
    /// Nearest item edge in the lane under the pointer. At a shared boundary the pointer side decides which edge it is.
    private func edge(at p: CGPoint, pps: CGFloat, geo: Geo) -> (id: UUID, edge: ClipEdge, lane: Lane)? {
        if let b = bandHit(p, pps: pps, geo: geo, slop: edgeHit) {
            let dS = abs(p.x - b.rect.minX), dE = abs(p.x - b.rect.maxX)
            if min(dS, dE) <= edgeHit { return (b.item.id, dS <= dE ? .start : .end, .callout) }
            return nil
        }
        guard let l = geo.lane(at: p.y) else { return nil }; let kind = laneKind(l)
        var best: (d: CGFloat, id: UUID, e: ClipEdge)?
        let want = rowAt(kind, l, p.y, geo)
        for it in items where it.lane == kind && !it.attached && (want == nil || it.row == want) {
            let r = rect(it, pps: pps)
            for (x, e) in [(r.x, ClipEdge.start), (r.x + r.w, ClipEdge.end)] {
                var d = abs(p.x - x)
                if d <= edgeHit { if d == 0 { d = 0.001 }; let prefer = (p.x < x && e == .end) || (p.x >= x && e == .start); if !prefer { d += 0.5 }; if best == nil || d < best!.d { best = (d, it.id, e) } }
            }
        }
        return best.map { ($0.id, $0.e, kind) }
    }
}

// MARK: clip tiles
/// Clip chrome shared by the timeline and the component board: header band with the name, thumbnails, controlled outline, selection + edge handles.
struct ClipOutline: ViewModifier {
    var radius: CGFloat = 5
    let selected: Bool, hover: Bool, editing: Bool
    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content.clipShape(shape)
            .overlay(shape.strokeBorder(Color.black.opacity(selected ? 0 : 0.55), lineWidth: 1))
            .overlay { if !selected { shape.inset(by: 1).strokeBorder(LinearGradient(colors: [.white.opacity(hover ? 0.34 : 0.13), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.4)), lineWidth: 1) } }
            .overlay { if hover && !selected { shape.strokeBorder(Color.white.opacity(0.5), lineWidth: 1) } }
            .overlay { if selected || editing { shape.strokeBorder(Theme.C.sel, lineWidth: 2) } }
    }
}
extension View { func clipOutline(selected: Bool, hover: Bool, editing: Bool) -> some View { modifier(ClipOutline(selected: selected, hover: hover, editing: editing)) } }

struct VideoClipFace: View {
    let media: String, sourceStart: Double, duration: Double, w: CGFloat, h: CGFloat, pps: CGFloat
    var held = false
    let selected: Bool, hover: Bool, editing: Bool
    var linked = true; var scaled = false; var title: String? = nil
    private let head: CGFloat = 18
    var body: some View {
        let name = title ?? URL(fileURLWithPath: media).lastPathComponent
        ZStack(alignment: .topLeading) {
            Theme.C.clipVideo
            ThumbStrip(media: media, sourceStart: sourceStart, duration: duration, pps: pps, height: h - head, held: held).offset(y: head)
            HStack(spacing: 4) {
                Text(name).font(Theme.F.smallMedium).lineLimit(1)
                if linked { Image(systemName: "link").font(Theme.F.iconSmall).opacity(0.75) }
                if scaled { Image(systemName: "arrow.up.left.and.arrow.down.right").font(Theme.F.iconSmall).opacity(0.75) }
            }.foregroundStyle(.white).padding(.horizontal, 7).frame(width: max(2, w - 1), height: head, alignment: .leading)
                .background(Color.black.opacity(0.22)).overlay(alignment: .bottom) { Rectangle().fill(Color.black.opacity(0.45)).frame(height: 1) }
        }
        .frame(width: max(2, w - 1), height: h, alignment: .topLeading)
        .clipOutline(selected: selected, hover: hover, editing: editing)
        .overlay(alignment: .leading) { if selected || editing { Grip(editing: editing).padding(.leading, 2) } }
        .overlay(alignment: .trailing) { if selected || editing { Grip(editing: editing).padding(.trailing, 2) } }
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.f("Clip video %@", "\(name)")).accessibilityValue(editing ? T("în editare") : (selected ? T("selectat") : ""))
    }
}
struct TitleFace: View {
    let text: String, w: CGFloat, h: CGFloat, selected: Bool, hover: Bool, editing: Bool, animated: Bool
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "textformat").font(Theme.F.iconSmall)
            Text(text).font(Theme.F.smallMedium).lineLimit(1)
            if animated { Image(systemName: "arrow.up.right").font(Theme.F.iconSmall).opacity(0.75) }
        }.foregroundStyle(.white).padding(.horizontal, 7).frame(width: max(2, w - 1), height: h, alignment: .leading).background(Theme.C.clipTitle)
            .clipOutline(selected: selected, hover: hover, editing: editing)
            .overlay(alignment: .leading) { if selected || editing { Grip(editing: editing).padding(.leading, 2) } }
            .overlay(alignment: .trailing) { if selected || editing { Grip(editing: editing).padding(.trailing, 2) } }
            .accessibilityElement(children: .ignore).accessibilityLabel("Titlu \(text)").accessibilityValue(editing ? T("în editare") : (selected ? "selectat" : ""))
    }
}
struct CalloutFace: View {
    let w: CGFloat, h: CGFloat, selected: Bool, hover: Bool, editing: Bool, dim: Double, blur: Double
    var target = ""
    init(w: CGFloat, h: CGFloat, target: String = "", selected: Bool, hover: Bool, editing: Bool, dim: Double, blur: Double) { self.w = w; self.h = h; self.target = target; self.selected = selected; self.hover = hover; self.editing = editing; self.dim = dim; self.blur = blur }
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "viewfinder").font(Theme.F.iconSmall)
            if w > 44 { Text(target.isEmpty ? T("Evidențiere") : T("Evidențiere") + " · " + target).font(Theme.F.smallMedium).lineLimit(1).truncationMode(.tail) }
        }.foregroundStyle(.white).padding(.horizontal, 7).frame(width: max(2, w - 1), height: h, alignment: .leading).background(Theme.C.clipCallout)
            .clipOutline(selected: selected, hover: hover, editing: editing)
            .overlay(alignment: .leading) { if selected || editing { Grip(editing: editing).padding(.leading, 2) } }
            .overlay(alignment: .trailing) { if selected || editing { Grip(editing: editing).padding(.trailing, 2) } }
            .accessibilityElement(children: .ignore).accessibilityLabel(T("Evidențiere")).accessibilityValue(editing ? T("în editare") : (selected ? "selectat" : ""))
    }
}
struct Grip: View {
    var editing = false
    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 2.5)
        shape.fill(editing ? Color.white : Theme.C.sel).frame(width: editing ? 8 : 6, height: editing ? 30 : 24)
            .overlay(shape.strokeBorder(Theme.C.sel, lineWidth: editing ? 1.5 : 0))
            .overlay(Rectangle().fill(Theme.C.bg0.opacity(editing ? 0.8 : 0.55)).frame(width: 1, height: editing ? 16 : 12))
            .shadow(color: editing ? Theme.C.sel.opacity(0.55) : .black.opacity(0.35), radius: editing ? 4 : 1.5)
    }
}

struct ThumbStrip: View {
    let media: String, sourceStart: Double, duration: Double, pps: CGFloat, height: CGFloat
    var held = false
    var body: some View {
        let tileW = height * 16 / 9; let n = max(1, Int((CGFloat(duration) * pps / tileW).rounded(.up)))
        HStack(spacing: 0) {
            ForEach(0..<n, id: \.self) { i in
                ThumbTile(media: media, t: held ? sourceStart : sourceStart + (Double(i) + 0.5) * Double(tileW / pps)).frame(width: tileW, height: height)
            }
        }.frame(width: CGFloat(n) * tileW, height: height, alignment: .leading)
    }
}
struct ThumbTile: View {
    let media: String, t: Double
    @State private var img: NSImage?
    var body: some View {
        Group { if let img { Image(nsImage: img).resizable().scaledToFill() } else { Color.black.opacity(0.25) } }.clipped()
            .task(id: "\(media)@\((t * 2).rounded())") { img = await ThumbCache.shared.image(media: media, at: t) }
    }
}

/// Direct fade handles on an audio clip (A1 clip or A2 item): two small squares on the top edge at the fade lengths, shown on hover/selection.
/// Dragging edits the SAME AudioEdit as the inspector (live preview, one undo step on release); limits: 0 … duration − the other fade.
struct FadeHandles: View {
    @ObservedObject var m: EditorModel
    let id: UUID, duration: Double, pps: CGFloat, width: CGFloat
    @State private var start: AudioEdit?
    var body: some View {
        let e = m.audioEdit(id), f = e.effectiveFades(duration: duration)
        ZStack(alignment: .topLeading) {
            handle(x: CGFloat(f.fadeIn) * pps, help: "Fade-in: trage spre dreapta", isIn: true)
            handle(x: width - CGFloat(f.fadeOut) * pps, help: T("Fade-out: trage spre stânga"), isIn: false)
        }.frame(width: width, alignment: .topLeading)
    }
    private func handle(x: CGFloat, help: String, isIn: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5).fill(Theme.C.text).frame(width: 7, height: 7).overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Theme.C.bg0, lineWidth: 1))
            .frame(width: 18, height: 16).contentShape(Rectangle())             // comfortable hit area around a fine mark
            .offset(x: max(-4, min(width - 14, x - 9)), y: -3)
            .highPriorityGesture(DragGesture(minimumDistance: 1).onChanged { v in
                let b = start ?? m.audioEdit(id); start = b
                var n = b; let dt = Double(v.translation.width / pps)
                if !isIn { n.fadeOut = max(0, min(duration - b.fadeIn, ((b.fadeOut - dt) * 100).rounded() / 100)) }
                if isIn { n.fadeIn = max(0, min(duration - b.fadeOut, ((b.fadeIn + dt) * 100).rounded() / 100)) }
                m.liveAudioEdit(id, n)
            }.onEnded { _ in start = nil; m.commitAudio(id) })
            .onHover { if $0 { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .help(help).accessibilityLabel(isIn ? T("Mâner fade-in") : T("Mâner fade-out"))
    }
}

/// Fade ramps drawn over an audio clip: darkened corner triangles with a light edge, `fadeIn`/`fadeOut` in points.
struct FadeOverlay: View {
    let fadeIn: CGFloat, fadeOut: CGFloat
    var body: some View {
        GeometryReader { g in
            let W = g.size.width, H = g.size.height
            if fadeIn > 0.5 {
                Path { p in p.move(to: .init(x: 0, y: 0)); p.addLine(to: .init(x: min(fadeIn, W), y: 0)); p.addLine(to: .init(x: 0, y: H)); p.closeSubpath() }.fill(.black.opacity(0.38))
                Path { p in p.move(to: .init(x: 0, y: H)); p.addLine(to: .init(x: min(fadeIn, W), y: 0)) }.stroke(Theme.C.text.opacity(0.85), lineWidth: 1)
            }
            if fadeOut > 0.5 {
                Path { p in p.move(to: .init(x: W, y: 0)); p.addLine(to: .init(x: max(0, W - fadeOut), y: 0)); p.addLine(to: .init(x: W, y: H)); p.closeSubpath() }.fill(.black.opacity(0.38))
                Path { p in p.move(to: .init(x: max(0, W - fadeOut), y: 0)); p.addLine(to: .init(x: W, y: H)) }.stroke(Theme.C.text.opacity(0.85), lineWidth: 1)
            }
        }.allowsHitTesting(false)
    }
}

struct AudioClipFace: View {
    let peaks: [Float], from: Double, to: Double, w: CGFloat, h: CGFloat, selected: Bool, hover: Bool, editing: Bool
    var label: String? = nil
    var fadeIn: CGFloat = 0, fadeOut: CGFloat = 0, dim = false
    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.C.clipAudio
            Rectangle().fill(Theme.C.wave.opacity(0.28)).frame(height: 1)
            WaveShape(peaks: peaks, from: from, to: to, perSecond: 20).fill(Theme.C.wave).padding(.vertical, 5).opacity(dim ? 0.3 : 1)
            FadeOverlay(fadeIn: fadeIn, fadeOut: fadeOut)
            if let label { Text(label).font(Theme.F.smallMedium).foregroundStyle(.white).lineLimit(1).padding(.horizontal, 6).padding(.top, 2).frame(width: max(2, w - 1), alignment: .leading) }
        }
        .frame(width: max(2, w - 1), height: h).clipOutline(selected: selected, hover: hover, editing: editing)
        .accessibilityElement(children: .ignore).accessibilityLabel(label == nil ? T("Clip audio") : T("Sunet separat")).accessibilityValue(selected ? T("selectat") : "")
    }
}

/// The linked sound of a main clip when the recording has several sources: ONE clip (one outline, one selection — the sources move and trim together
/// with the picture), split into one waveform row per source; a muted source is dimmed and crossed by a flat line.
struct MultiAudioClipFace: View {
    let rows: [(peaks: [Float], muted: Bool)]; let from: Double, to: Double, w: CGFloat, h: CGFloat, selected: Bool, hover: Bool, editing: Bool
    var fadeIn: CGFloat = 0, fadeOut: CGFloat = 0
    var body: some View {
        let rh = h / CGFloat(max(1, rows.count))
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { k in
                ZStack {
                    Theme.C.clipAudio
                    WaveShape(peaks: rows[k].peaks, from: from, to: to, perSecond: 20).fill(Theme.C.wave).padding(.vertical, 3).opacity(rows[k].muted ? 0.25 : 1)
                    if rows[k].muted { Rectangle().fill(Theme.C.textFaint.opacity(0.6)).frame(height: 1) }
                }.frame(height: rh).overlay(alignment: .bottom) { if k < rows.count - 1 { Rectangle().fill(.black.opacity(0.35)).frame(height: 1) } }
            }
        }
        .overlay(FadeOverlay(fadeIn: fadeIn, fadeOut: fadeOut))
        .frame(width: max(2, w - 1), height: h).clipOutline(selected: selected, hover: hover, editing: editing)
        .accessibilityElement(children: .ignore).accessibilityLabel(L10n.f("Clip audio cu %@ surse", "\(rows.count)")).accessibilityValue(selected ? T("selectat") : "")
    }
}

struct WaveShape: Shape {
    let peaks: [Float]; let from: Double, to: Double; let perSecond: Double
    func path(in r: CGRect) -> Path {
        var p = Path(); guard !peaks.isEmpty, to > from else { return p }
        let cols = max(1, Int(r.width / 2)); 
        for c in 0..<cols {
            let t0 = from + (to - from) * Double(c) / Double(cols), t1 = from + (to - from) * Double(c + 1) / Double(cols)
            let i0 = max(0, Int(t0 * perSecond)), i1 = min(peaks.count - 1, max(i0, Int(t1 * perSecond)))
            guard i0 < peaks.count else { break }
            let v = CGFloat(peaks[i0...i1].max() ?? 0); let hh = max(1, v * r.height)
            p.addRoundedRect(in: CGRect(x: r.minX + CGFloat(c) * 2, y: r.midY - hh / 2, width: 1.4, height: hh), cornerSize: CGSize(width: 0.7, height: 0.7))
        }
        return p
    }
}

struct Ruler: View {
    let total: Double, pps: CGFloat
    var rangeIn: Double? = nil, rangeOut: Double? = nil
    /// Height of the strip under the time labels reserved for markers: labels and markers never share a band.
    var markerLane: CGFloat = 0
    var body: some View {
        Canvas { ctx, size0 in
            let size = CGSize(width: size0.width, height: size0.height - markerLane)
            if markerLane > 0 {
                ctx.fill(Path(CGRect(x: 0, y: size.height, width: size0.width, height: markerLane)), with: .color(Theme.C.bg0.opacity(0.55)))
                ctx.fill(Path(CGRect(x: 0, y: size.height, width: size0.width, height: 1)), with: .color(Theme.C.line.opacity(0.5)))
            }
            if rangeIn != nil || rangeOut != nil {
                let a = CGFloat(rangeIn ?? 0) * pps, b = CGFloat(rangeOut ?? total) * pps, h = size0.height
                ctx.fill(Path(CGRect(x: a, y: 0, width: max(1, b - a), height: h)), with: .color(Theme.C.accent.opacity(0.16)))
                if rangeIn != nil { ctx.fill(Path(CGRect(x: a, y: 0, width: 2, height: h)), with: .color(Theme.C.accent)) }
                if rangeOut != nil { ctx.fill(Path(CGRect(x: b - 2, y: 0, width: 2, height: h)), with: .color(Theme.C.accent)) }
            }
            let majors: [(Double, Double)] = [(0.5, 0.1), (1, 0.2), (2, 0.5), (5, 1), (10, 2), (15, 5), (30, 5), (60, 10), (120, 30), (300, 60), (600, 120)]
            let (major, minor) = majors.first { CGFloat($0.0) * pps >= 84 } ?? majors.last!
            var t = 0.0
            while t <= total + 0.0001 {
                let x = CGFloat(t) * pps
                let isMajor = abs(t / major - (t / major).rounded()) < 0.0001
                ctx.fill(Path(CGRect(x: x, y: size.height - (isMajor ? 9 : 5), width: 1, height: isMajor ? 9 : 5)), with: .color(isMajor ? Theme.C.textDim : Theme.C.textFaint))
                if isMajor {
                    // t accumulates minor steps (1.9999…): round before formatting, or 2 s is labelled "00:01"
                    let tr = (t * 10).rounded() / 10, ts = Int(tr.rounded())
                    let s = major < 1 ? String(format: "%02d:%04.1f", Int(tr) / 60, tr.truncatingRemainder(dividingBy: 60)) : String(format: "%02d:%02d", ts / 60, ts % 60)
                    ctx.draw(Text(s).font(Theme.F.monoSmall).foregroundStyle(Theme.C.textDim), at: CGPoint(x: x + 4, y: 9), anchor: .leading)
                }
                t += minor
            }
        }.background(Theme.C.bg1).overlay(alignment: .bottom) { Rectangle().fill(Theme.C.line).frame(height: 1) }
    }
}

/// A timeline marker on the ruler: click goes there, double-click renames, the context menu renames or removes it.
struct MarkerFlag: View {
    @ObservedObject var m: EditorModel
    let marker: TimelineMarker
    /// Width available to the name before the next marker (it is cut with an ellipsis, never overlapped).
    var room: CGFloat = 0
    var body: some View {
        HStack(spacing: 3) {
            Triangle().rotation(.degrees(180)).fill(Theme.C.sel).frame(width: 10, height: 8)
            if room > 56, !marker.name.isEmpty { Text(marker.name).font(Theme.F.monoSmall).foregroundStyle(Theme.C.text.opacity(0.85)).lineLimit(1).truncationMode(.tail).frame(maxWidth: room, alignment: .leading) }
        }.contentShape(Rectangle().inset(by: -3))
            .onTapGesture { m.seek(marker.time) }
            .help(marker.name.isEmpty ? String(format: "%.1f s", marker.time) : marker.name).accessibilityLabel(marker.name.isEmpty ? T("Marcaj") : marker.name)
            .contextMenu {
                Button(T("Redenumește marcajul…")) { m.promptMarkerName(marker.id) }
                Button(T("Șterge marcajul"), role: .destructive) { m.removeMarker(marker.id) }
            }
    }
}

struct Triangle: Shape { func path(in r: CGRect) -> Path { var p = Path(); p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath(); return p } }

extension SadrogProject {
    func start(of c: Clip) -> Double { start(ofClip: c.id) ?? 0 }
}
