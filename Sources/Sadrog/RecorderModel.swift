// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import Carbon.HIToolbox
import AVFoundation
import SadrogCore

/// Thread-safe peak store: audio callbacks write, a 15 Hz UI timer reads (no main-actor hop per buffer).
final class LevelBox: @unchecked Sendable {
    private var v: [String: Float] = [:]; private let l = NSLock()
    func set(_ id: String, _ p: Float) { l.lock(); v[id] = max(v[id] ?? 0, p); l.unlock() }
    func take() -> [String: Float] { l.lock(); defer { l.unlock() }; let r = v; v = [:]; return r }
}

enum RecPhase: Equatable { case idle, preparing, countdown(Int), starting, recording, paused, stopping }

/// An additional screen row (display or window); its own file at recording time.
struct ExtraScreenRow: Identifiable, Equatable { var id = UUID().uuidString; var mode: VideoMode = .display; var sourceID: UInt32?; var enabled = true }
/// A camera row; its own file at recording time.
struct CameraRow: Identifiable, Equatable { var id = UUID().uuidString; var uid: String?; var enabled = true; var format: CameraFormatOption? }

@MainActor
final class RecorderModel: ObservableObject {
    // sources
    @Published var sources: [SourceInfo] = []
    @Published var devices: [AvailableDevice] = []
    @Published var cameras: [CameraSpec] = []
    /// The camera recorded with the screen (own file, same clock). Off at every launch: a camera is used only when chosen here.
    /// Additional screens and cameras (off at every launch: nothing is chosen, nothing starts by itself).
    @Published var extraScreens: [ExtraScreenRow] = []
    @Published var cameraRows: [CameraRow] = []
    @Published var preparingCameras = false
    @Published var cameraAuth = AVCaptureDevice.authorizationStatus(for: .video)
    @Published var micAuth = AudioInputCapture.authorization
    /// Switching mode refreshes the source list: windows opened after launch (or since the last listing) appear without restarting the app.
    @Published var mode: VideoMode = .display { didSet { if oldValue != mode { previewOn = false; regionSpec = nil; if phase == .idle { Task { await refresh() } } } } }
    /// Choosing a monitor/window identifies it briefly (the same temporary red frame as the identify button); nothing records.
    @Published var displayID: UInt32? { didSet {
        guard displayID != oldValue, let id = displayID else { return }
        if let n = sources.first(where: { $0.id == id && $0.kind == .display })?.title { UserDefaults.standard.set(n, forKey: "lastDisplayName") }
        restoredDisplay = restoring
        if !restoring, mode != .window { identify("alegere monitor") }
    } }
    private var restoring = false
    /// The monitor shown was restored from the last session (not chosen now) — said in the UI until the user picks one.
    @Published var restoredDisplay = false
    @Published var windowID: UInt32? { didSet { if windowID != oldValue, windowID != nil, mode == .window { identify("alegere fereastră") } } }
    @Published var regionSpec: RegionSpec?
    @Published var outCap: OutCap = .source
    enum OutCap: String, CaseIterable { case source, panel, hd }
    var maxLong: Int? { switch outCap { case .source: return nil; case .hd: return 1920; case .panel: return selectedSource.map { max($0.panelWidth, $0.panelHeight) }.flatMap { $0 > 0 ? $0 : nil } } }
    @Published var audio: [AudioSourceSpec] = []
    @Published var monitoring: Set<String> = []
    @Published var levels: [String: Float] = [:]
    /// What the audio meters show: held digital peak (dBFS) and the clipping flag, per source (see AudioLevelMath).
    @Published var readings: [String: MeterReading] = [:]
    @Published var lost: [String: String] = [:]
    @Published var previewOn = false { didSet { previewChanged() } }
    @Published var previewImage: NSImage?
    /// The still preview could not get a picture (permission, source gone): said in the popover instead of an endless spinner.
    @Published var previewFailed = false
    @Published var countdownSeconds = UserDefaults.standard.object(forKey: "countdown") as? Int ?? 3 { didSet { UserDefaults.standard.set(countdownSeconds, forKey: "countdown") } }
    // state
    @Published var phase: RecPhase = .idle { didSet { if phase != .idle { stopAllCameraPreviews() } } }   // the recording opens the cameras itself: a preview never competes with it
    @Published var destination: URL? = UserDefaults.standard.string(forKey: "destination").map { URL(fileURLWithPath: $0) }
    @Published var elapsed: TimeInterval = 0
    @Published var message = ""
    @Published var freeGB: Double?
    @Published var hasPermission = ScreenCapturer.hasPermission()
    @Published var unfinished: [SessionJournal] = []
    @Published var editable: [(folder: URL, journal: SessionJournal)] = []
    /// Edit documents created without a recording (folders holding only project.sadrogproj), newest first.
    @Published var documents: [(folder: URL, name: String, date: Date)] = []
    @Published var editor: EditorModel?
    /// "Add recording…" from the editor: the project stays parked here (saved, selection and playhead intact) while the capture page is shown; the next finished session
    /// joins THAT project. Cancelling returns to it unchanged; a failed or empty capture leaves it as it was.
    struct AddTarget { let editor: EditorModel; let since: Date }
    @Published var addTarget: AddTarget?
    /// A recording that just ended outside "Add recording…": the user chooses where it goes (new document, existing project, or just keep it in Recent). Nothing is deleted by any choice.
    struct FinishedRecording { let folder: URL; let journal: SessionJournal; let duration: Double }
    @Published var finished: FinishedRecording?
    @Published var finishName = ""
    /// Start page the next StartView should show (File ▸ New document).
    @Published var requestedPage: String?
    func requestNewDocument() { guard phase == .idle else { return }; leaveContext(); addTarget = nil; requestedPage = "document"; editor = nil }
    @Published var started: ScreenCapturer.Started?
    var recording: Bool { phase == .recording }

