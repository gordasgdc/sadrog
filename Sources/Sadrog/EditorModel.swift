// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AVFoundation
import SadrogCore

enum ExportState: Equatable {
    case idle, running(Double), done(URL, Int64), failed(String), cancelled
}
enum ExportQuality: String, CaseIterable, Identifiable {
    case reencode = "Calitate maximă (re-codificare)", web1080 = "Web 1080p", compact720 = "Compact 720p", passthrough = "Rapid, fără re-codificare"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .reencode: return T("Calitate maximă (re-codificare)")
        case .web1080: return T("Web 1080p")
        case .compact720: return T("Compact 720p")
        case .passthrough: return T("Rapid, fără re-codificare")
        }
    }
    /// The long side the picture is limited to (never enlarged, aspect kept); nil = the document's own size.
    var longSideCap: Int? { self == .web1080 ? 1920 : (self == .compact720 ? 1280 : nil) }
    var preset: String { self == .web1080 ? AVAssetExportPreset1920x1080 : (self == .compact720 ? AVAssetExportPreset1280x720 : AVAssetExportPresetHighestQuality) }
    var isRapid: Bool { self == .passthrough }
    var mode: ExportMode { self == .passthrough ? .passthrough : .reencode(preset: preset) }
    var detail: String {
        switch self {
        case .reencode: return T("Compune din nou imaginea; mai lent, compatibil peste tot.")
        case .web1080: return T("Latura lungă cel mult 1920 px; fișier mai mic, potrivit pentru web.")
        case .compact720: return T("Latura lungă cel mult 1280 px; fișier mic pentru trimis sau previzualizat.")
        case .passthrough: return T("Copiază fluxurile existente; tăieturile urmează lista de editare.")
        }
    }
}
enum EditTool: Equatable { case select, blade, volume }
enum ClipEdge { case start, end }
struct MediaInfo {
    var duration: Double; var size: CGSize; var fps: Double; var peaks: [Float]; var poster: NSImage?; var hasVideo = true; var hasAudio = true
    var sources: [AudioSourceInfo] = []     // every audio track of the file, named from its sources.json
    var trackPeaks: [[Float]] = []          // per track, on one shared scale (a quiet track stays flat next to a loud one) — DISPLAY ONLY
    var sourcePeak: [Float] = []            // true sample peak of each track (linear, 1 = 0 dBFS), measured on the whole file; not affected by gains
}
enum DrawTool { case rect, ellipse, freehand, line, arrow, frame }
enum LibrarySort: CaseIterable { case added, name, duration }
enum LibraryFilter: CaseIterable { case all, video, audio, missing }
enum Lane { case text, overlay, main, audio, callout }     // T / V2 / V1(+linked sound) / independent audio
struct Picked { var id: UUID; var lane: Lane }

/// Lazy, cached thumbnails taken from the SOURCE media (so they stay valid across edits and zoom levels).
final class ThumbCache {
    static let shared = ThumbCache()
    private let cache = NSCache<NSString, NSImage>()
    private var gens: [String: AVAssetImageGenerator] = [:]
    func image(media: String, at t: Double) async -> NSImage? {
        let q = (t * 2).rounded() / 2            // half-second buckets
        let key = "\(media)@\(q)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let g: AVAssetImageGenerator = await MainActor.run {
            if let g = gens[media] { return g }
            let g = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: media)))
            g.maximumSize = CGSize(width: 320, height: 180); g.appliesPreferredTrackTransform = true
            g.requestedTimeToleranceBefore = CMTime(seconds: 0.15, preferredTimescale: 600); g.requestedTimeToleranceAfter = CMTime(seconds: 0.15, preferredTimescale: 600)
            gens[media] = g; return g
        }
        guard let r = try? await g.image(at: CMTime(seconds: q, preferredTimescale: 600)) else { return nil }
        let img = NSImage(cgImage: r.image, size: .zero); cache.setObject(img, forKey: key); return img
    }
}

