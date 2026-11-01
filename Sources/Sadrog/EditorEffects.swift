// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AppKit
import AVFoundation
import CoreAudioKit
import SadrogCore
import os

let fxLog = Logger(subsystem: "dev.gordas.sadrog", category: "fx")

/// Processing state of one recording source's effect chain, as the editor shows it.
enum FxState: Equatable {
    case processing(Double)      // 0…1; until done the source plays WITHOUT effects (said in the UI) and exports wait
    case ready
    case failed(String)
}

struct UncheckedBox<T>: @unchecked Sendable { let value: T }

extension EditorModel {
    func effects(_ k: Int, media m: String? = nil) -> [AudioEffect] { project.recording(m ?? shownMedia).effects[k] ?? [] }
    private func slots(_ k: Int) -> [String] { [EffectRenderer.slot(shownMedia, k)] }

    func fxState(_ k: Int, media: String? = nil) -> FxState? {
        let media = media ?? shownMedia
        guard !project.activeEffects(ofSource: k, media: self.shownMedia).isEmpty else { return nil }
        let jobs = fxPlan.jobs.filter { $0.track == k && $0.media == media }
        for j in jobs { if let f = fxFailed[EffectRenderer.slot(j.media, j.track)], f.key == j.key { return .failed(f.message) } }
        if !jobs.isEmpty { return .processing(jobs.map { fxProgress[EffectRenderer.slot($0.media, $0.track)] ?? 0 }.min() ?? 0) }
        return .ready
    }
    /// Delay handling of the processed result (from the render report next to the processed file).
    func fxReport(_ k: Int) -> EffectReport? { slots(k).compactMap { fxPlan.ready[$0] }.first.flatMap { EffectRenderer.report(for: $0) } }
    func isInstalled(_ e: AudioEffect) -> Bool { AUCatalog.installed(e.component) != nil }
    /// Why an export cannot start now (effects still processing or failed); nil = ready.
    var fxBlockReason: String? {
        let pairs = project.recordings.sorted { $0.key < $1.key }.flatMap { m, r in r.effects.keys.sorted().filter { !project.activeEffects(ofSource: $0, media: m).isEmpty }.map { (m, $0) } }
        for (m, k) in pairs { if case .failed(let w) = fxState(k, media: m) { return L10n.f("Efectele sursei „%@” nu s-au procesat: %@", "\(sourceName(k, media: m))", "\(w)") } }
        for (m, k) in pairs { if case .processing(let f) = fxState(k, media: m) { return L10n.f("Efectele audio se procesează (%@%%) — exportul devine disponibil după final", "\(Int(f * 100))") } }
        return nil
    }
    func sourceName(_ k: Int, media: String? = nil) -> String { (media.flatMap { self.media[$0]?.sources } ?? mainSources).first { $0.index == k }?.name ?? L10n.f("Pista audio %@", "\(k + 1)") }

    // MARK: chain edits (each = one undo step; the cache key changes, so the old result is never played as the new one)
    func addEffect(_ k: Int, _ info: AUInfo) {
        let e = AudioEffect(component: info.id, name: info.name, manufacturerName: info.manufacturerName, componentVersion: info.version)
        apply { $0.setEffects(k, self.effects(k) + [e], media: self.shownMedia) }
    }
    func removeEffect(_ k: Int, _ id: UUID) {
        pluginWindows[id]?.close()
        apply { $0.setEffects(k, self.effects(k).filter { $0.id != id }, media: self.shownMedia) }
    }
    func moveEffect(_ k: Int, _ id: UUID, by d: Int) {
        var c = effects(k); guard let i = c.firstIndex(where: { $0.id == id }), c.indices.contains(i + d) else { return }
        c.swapAt(i, i + d); apply { $0.setEffects(k, c, media: self.shownMedia) }
    }
    func setBypass(_ k: Int, _ id: UUID, _ on: Bool) {
        apply { $0.setEffects(k, self.effects(k).map { var e = $0; if e.id == id { e.bypassed = on }; return e }, media: self.shownMedia) }
    }
    /// A new plugin state from its window; ignored when identical to the saved one.
    func setEffectState(_ k: Int, _ id: UUID, _ state: Data, version: UInt32, media m: String) {
        guard let cur = effects(k, media: m).first(where: { $0.id == id }), cur.state != state || cur.componentVersion != version else { return }
        apply { $0.setEffects(k, self.effects(k, media: m).map { var e = $0; if e.id == id { e.state = state; e.componentVersion = version }; return e }, media: m) }
    }
    func retryEffects(_ k: Int) { for s in slots(k) { fxFailed[s] = nil }; scheduleEffects() }
    func stopEffects(_ k: Int) {
        for j in fxPlan.jobs where j.track == k {
            let s = EffectRenderer.slot(j.media, j.track)
            fxTasks[s]?.task.cancel(); fxTasks[s] = nil; fxProgress[s] = nil
            fxFailed[s] = (j.key, T("procesare oprită — apasă Reîncearcă"))
        }
    }