    private let capturer = ScreenCapturer()
    /// The pointer path is read ONLY while a recording runs and ONLY when the user turned `sadrog.collectMouse` on (off by default): position and button, never keys.
    private var mouseRecorder: MouseRecorder?
    private var keyRecorder: KeyRecorder?, keyMonitor: Any?
    private var windowRecorder: WindowRecorder?
    static let collectWindowKey = "sadrog.collectWindow"
    static let collectMouseKey = "sadrog.collectMouse"
    static let collectKeysKey = "sadrog.collectKeys"
    private let levelBox = LevelBox()
    private var timer: Timer?, meterTimer: Timer?
    private var startedAt = Date()
    private var monitors: [String: AudioInputCapture] = [:]
    private var systemMonitor: SystemAudioMonitor?
    private var previewTask: Task<Void, Never>?
    private var probeObserver: NSObjectProtocol?
    private let picker = RegionPicker()

    // MARK: derived
    var video: VideoSourceSpec? {
        switch mode {
        case .display: return displayID.flatMap { id in sources.first { $0.id == id && $0.kind == .display } }.map { VideoSourceSpec(mode: .display, sourceID: $0.id, title: $0.title, maxLongSide: maxLong) }
        case .region: return displayID.flatMap { id in sources.first { $0.id == id && $0.kind == .display } }.map { VideoSourceSpec(mode: .region, sourceID: $0.id, title: $0.title, region: regionSpec, maxLongSide: maxLong) }
        case .window: return windowID.flatMap { id in sources.first { $0.id == id && $0.kind == .window } }.map { VideoSourceSpec(mode: .window, sourceID: $0.id, title: $0.title, maxLongSide: maxLong) }
        }
    }
    var extraVideoSpecs: [VideoSourceSpec] {
        extraScreens.filter(\.enabled).compactMap { r in
            guard let id = r.sourceID, let s = sources.first(where: { $0.id == id && $0.kind == (r.mode == .window ? .window : .display) }) else { return nil }
            return VideoSourceSpec(id: r.id, mode: r.mode, sourceID: id, title: s.title, maxLongSide: maxLong)
        }
    }
    var cameraSpecs: [CameraSpec] { cameraRows.filter(\.enabled).compactMap { r in r.uid.map { u in CameraSpec(uid: u, name: cameras.first { $0.uid == u }?.name ?? T("Cameră"), format: r.format) } } }
    var config: CaptureConfig { CaptureConfig(video: video, extraVideos: extraVideoSpecs, audio: audio, cameras: cameraSpecs) }
    /// An enabled row without a chosen source blocks the start (a source is never guessed).
    var rowIssue: String? {
        if extraScreens.contains(where: { $0.enabled && $0.sourceID == nil }) { return T("Alege monitorul sau fereastra pentru fiecare sursă adăugată (sau dezactiveaz-o).") }
        if cameraRows.contains(where: { $0.enabled && $0.uid == nil }) { return T("Alege camera pentru fiecare rând de cameră (sau dezactivează-l).") }
        return nil
    }
    func addExtraScreen(_ mode: VideoMode) { extraScreens.append(ExtraScreenRow(mode: mode)) }
    func removeExtraScreen(_ id: String) { extraScreens.removeAll { $0.id == id } }
    func addCameraRow() { cameraRows.append(CameraRow()) }
    func removeCameraRow(_ id: String) { stopCameraPreview(id); cameraRows.removeAll { $0.id == id } }
    /// Choosing a camera is the explicit action that asks macOS for camera access (once); nothing asks for it at launch.
    func setCamera(_ rowID: String, _ uid: String?) async {
        guard let i = cameraRows.firstIndex(where: { $0.id == rowID }) else { return }
        stopCameraPreview(rowID)
        cameraRows[i].uid = uid; cameraRows[i].format = nil      // another camera: its own modes
        if uid != nil, CameraCapture.authorization == .notDetermined { _ = await CameraCapture.requestAccess() }
        cameraAuth = CameraCapture.authorization
    }
    func setCameraFormat(_ rowID: String, _ f: CameraFormatOption?) {
        guard let i = cameraRows.firstIndex(where: { $0.id == rowID }) else { return }
        cameraRows[i].format = f
        if cameraPreviews[rowID]?.isRunning == true { stopCameraPreview(rowID); Task { await toggleCameraPreview(rowID) } }    // the preview shows the mode that was just chosen
    }
    // MARK: camera preview on request (no recording, no file; released when stopped, when leaving the page or when a recording starts)
    @Published var cameraPreviews: [String: CameraPreviewState] = [:]
    private var previewSessions: [String: CameraPreviewSession] = [:]
    func cameraPreviewSession(_ rowID: String) -> AVCaptureSession? { previewSessions[rowID]?.session }
    func toggleCameraPreview(_ rowID: String) async {
        if cameraPreviews[rowID]?.isRunning == true { stopCameraPreview(rowID); return }
        guard phase == .idle, let row = cameraRows.first(where: { $0.id == rowID }), let uid = row.uid else { return }
        cameraAuth = CameraCapture.authorization
        if let blocked = CameraPreviewState.gate(auth: cameraAuth, present: cameras.contains { $0.uid == uid }) { cameraPreviews[rowID] = blocked; return }
        cameraPreviews[rowID] = .loading
        if cameraAuth == .notDetermined {      // the user asked for the preview: this is the moment macOS asks
            _ = await CameraCapture.requestAccess(); cameraAuth = CameraCapture.authorization
            if let blocked = CameraPreviewState.gate(auth: cameraAuth, present: true) { cameraPreviews[rowID] = blocked; return }
        }
        guard cameraPreviews[rowID] == .loading, phase == .idle else { return }      // cancelled while the question was open
        do {
            let p = try CameraPreviewSession(uid: uid, format: row.format)
            p.onState = { [weak self] st in Task { @MainActor in self?.cameraPreviewReported(rowID, st) } }
            previewSessions[rowID] = p; p.start()
        } catch { cameraPreviews[rowID] = .failed(error.localizedDescription); DiagnosticLog("camera-preview").error("nu pornește: \(error.localizedDescription)") }
    }
    private func cameraPreviewReported(_ rowID: String, _ st: CameraPreviewState) {
        guard previewSessions[rowID] != nil else { return }
        cameraPreviews[rowID] = st
        if case .failed = st { releasePreview(rowID) } else if st == .absent { releasePreview(rowID) }
    }
    private func releasePreview(_ rowID: String) { let p = previewSessions.removeValue(forKey: rowID); p?.stop() }
    func stopCameraPreview(_ rowID: String) { releasePreview(rowID); cameraPreviews[rowID] = nil }
    func stopAllCameraPreviews() { for k in Array(previewSessions.keys) { releasePreview(k) }; cameraPreviews = [:] }
    /// The camera's REAL current format (size and maximum frame rate), read from the device without starting it.
    func cameraFormat(_ uid: String) -> String? {
        guard let d = AVCaptureDevice(uniqueID: uid) else { return nil }
        let dim = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
        let fps = d.activeFormat.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 0
        return "\(dim.width)×\(dim.height) · \(Int(fps.rounded())) \(T("cadre/s"))"
    }
    // MARK: pause
    private var pausedAt: Date?
    private var probePauseDone = false
    private var probePauseUntil: Date?
    private var pausedTotal: TimeInterval = 0
    var isPaused: Bool { phase == .paused }
    func togglePause() { flow.togglePause() }
    var displays: [SourceInfo] { sources.filter { $0.kind == .display } }
    var windows: [SourceInfo] { sources.filter { $0.kind == .window } }
    var selectedSource: SourceInfo? { let id = mode == .window ? windowID : displayID; return sources.first { $0.id == id && $0.kind == (mode == .window ? .window : .display) } }
    var issues: [CaptureIssue] { CaptureValidator.check(config, sources: sources, devices: devices, cameras: cameras.map(\.uid), cameraAllowed: cameraAuth == .authorized) }
    /// Source pixels and output pixels (shown separately when they differ).
    var sizes: (src: (w: Int, h: Int), out: (w: Int, h: Int))? {
        guard let s = selectedSource else { return nil }
        var src = s.pixels
        if mode == .region, let r = regionSpec, r.isValid { let p = RegionMath.pixels(points: RegionMath.sourceRect(r, displayPoints: CGSize(width: s.pointsWidth, height: s.pointsHeight)).size, scale: s.scale); src = (p.w, p.h) }
        return (src, RegionMath.output(source: src, maxLongSide: maxLong))
    }
    var canRecord: Bool { phase == .idle && readyToRecord }
    private var readyToRecord: Bool { ActivationModel.shared.allowsRecordAndExport && destination != nil && hasPermission && issues.isEmpty && rowIssue == nil && !config.activeAudio.contains { lost[$0.id] != nil } }
    var blocker: String? {
        if destination == nil { return T("Alege destinația.") }
        if !hasPermission { return T("Acordă permisiunea pentru înregistrarea ecranului.") }
        if !ActivationModel.shared.allowsRecordAndExport { return ActivationModel.shared.blockedText }
        return issues.first?.text ?? rowIssue
    }