@MainActor
final class EditorModel: ObservableObject {
    let folder: URL
    private let editor: ProjectEditor
    @Published var project: SadrogProject
    @Published var selection: UUID? { didSet { if oldValue != selection { editingEnd = false; editingKey = nil; if focusedSource != nil, !project.clips.contains(where: { $0.id == selection }) { focusedSource = nil } } } }
    /// The recorded sound (audio track index of the main recording) the inspector is focused on; set by choosing it in the A1 header. Selection only: nothing in the project changes.
    @Published var focusedSource: Int?
    func focusSource(_ k: Int) {
        if selectedClip == nil, let id = project.clipID(at: time) ?? project.clips.first?.id { selection = id }
        focusedSource = focusedSource == k ? nil : k
    }
    @Published var editingKey: Int?              // animation: index of the keyframe the Inspector edits (nil = the start/end states)
    @Published var extra: Set<UUID> = []         // further selected items (⇧/⌘-click); `selection` stays the one the Inspector edits
    @Published var editingEnd = false            // animation: which state the Inspector and the viewer frame edit (UI state, not in the project)
    @Published var movePreview: (id: UUID, delta: Double)?
    @Published var groupMoving: Set<UUID> = []
    @Published var mixedPlan: ProjectEditor.MixedPlan?        // while dragging a selection that includes V1 clips: where the block will land
    @Published var mixedRefusal: GroupMove.Reason?
    /// Crop handles are shown on the selected picture in the viewer (off whenever the selection changes).
    /// „Încadrează imaginea în cerc”: the circle is fixed and the whole camera rectangle is shown (faded outside the circle) — editor preview only.
    @Published var circleFraming = false
    var framingStart: CircleCrop?
    @Published var cropEditing = false      // items that follow the dragged one (multiple selection); empty = single drag
    private var built: BuiltComposition?
    @Published var time = 0.0
    @Published var message = ""
    /// Drag-and-drop state: files being dragged out of the library, and the live hover over the timeline.
    @Published var libraryDrag: [String] = []
    @Published var dropHover: DropHover?
    /// While an effect block is dragged over a clip/overlay: the item it would act on (highlighted); dropping retargets the effect.
    @Published var effectDropTarget: UUID?
    @Published var playing = false
    @Published var missing: [String] = []
    @Published var media: [String: MediaInfo] = [:]
    @Published var tool = EditTool.select
    /// Timeline follows the playhead while playing. Switched off by a manual scroll during playback (or by the user); the button in the timeline bar brings it back.
    @Published var followPlayhead = true
    /// True while any text field/view of the app is being edited: the editor's single-key and ⌘Z shortcuts are then switched off, so typing
    /// (⌫, Space, arrows, letters, Esc, ⌘Z) goes to the field and can never delete or move clips. Set by `TextFocusWatcher` from the window's
    /// first responder (focus), so it is already true before the first keystroke.
    @Published var textEditing = false
    /// Selection-drawing tool for callouts: while set, a drag in the viewer DRAWS a selection; while nil, handles move/resize the existing one.
    @Published var drawTool: DrawTool?
    /// Multiplier on the automatic lane heights (⌃⌥= / ⌃⌥−); remembered between launches.
    @Published var trackScale: Double = { let v = UserDefaults.standard.double(forKey: "timeline.trackScale"); return v > 0 ? v : 1 }() { didSet { UserDefaults.standard.set(trackScale, forKey: "timeline.trackScale") } }
    /// Inspector tab asked by a command (⌥1…⌥4); the panel takes it and clears it.
    @Published var inspectorRequest: InspCat?
    @Published var zoom = 1.0                    // 1 = fit the whole project in the visible width
    @Published var hoverCut: Double?             // blade preview position (timeline seconds)
    @Published var trimPreview: (clip: UUID, edge: ClipEdge, delta: Double)?
    @Published var search = ""
    @Published var librarySort: LibrarySort = .added
    @Published var libraryFilter: LibraryFilter = .all
    // Viewer view state: never saved in the project and never part of the composition (so it cannot change an export).
    @Published var viewZoom: Double?             // nil = "Potrivire"; otherwise the frame is shown at this fraction of its pixel size
    @Published var viewPan = CGSize.zero
    @Published var stageSize = CGSize.zero
    // Timeline magnet (a per-user preference, not part of the project)
    @Published var snapOn: Bool = (UserDefaults.standard.object(forKey: "sadrog.snap") as? Bool) ?? true { didSet { UserDefaults.standard.set(snapOn, forKey: "sadrog.snap") } }
    @Published var snapGuide: Double?            // timeline second of the guide while an edge is snapped
    var fps: Double { project.canvas?.fps ?? project.clips.first.flatMap { media[$0.media]?.fps } ?? media.values.first?.fps ?? 30 }
    @Published var videoSize = CGSize.zero
    @Published var exportState = ExportState.idle
    @Published var showExport = false
    @Published var exportName = ""
    /// Personal export presets + the default (a JSON file next to the app's other data); the sheet starts from the default.
    @Published var exportPresets = ExportPresetStore(url: AppInfo.supportFolder.appendingPathComponent("ExportPresets.json"))
    @Published var exportSettings = ExportPresetStore(url: AppInfo.supportFolder.appendingPathComponent("ExportPresets.json")).defaultSettings
    /// Export only the In–Out range when one is set (video export).
    @Published var onlyRange = true
    /// Where exports go: the project folder unless the user picks another one (kept for this editor session).
    @Published var exportFolderChoice: URL?
    var exportFolder: URL { exportFolderChoice ?? folder }
    func chooseExportFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.directoryURL = exportFolder; p.prompt = "Alege"
        if p.runModal() == .OK, let u = p.url { exportFolderChoice = u }
    }
    /// Why the fast (stream copy) mode cannot be used for this project, if it cannot; nil when it can.
    var reencodeReason: String? {
        if project.needsCompositing { return T("proiectul are titluri, suprapuneri sau transformări") }
        if let c = project.canvas, (CGSize(width: c.width, height: c.height) != videoSize || abs(c.fps - (project.clips.first.flatMap { media[$0.media]?.fps } ?? c.fps)) > 0.01) { return T("documentul are altă mărime sau cadență decât sursa") }
        if !project.mutedSources.isEmpty || project.mutedLanes.contains(.a1) || project.mutedLanes.contains(.a2) { return T("există surse audio mute") }
        if mainSources.count > 1 || project.layers.contains(where: { $0.kind == .audio }) { return T("mai multe surse audio se mixează într-o pistă") }
        if project.hasActiveEffects { return T("o sursă are efecte audio") }
        return nil
    }
    // Audio Unit effects on recording sources (see EditorEffects.swift)
    var fxPlan = EffectPlan()
    var fxTasks: [String: (key: String, task: Task<Void, Never>)] = [:]      // by EffectRenderer.slot
    @Published var fxProgress: [String: Double] = [:]                         // running renders, by slot
    @Published var fxFailed: [String: (key: String, message: String)] = [:]   // last failure per slot (not retried until the chain changes or "Reîncearcă")
    @Published var fxPeaks: [String: Float] = [:]                             // true peak of each processed file (by path)
    @Published var pluginWindows: [UUID: PluginWindow] = [:]
    let player = AVPlayer()
    /// Listening volume of the editor (the headphones control): the level of the PLAYER only. It never changes a clip's level, the mix or an export.
    @Published var monitorVolume: Double = (UserDefaults.standard.object(forKey: "sadrog.monitorVolume") as? Double) ?? 1 { didSet { UserDefaults.standard.set(monitorVolume, forKey: "sadrog.monitorVolume"); applyMonitor() } }
    @Published var monitorMuted = false { didSet { applyMonitor() } }
    /// Quick access from a clip's menu: opens the inspector (if hidden) on the requested tab; nil = keep the current tab.
    func revealInspector(_ tab: InspCat?) { UserDefaults.standard.set(true, forKey: "editor.showInspector"); DispatchQueue.main.async { self.inspectorRequest = tab } }      // after the selection change picked its default tab
    func applyMonitor() { player.volume = Float(max(0, min(1, monitorVolume))); player.isMuted = monitorMuted }
    private var observer: Any?
    private var exportTask: Task<Void, Never>?
    private var projectURL: URL { folder.appendingPathComponent("project.sadrogproj") }

    /// A recording session (journal) or a document folder created from "Document nou" (no journal: the project must exist).
    init(session folder: URL, journal: SessionJournal?) async throws {
        self.folder = folder
        let loaded: SadrogProject
        if let p = try? ProjectStore.load(from: folder.appendingPathComponent("project.sadrogproj")) { loaded = p }
        else {
            guard let journal else { throw CocoaError(.fileReadNoSuchFile) }
            let media = folder.appendingPathComponent(journal.mediaFile)
            let d = try await AVURLAsset(url: media).load(.duration).seconds
            loaded = SadrogProject.forRecording(name: L10n.f("Înregistrare %@", "\(journal.startedAt.formatted())"), media: media.path, duration: d, journal: journal)
        }
        editor = ProjectEditor(project: loaded); project = loaded
        applyMonitor()
        missing = ProjectStore.missingMedia(loaded)
        let stamp = DateFormatter(); stamp.dateFormat = "yyyy-MM-dd HH.mm"
        let base = loaded.name.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        exportName = (base.isEmpty ? "SADROG" : base) + " " + stamp.string(from: Date())
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 20), queue: .main) { [weak self] t in
            Task { @MainActor in
                guard let self else { return }
                self.time = max(0, t.seconds); self.playing = self.player.timeControlStatus != .paused
            }
        }
        await reload(keepTime: false)
    }

    var canUndo: Bool { editor.canUndo }
    var canRedo: Bool { editor.canRedo }
    var selectedClip: Clip? { project.clips.first { $0.id == selection } }
    var selectedLayer: Layer? { project.layers.first { $0.id == selection } }
    var selectedText: TextOverlay? { project.texts.first { $0.id == selection } }
    var selectedCallout: Callout? { project.callouts.first { $0.id == selection } }
    var selectedStart: Double { selectedClip.flatMap { project.start(ofClip: $0.id) } ?? selectedLayer?.start ?? selectedText?.start ?? selectedCallout?.start ?? 0 }
    var selectedDuration: Double { selectedClip?.duration ?? selectedLayer?.duration ?? selectedText?.duration ?? selectedCallout?.duration ?? 0 }
    var selectedMedia: String? { selectedClip?.media ?? selectedLayer?.media }
    /// Transform of the selected video item (main clip or overlay); nil for audio or no selection.
    /// (start state, end state) of the selected visual item; the end state exists only while the item is animated.
    private var selectedPair: (Transform, Transform?)? {
        if let c = selectedClip { return (c.transform, c.endTransform) }
        if let l = selectedLayer, l.kind == .video { return (l.transform, l.endTransform) }
        if let t = selectedText { return (t.transform, t.endTransform) }
        return nil
    }
    var selectedAnimated: Bool { selectedPair?.1 != nil }
    var selectedMotion: Motion? { selectedClip?.motion ?? selectedLayer?.motion ?? selectedText?.motion }
    /// Seconds from the start of the selected item (playhead), when strictly inside it (keyframes cannot sit on its edges).
    var keyTimeHere: Double? { let r = time - selectedStart; return r > 0.05 && r < selectedDuration - 0.05 ? r : nil }
    /// Property whose keys the timeline band shows (nil = every key).
    @Published var keyBandProp: ProjectEditor.KeyProperty?
    /// Adds a keyframe at the playhead holding the state shown there, and edits it.
    func addKeyHere() { if let rel = keyTimeHere { addKey(at: rel) } }
    /// Adds a keyframe `rel` seconds into the selected item (inside it, off its edges) holding the state shown there.
    func addKey(at rel: Double) {
        guard let id = selection, rel > 0.05, rel < selectedDuration - 0.05, let p = selectedPair else { return }
        var base = selectedMotion ?? Motion(); base.fadeIn = 0; base.fadeOut = 0
        let st = base.state(start: p.0, end: p.1, elapsed: rel, duration: selectedDuration)
        apply(reload: false) { $0.setKey(id, at: rel, st) }
        editingEnd = false; editingKey = selectedMotion?.keys.firstIndex { abs($0.t - rel) < 0.06 }
    }
    /// Moves the playhead to the next / previous keyframe of the selected item and selects it.
    func gotoKey(next: Bool) {
        guard let ks = selectedMotion?.keys, !ks.isEmpty else { return }
        let rel = time - selectedStart
        let order = ks.indices.sorted { ks[$0].t < ks[$1].t }
        let pick = next ? order.first { ks[$0].t > rel + 0.001 } : order.last { ks[$0].t < rel - 0.001 }
        if let i = pick { showKey(i) }
    }
    /// Fade of the selected sound item ends (fade-in) / starts (fade-out) at the playhead; one undo step.
    func setFadeToPlayhead(isIn: Bool) {
        guard let id = selection, selectedLayer?.kind == .audio || (selectedClip.flatMap { media[$0.media]?.hasAudio } == true) else { return }
        let rel = time - selectedStart, d = selectedDuration
        var e = audioEdit(id)
        if isIn { e.fadeIn = max(0, min(d - e.fadeOut, (rel * 100).rounded() / 100)) } else { e.fadeOut = max(0, min(d - e.fadeIn, ((d - rel) * 100).rounded() / 100)) }
        commitAudio(id, e)
    }
    /// Every editor command that has a shortcut but no menu item of its own (the menu items call their own actions; both read the same combination).
    func perform(_ id: String) {
        switch id {
        case "tool.escape": if tool != .select { tool = .select }
        case "tool.selectAlt", "tool.select": tool = .select
        case "tool.blade": tool = .blade
        case "tool.volume": tool = .volume
        case "tool.snap": snapOn.toggle()
        case "play.toggle": togglePlay()
        case "play.stepBack": step(frames: -1)
        case "play.stepForward": step(frames: 1)
        case "key.marker": addMarkerHere()
        case "key.in": setIn()
        case "key.out": setOut()
        case "timeline.zoomIn": zoom = min(16, zoom * 1.5)
        case "timeline.zoomOut": zoom = max(1, zoom / 1.5)
        case "timeline.fit": zoom = 1
        case "timeline.tracksTaller": trackScale = min(2.5, trackScale * 1.2)
        case "timeline.tracksShorter": trackScale = max(0.6, trackScale / 1.2)
        case "keyframe.add": addKeyHere()
        case "keyframe.delete": if let i = editingKey { removeKey(i) }
        case "keyframe.next": gotoKey(next: true)
        case "keyframe.prev": gotoKey(next: false)
        case "audio.fadeIn": setFadeToPlayhead(isIn: true)
        case "audio.fadeOut": setFadeToPlayhead(isIn: false)
        case "inspector.video": inspectorRequest = .image
        case "inspector.sound": inspectorRequest = .sound
        case "inspector.time": inspectorRequest = .time
        case "inspector.cursor": inspectorRequest = .cursor
        default: break
        }
    }
    func removeKey(_ i: Int) { guard let id = selection else { return }; apply(reload: false) { $0.removeKey(id, at: i) }; editingKey = nil }
    func showKey(_ i: Int) {
        guard let k = selectedMotion?.keys[safe: i] else { return }
        editingEnd = false; editingKey = i; seek(selectedStart + k.t)
    }
    /// Live (while scrubbing a field): the picture follows at once, the undo step comes with `commitMotion`.
    func liveMotion(_ edit: (inout Motion) -> Void) {
        guard let id = selection else { return }
        func upd(_ m: inout Motion?) { var v = m ?? Motion(); edit(&v); v.normalize(); m = v.isNeutral ? nil : v }
        if let i = project.clips.firstIndex(where: { $0.id == id }) { upd(&project.clips[i].motion) }
        else if let i = project.layers.firstIndex(where: { $0.id == id }) { upd(&project.layers[i].motion) }
        else if let i = project.texts.firstIndex(where: { $0.id == id }) { upd(&project.texts[i].motion) }
        refreshVideoComposition()
    }
    func commitMotion() { guard let id = selection else { return }; let v = selectedMotion ?? Motion(); apply(reload: false) { $0.updateMotion(id) { $0 = v } } }
    func setMotion(_ edit: @escaping (inout Motion) -> Void) { guard let id = selection else { return }; apply(reload: false) { $0.updateMotion(id, edit) } }
    /// The state being edited: the start state, or the end state when the Inspector is on "Sfârșit".
    var selectedTransform: Transform? {
        if let i = editingKey, let k = selectedMotion?.keys[safe: i] { return k.transform }
        return selectedPair.map { editingEnd ? ($0.1 ?? $0.0) : $0.0 }
    }
    /// What the viewer shows at the playhead (the eased blend between the two states).
    var displayTransform: Transform? {
        guard let p = selectedPair else { return nil }
        return Transform.state(start: p.0, end: p.1, motion: selectedMotion, elapsed: time - selectedStart, duration: selectedDuration)
    }
    /// Size of the selected item before scale, in render pixels, and whether it is aspect-fitted into the frame (media) or placed as is (title).
    var selectedNatural: (size: CGSize, fit: Bool)? {
        if let t = selectedText { return (TextRenderer.layoutSize(t, render: renderSize), false) }
        if let n = selectedMedia.flatMap({ media[$0]?.size }), n.width > 0 { return (selectedCrop != nil ? Self.square(n) : (selectedRectCrop?.window(of: n).size ?? n), true) }
        return nil
    }
    var renderSize: CGSize { built?.renderSize ?? (videoSize == .zero ? CGSize(width: 1280, height: 720) : videoSize) }
    /// Canvas alignment (viewer guides) — independent of the timeline magnet (`snapOn`).
    @Published var alignOn: Bool = (UserDefaults.standard.object(forKey: "sadrog.align") as? Bool) ?? true { didSet { UserDefaults.standard.set(alignOn, forKey: "sadrog.align") } }
    /// Bounding box in canvas pixels of an item of natural size `n` placed by `t` (same maths as the compositor; rotation → its bounding box).
    func canvasBox(natural n: CGSize, fit: Bool, _ t: Transform) -> CGRect {
        let R = renderSize, f = fit ? min(R.width / max(n.width, 1), R.height / max(n.height, 1)) : 1
        let w = n.width * f * t.scale, h = n.height * f * t.scale, a = abs(t.rotation) * .pi / 180
        let bw = w * cos(a) + h * sin(a), bh = w * sin(a) + h * cos(a)
        let c = CGPoint(x: R.width / 2 + t.x * R.width, y: R.height / 2 + t.y * R.height)
        return CGRect(x: c.x - bw / 2, y: c.y - bh / 2, width: bw, height: bh)
    }
    /// Boxes of the other visual items on screen at the playhead (main clip, V2 overlays, titles of visible lanes), for alignment.
    func otherCanvasBoxes(excluding id: UUID) -> [CGRect] {
        var out: [CGRect] = []
        if !project.hiddenLanes.contains(.v1), let (i, off) = project.locate(time) {
            let c = project.clips[i]
            if c.id != id, let n0 = media[c.media]?.size, n0.width > 0 { let n = c.crop != nil ? Self.square(n0) : (c.rectCrop?.window(of: n0).size ?? n0); out.append(canvasBox(natural: n, fit: true, Transform.state(start: c.transform, end: c.endTransform, elapsed: off, duration: c.duration))) }
        }
        if !project.hiddenLanes.contains(.v2) {
            for l in project.layers where l.kind == .video && l.id != id && time >= l.start && time < l.end {
                if let n0 = media[l.media]?.size, n0.width > 0 { let n = l.crop != nil ? Self.square(n0) : (l.rectCrop?.window(of: n0).size ?? n0); out.append(canvasBox(natural: n, fit: true, Transform.state(start: l.transform, end: l.endTransform, elapsed: time - l.start, duration: l.duration))) }
            }
        }
        if !project.hiddenLanes.contains(.t) {
            for t in project.texts where t.id != id && time >= t.start && time < t.end {
                out.append(canvasBox(natural: TextRenderer.layoutSize(t, render: renderSize), fit: false, Transform.state(start: t.transform, end: t.endTransform, elapsed: time - t.start, duration: t.duration)))
            }
        }
        return out
    }
    var needsCompositing: Bool { project.needsCompositing }
    var materials: [(name: String, duration: Double, path: String)] {
        var paths = project.library
        for p in project.clips.map(\.media) + project.layers.map(\.media) where !paths.contains(p) { paths.append(p) }
        return paths.map { (URL(fileURLWithPath: $0).lastPathComponent, media[$0]?.duration ?? 0, $0) }
    }

    func apply(reload: Bool = true, _ edit: (ProjectEditor) -> Void) {
        let before = project
        edit(editor); project = editor.project
        if let sel = selection, lockedLane(of: sel), project == before { message = T("Pista este blocată — deblochează-o ca să editezi.") }
        extra = extra.filter { exists($0) }
        if selection != nil, selectedClip == nil, selectedLayer == nil, selectedText == nil, selectedCallout == nil { selection = nil }
        try? ProjectStore.save(project, to: projectURL)      // autosave on every edit
        if reload { Task { await self.reload(keepTime: true) } } else { refreshVideoComposition() }
    }
    var framingGuideID: UUID? { circleFraming ? selectedVideoID : nil }
    func refreshVideoComposition() { player.currentItem?.videoComposition = built?.videoComposition(for: project, framingGuide: framingGuideID); player.currentItem?.audioMix = built?.audioMix(for: project) }

    func reload(keepTime: Bool) async {
        guard missing.isEmpty else { message = L10n.f("Lipsește fișierul media: %@", "\(missing.joined(separator: ", "))"); return }
        let t = keepTime ? player.currentTime() : .zero
        do {
            fxPlan = await EffectRenderer.plan(project, folder: folder)
            let b = try await CompositionBuilder.buildFull(project, fx: fxPlan.ready); built = b; let comp = b.composition
            let item = AVPlayerItem(asset: comp); item.audioTimePitchAlgorithm = b.pitch; item.videoComposition = b.videoComposition(for: project, framingGuide: framingGuideID); item.audioMix = b.audioMix(for: project)
            player.replaceCurrentItem(with: item)
            if keepTime { await player.seek(to: min(t, comp.duration), toleranceBefore: .zero, toleranceAfter: .zero) }
            if let v = try? await comp.loadTracks(withMediaType: .video).first, let s = try? await v.load(.naturalSize) { videoSize = s }
            await loadMedia()
            scheduleEffects()
        } catch { message = L10n.f("Nu pot construi previzualizarea: %@", "\(error.localizedDescription)") }
    }

    func loadMedia() async {
        let all = Array(Set(project.library + project.clips.map(\.media) + project.layers.map(\.media))).sorted()
        for path in all where media[path] == nil {
            let url = URL(fileURLWithPath: path); let asset = AVURLAsset(url: url)
            let d = (try? await asset.load(.duration).seconds) ?? 0
            var size = CGSize.zero, fps = 30.0
            let vt = try? await asset.loadTracks(withMediaType: .video).first, nA = (try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0, hasA = nA > 0
            if let v = vt { size = (try? await v.load(.naturalSize)) ?? .zero; fps = Double((try? await v.load(.nominalFrameRate)) ?? 30) }
            media[path] = MediaInfo(duration: d, size: size, fps: fps > 1 ? fps : 30, peaks: [], poster: vt == nil ? nil : await ThumbCache.shared.image(media: path, at: min(1, d / 2)), hasVideo: vt != nil, hasAudio: hasA,
                                    sources: RecordingAudio.sources(media: path, trackCount: nA))
            Task.detached { [weak self] in
                let (tp, raw) = await EditorModel.trackPeaks(url: url, duration: d)
                await self?.setSourcePeak(path, raw)
                let all = tp.first.map { f in f.indices.map { i in tp.map { $0.indices.contains(i) ? $0[i] : 0 }.max() ?? 0 } } ?? []
                await self?.setPeaks(path, tracks: tp, all: all)
            }
        }
    }

    private func setSourcePeak(_ path: String, _ raw: [Float]) { media[path]?.sourcePeak = raw }
    private func setPeaks(_ path: String, tracks: [[Float]], all: [Float]) { media[path]?.trackPeaks = tracks; media[path]?.peaks = all }

    /// Real audio peaks of every audio track of the file, 20 per second on the FILE timeline (each track placed at its own start offset),
    /// normalised together for display only: the loudest track fills its row, a silent track stays flat.
    nonisolated static func trackPeaks(url: URL, duration: Double) async -> ([[Float]], [Float]) {
        let asset = AVURLAsset(url: url)
        guard let tracks = try? await asset.loadTracks(withMediaType: .audio), !tracks.isEmpty else { return ([], []) }
        let bins = max(1, Int(duration * 20)); let rate = 8000.0
        var out: [[Float]] = []
        for track in tracks {
            var peaks = [Float](repeating: 0, count: bins)
            let start = (try? await track.load(.timeRange).start.seconds) ?? 0
            if let reader = try? AVAssetReader(asset: asset) {
                let o = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false, AVNumberOfChannelsKey: 1, AVSampleRateKey: rate])
                reader.add(o)
                if reader.startReading() {
                    var idx = Int((max(0, start) * rate).rounded())
                    while let sb = o.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                        let len = CMBlockBufferGetDataLength(bb); var data = [Float](repeating: 0, count: len / 4)
                        CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &data)
                        for v in data { let b = min(bins - 1, Int(Double(idx) / rate * 20)); peaks[b] = max(peaks[b], abs(v)); idx += 1 }
                    }
                }
            }
            out.append(peaks)
        }
        let raw = out.map { $0.max() ?? 0 }
        let mx = max(raw.max() ?? 0, 0.0001)
        return (out.map { $0.map { min(1, $0 / mx) } }, raw)
    }

    func seek(_ t: Double) { time = t; player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
    func select(at t: Double) { if let (i, _) = project.locate(min(t, project.duration - 0.001)) { selection = project.clips[i].id } }
    func select(_ id: UUID?) { extra = []; if id != selection { cropEditing = false; endFraming() }; selection = id }
    /// The pointer track of the selected clip's recording (nil when it was recorded without the setting, or the file is not there).
    var selectedMouseTrack: MouseTrack? { selectedClip.flatMap { $0.held ? nil : MouseTrack.load(besideMedia: $0.media) } }
    /// The front-window track of the selected clip's recording (nil when it was recorded without the setting).
    var selectedWindowTrack: WindowTrack? { selectedClip.flatMap { $0.held ? nil : WindowTrack.load(besideMedia: $0.media) } }
    @Published var followWindowChoice: UInt32 = 0      // 0 = whichever window was in front
    func followWindow(_ id: UUID) {
        guard let t = selectedWindowTrack else { return }
        var ok = false; apply { ok = $0.followWindow(clip: id, track: t, only: self.followWindowChoice == 0 ? nil : self.followWindowChoice) }
        if !ok { message = T("Fereastra aleasă nu apare în această parte a înregistrării.") }
    }
    func setMouseFX(_ id: UUID, _ fx: MouseFX) { apply { $0.setMouseFX(clip: id, fx) } }
    var selectedKeyTrack: KeyTrack? { selectedClip.flatMap { $0.held ? nil : KeyTrack.load(besideMedia: $0.media) } }
    func setKeyFX(_ id: UUID, _ fx: KeyFX) { apply { $0.setKeyFX(clip: id, fx) } }
    func followMouse(_ id: UUID, scale: Double) {
        guard let t = selectedMouseTrack else { return }
        apply { _ = $0.followMouse(clip: id, track: t, scale: scale) }
    }
    func setTextAnimation(_ a: TextAnimation) { guard let id = selection, selectedText != nil else { return }; applyTitles { $0.setTextAnimation(id, a) } }
    func maxDissolve(of id: UUID) -> Double { editor.maxDissolve(forClip: id) }
    func setDissolve(_ id: UUID, _ seconds: Double) { apply { $0.setDissolve(clip: id, seconds: seconds) } }
    func togglePlay() { if player.timeControlStatus == .paused { player.play() } else { player.pause() } }
    func split() {
        if selectedText != nil { splitAt(time, lane: .text) } else if let l = selectedLayer { splitAt(time, lane: l.kind == .video ? .overlay : .audio) } else { splitAt(time) }
    }
    func splitAt(_ t: Double, lane: Lane = .main) {
        switch lane {
        case .main: apply { $0.split(at: t) }
        case .overlay: apply { $0.splitLayer(kind: .video, at: t) }
        case .audio: apply { $0.splitLayer(kind: .audio, at: t) }
        case .text: applyTitles { $0.splitText(at: t) }
        case .callout: break      // a callout is not split (trim or add another)
        }
    }
    /// Freeze frame at the playhead (2 s; trim it to the length you need). Selects the new held clip.
    func freezeHere() {
        var made: UUID?; player.pause()
        apply { made = $0.freezeFrame(at: time, length: 2) }
        if let made { select(made) } else { message = T("Nu se poate îngheța cadrul aici: cursorul trebuie să fie pe un clip video normal.") }
    }
    // MARK: markers and In/Out
    func addMarkerHere() { apply(reload: false) { $0.addMarker(at: time) } }
    func goToMarker(next: Bool) {
        let ts = project.markers.map(\.time)
        if let t = next ? ts.first(where: { $0 > time + 0.02 }) : ts.last(where: { $0 < time - 0.02 }) { player.pause(); seek(t) }
    }
    func setIn() { apply(reload: false) { $0.setRange(in: time) } }
    func setOut() { apply(reload: false) { $0.setRange(out: time) } }
    func clearRange() { apply(reload: false) { $0.clearRange() } }
    func renameMarker(_ id: UUID, _ name: String) { apply(reload: false) { $0.renameMarker(id, name) } }
    func removeMarker(_ id: UUID) { apply(reload: false) { $0.removeMarker(id) } }
    func step(frames n: Int) { player.pause(); seek(max(0, min(project.timelineEnd, time + Double(n) / fps))) }
    var boundaries: [Double] { var b = [0.0]; for sp in project.clipSpans { b += [sp.start, sp.end] }; for l in project.layers { b += [l.start, l.end] }; for t in project.texts { b += [t.start, t.end] }; for c in project.callouts { b += [c.start, c.end] }; return Array(Set(b)).sorted() }
    func jump(next: Bool) {
        let b = boundaries
        if next { if let t = b.first(where: { $0 > time + 0.01 }) { seek(min(t, max(0, project.timelineEnd - 0.001))) } }
        else if let t = b.last(where: { $0 < time - 0.01 }) { seek(t) }
    }
    func select(clip id: Clip.ID?) { extra = []; if id != selection { cropEditing = false; endFraming() }; selection = id }
    /// Edge trim with ripple. `delta` seconds on the timeline: positive moves the edge right.
    func trim(clip id: Clip.ID, edge: ClipEdge, by delta: Double) {
        guard let c = project.clips.first(where: { $0.id == id }) else { return }
        let avail = c.held ? Double.infinity : max(0, ((media[c.media]?.duration ?? (c.sourceStart + c.sourceSpan)) - (c.sourceStart + c.sourceSpan)) / c.speed)    // timeline seconds the source still allows
        switch edge {
        case .start: apply { $0.trimStart(clip: id, by: delta) }
        case .end: let cut = -delta; apply { $0.trimEnd(clip: id, by: max(-avail, cut)) }
        }
    }
    func trimLayer(_ id: UUID, edge: ClipEdge, by delta: Double) {
        guard let l = project.layers.first(where: { $0.id == id }) else { return }
        switch edge {
        case .start: apply { $0.trimLayerStart(id, by: delta) }
        case .end: let len = media[l.media]?.duration; apply { $0.trimLayerEnd(id, by: -delta, sourceLength: len) }
        }
    }
    func deleteSelected() {
        guard let s = selection else { return }
        if selectedText != nil { applyTitles { $0.removeText(s) } }
        else if selectedCallout != nil { applyCallouts { $0.removeCallout(s) } }
        else if selectedLayer != nil { apply { $0.deleteLayer(s) } } else { apply { $0.delete(clip: s) } }
        selection = nil
    }
    // MARK: titles (lane T)
    /// Title edits keep the composition in step with the project length without a full rebuild unless the length changed.
    private func applyTitles(_ edit: (ProjectEditor) -> Void) {
        apply(reload: false, edit)
        if abs(project.timelineEnd - (built?.composition.duration.seconds ?? 0)) > 0.03 { Task { await self.reload(keepTime: true) } }
    }
    func addTitle() {
        var start = time
        for t in project.texts.sorted(by: { $0.start < $1.start }) where start < t.end - 1e-6 && start + 3 > t.start + 1e-6 { start = t.end }
        let t = TextOverlay(text: "Titlu", start: start, duration: 3)
        var ok = false; applyTitles { ok = $0.addText(t) }
        if ok { selection = t.id; message = "" } else { message = T("Nu pot adăuga titlul acolo.") }
    }
    /// Property edit of the selected title as ONE undo step; refused (with a message) if it would overlap another title.
    func updateTitle(_ edit: @escaping (inout TextOverlay) -> Void) {
        guard let id = selection, selectedText != nil else { return }
        var ok = true; applyTitles { ok = $0.updateText(id, edit) }
        message = ok ? "" : T("Nu se poate: titlul s-ar suprapune cu altul pe aceeași pistă, sau textul e gol.")
        if !ok { project = editor.project }
    }
    /// Live (no undo) property edit while a slider moves; `commitTitle` then records ONE undo step.
    func liveTitle(_ edit: (inout TextOverlay) -> Void) {
        guard let id = selection, let i = project.texts.firstIndex(where: { $0.id == id }) else { return }
        edit(&project.texts[i]); refreshVideoComposition()
    }
    func commitTitle() {
        guard let id = selection, let v = selectedText else { return }
        updateTitle { $0 = v }; _ = id
    }
    func moveTitle(_ id: UUID, to start: Double) {
        var ok = true; applyTitles { ok = $0.moveText(id, to: start) }
        message = ok ? "" : T("Nu se poate muta acolo: se suprapune cu alt titlu.")
    }
    func trimTitle(_ id: UUID, edge: ClipEdge, by delta: Double) {
        switch edge { case .start: applyTitles { $0.trimTextStart(id, by: delta) }; case .end: applyTitles { $0.trimTextEnd(id, by: -delta) } }
    }
    // MARK: callouts (lane C)
    private func applyCallouts(_ edit: (ProjectEditor) -> Void) { applyTitles(edit) }
    /// A new callout belongs to the clip under its start and never runs past that clip's end.
    private func bindToClip(_ c: inout Callout) {
        guard let span = project.clipSpans.first(where: { c.start >= $0.start - 1e-6 && c.start < $0.end - 1e-6 }) else { return }
        c.clipID = span.id; c.duration = max(SadrogProject.minCalloutLength, min(c.duration, span.end - c.start))
    }
    /// Binds the selected callout to a video overlay (nil = releases it). One undo step.
    /// An effect dropped on a clip or overlay acts on that item from the drop point on (one undo step).
    func dropEffect(_ id: UUID, on target: UUID, at t: Double) {
        let isClip = project.clips.contains { $0.id == target }
        var ok = false
        applyCallouts { ok = $0.retargetCallout(id, toClip: isClip ? target : nil, toLayer: isClip ? nil : target, at: t) }
        message = ok ? T("Efectul acționează acum asupra elementului ales.") : T("Nu pot lega efectul de elementul acela.")
    }
    func bindSelectedCallout(toLayer id: UUID?) {
        guard let cid = selection, selectedCallout != nil else { return }
        var ok = false; applyCallouts { ok = $0.bindCallout(cid, toLayer: id) }
        if !ok { message = T("Nu pot lega evidențierea de suprapunere acolo.") }
    }
    /// Video overlays on screen at `t` (the possible targets of a callout starting there).
    func overlays(at t: Double) -> [Layer] { project.layers.filter { $0.kind == .video && t >= $0.start - 1e-6 && t < $0.end - 1e-6 } }
    func layerName(_ l: Layer) -> String { l.label ?? URL(fileURLWithPath: l.media).lastPathComponent }
    /// ONE targeting rule for every way of creating an effect (button, drawing, inspector): the selected video clip is the target
    /// (an effect starts at the playhead when it is inside that clip, else at the clip's start); else the selected overlay;
    /// else the clip under the playhead. The start is never pushed because another effect already sits there.
    func newCallout() -> Callout {
        var c = Callout(start: time, duration: 3)
        if let l = selectedLayer, l.kind == .video, time >= l.start - 1e-6, time < l.end - 1e-6 {
            c.layerID = l.id; c.duration = max(SadrogProject.minCalloutLength, min(c.duration, l.end - time))
        } else if let span = project.clipSpans.first(where: { $0.id == selection }) {
            if !(time >= span.start - 1e-6 && time < span.end - 1e-6) { c.start = span.start }
            c.clipID = span.id; c.duration = max(SadrogProject.minCalloutLength, min(c.duration, span.end - c.start))
        } else { bindToClip(&c) }
        return c
    }
    // MARK: sound detached from its picture
    /// The main-track clip a command on the selection (or on `id`) concerns.
    private func clipForAudioCommand(_ id: UUID?) -> Clip? {
        let i = id ?? selection
        if let c = project.clips.first(where: { $0.id == i }) { return c }
        if let l = project.layers.first(where: { $0.id == i && $0.kind == .audio }), let cid = l.linkedClip { return project.clips.first { $0.id == cid } }
        return nil
    }
    func canDetachAudio(_ id: UUID? = nil) -> Bool {
        guard let c = project.clips.first(where: { $0.id == (id ?? selection) }) else { return false }
        return !c.held && !c.audioDetached && media[c.media]?.hasAudio == true
    }
    func canReattachAudio(_ id: UUID? = nil) -> Bool { clipForAudioCommand(id)?.audioDetached == true }
    /// Detach the clip's sound into an independent audio item (A2); the new item becomes the selection. One undo step.
    func detachAudio(_ id: UUID? = nil) {
        guard let c = project.clips.first(where: { $0.id == (id ?? selection) }) else { return }
        var made: UUID?; apply { made = $0.detachAudio(of: c.id) }
        if let made { selection = made; extra = []; message = T("Sunetul e acum un element separat — poate fi mutat, tăiat sau șters independent.") }
        else if project.clips.first(where: { $0.id == c.id })?.audioDetached != true { message = T("Nu pot detașa sunetul acestui clip.") }
    }
    func canMoveToOverlay(_ id: UUID? = nil) -> Bool { let i = id ?? selection; return project.clips.count > 1 && i != nil && editor.overlayMoveBlocker(of: i!) == nil }
    /// Lifts the main-track clip onto a video overlay row (V2); the new item becomes the selection. One undo step.
    func moveToOverlay(_ id: UUID? = nil) {
        guard let i = id ?? selection, project.clips.contains(where: { $0.id == i }) else { return }
        if let why = editor.overlayMoveBlocker(of: i) {
            message = why == "held" ? T("Un cadru înghețat rămâne pe pista principală.") : (why == "dissolve" ? T("Clipul are o tranziție cu clipul dinainte — scoate-o ca să-l poți muta pe o pistă video.") : T("Clipul are efectul de cursor — rămâne pe pista principală."))
            return
        }
        var made: UUID?; apply { made = $0.moveClipToOverlay(i) }
        if let made { selection = made; extra = []; message = T("Clipul e acum pe o pistă video (V2); pista principală s-a strâns în locul lui.") }
        else { message = T("Nu pot muta clipul pe o pistă video (ultimul clip rămâne pe pista principală).") }
    }
    /// Give the clip its sound back (removes the detached item when it is still in sync). Refused, with a message, when the item was moved/trimmed/cut.
    func reattachAudio(_ id: UUID? = nil) {
        guard let c = clipForAudioCommand(id) else { return }
        let why = editor.reattachBlocker(of: c.id)
        var ok = false; apply { ok = $0.reattachAudio(of: c.id) }
        if ok { selection = c.id; extra = []; message = "" }
        else if why == "edited" { message = T("Sunetul detașat are volum sau mute propriu — clipul nu le poate purta. Resetează-le sau păstrează sunetul separat.") }
        else { message = T("Sunetul detașat a fost mutat sau tăiat — șterge-l sau pune-l înapoi la locul lui, apoi reatașează.") }
    }
    /// Select only the picture of a detached pair, or only its separate sound ("select one side" vs "detach").
    func selectLinkedPart(of id: UUID) {
        if let l = project.layers.first(where: { $0.id == id && $0.kind == .audio }), let cid = l.linkedClip, project.clips.contains(where: { $0.id == cid }) { select(cid) }
        else if let l = project.layers.first(where: { $0.kind == .audio && $0.linkedClip == id }) { select(l.id) }
    }
    func detachedAudioInSyncFlag(_ id: UUID) -> Bool { editor.detachedAudioInSync(id) }
    func hasLinkedPart(_ id: UUID) -> Bool {
        if let l = project.layers.first(where: { $0.id == id && $0.kind == .audio }), let cid = l.linkedClip { return project.clips.contains { $0.id == cid } }
        return project.layers.contains { $0.kind == .audio && $0.linkedClip == id }
    }
    func addCallout() {
        let c = newCallout()
        var ok = false; applyCallouts { ok = $0.addCallout(c) }
        if ok { selection = c.id; message = "" } else { message = T("Nu pot adăuga evidențierea acolo.") }
    }
    /// Property edit of the selected callout as ONE undo step; overlap with other effects is allowed.
    func updateCallout(_ edit: @escaping (inout Callout) -> Void) {
        guard let id = selection, selectedCallout != nil else { return }
        var ok = true; applyCallouts { ok = $0.updateCallout(id, edit) }
        message = ok ? "" : T("Nu se poate: evidențierea s-ar suprapune cu alta pe aceeași pistă.")
        if !ok { project = editor.project }
    }
    /// Live (no undo) edit while a handle or slider moves; `commitCallout` then records ONE undo step.
    func liveCallout(_ edit: (inout Callout) -> Void) {
        guard let id = selection, let i = project.callouts.firstIndex(where: { $0.id == id }) else { return }
        edit(&project.callouts[i]); project.callouts[i].normalize(); refreshVideoComposition()
    }
    func commitCallout() { guard let v = selectedCallout else { return }; updateCallout { $0 = v } }
    func moveCallout(_ id: UUID, to start: Double) {
        var ok = true; applyCallouts { ok = $0.moveCallout(id, to: start) }
        message = ok ? "" : T("Nu se poate muta acolo: se suprapune cu altă evidențiere.")
    }
    func trimCallout(_ id: UUID, edge: ClipEdge, by delta: Double) {
        switch edge { case .start: applyCallouts { $0.trimCalloutStart(id, by: delta) }; case .end: applyCallouts { $0.trimCalloutEnd(id, by: -delta) } }
    }
    /// Creates the callout drawn in the viewer (box and points in frame fractions) as ONE undo step — or, when a callout is selected and the playhead is inside it, redraws ITS selection.
    func commitDrawn(_ tool: DrawTool, box: CGRect, points: [CalloutPoint]) {
        defer { drawTool = nil }
        func shape(_ c: inout Callout) {
            switch tool {
            case .rect: if c.shape == .line || c.shape == .arrow { c.dim = 0.6 }; c.shape = .rect; c.points = []
            case .frame: c.shape = .rect; c.points = []; c.makeFrameOnly()
            case .ellipse: if c.shape == .line || c.shape == .arrow { c.dim = 0.6 }; c.shape = .ellipse; c.points = []
            case .freehand: c.setFreehand(frame: points)
            case .line, .arrow: if points.count == 2 { c.setStroke(tool == .line ? .line : .arrow, from: points[0], to: points[1]); c.dim = 0 }
            }
            if tool == .rect || tool == .ellipse || tool == .frame { c.x = Double(box.minX); c.y = Double(box.minY); c.w = Double(box.width); c.h = Double(box.height) }
        }
        if tool == .freehand, points.count < 3 { return }
        if tool == .line || tool == .arrow, points.count != 2 || hypot(points[1].x - points[0].x, points[1].y - points[0].y) < 0.02 { return }
        if tool == .rect || tool == .ellipse || tool == .frame, box.width < Callout.minSide || box.height < Callout.minSide { return }
        if let sel = selectedCallout, time >= sel.start, time < sel.end { updateCallout { shape(&$0) }; return }
        var c = newCallout(); shape(&c)
        var ok = false; applyCallouts { ok = $0.addCallout(c) }
        if ok { selection = c.id; message = "" } else { message = T("Nu pot adăuga evidențierea acolo.") }
    }
    /// Turns the selection into a circle: same centre, equal width and height in PIXELS of the output frame.
    func makeCircle() {
        let r = renderSize; guard r.width > 0, r.height > 0 else { return }
        updateCallout { c in
            let side = min(c.w * Double(r.width), c.h * Double(r.height)); let nw = side / Double(r.width), nh = side / Double(r.height)
            let cx = c.x + c.w / 2, cy = c.y + c.h / 2
            c.shape = .ellipse; c.points = []; c.w = nw; c.h = nh; c.x = cx - nw / 2; c.y = cy - nh / 2
        }
    }
    /// Frame zoom towards the selection: the main clip under the callout's start animates to the scale/offset that fills the frame with the box (existing two-state animation).
    func zoomFrameToCallout() {
        guard let c = selectedCallout, let (i, _) = project.locate(c.start) else { message = T("Nu există un clip principal sub evidențiere."); return }
        let clip = project.clips[i]
        let k = min(1 / c.w, 1 / c.h), s = max(1, min(8, k)), cx = c.x + c.w / 2, cy = c.y + c.h / 2
        apply { e in
            e.setAnimated(clip.id, true)
            e.setTransform(clip.id, Transform(x: (0.5 - cx) * s, y: (0.5 - cy) * s, scale: s), end: true)
        }
        message = T("Zoom de cadru către zonă: setat ca stare finală a clipului (animat).")
    }
    /// Rows of the V2 lane: one per overlay track in use, plus none extra (a project without tracks keeps one row).
    var overlayRows: Int { project.rowCount(.v2) }
    var audioRows: Int { project.rowCount(.a2) }
    var attachedDepth: (clips: Int, layers: Int) { project.attachedRowDepth }
    var textRowCount: Int { (project.textRows().values.max() ?? 0) + 1 }
    var calloutRowCount: Int { (project.globalCalloutRows().values.max() ?? 0) + 1 }
    /// Row under the pointer while a V2/A2 item is dragged: free = the item fits there (no overlap), otherwise the drop will be refused.
    @Published var rowPreview: (id: UUID, row: Int, free: Bool)?
    func trackName(_ lane: TrackLane, _ row: Int) -> String {
        if let n = project.trackNames[SadrogProject.rowKey(lane, row)] { return n }
        return (lane == .v2 ? "V2" : "A2") + (project.rowCount(lane) > 1 ? "·\(row + 1)" : "")
    }
    func placeLayer(_ id: UUID, start: Double, row: Int) {
        var ok = true; apply { ok = $0.placeLayer(id, start: start, row: row) }
        message = ok ? "" : T("Nu se poate muta acolo: se suprapune cu alt element de pe pista aceea.")
    }
    func moveTrackRow(_ lane: TrackLane, from a: Int, to b: Int) {
        var ok = true; apply { ok = $0.moveRow(lane, from: a, to: b) }
        if !ok { message = T("Pista nu poate fi mutată acolo.") }
    }
    func swapTracks(_ lane: TrackLane, _ a: Int, _ b: Int) {
        var ok = true; apply { ok = $0.swapRows(lane, a, b) }
        if !ok { message = T("Pista nu poate fi mutată acolo.") }
    }
    // lane layout (presentation only: never rebuilds the composition or touches the mix)
    func setLaneHeight(_ lane: TrackLane, _ h: Double?) { apply(reload: false) { $0.setLaneHeight(lane, h) } }
    func setRowHeight(_ lane: TrackLane, _ row: Int, _ h: Double?) { apply(reload: false) { $0.setRowHeight(lane, row, h) } }
    func moveLane(_ lane: TrackLane, to index: Int) { apply(reload: false) { $0.moveLane(lane, to: index) } }
    func resetLaneLayout() { apply(reload: false) { $0.resetLayout() } }
    func addTrack(_ lane: TrackLane) { var ok = true; apply(reload: false) { ok = $0.addRow(lane) }; if !ok { message = T("Nu mai pot adăuga piste în această zonă.") } }
    func removeTrack(_ lane: TrackLane, _ row: Int) { var ok = true; apply(reload: false) { ok = $0.removeRow(lane, row) }; if !ok { message = T("Pista are elemente sau este singura rămasă — golește-o înainte să o elimini.") } }
    func renameTrack(_ lane: TrackLane, _ row: Int) {
        let a = NSAlert(); a.messageText = T("Redenumește pista"); a.informativeText = T("Un nume gol readuce numele implicit.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = project.trackNames[SadrogProject.rowKey(lane, row)] ?? ""; a.accessoryView = f
        a.addButton(withTitle: T("Redenumește")); a.addButton(withTitle: T("Anulează")); a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { let v = f.stringValue; apply(reload: false) { _ = $0.setTrackName(lane, row, v) } }
    }
    /// Position of a row inside its lane, top = 0. Video rows stack upwards (the top row is drawn over the others, like the track above in any editor); audio and effect rows go downwards.
    func slot(_ lane: TrackLane, _ row: Int) -> Int { lane == .v2 ? project.rowCount(.v2) - 1 - row : row }
    /// Moves an overlay one row up (drawn in front) or down; refused (with a message) when it would overlap an item there.
    func moveLayerRow(_ id: UUID, by d: Int) {
        guard let l = project.layers.first(where: { $0.id == id }) else { return }
        var ok = false; apply(reload: false) { ok = $0.setLayerRow(id, l.row + d) }
        if !ok { message = T("Pe rândul acela există deja un element în același interval.") }
    }
    func moveLayer(_ id: UUID, to start: Double) {
        var ok = true; apply { ok = $0.moveLayer(id, to: start) }
        message = ok ? "" : T("Nu se poate muta acolo: se suprapune cu alt element de pe pistă.")
    }
    func moveMain(_ id: UUID, by offset: Int) {
        guard let i = project.clips.firstIndex(where: { $0.id == id }) else { return }
        apply { $0.move(clip: id, toIndex: max(0, min(project.clips.count - 1, i + offset))) }
    }

    // MARK: library and placement
    func importMaterials() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio]; panel.message = T("Alege materialele de importat")
        guard panel.runModal() == .OK else { return }
        importMaterials(panel.urls.map(\.path))
    }
    func importMaterials(_ paths: [String]) {
        apply(reload: false) { $0.addToLibrary(paths) }
        Task { await loadMedia() }
    }
    /// A captured session joins this project after the last clip (one undo step); the playhead goes to the new material and it is selected.
    func addRecordedSession(media: String, duration: Double, journal: SessionJournal) async -> Bool {
        var ids: [UUID]?; let at = editor.endOfMain
        apply(reload: false) { ids = $0.addRecordingSession(media: media, duration: duration, journal: journal) }
        guard let ids else { return false }
        missing = ProjectStore.missingMedia(project)
        await loadMedia(); await reload(keepTime: true)
        selection = ids.first; extra = []; seek(at)
        message = T("Înregistrarea a fost adăugată la sfârșitul proiectului.")
        return true
    }
    /// Relinks a file that went missing: the user picks the new file, every use follows (one undo step), the project reloads.
    func relink(_ old: String) {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = false
        panel.allowedContentTypes = [.movie, .audio]; panel.message = L10n.f("Alege fișierul care înlocuiește %@", "\(URL(fileURLWithPath: old).lastPathComponent)")
        guard panel.runModal() == .OK, let new = panel.url?.path else { return }
        apply(reload: false) { $0.relinkMedia(from: old, to: new) }
        missing = ProjectStore.missingMedia(project)
        Task { await loadMedia(); await reload(keepTime: true) }
    }
    func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    private func length(of path: String) -> Double { media[path]?.duration ?? 0 }
    func addToMain(_ path: String) {
        let d = length(of: path); guard d > 0, media[path]?.hasVideo != false else { return }
        apply { $0.appendClip(media: path, duration: d) }
    }
    /// Adds a video as an overlay on the first free spot at/after the playhead (so a drop never overlaps an existing overlay).
    func addAsOverlay(_ path: String) {
        let d = length(of: path); guard d > 0, media[path]?.hasVideo == true else { return }
        let dur = min(d, 12)
        var start = time
        for l in project.layers.filter({ $0.kind == .video }).sorted(by: { $0.start < $1.start }) where start < l.end && start + dur > l.start { start = l.end }
        var layer = Layer(kind: .video, media: path, start: start, duration: dur, transform: Transform(x: 0.22, y: -0.2, scale: 0.4))
        // first V2 row free over that interval (several overlays can play at once on different rows)
        var row = 0
        while project.layers.contains(where: { $0.kind == .video && $0.row == row && $0.start < start + dur - 1e-6 && start < $0.end - 1e-6 }) { row += 1 }
        layer.track = row == 0 ? nil : row
        apply { $0.addLayer(layer) }; selection = layer.id
    }
    func addAsAudio(_ path: String) {
        let d = length(of: path); guard d > 0, media[path]?.hasAudio == true else { return }
        var start = time
        for l in project.layers.filter({ $0.kind == .audio }).sorted(by: { $0.start < $1.start }) where start < l.end && start + d > l.start { start = l.end }
        let layer = Layer(kind: .audio, media: path, start: start, duration: d)
        apply { $0.addLayer(layer) }; selection = layer.id
    }

    // MARK: transform (live while dragging, one undo step on release)
    func liveTransform(_ id: UUID, _ t: Transform) {
        if let k = editingKey {
            func set(_ m: inout Motion?) { if m?.keys.indices.contains(k) == true { m?.keys[k].transform = t } }
            if let i = project.clips.firstIndex(where: { $0.id == id }) { set(&project.clips[i].motion) }
            else if let i = project.layers.firstIndex(where: { $0.id == id }) { set(&project.layers[i].motion) }
            else if let i = project.texts.firstIndex(where: { $0.id == id }) { set(&project.texts[i].motion) }
            refreshVideoComposition(); return
        }
        let end = editingEnd && selectedAnimated
        if let i = project.clips.firstIndex(where: { $0.id == id }) { if end { project.clips[i].endTransform = t } else { project.clips[i].transform = t } }
        else if let i = project.layers.firstIndex(where: { $0.id == id }) { if end { project.layers[i].endTransform = t } else { project.layers[i].transform = t } }
        else if let i = project.texts.firstIndex(where: { $0.id == id }) { if end { project.texts[i].endTransform = t } else { project.texts[i].transform = t } }
        refreshVideoComposition()
    }
    func commitTransform(_ id: UUID, _ t: Transform) {
        if let k = editingKey, selectedMotion?.keys[safe: k] != nil { apply(reload: false) { $0.updateMotion(id) { if $0.keys.indices.contains(k) { $0.keys[k].transform = t } } }; return }
        let end = editingEnd && selectedAnimated; apply(reload: false) { $0.setTransform(id, t, end: end) }
    }
    /// Switches the two-state animation on/off for the selection (on: the end state starts equal to the start state).
    func setAnimated(_ on: Bool) {
        guard let id = selection, selectedPair != nil else { return }
        apply(reload: false) { $0.setAnimated(id, on) }; editingEnd = false
    }
    /// Chooses which state is edited and moves the playhead onto it, so the viewer shows exactly what is being edited.
    func showState(end: Bool) {
        guard selectedAnimated else { return }
        editingEnd = end; editingKey = nil
        seek(end ? max(selectedStart, selectedStart + selectedDuration - 1 / max(fps, 1)) : selectedStart)
    }
    /// Simple zoom preset: the end state is the start state 20 % larger.
    func presetSlowZoom() {
        guard let id = selection, let t = selectedPair?.0 else { return }
        apply(reload: false) { $0.setAnimated(id, true); $0.setTransform(id, Transform(x: t.x, y: t.y, scale: t.scale * 1.2, opacity: t.opacity, rotation: t.rotation), end: true) }
        showState(end: false)
    }

    // MARK: lanes, project name
    func isOff(_ lane: TrackLane) -> Bool { lane.isVideo ? project.hiddenLanes.contains(lane) : project.mutedLanes.contains(lane) }
    func toggle(_ lane: TrackLane) { let off = !isOff(lane); apply { $0.setLane(lane, off: off) } }
    /// The separate sounds of the main recording(s), in file order: the recording with the most audio tracks names them.
    /// The recording whose sources the A1 header and the inspector show and edit: the selected clip's (or the sound detached from it),
    /// otherwise the one with the most audio tracks. Every control passes THIS file explicitly — settings never cross recordings.
    var shownMedia: String {
        if let c = selectedClip { return c.media }
        if let l = selectedLayer, l.keepsSource { return l.media }
        return project.clips.map(\.media).max { (media[$0]?.sources.count ?? 0) < (media[$1]?.sources.count ?? 0) } ?? project.primaryMedia
    }
    var mainSources: [AudioSourceInfo] { media[shownMedia]?.sources ?? [] }
    /// Display name of a recording (its file name without extension).
    func recordingTitle(_ path: String) -> String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    /// Every recording on the main track, in order of first appearance.
    var recordingsInUse: [String] { var seen = Set<String>(); return project.clips.map(\.media).filter { seen.insert($0).inserted } }
    // MARK: per-item sound edits (A2 volume/mute, fades on A1 clips and A2 items) — same mix as preview/export
    @Published var liveAudio: [UUID: AudioEdit] = [:]
    func audioEdit(_ id: UUID) -> AudioEdit { liveAudio[id] ?? (project.clips.first { $0.id == id }?.audio ?? project.layers.first { $0.id == id }?.audio ?? AudioEdit()) }
    /// While a slider/field is dragged: preview only (mix rebuilt from a copy), nothing saved, no undo step.
    func liveAudioEdit(_ id: UUID, _ e: AudioEdit) {
        liveAudio[id] = e
        var p = project
        if let i = p.clips.firstIndex(where: { $0.id == id }) { p.clips[i].audio = e } else if let i = p.layers.firstIndex(where: { $0.id == id }) { p.layers[i].audio = e }
        player.currentItem?.audioMix = built?.audioMix(for: p)
    }
    /// End of a gesture / typed value / toggle / reset: ONE undo step.
    func commitAudio(_ id: UUID, _ e: AudioEdit? = nil) { let v = e ?? liveAudio[id] ?? audioEdit(id); liveAudio[id] = nil; apply(reload: false) { $0.setAudio(id, v) } }
    var selectedAudioDuration: Double { selectedClip?.duration ?? selectedLayer?.duration ?? 0 }
    func isSourceMuted(_ k: Int) -> Bool { project.isMuted(source: k, media: shownMedia) }
    // MARK: mix volume (master)
    @Published var liveMaster: Double?
    var masterDisplay: Double { liveMaster ?? project.masterGainDB }
    func liveMasterGain(_ dB: Double) { liveMaster = dB; var p = project; p.masterGainDB = dB; player.currentItem?.audioMix = built?.audioMix(for: p) }
    func commitMasterGain(_ dB: Double? = nil) { let v = dB ?? liveMaster ?? project.masterGainDB; liveMaster = nil; apply(reload: false) { $0.setMasterGain(v) } }
    // MARK: audio delivery (mix + separate sources)
    enum ExportKind: String, CaseIterable, Identifiable { case video = "Video (mix)", audio = "Audio: mix + surse separate", archive = "Arhivă: proiect + media"; var id: String { rawValue } }
    @Published var exportKind: ExportKind = .video
    var deliveryPlan: [AudioDelivery.Item] { AudioDelivery.plan(project, recordings: recordingsInUse.map { .init(media: $0, title: recordingTitle($0), sources: media[$0]?.sources ?? []) }, baseName: exportName.trimmingCharacters(in: .whitespaces).isEmpty ? "SADROG-export" : exportName.trimmingCharacters(in: .whitespaces)) }
    var deliveryConflicts: [String] { deliveryPlan.map(\.fileName).filter { FileManager.default.fileExists(atPath: exportFolder.appendingPathComponent($0).path) } }
    @Published var deliveredFiles: [URL] = []
    func startAudioDelivery() {
        guard exportTask == nil else { return }
        guard ActivationModel.shared.allowsRecordAndExport else { exportState = .failed(ActivationModel.shared.blockedText); return }
        let p = project, items = deliveryPlan, dir = exportFolder, fx = fxPlan
        exportState = .running(0); deliveredFiles = []
        exportTask = Task {
            do {
                try Destination(url: dir).validate(requiredBytes: 200_000_000)
                let urls = try await AudioDelivery.export(p, items: items, to: dir, effects: fx) { f in Task { @MainActor in if case .running = self.exportState { self.exportState = .running(f) } } }
                try Task.checkCancellation()
                deliveredFiles = urls
                let size = urls.reduce(Int64(0)) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int64) ?? 0) }
                exportState = .done(dir, size)
            } catch is CancellationError { exportState = .cancelled }
            catch AudioDelivery.DeliveryError.exists(let n) { exportState = .failed(L10n.f("Există deja: %@. Nimic nu a fost suprascris; alege alt nume.", "\(n.joined(separator: ", "))")) }
            catch AudioDelivery.DeliveryError.noSound { exportState = .failed(T("Proiectul nu are sunet de exportat.")) }
            catch { exportState = .failed(L10n.f("%@ — fișierele parțiale au fost șterse.", "\(error.localizedDescription)")) }
            exportTask = nil
        }
    }
    func sourceGain(_ k: Int) -> Double { project.gain(ofSource: k, media: shownMedia) }
    /// Live value while a slider/field is dragged (no undo step); `commitSourceGain` records ONE undo step for the gesture.
    @Published var liveGains: [Int: Double] = [:]
    func displayGain(_ k: Int) -> Double { liveGains[k] ?? sourceGain(k) }
    func liveSourceGain(_ k: Int, _ dB: Double) {
        liveGains[k] = dB
        var p = project; var r = p.recording(shownMedia); r.gains[k] = dB == 0 ? nil : dB; p.recordings[shownMedia] = r.isEmpty ? nil : r
        player.currentItem?.audioMix = built?.audioMix(for: p)          // hear it while dragging; nothing is saved yet
    }
    func commitSourceGain(_ k: Int) { let m = shownMedia; let v = liveGains[k] ?? sourceGain(k); liveGains[k] = nil; apply(reload: false) { $0.setSourceGain(k, dB: v, media: m) } }
    func resetSourceGain(_ k: Int) { let m = shownMedia; liveGains[k] = nil; apply(reload: false) { $0.setSourceGain(k, dB: 0, media: m) } }
    /// CONSERVATIVE ESTIMATE (upper bound) of the mixed peak: Σ (true peak of each unmuted source / A2 item × its gain).
    /// The real mix can be lower (peaks rarely coincide); above 1 (0 dBFS) clipping is POSSIBLE. Nothing is limited automatically.
    var estimatedMixPeakDB: Double? {
        guard !project.clips.isEmpty else { return nil }
        // A1: only one main clip sounds at a time (two while a dissolve overlaps), so the bound is the LOUDEST recording used by the montage, not the first one and not their sum.
        var perRecording: [Double] = []
        for mediaPath in estimatedPeakRecordings {
            guard let pk0 = media[mediaPath]?.sourcePeak, !pk0.isEmpty else { return nil }
            if project.mutedLanes.contains(.a1) { perRecording.append(0); continue }
            guard let pk = processedPeaks(mediaPath, pk0) else { return nil }
            perRecording.append(pk.enumerated().reduce(0.0) { acc, e in project.isMuted(source: e.offset, media: mediaPath) ? acc : acc + Double(e.element) * Double(SadrogProject.linear(dB: mediaPath == shownMedia ? displayGain(e.offset) : project.gain(ofSource: e.offset, media: mediaPath))) })
        }
        let a1Auto = Double(SadrogProject.linear(dB: project.clips.map { audioEdit($0.id).automationPeakDB }.max() ?? 0))
        perRecording = perRecording.map { $0 * a1Auto }
        var a2 = 0.0
        if !project.mutedLanes.contains(.a2) {           // A2 items may overlap A1 anywhere: added to the bound (conservative)
            for l in project.layers where l.kind == .audio {
                let e = audioEdit(l.id); if e.muted { continue }
                let raw = media[l.media]?.sourcePeak ?? []
                guard let pk = processedPeaks(l.media, raw) else { return nil }
                a2 += Double(pk.reduce(0, +)) * Double(SadrogProject.linear(dB: e.gainDB + e.automationPeakDB))      // automation can only raise the bound
            }
        }
        let sum = MixPeakBound.linear(perRecording: perRecording, dissolves: project.clips.contains { $0.dissolve > 0 }, layers: a2, masterLinear: Double(SadrogProject.linear(dB: liveMaster ?? project.masterGainDB)))
        return sum > 0 ? 20 * log10(sum) : nil
    }
    /// A source with effects is estimated from its PROCESSED file (effects change the level); nil while it is still processing.
    private func processedPeaks(_ mediaPath: String, _ pk0: [Float]) -> [Float]? {
        var pk = pk0
        for k in pk.indices where !project.activeEffects(ofSource: k, media: mediaPath).isEmpty {
            guard let u = fxPlan.ready[EffectRenderer.slot(mediaPath, k)], let v = fxPeaks[u.path] else { return nil }
            pk[k] = v
        }
        return pk
    }
    /// Distinct recordings the montage plays on A1 (in order of first use); the estimate covers all of them.
    var estimatedPeakRecordings: [String] { var seen = Set<String>(); return project.clips.map(\.media).filter { seen.insert($0).inserted } }
    func toggleSource(_ k: Int) { let on = !isSourceMuted(k), m = shownMedia; apply(reload: false) { $0.setSourceMuted(k, on, media: m) } }
    func rename(_ name: String) { apply(reload: false) { $0.rename(name) } }
    /// The configured capture settings of the SADROG session this project lives in (nil for documents and external material).
    lazy var captureSetting: DocumentFormat? = (try? SessionJournal.read(from: folder)).flatMap { j in j.fps > 0 && j.width > 0 ? DocumentFormat(width: j.width, height: j.height, fps: Double(j.fps)) : nil }
    /// Document size/frame rate (one undo step); rebuilds the composition so preview and export use the new canvas.
    func setCanvas(_ f: DocumentFormat?) { apply { $0.setCanvas(f) } }
    /// What the canvas is now: the document format, or the first source when none is set (legacy projects).
    var canvasDescription: String {
        if let c = project.canvas { return "\(c.width)×\(c.height) · \(c.aspect) · \(c.fps.formatted(.number.precision(.fractionLength(0...2)))) cadre/s" }
        return L10n.f("ca sursa: %@×%@ · %@ cadre/s", "\(Int(renderSize.width))", "\(Int(renderSize.height))", "\(fps.formatted(.number.precision(.fractionLength(0...2))))")
    }

    // MARK: viewer zoom ("Potrivire" and magnification; independent of the clip's own transform)
    var stageArea: CGRect { CGRect(origin: .zero, size: stageSize).insetBy(dx: Theme.S.md, dy: Theme.S.md) }
    var viewerFrame: CGRect { ViewerFrame.frame(render: renderSize, area: stageArea, zoom: viewZoom, pan: viewPan) }
    var displayedZoom: Double { ViewerFrame.displayedZoom(render: renderSize, area: stageArea, zoom: viewZoom) }
    func fitView() { viewZoom = nil; viewPan = .zero }
    func setViewZoom(_ z: Double) { viewZoom = max(0.1, min(8, z)); viewPan = ViewerFrame.clampedPan(viewPan, frame: CGSize(width: renderSize.width * (viewZoom ?? 1), height: renderSize.height * (viewZoom ?? 1)), area: stageArea.size) }
    func stepView(_ up: Bool) {
        let cur = displayedZoom, steps = ViewerFrame.steps
        if up { setViewZoom(steps.first { $0 > cur * 1.01 } ?? steps.last!) } else { setViewZoom(steps.last { $0 < cur / 1.01 } ?? steps.first!) }
    }
    func panView(dx: CGFloat, dy: CGFloat) {
        let f = viewerFrame.size; guard f.width > stageArea.width + 0.5 || f.height > stageArea.height + 0.5 else { return }
        viewPan = ViewerFrame.clampedPan(CGSize(width: viewPan.width + dx, height: viewPan.height + dy), frame: f, area: stageArea.size)
    }

    func undo() { apply { _ in _ = self.editor.undo() } }
    func redo() { apply { _ in _ = self.editor.redo() } }
    func trimStartToPlayhead() {
        guard let s = selection else { return }
        guard selectedClip != nil else { return }; let start = selectedStart; apply { $0.trimStart(clip: s, by: self.time - start) }
    }
    func trimEndToPlayhead() {
        guard let s = selection, selectedClip != nil else { return }
        let end = selectedStart + (selectedClip?.duration ?? 0); apply { $0.trimEnd(clip: s, by: end - self.time) }
    }

    // MARK: export
    func openExport() { exportState = .idle; deliveredFiles = []; showExport = true }
    func startExport() {
        guard exportTask == nil else { return }
        guard ActivationModel.shared.allowsRecordAndExport else { exportState = .failed(ActivationModel.shared.blockedText); return }
        let name = exportName.trimmingCharacters(in: .whitespaces).isEmpty ? "SADROG-export" : exportName.trimmingCharacters(in: .whitespaces)
        let st = exportSettings, pl = ExportPlan.video(project, documentSize: renderSize, documentFPS: fps, settings: st, copyPossible: reencodeReason == nil)
        let url = exportFolder.appendingPathComponent(pl.fileExtension.isEmpty ? name : name + "." + pl.fileExtension); let p = project; let rng = st.onlyRange ? p.exportRange : nil; let fx = fxPlan; let docSize = renderSize, docFPS = fps
        exportState = .running(0)
        exportTask = Task {
            do {
                if FileManager.default.fileExists(atPath: url.path) { throw CocoaError(.fileWriteFileExists) }
                try Destination(url: self.exportFolder).validate(requiredBytes: 500_000_000)      // the folder the file is written to, not the project folder
                try await ProjectExporter.export(p, to: url, settings: st, documentSize: docSize, documentFPS: docFPS, effects: fx, range: rng) { f in Task { @MainActor in if case .running = self.exportState { self.exportState = .running(f) } } }
                try Task.checkCancellation()
                var size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { size = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: url.appendingPathComponent($1).path)[.size] as? Int64) ?? 0) } }
                guard size > 0 else { throw CocoaError(.fileWriteUnknown) }
                exportState = .done(url, size)
            } catch is CancellationError { exportState = .cancelled }      // the core removes only its own temporary item
            catch let e as CocoaError where e.code == .fileWriteFileExists { exportState = .failed(T("Există deja un fișier cu acest nume. Alege alt nume.")) }
            catch { DiagnosticLog("export").error("export refused or failed: \(error.localizedDescription)"); exportState = .failed(error.localizedDescription) }
            exportTask = nil
        }
    }
    /// Project + media archive into the export folder (a copy; originals untouched, nothing overwritten, whole or not at all). Not gated by activation: it is a backup of the user's own work.
    func startArchive() {
        guard exportTask == nil else { return }
        let p = project, parent = exportFolder, name = exportName.trimmingCharacters(in: .whitespaces)
        exportState = .running(0)
        exportTask = Task.detached { [weak self] in
            do {
                let r = try ProjectArchive.create(p, in: parent, named: name.isEmpty ? nil : name) { f in Task { @MainActor in if case .running = self?.exportState { self?.exportState = .running(f) } } }
                await MainActor.run { self?.exportState = .done(r.folder, r.bytes); self?.archiveMissing = r.missing.count; self?.exportTask = nil }
            } catch is CancellationError { await MainActor.run { self?.exportState = .cancelled; self?.exportTask = nil }
            } catch let e as ProjectArchive.ArchiveError {
                let text: String
                switch e { case .exists: text = T("Există deja o arhivă cu acest nume. Alege alt nume."); case .noSpace: text = T("Nu este destul spațiu liber pentru arhivă."); case .missing(let l): text = L10n.f("%@ fișiere lipsesc și nu pot fi arhivate.", "\(l.count)") + " " + T("Arhiva nu a fost creată.") }
                await MainActor.run { self?.exportState = .failed(text); self?.exportTask = nil }
            } catch { await MainActor.run { self?.exportState = .failed(error.localizedDescription); self?.exportTask = nil } }
        }
    }
    @Published var archiveMissing = 0
    func cancelExport() { exportTask?.cancel() }
}

extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