    // MARK: scheduling
    /// Called after every rebuild: cancels renders whose input changed, starts the missing ones (never a failed one again until the chain
    /// changes or the user retries), measures peaks of finished files, keeps the plugin windows in step with undo.
    func scheduleEffects() {
        var want: [String: EffectJob] = [:]
        for j in fxPlan.jobs { want[EffectRenderer.slot(j.media, j.track)] = j }
        for (s, t) in fxTasks where want[s]?.key != t.key { t.task.cancel(); fxTasks[s] = nil; fxProgress[s] = nil }
        for (s, job) in want where fxTasks[s] == nil {
            if let f = fxFailed[s], f.key == job.key { continue }
            fxFailed[s] = nil; fxProgress[s] = 0
            fxLog.notice("\("procesare pornită: sursa \(job.track + 1), \(job.chain.map(\.name).joined(separator: " › "))", privacy: .public)")
            let task = Task { [weak self] in
                do {
                    let rep = try await EffectRenderer.render(job) { f in Task { @MainActor in if self?.fxTasks[s]?.key == job.key { self?.fxProgress[s] = f } } }
                    guard let self else { return }
                    fxLog.notice("\(String(format: "procesare gata: sursa %d în %.1f s, compensare %d eșantioane", job.track + 1, rep.renderSeconds, rep.compensationSamples), privacy: .public)")
                    if self.fxTasks[s]?.key == job.key { self.fxTasks[s] = nil; self.fxProgress[s] = nil }
                    await self.measurePeak(job.output)
                    await self.reload(keepTime: true)
                } catch {
                    guard let self else { return }
                    let e = error as? EffectError
                    if self.fxTasks[s]?.key == job.key { self.fxTasks[s] = nil; self.fxProgress[s] = nil }
                    if e != .cancelled {
                        let msg = e?.description ?? error.localizedDescription
                        self.fxFailed[s] = (job.key, msg)
                        fxLog.notice("\("procesare eșuată: sursa \(job.track + 1): \(msg)", privacy: .public)")
                    }
                }
            }
            fxTasks[s] = (job.key, task)
        }
        for u in fxPlan.ready.values where fxPeaks[u.path] == nil { Task { await measurePeak(u) } }
        if fxPlan.jobs.isEmpty { EffectRenderer.prune(folder: folder, keep: Set(fxPlan.ready.values)) }
        // undo/redo may have changed or removed an effect whose window is open
        for (id, w) in pluginWindows {
            guard let e = project.sourceEffects.values.joined().first(where: { $0.id == id }) else { w.close(); continue }
            w.sync(to: e)
        }
    }

    func measurePeak(_ url: URL) async {
        let path = url.path
        let v: Float? = await Task.detached {
            guard let f = try? AVAudioFile(forReading: url), let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: 65536) else { return nil }
            var m: Float = 0
            while f.framePosition < f.length {
                guard (try? f.read(into: b)) != nil, b.frameLength > 0 else { break }
                for c in 0..<Int(b.format.channelCount) { for i in 0..<Int(b.frameLength) { m = max(m, abs(b.floatChannelData![c][i])) } }
            }
            return m
        }.value
        if let v { fxPeaks[path] = v }
    }

    // MARK: plugin windows
    func openPlugin(_ k: Int, _ id: UUID) {
        if let w = pluginWindows[id] { w.front(); return }
        let m = shownMedia
        guard let e = effects(k, media: m).first(where: { $0.id == id }) else { return }
        let w = PluginWindow(model: self, source: k, media: m, effect: e, title: "\(e.name) — \(sourceName(k))")
        pluginWindows[id] = w
        Task { await w.open() }
    }
    func closeAllPluginWindows() { for w in pluginWindows.values { w.close() } }
}