    // MARK: refresh / permissions
    func refresh() async {
        hasPermission = simulatedCapture || ScreenCapturer.hasPermission(); micAuth = AudioInputCapture.authorization; cameraAuth = AVCaptureDevice.authorizationStatus(for: .video)
        updateDestination()
        devices = AudioDevices.inputs()
        cameras = CameraCapture.list()
        if simulatedCapture {          // development only: one synthetic display, nothing of the real screen is read
            sources = [SourceInfo(id: 9_000_001, kind: .display, title: "Display simulat", width: 1280, height: 720, pointsWidth: 1280, pointsHeight: 720, scale: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 720))]
            if displayID == nil { restoring = true; displayID = 9_000_001; restoring = false }
            // verification only (never reachable without the simulated capture): a camera row already bound to the first listed camera, so the row can be shown without asking macOS for camera access
            if ProcessInfo.processInfo.environment["SADROG_VERIFY_CAMERA_ROW"] == "1", cameraRows.isEmpty, let c = cameras.first { cameraRows = [CameraRow(uid: c.uid)] }
            if ProcessInfo.processInfo.environment["SADROG_VERIFY_CAMERA_ROW"] == "absent" { cameraRows = [CameraRow(uid: "unplugged-camera")] }
        } else if hasPermission {
            do { sources = try await ScreenCapturer.listSources() } catch { message = L10n.f("Nu pot lista sursele: %@", "\(error.localizedDescription)") }
        }
        // the last monitor chosen (by name) is selected again, quietly: restoring is not choosing, so no identification frame
        if displayID == nil, let n = UserDefaults.standard.string(forKey: "lastDisplayName"), let d = sources.first(where: { $0.kind == .display && $0.title == n }) { restoring = true; displayID = d.id; restoring = false }
        // a vanished source stays selected-but-missing (visible issue); it is never replaced by another one
        for a in audio where a.kind == .input && !devices.contains(where: { $0.uid == a.deviceUID }) { lost[a.id] = "dispozitiv indisponibil" }
    }

    func requestPermission() {
        if !ScreenCapturer.requestPermission() { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }
    }

    // MARK: sources
    func addSystemAudio() { guard !audio.contains(where: { $0.kind == .system }) else { return }; audio.append(AudioSourceSpec(kind: .system, deviceName: "Sunetul calculatorului")) }
    func addInput(_ d: AvailableDevice) {
        // channel choice is explicit; a mono device gets channel 1, a multichannel one starts with 1–2 and the user adjusts
        audio.append(AudioSourceSpec(kind: .input, deviceUID: d.uid, deviceName: d.name, channels: d.inputChannels == 1 ? [1] : [1, 2]))
    }
    /// One mono row per channel (separate tracks for editing); each row is still individually switchable.
    func addInputSplit(_ d: AvailableDevice) {
        for c in 1...d.inputChannels { audio.append(AudioSourceSpec(kind: .input, deviceUID: d.uid, deviceName: "\(d.name) · canal \(c)", channels: [c])) }
    }
    func remove(_ id: String) { stopMonitor(id); audio.removeAll { $0.id == id }; lost[id] = nil; levels[id] = nil }
    func toggleChannel(_ id: String, _ ch: Int) {
        guard let i = audio.firstIndex(where: { $0.id == id }) else { return }
        var c = audio[i].channels; if let k = c.firstIndex(of: ch) { c.remove(at: k) } else { c.append(ch) }
        audio[i].channels = c.sorted()
        if monitoring.contains(id) { stopMonitor(id); Task { await startMonitor(id) } }
    }
    func setEnabled(_ id: String, _ on: Bool) { guard let i = audio.firstIndex(where: { $0.id == id }) else { return }; audio[i].enabled = on; if !on { stopMonitor(id) } }

    /// Temporary identification only (2 s). Never while counting down or recording; an unknown frame draws nothing rather than a wrong place.
    func identify(_ why: String = "buton") { guard phase == .idle, let s = selectedSource, s.frame != .zero else { return }; RedFrame.shared.show(globalFrame: s.frame, reason: "\(why) phase=\(phase)") }
    /// Pointer over a row of the monitor/window list: its red frame shows WHICH one it is before it is chosen (nothing records, nothing is selected).
    /// nil = the pointer left the list. Never while counting down or recording; an unknown frame draws nothing rather than a wrong place.
    func previewCandidate(_ id: UInt32?, window: Bool? = nil) {
        guard let id, phase == .idle else { RedFrame.shared.close(); return }
        let list = (window ?? (mode == .window)) ? windows : displays
        guard let s = list.first(where: { $0.id == id }), s.frame != .zero else { RedFrame.shared.close(); return }
        RedFrame.shared.show(globalFrame: s.frame, seconds: 6, reason: "pointer pe listă phase=\(phase)")
    }
    /// Leaves the capture context (editor, window closed): no identification frame, no preview stream, no level meters keep running.
    func leaveContext() { RedFrame.shared.close(); previewOn = false; stopAllMonitors(); stopAllCameraPreviews() }
    func identifyWindowFrame() { identify() }

    func drawRegion() {
        guard let d = displays.first(where: { $0.id == displayID }) else { message = T("Alege întâi monitorul."); return }
        picker.pick(on: d) { [weak self] rect in
            guard let self else { return }
            NSApp.windows.first { $0.title == "SADROG" }?.makeKeyAndOrderFront(nil)
            if let rect, let r = RegionMath.region(rect: rect, displayPoints: CGSize(width: d.pointsWidth, height: d.pointsHeight)) { self.regionSpec = r } else { self.message = T("Regiune anulată sau prea mică (minim 16×16 pt).") }
        }
    }

    // MARK: eye preview (single stills at ~1.4 fps, nothing recorded)
    private func previewChanged() {
        previewTask?.cancel(); previewTask = nil
        guard previewOn else { previewImage = nil; previewFailed = false; return }
        previewTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let s = self.selectedSource else { break }
                if let img = await ScreenCapturer.snapshot(source: s, region: self.mode == .region ? self.regionSpec : nil) { self.previewImage = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height)); self.previewFailed = false } else { self.previewFailed = true }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
    }

    // MARK: level monitoring (real audio; no playback, so no feedback)
    func toggleMonitor(_ id: String) { if monitoring.contains(id) { stopMonitor(id) } else { Task { await startMonitor(id) } } }
    private func startMonitor(_ id: String) async {
        guard phase == .idle, let a = audio.first(where: { $0.id == id }) else { return }
        ensureMeterTimer()
        if a.kind == .system {
            let m = SystemAudioMonitor(); m.onLevel = { [levelBox] p in levelBox.set(id, p) }
            do { try await m.start(); systemMonitor = m; monitoring.insert(id) } catch { message = "Nivelul sunetului calculatorului: \(error.localizedDescription)" }
            return
        }
        if AudioInputCapture.authorization == .notDetermined { _ = await AudioInputCapture.requestAccess() }
        micAuth = AudioInputCapture.authorization
        do {
            let c = try AudioInputCapture(spec: a)
            c.onLevel = { [levelBox] p in levelBox.set(id, p) }
            c.onLost = { [weak self] why in Task { @MainActor in self?.lost[id] = why; self?.stopMonitor(id) } }
            try c.start(); monitors[id] = c; monitoring.insert(id); lost[id] = nil
        } catch { lost[id] = error.localizedDescription; message = error.localizedDescription }
    }
    func stopMonitor(_ id: String) {
        monitors[id]?.stop(); monitors[id] = nil
        if audio.first(where: { $0.id == id })?.kind == .system { let m = systemMonitor; systemMonitor = nil; Task { await m?.stop() } }
        monitoring.remove(id); levels[id] = 0; readings[id] = nil
    }
    func clearClip(_ id: String) { readings[id]?.clearClip() }
    func stopAllMonitors() { for id in monitoring { stopMonitor(id) } }
    private func ensureMeterTimer() {
        guard meterTimer == nil else { return }
        meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let fresh = self.levelBox.take()
                for k in self.monitoring.union(Set(fresh.keys)) { var r = self.readings[k] ?? MeterReading(); r.update(peak: fresh[k] ?? 0); self.readings[k] = r }
                for (k, r) in self.readings where r.heldPeak == 0 && !r.clipped && !self.monitoring.contains(k) && fresh[k] == nil { self.readings[k] = nil }
                for (k, p) in fresh { self.levels[k] = max(p, (self.levels[k] ?? 0) * 0.8) }
                for k in self.levels.keys where fresh[k] == nil { self.levels[k] = (self.levels[k] ?? 0) * 0.8 }
            }
        }
    }

    // MARK: destination / recovery (unchanged behaviour)
    func updateDestination() {
        guard let d = destination else { freeGB = nil; unfinished = []; return }
        freeGB = (try? Destination(url: d).availableBytes()).map { Double($0) / 1e9 }
        let active = recording ? capturer.writer?.journal.id : nil
        let hidden = recentExcluded
        editable = SessionJournal.editable(under: d).filter { !hidden.contains($0.folder.path) }
        let fm = FileManager.default
        documents = ((try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { !hidden.contains($0.path) }
            .filter { fm.fileExists(atPath: $0.appendingPathComponent("project.sadrogproj").path) && !fm.fileExists(atPath: $0.appendingPathComponent("session.json").path) }
            .compactMap { u in (try? ProjectStore.load(from: u.appendingPathComponent("project.sadrogproj"))).map { (u, $0.name, (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) } }
            .sorted { $0.date > $1.date }
        unfinished = SessionJournal.unfinished(under: d).map(\.journal).filter { $0.id != active }
    }
    // MARK: Recent list management (never touches the files)
    private static let excludedKey = "recent.excluded"
    /// Folders the user removed from Recent; the scan skips them so they do not come back at the next refresh.
    var recentExcluded: Set<String> { Set(UserDefaults.standard.stringArray(forKey: Self.excludedKey) ?? []) }
    func removeFromRecent(_ folder: URL) {
        var set = recentExcluded; set.insert(folder.path)
        UserDefaults.standard.set(Array(set).sorted(), forKey: Self.excludedKey)
        updateDestination()
    }
    /// The user points at where a missing document went; a folder that really holds a project is opened (the Recent entry is rebuilt by the next scan).
    func relocateDocument(missing: URL) async {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = T("Alege")
        p.message = L10n.f("Alege folderul în care se află acum «%@» (cel care conține project.sadrogproj)", missing.lastPathComponent)
        guard p.runModal() == .OK, let u = p.url else { return }
        guard FileManager.default.fileExists(atPath: u.appendingPathComponent("project.sadrogproj").path) else { message = T("Folderul ales nu conține un proiect SADROG (project.sadrogproj)."); return }
        await openDocument(u)
    }
    /// Shows the exact item in Finder; a missing one reveals the nearest existing parent and says so.
    @discardableResult func revealInFinder(_ item: URL) -> Bool {
        if FileManager.default.fileExists(atPath: item.path) { NSWorkspace.shared.activateFileViewerSelecting([item]); return true }
        var p = item.deletingLastPathComponent()
        while !FileManager.default.fileExists(atPath: p.path), p.path != "/" { p = p.deletingLastPathComponent() }
        NSWorkspace.shared.open(p); message = L10n.f("«%@» lipsește de pe disc, deci NU l-am putut arăta. Am deschis doar folderul existent %@. Folosește «Localizează…» ca să-l găsești.", item.lastPathComponent, p.path); return false
    }
    func chooseDestination() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        p.prompt = "Alege"; p.message = T("Alege folderul în care se salvează înregistrările")
        if p.runModal() == .OK, let u = p.url { destination = u; UserDefaults.standard.set(u.path, forKey: "destination"); updateDestination() }
    }

    // MARK: record
    /// The Record button's state machine (preparing → countdown → starting → recording), tested with a simulated capturer in SadrogCore.
    /// Only its `startCapture` step touches the real capturer; a cancel invalidates every pending step, so nothing starts late.
    private lazy var flow: RecordFlow = {
        let f = RecordFlow(countdownSeconds: countdownSeconds,
            prepare: { [weak self] in
                guard let self else { return "" }
                guard self.readyToRecord else { return self.blocker ?? "" }
                await self.refresh()                     // validate against a fresh listing; never substitute another source/device
                if let i = self.issues.first { return i.text }
                if let r = self.rowIssue { return r }
                self.stopAllMonitors(); self.previewOn = false
                // cameras: started now and checked (frames + exposure settled) BEFORE the countdown; a camera that is not ready blocks the start
                let cams = self.config.cameras
                if !cams.isEmpty {
                    self.preparingCameras = true; self.message = cams.count == 1 ? T("Se pregătește camera…") : T("Se pregătesc camerele…")
                    let b = await self.capturer.prepareCameras(cams)
                    self.preparingCameras = false
                    if let b { return b }
                    self.message = ""
                }
                return nil
            },
            startCapture: { [weak self] in try await self?.startCapture() },
            stopCapture: { [weak self] cause, request in await self?.stopCapture(cause: cause, request: request) },
            closeIdentification: { RedFrame.shared.close() })
        f.onPhase = { [weak self, weak f] p in
            guard let self else { return }
            let was = self.phase
            defer { if p == .idle, was != .idle { if self.addTarget != nil { Task { await self.completeAddRecording() } } else { Task { await self.presentFinished() } } } }
            switch p { case .idle: self.phase = .idle; case .preparing: self.phase = .preparing; case .countdown(let n): self.phase = .countdown(n)
                       case .starting: self.phase = .starting; case .recording: self.phase = .recording; case .paused: self.phase = .paused; case .stopping: self.phase = .stopping }
            ControlPanel.shared.update(for: self)
            self.syncCountdownAndWindow(p)
            if let m = f?.message, !m.isEmpty { self.message = m }
        }
        f.onStartAbandoned = { [weak self] in self?.capturer.releasePreparedCameras(); self?.preparingCameras = false }
        f.pauseCapture = { [weak self] in self?.mouseRecorder?.pause(); self?.keyRecorder?.pause(); self?.windowRecorder?.pause(); self?.capturer.pause(); self?.pausedAt = Date() }
        f.resumeCapture = { [weak self] in
            guard let self else { return }
            self.mouseRecorder?.resume(); self.keyRecorder?.resume(); self.windowRecorder?.resume(); self.capturer.resume(); if let p = self.pausedAt { self.pausedTotal += Date().timeIntervalSince(p) }; self.pausedAt = nil
        }
        return f
    }()

    func toggle() async {
        if phase == .idle { flow.countdownSeconds = countdownSeconds }
        flow.press()
    }
    /// Monitors that show the countdown: the display of every enabled video source (a window → the display holding its centre); never a guess.
    var countdownFrames: [CGRect] {
        var out: [CGRect] = []
        for spec in ([video].compactMap { $0 } + extraVideoSpecs) {
            guard let s = sources.first(where: { $0.id == spec.sourceID && $0.kind == (spec.mode == .window ? .window : .display) }), s.frame != .zero else { continue }
            let f: CGRect? = s.kind == .display ? s.frame : displays.first { $0.frame.contains(CGPoint(x: s.frame.midX, y: s.frame.midY)) }?.frame
            if let f, !out.contains(f) { out.append(f) }
        }
        return out
    }
    private var retreatedWindow: NSWindow?
    /// Countdown overlay while counting; closed before the first frame. The setup window steps back once recording really started and
    /// returns when the flow is idle again (stop or error), never closing the application.
    private func syncCountdownAndWindow(_ p: RecordFlow.Phase) {
        if case .countdown(let n) = p { CountdownOverlay.shared.show(n, on: countdownFrames) } else { CountdownOverlay.shared.close() }
        switch p {
        case .recording where retreatedWindow == nil:
            if let w = NSApp.windows.first(where: { $0.title == "SADROG" && $0.isVisible && !$0.isMiniaturized }) { retreatedWindow = w; w.miniaturize(nil) }
        case .idle:
            if let w = retreatedWindow { retreatedWindow = nil; w.deminiaturize(nil) }
        default: break
        }
    }
    /// Cancels a pending start (preparing or counting down); no effect while recording.
    func cancelStart() { flow.cancel() }

    private struct StartError: LocalizedError { let errorDescription: String? }
    /// Development only (SADROG_SIMULATED_CAPTURE=1, set at launch like SADROG_CONTENT_SIZE): the Record flow runs, but the capturer is never
    /// touched — no stream, no file. Permission checks are unchanged. The UI shows "SIMULARE" so it can never be mistaken for a recording.
    let simulatedCapture = ProcessInfo.processInfo.environment["SADROG_SIMULATED_CAPTURE"] == "1"
    private func startCapture() async throws {
        if simulatedCapture { message = ""; startedAt = Date(); elapsed = 0; return }
        guard let d = destination else { throw StartError(errorDescription: T("Alege destinația.")) }
        do { try Destination(url: d).validate(requiredBytes: 1_000_000_000) }
        catch StorageError.destinationMissing { updateDestination(); throw StartError(errorDescription: T("Destinația nu există (discul e deconectat?). Alege alt folder.")) }
        catch StorageError.notEnoughSpace { throw StartError(errorDescription: T("Spațiu insuficient pe destinație (minim 1 GB liber).")) }
        capturer.onStop = { [weak self] err in Task { @MainActor in self?.stopped(error: err) } }
        capturer.onLevel = { [levelBox] id, p in levelBox.set(id, p) }
        capturer.onTrackLost = { [weak self] id, why in Task { @MainActor in
            guard let self else { return }
            self.lost[id] = why
            let name: String
            if id.hasPrefix("camera:") { let u = String(id.dropFirst(7)); name = L10n.f("Camera „%@”", "\(self.cameras.first { $0.uid == u }?.name ?? u)") }
            else if id.hasPrefix("screen:") { let r = String(id.dropFirst(7)); name = L10n.f("Sursa video „%@”", "\(self.extraVideoSpecs.first { $0.id == r }?.title ?? r)") }
            else { name = L10n.f("Sursa audio „%@”", "\(self.audio.first { $0.id == id }?.deviceName ?? id)") }
            self.message = L10n.f("%@ a dispărut: %@. Celelalte surse continuă; nu s-a trecut la alt dispozitiv.", "\(name)", "\(why)")
        } }
        pausedTotal = 0; pausedAt = nil; probePauseDone = false; probePauseUntil = nil
        ensureMeterTimer()
        started = try await capturer.start(config: config, sources: sources, destination: Destination(url: d))
        message = ""; startedAt = Date(); elapsed = 0
        if UserDefaults.standard.bool(forKey: Self.collectMouseKey), let f = selectedSource?.frame, f.width > 0 {
            let r = MouseRecorder(frame: f) { (CGEvent(source: nil)?.location ?? .zero, CGEventSource.buttonState(.combinedSessionState, button: .left)) }
            mouseRecorder = r; r.start()
        }
        // key COMMANDS (⌘/⌃/⌥ chords and function keys) only, for a recording that opted in (own setting, default off) and only with the system's Input Monitoring permission;
        // every key press reaches the monitor (the system gives it to any app with the permission) and is classified at once by KeyCapture: only a command label is kept, nothing typed is stored
        if UserDefaults.standard.bool(forKey: Self.collectKeysKey) {
            if CGPreflightListenEventAccess() {
                let r = KeyRecorder(); keyRecorder = r; r.start()
                keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { e in
                    let f = e.modifierFlags      // the system delivers every key press here; KeyCapture decides at once and only a command label can survive
                    if let l = KeyCapture.label(keyCode: e.keyCode, characters: e.charactersIgnoringModifiers, command: f.contains(.command), control: f.contains(.control), option: f.contains(.option), shift: f.contains(.shift), secureInput: IsSecureEventInputEnabled()) { r.record(label: l) }
                }
            } else { DiagnosticLog("keys").error("comenzile de tastă nu se salvează: lipsește permisiunea Monitorizare intrare") }
        }
        // the front window is read only for a recording that opted in (own setting, default off); geometry and owner only, never the title
        if UserDefaults.standard.bool(forKey: Self.collectWindowKey), let f = selectedSource?.frame, f.width > 0 {
            let r = WindowRecorder(frame: f) { ForegroundWindow.systemFront(pidToBundle: { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier }) }
            windowRecorder = r; r.start()
        }
        // hard limit (set by the probe guard for test recordings; no limit when absent): a recording can never run unbounded by mistake
        let limit = UserDefaults.standard.double(forKey: "maxRecordSeconds")
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let pausedNow = self.pausedAt.map { Date().timeIntervalSince($0) } ?? 0
                self.elapsed = Date().timeIntervalSince(self.startedAt) - self.pausedTotal - pausedNow; self.updateDestination()
                // Development only: an automatic pause at fixed moments, honoured ONLY while the probe guard has armed the app
                // (`probeGuardStop`), so a test pause is not a hand-timed click. Format "start,length" in seconds of recording time.
                if UserDefaults.standard.bool(forKey: "probeGuardStop"), let spec = UserDefaults.standard.string(forKey: "probePause"),
                   let parts = Optional(spec.split(separator: ",").compactMap { Double($0) }), parts.count == 2 {
                    if self.phase == .recording, self.probePauseDone == false, self.elapsed >= parts[0] { self.probePauseDone = true; self.togglePause(); self.probePauseUntil = Date().addingTimeInterval(parts[1]) }
                    if self.phase == .paused, let u = self.probePauseUntil, Date() >= u { self.probePauseUntil = nil; self.togglePause() }
                }
                if limit > 0, self.elapsed >= limit, self.phase == .recording { self.flow.stop(reason: L10n.f("Oprit la limita de %@ s; înregistrarea a fost salvată.", "\(Int(limit))"), cause: .durationLimit); return }
                if let f = self.freeGB, f < 2, self.phase == .recording { self.flow.stop(reason: T("Spațiu insuficient pe destinație — înregistrarea a fost oprită și salvată."), cause: .lowSpace) }
            }
        }
    }

    private func stopCapture(cause: StopCause, request: String?) async {
        timer?.invalidate(); timer = nil
        if simulatedCapture { timer?.invalidate(); timer = nil; writeSimulatedSession(); updateDestination(); return }
        let folder = capturer.writer?.folder, mouse = mouseRecorder, windows = windowRecorder, keys = keyRecorder; mouseRecorder = nil; windowRecorder = nil; keyRecorder = nil
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        do { try await capturer.stop(cause: cause, request: request) }
        catch { message = L10n.f("Oprit cu eroare: %@", "\(error.localizedDescription)") }
        if let mouse, let folder { let t = mouse.stop(); if !t.samples.isEmpty { do { try t.save(to: folder) } catch { DiagnosticLog("mouse").error("mouse.json nu a putut fi scris: \(error.localizedDescription)") } } } else { _ = mouse?.stop() }
        if let keys, let folder { let t = keys.stop(); if !t.strokes.isEmpty { do { try t.save(to: folder) } catch { DiagnosticLog("keys").error("keys.json nu a putut fi scris: \(error.localizedDescription)") } } }
        if let windows, let folder { var t = windows.stop(); t.mediaFile = "capture.mov"; if !t.samples.isEmpty { do { try t.save(to: folder) } catch { DiagnosticLog("windows").error("windows.json nu a putut fi scris: \(error.localizedDescription)") } } } else { _ = windows?.stop() }
        updateDestination()
    }

    private func stopped(error: Error?) {
        guard phase == .recording else { return }
        timer?.invalidate(); timer = nil
        flow.captureEnded(L10n.f("Captura s-a oprit: %@. Ce s-a înregistrat până acum a fost salvat.", "\(error?.localizedDescription ?? "necunoscut")"))
        updateDestination()
    }

    /// Stop requested by the probe guard (development tool). Honoured only while the guard has switched it on (`probeGuardStop`), so no other
    /// process can stop a normal recording; a pending countdown is cancelled as well.
    /// Stop request from the probe guard (existing distributed notification, with a request id). Handled by GuardStopReceiver (tested in core):
    /// honoured only while the guard switched it on; receipt and outcome are logged in the session's events.jsonl.
    func observeProbeGuard() {
        guard probeObserver == nil else { return }
        probeObserver = DistributedNotificationCenter.default().addObserver(forName: .init("dev.gordas.sadrog.probeGuard.stop"), object: nil, queue: .main) { [weak self] n in
            let request = n.userInfo?["request"] as? String ?? "fără-id"
            Task { @MainActor in self?.guardReceiver.receive(request: request) }
        }
    }
    private lazy var guardReceiver = GuardStopReceiver(flow: flow, enabled: { UserDefaults.standard.bool(forKey: "probeGuardStop") }, log: { [weak self] event, request in
        guard let w = self?.capturer.writer else { return }
        SessionEventLog.append(SessionEvent(session: w.journal.id, event: event, request: request), to: w.folder)
    })

    /// Test capturer only (SADROG_SIMULATED_CAPTURE=1): a finished session whose media is a synthetic file named by SADROG_SIMULATED_MEDIA, so the whole add-recording path
    /// runs without touching the screen, camera or microphone.
    private func writeSimulatedSession() {
        guard let d = destination, let src = ProcessInfo.processInfo.environment["SADROG_SIMULATED_MEDIA"] else { return }
        let id = "sim-\(UUID().uuidString.prefix(8))", folder = d.appendingPathComponent("SADROG-\(id)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: URL(fileURLWithPath: src), to: folder.appendingPathComponent("capture.mov"))
            try SessionJournal(id: id, state: .finished, startedAt: startedAt, mediaFile: "capture.mov", width: 1280, height: 720, fps: 30, note: "simulat").write(to: folder)
        } catch { message = L10n.f("Sesiunea simulată nu a putut fi scrisă: %@", "\(error.localizedDescription)") }
    }
    /// Editor → capture page, project parked. Only while idle (a running capture is never interrupted).
    func beginAddRecording() {
        guard phase == .idle, let e = editor else { return }
        e.closeAllPluginWindows(); e.player.pause()
        addTarget = AddTarget(editor: e, since: Date().addingTimeInterval(-1)); editor = nil; message = ""
    }
    /// Back to the parked project exactly as it was (nothing recorded, nothing changed).
    func cancelAddRecording() {
        guard phase == .idle, let t = addTarget else { return }
        leaveContext(); addTarget = nil; editor = t.editor
    }
    /// The capture ended: the new session joins the parked project (one undo step, recordings untouched on disk). No new session (error, nothing captured) → the project
    /// stays parked and safe; if it cannot take the recording, the session stays in Recent for later.
    private func completeAddRecording() async {
        guard let t = addTarget else { return }
        updateDestination()
        guard let s = editable.first(where: { $0.journal.startedAt >= t.since }) else { return }
        let media = s.folder.appendingPathComponent(s.journal.mediaFile)
        guard let d = try? await AVURLAsset(url: media).load(.duration).seconds, d > 0.05 else { message = T("Înregistrarea nu poate fi citită; rămâne în Recente."); return }
        guard addTarget != nil else { return }      // cancelled meanwhile: the session simply stays in Recent
        if await t.editor.addRecordedSession(media: media.path, duration: d, journal: s.journal) {
            leaveContext(); addTarget = nil; editor = t.editor
        } else { message = T("Nu am putut adăuga înregistrarea în proiect; rămâne în Recente.") }
    }

    private func presentFinished() async {
        updateDestination()
        guard let s = editable.first(where: { $0.journal.startedAt >= startedAt.addingTimeInterval(-2) }) else { return }
        let media = s.folder.appendingPathComponent(s.journal.mediaFile)
        guard let d = try? await AVURLAsset(url: media).load(.duration).seconds, d > 0.05 else { message = T("Înregistrarea nu poate fi citită; rămâne în Recente."); return }
        finishName = RecordingFinish.defaultName(for: s.journal.startedAt, prefix: T("Înregistrare"))
        finished = FinishedRecording(folder: s.folder, journal: s.journal, duration: d)
    }
    func dismissFinished() { finished = nil }
    func finishIntoOtherProject() async {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = T("Alege")
        p.message = T("Alege folderul proiectului (cel care conține project.sadrogproj)")
        guard p.runModal() == .OK, let u = p.url else { return }
        let folder = u.pathExtension == "sadrogproj" ? u.deletingLastPathComponent() : u
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.sadrogproj").path) else { message = T("Folderul ales nu conține un proiect SADROG (project.sadrogproj)."); return }
        await finishIntoProject(folder)
    }
    /// Finished recording → a NEW document named by the user, the recording placed at its start. The recording stays in its own folder either way.
    func finishIntoNewDocument() async {
        guard let f = finished, let d = destination else { return }
        let name = RecordingFinish.cleanName(finishName, fallback: T("Proiect nou"))
        do {
            let folder = try RecordingFinish.createDocument(name: name, format: RecordingFinish.format(width: f.journal.width, height: f.journal.height, fps: Double(f.journal.fps)), in: d)
            await place(f, intoProjectAt: folder, created: true)
        } catch { message = L10n.f("Nu am putut crea documentul: %@", "\(error.localizedDescription)") }
    }
    /// Finished recording → an existing project, at the end of its main track (nothing already there moves).
    func finishIntoProject(_ folder: URL) async {
        guard let f = finished else { return }
        await place(f, intoProjectAt: folder, created: false)
    }
    private func place(_ f: FinishedRecording, intoProjectAt folder: URL, created: Bool) async {
        do {
            let e = try await EditorModel(session: folder, journal: nil)
            if await e.addRecordedSession(media: f.folder.appendingPathComponent(f.journal.mediaFile).path, duration: f.duration, journal: f.journal) {
                leaveContext(); finished = nil; editor = e
            } else { message = discardNote(created, folder) ?? T("Nu am putut adăuga înregistrarea în proiect; rămâne în Recente.") }
        } catch { message = discardNote(created, folder) ?? L10n.f("Nu pot deschide documentul: %@", "\(error.localizedDescription)") }
    }
    /// A document made just for this recording that never received it is moved to the Trash; the recording stays in Recent. nil = nothing was discarded.
    private func discardNote(_ created: Bool, _ folder: URL) -> String? {
        guard created, RecordingFinish.discardIfUnused(folder) else { return nil }
        return T("Nu am putut crea documentul cu înregistrarea; documentul temporar gol a fost mutat în Coș, înregistrarea rămâne în Recente.")
    }
    /// New edit document in the destination folder: name, canvas size and frame rate are saved in the project before the editor opens.
    func createDocument(name: String, format: DocumentFormat) async {
        guard let d = destination else { message = T("Alege întâi folderul de destinație."); return }
        let clean = name.trimmingCharacters(in: .whitespaces).isEmpty ? T("Proiect nou") : name.trimmingCharacters(in: .whitespaces)
        let folder = d.appendingPathComponent("SADROG-Proiect-\(UUID().uuidString.prefix(8))")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            var p = SadrogProject(name: clean); p.canvas = format
            try ProjectStore.save(p, to: folder.appendingPathComponent("project.sadrogproj"))
            leaveContext(); editor = try await EditorModel(session: folder, journal: nil)
        } catch { message = L10n.f("Nu am putut crea documentul: %@", "\(error.localizedDescription)") }
    }
    /// A project folder from anywhere (it holds project.sadrogproj). The project opens in place; nothing is copied into the destination.
    func openProjectFromDisk() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.prompt = "Deschide"
        p.message = T("Alege folderul proiectului (cel care conține project.sadrogproj)")
        guard p.runModal() == .OK, let u = p.url else { return }
        let folder = u.pathExtension == "sadrogproj" ? u.deletingLastPathComponent() : u
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.sadrogproj").path) else { message = T("Folderul ales nu conține un proiect SADROG (project.sadrogproj)."); return }
        Task { await openDocument(folder) }
    }
    /// Development / verification only (SADROG_OPEN_PROJECT=<project folder>, set at launch like SADROG_CONTENT_SIZE): opens that project ONCE through the same
    /// `openDocument` as the Open command — same load and validation, no activation or protection bypassed. Nothing is copied; a missing project only shows the usual message.
    @MainActor private static var openRequestHandled = false
    func openRequestedProject() async {
        guard !Self.openRequestHandled, editor == nil, let path = ProcessInfo.processInfo.environment["SADROG_OPEN_PROJECT"], !path.isEmpty else { return }
        Self.openRequestHandled = true
        let u = URL(fileURLWithPath: path), folder = u.pathExtension == "sadrogproj" ? u.deletingLastPathComponent() : u
        guard FileManager.default.fileExists(atPath: folder.appendingPathComponent("project.sadrogproj").path) else { message = T("Folderul ales nu conține un proiect SADROG (project.sadrogproj)."); return }
        await openDocument(folder)
    }
    func openDocument(_ folder: URL) async {
        leaveContext(); addTarget = nil
        do { editor = try await EditorModel(session: folder, journal: nil) } catch { message = L10n.f("Nu pot deschide documentul: %@", "\(error.localizedDescription)") }
    }

    func openEditor(_ e: (folder: URL, journal: SessionJournal)) async {
        leaveContext(); addTarget = nil
        do { editor = try await EditorModel(session: e.folder, journal: e.journal) }
        catch { message = L10n.f("Nu pot deschide editorul: %@", "\(error.localizedDescription)") }
    }
    func recover(_ j: SessionJournal) async {
        guard let d = destination else { return }
        let folder = d.appendingPathComponent("SADROG-\(j.id)")
        do { let (r, _) = try await SessionRecovery.resolve(folder: folder); message = r.note } catch { message = L10n.f("Recuperare eșuată: %@", "\(error.localizedDescription)") }
        updateDestination()
    }
}
