// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import SadrogCore

/// What the pointer shows while files are dragged over the timeline: where it would land and whether it is allowed. `plan` is nil for Finder files
/// (their length is only readable on drop); library drags know their length, so the exact span is drawn.
struct DropHover: Equatable {
    var destination: DropDestination?
    var time: Double
    var plan: DropPlan?
    var note: String
}

extension DropRefusal {
    var text: String {
        switch self {
        case .nothing: return T("Nu s-a primit niciun fișier.")
        case .incompatible: return T("Materialul nu se potrivește cu pista aceasta.")
        case .locked: return T("Pista este blocată.")
        case .overlap: return T("Se suprapune cu alt element de pe pistă.")
        case .tooManyTracks: return T("Nu mai pot adăuga piste în această zonă.")
        case .unreadable: return T("Fișierul nu poate fi citit.")
        }
    }
}

extension EditorModel {
    /// Reads length and streams without touching the project.
    func probeMaterial(_ path: String) async -> DropMaterial? {
        if let i = media[path], i.duration > 0 { return DropMaterial(path: path, duration: i.duration, hasVideo: i.hasVideo, hasAudio: i.hasAudio) }
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let d = (try? await asset.load(.duration).seconds) ?? 0
        let v = ((try? await asset.loadTracks(withMediaType: .video))?.count ?? 0) > 0, a = ((try? await asset.loadTracks(withMediaType: .audio))?.count ?? 0) > 0
        guard d.isFinite, d > 0, v || a else { return nil }
        return DropMaterial(path: path, duration: d, hasVideo: v, hasAudio: a)
    }
    func snapPointsForDrop(pps: CGFloat) -> (points: [Double], threshold: Double) {
        snapOn && pps > 0 ? (Snapping.points(of: project, playhead: time), Double(8 / pps)) : ([], 0)
    }
    /// Live feedback for the pointer (library drags have known lengths, Finder files are previewed as an insertion mark).
    func updateDropHover(destination: DropDestination?, time t: Double, pps: CGFloat, fromLibrary: Bool) {
        guard let destination else { let n = T("Aici nu se pot lăsa materiale: alege V1, V2 sau A2."); dropHover = DropHover(destination: nil, time: t, plan: nil, note: n); message = n; return }
        let sn = snapPointsForDrop(pps: pps)
        if fromLibrary, !libraryDrag.isEmpty {
            let mats = libraryDrag.compactMap { p in media[p].map { DropMaterial(path: p, duration: $0.duration, hasVideo: $0.hasVideo, hasAudio: $0.hasAudio) } }
            let plan = DropPlanner.plan(project, materials: mats, destination: destination, at: t, snapPoints: sn.points, threshold: sn.threshold)
            dropHover = DropHover(destination: destination, time: plan.isValid ? plan.start : t, plan: plan, note: plan.refusal?.text ?? (plan.createsTrack ? T("Pistă nouă + inserare") : ""))
            if let r = plan.refusal { message = r.text }      // a refused drop is never performed by the system, so the reason stays in the status bar after release
        } else {
            dropHover = DropHover(destination: destination, time: t, plan: nil, note: "")
        }
    }
    /// The drop itself: probe, plan with the same rules as the preview, perform as one undo step, or say why not and change nothing.
    func performDrop(paths: [String], destination: DropDestination?, at t: Double, pps: CGFloat) async {
        dropHover = nil; libraryDrag = []
        guard let destination else { message = T("Aici nu se pot lăsa materiale: alege V1, V2 sau A2."); return }
        var mats: [DropMaterial] = []
        for p in paths { guard let m = await probeMaterial(p) else { message = L10n.f("Nu pot citi %@.", URL(fileURLWithPath: p).lastPathComponent); return }; mats.append(m) }
        let sn = snapPointsForDrop(pps: pps)
        let plan = DropPlanner.plan(project, materials: mats, destination: destination, at: t, snapPoints: sn.points, threshold: sn.threshold)
        guard plan.isValid else { message = plan.refusal?.text ?? T("Nu s-a primit niciun fișier."); return }
        var ids: [UUID]?
        apply(reload: false) { ids = $0.perform(plan) }
        guard let ids else { message = T("Nu s-a putut insera."); return }
        missing = ProjectStore.missingMedia(project)
        await loadMedia(); await reload(keepTime: true)
        selection = ids.first; extra = []
        message = plan.createsTrack ? T("Pistă nouă creată și materialul inserat.") : (ids.count == 1 ? T("Inserat: 1 element.") : L10n.f("Inserat: %@ elemente.", "\(ids.count)"))
    }
}

let libraryDragType = UTType(exportedAs: "dev.gordas.sadrog.library-material")
/// The provider a library cell drags: the file URL (so Finder-style handlers also understand it) plus a marker that says it comes from THIS library.
func libraryProvider(_ path: String) -> NSItemProvider {
    let ip = NSItemProvider(object: URL(fileURLWithPath: path) as NSURL)
    ip.registerDataRepresentation(forTypeIdentifier: libraryDragType.identifier, visibility: .ownProcess) { done in done(Data(path.utf8), nil); return nil }
    return ip
}
/// File URLs from a drop (Finder or the library, which offers the same file URL).
func droppedPaths(_ info: DropInfo) async -> [String] {
    var out: [String] = []
    for p in info.itemProviders(for: [.fileURL]) {
        let url: URL? = await withCheckedContinuation { c in
            _ = p.loadObject(ofClass: URL.self) { u, _ in c.resume(returning: u) }
        }
        if let url, url.isFileURL { out.append(url.path) }
    }
    return out
}

struct TimelineDropDelegate: DropDelegate {
    let m: EditorModel
    let pps: CGFloat
    let locate: (CGPoint) -> (DropDestination?, Double)?
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) }
    func dropEntered(info: DropInfo) { update(info) }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        update(info)
        if let h = m.dropHover { return DropProposal(operation: h.destination == nil || h.plan?.isValid == false ? .forbidden : .copy) }
        return DropProposal(operation: .forbidden)
    }
    func dropExited(info: DropInfo) { m.dropHover = nil }
    func performDrop(info: DropInfo) -> Bool {
        guard let (dest, t) = locate(info.location) else { m.dropHover = nil; return false }
        let pps = pps, model = m, fromLib = info.hasItemsConforming(to: [libraryDragType])
        Task { @MainActor in
            let paths = fromLib && !model.libraryDrag.isEmpty ? model.libraryDrag : await droppedPaths(info)
            await model.performDrop(paths: paths, destination: dest, at: t, pps: pps)
        }
        return true
    }
    private func update(_ info: DropInfo) {
        guard let (dest, t) = locate(info.location) else { m.dropHover = nil; return }
        m.updateDropHover(destination: dest, time: t, pps: pps, fromLibrary: info.hasItemsConforming(to: [libraryDragType]))
    }
}

/// Drop of files onto the library: imports them (no placement).
struct LibraryDropDelegate: DropDelegate {
    let m: EditorModel
    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.fileURL]) && !info.hasItemsConforming(to: [libraryDragType]) }
    func performDrop(info: DropInfo) -> Bool {
        let model = m
        Task { @MainActor in
            let paths = await droppedPaths(info)
            let ok = paths.filter { FileManager.default.fileExists(atPath: $0) }
            guard !ok.isEmpty else { model.message = T("Nu s-a primit niciun fișier."); return }
            model.importMaterials(ok)
            model.message = L10n.f("Importat în bibliotecă: %@ fișiere.", "\(ok.count)")
        }
        return true
    }
}