/// The plugin's OWN interface in a SADROG window. The plugin runs out of process (an editing instance restored from the saved state);
/// every change of its state — parameter edits reported by the plugin, or state differences seen by a 1 s check — is saved into the project
/// (one undo step per burst of changes) and re-processed. Nothing is auditioned live here: the result is heard in the preview after processing.
@MainActor
final class PluginWindow: NSObject, NSWindowDelegate {
    private weak var model: EditorModel?
    let source: Int, recording: String, effectID: UUID
    private var effect: AudioEffect
    private let title: String
    private var unit: AVAudioUnit?
    private var window: NSWindow?
    private var token: AUParameterObserverToken?
    private var timer: Timer?
    private var saved: Data?                  // last state written to the project, or the plugin's own serialization right after the restore
    private var pending: DispatchWorkItem?
    private var quietChanges = 0              // state changing on its own (without parameter events): polling is switched off
    private var pollOn = true
    private var lastParamEvent = Date.distantPast
    @Published var error: String?

    init(model: EditorModel, source: Int, media: String, effect: AudioEffect, title: String) {
        self.model = model; self.source = source; self.recording = media; self.effectID = effect.id; self.effect = effect; self.title = title; self.saved = effect.state
    }

    /// A second (third…) plug-in window must not open exactly over the first: it is offset by a title-bar step from the last one still open,
    /// and kept inside the visible area of the screen. Windows the user has moved are never touched (only NEW windows are placed).
    static func cascade(_ w: NSWindow) {
        let others = NSApp.windows.filter { $0 !== w && $0.isVisible && $0.delegate is PluginWindow }
        guard let last = others.max(by: { $0.windowNumber < $1.windowNumber }) else { return }
        var f = w.frame
        f.origin = NSPoint(x: last.frame.minX + 28, y: last.frame.minY - 28)
        let vis = (last.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        if vis != .zero {
            f.origin.x = min(max(f.origin.x, vis.minX), max(vis.minX, vis.maxX - f.width))
            f.origin.y = min(max(f.origin.y, vis.minY), max(vis.minY, vis.maxY - f.height))
            // at the bottom/right edge the cascade wraps back to the top-left corner of the visible area
            if f.origin.y <= vis.minY || f.maxX >= vis.maxX { f.origin = NSPoint(x: vis.minX + 40, y: vis.maxY - f.height - 40) }
        }
        w.setFrame(f, display: false)
    }

    func open() async {
        let id = effect.component, name = effect.name
        guard AUCatalog.installed(id) != nil else { fail(L10n.f("Pluginul „%@” nu e instalat pe acest Mac.", "\(name)")); return }
        let box: UncheckedBox<AVAudioUnit>
        do { box = try await Task.detached { UncheckedBox(value: try AUCatalog.instantiate(id)) }.value }
        catch { fail((error as? EffectError)?.description ?? error.localizedDescription); return }
        let u = box.value; unit = u
        if let s = effect.decodedState { u.auAudioUnit.fullState = s }
        // the reference is what the plugin reports right after the restore: a plugin may serialize the same state with different bytes
        // (seen with voxium), and that must not become an edit (an extra undo step and a needless re-process)
        saved = currentState()
        let au = u.auAudioUnit
        token = au.parameterTree?.token(byAddingParameterObserver: { [weak self] _, _ in
            Task { @MainActor in self?.lastParamEvent = Date(); self?.scheduleSave() }
        })
        let vc: NSViewController? = await withCheckedContinuation { c in au.requestViewController { c.resume(returning: $0) } }
        guard let vc else { fail(L10n.f("„%@” nu are o interfață proprie pe care SADROG s-o poată afișa.", "\(name)")); return }
        var size = vc.preferredContentSize
        if size.width < 50 || size.height < 50 { size = vc.view.frame.size }
        if size.width < 50 || size.height < 50 { size = CGSize(width: 640, height: 420) }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title; w.contentViewController = vc; w.setContentSize(size); w.isReleasedWhenClosed = false; w.delegate = self
        w.center()
        Self.cascade(w)
        // Auxiliary window of the project: a CHILD of the editor window — always above it (clicks, scrolling and playback in the timeline never bury it),
        // hidden/shown together with the app (never left over another application), and below modal dialogs. No window level, no timer.
        if let parent = NSApp.mainWindow ?? NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }), parent !== w { parent.addChildWindow(w, ordered: .above) }
        w.makeKeyAndOrderFront(nil); window = w
        fxLog.notice("\("fereastra pluginului deschisă: \(name) (\(Int(size.width))×\(Int(size.height)))", privacy: .public)")
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.poll() } }
        // Development only (like SADROG_SIMULATED_CAPTURE): the plugin's interface runs in another process that test automation may not
        // drive, so this moves its first continuous parameter by code, through the same observer → save → re-process path as a hand gesture.
        if ProcessInfo.processInfo.environment["SADROG_FX_PARAM_SELFTEST"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let p = self?.unit?.auAudioUnit.parameterTree?.allParameters.first(where: { $0.flags.contains(.flag_IsWritable) && $0.maxValue > $0.minValue && $0.unit != .boolean && $0.unit != .indexed }) else { return }
                let a = p.minValue + (p.maxValue - p.minValue) * 0.37, b = p.minValue + (p.maxValue - p.minValue) * 0.63
                let v = abs(p.value - a) < (p.maxValue - p.minValue) * 0.01 ? b : a      // always a real change
                fxLog.notice("\("autotest: \(p.displayName) \(p.value) → \(v)", privacy: .public)")
                p.setValue(v, originator: nil)
            }
        }
    }
    func front() { window?.makeKeyAndOrderFront(nil) }

    private func currentState() -> Data? { AudioEffect.encode(state: unit?.auAudioUnit.fullState) }
    private func scheduleSave() {
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        pending = w; DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: w)
    }
    private func poll() {
        guard pollOn, pending == nil || pending!.isCancelled, let s = currentState(), s != saved else { return }
        if Date().timeIntervalSince(lastParamEvent) > 2 { quietChanges += 1 } else { quietChanges = 0 }
        if quietChanges >= 3 { pollOn = false; fxLog.notice("\("\(self.effect.name): starea se schimbă singură; salvez doar la modificări de parametri și la închidere", privacy: .public)"); return }
        save()
    }
    private func save() {
        pending = nil
        guard let s = currentState(), s != saved else { return }
        saved = s
        model?.setEffectState(source, effectID, s, version: AUCatalog.installed(effect.component)?.version ?? effect.componentVersion, media: recording)
    }
    /// The project changed under the window (undo/redo): load that state into the plugin.
    func sync(to e: AudioEffect) {
        let changed = e.state != effect.state
        effect = e
        guard changed, let u = unit, e.state != saved else { return }
        if let s = e.decodedState { u.auAudioUnit.fullState = s }
        saved = currentState()                 // the plugin's own bytes for the restored state: not an edit
    }
    private func fail(_ msg: String) {
        error = msg
        fxLog.notice("\("fereastra pluginului: \(msg)", privacy: .public)")
        model?.message = msg
        teardown()
    }
    func close() { window?.close(); if window == nil { teardown() } }
    func windowWillClose(_ notification: Notification) { pending?.cancel(); save(); teardown() }
    private func teardown() {
        timer?.invalidate(); timer = nil
        if let t = token { unit?.auAudioUnit.parameterTree?.removeParameterObserver(t) }; token = nil
        if let w = window { w.parent?.removeChildWindow(w) }
        unit = nil; window?.delegate = nil; window = nil
        model?.pluginWindows[effectID] = nil
    }
}
