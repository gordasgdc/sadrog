// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import AppKit
import SadrogCore

/// Edit commands of the editor (Copy / Cut / Paste / Duplicate / Select All / Rename / lane locks). ONE implementation behind the menu bar,
/// the keyboard shortcuts and the timeline context menu. Text fields keep their own standard editing: see `EditCommand.run`.
extension EditorModel {
    static var clipboard: [ClipboardItem] = []

    func exists(_ id: UUID) -> Bool {
        project.clips.contains { $0.id == id } || project.layers.contains { $0.id == id } || project.texts.contains { $0.id == id } || project.callouts.contains { $0.id == id }
    }
    var selectedIDs: [UUID] { ([selection].compactMap { $0 }) + extra.filter { $0 != selection } }
    func isSelected(_ id: UUID) -> Bool { selection == id || extra.contains(id) }
    /// ⇧/⌘-click: adds the item to the selection or removes it.
    func toggleSelect(_ id: UUID) {
        if selection == nil { selection = id }
        else if selection == id { selection = extra.first; if let n = selection { extra.remove(n) } }
        else if extra.contains(id) { extra.remove(id) } else { extra.insert(id) }
    }
    var hasSelection: Bool { selection != nil }
    var canPaste: Bool { !Self.clipboard.isEmpty }

    func lockedLane(of id: UUID) -> Bool {
        let l: TrackLane? = project.clips.contains { $0.id == id } ? .v1 : project.layers.first { $0.id == id }.map { $0.kind == .video ? .v2 : .a2 }
            ?? (project.texts.contains { $0.id == id } ? .t : (project.callouts.contains { $0.id == id } ? .c : nil))
        return l.map { project.lockedLanes.contains($0) } ?? false
    }
    func isLocked(_ lane: TrackLane) -> Bool { project.lockedLanes.contains(lane) }
    func toggleLock(_ lane: TrackLane) { let on = !isLocked(lane); apply(reload: false) { $0.setLock(lane, on) } }

    func copySelection() {
        var items: [ClipboardItem] = []
        apply(reload: false) { items = $0.clipboardItems(for: self.selectedIDs) }
        if !items.isEmpty { Self.clipboard = items; message = "" }
    }
    func cutSelection() { copySelection(); deleteSelectedItems() }
    func deleteSelectedItems() {
        let ids = selectedIDs; guard !ids.isEmpty else { return }
        if ids.count == 1 { deleteSelected(); return }
        apply { $0.delete(items: ids) }
        if project.clips.allSatisfy({ !ids.contains($0.id) }) == false || ids.contains(where: { exists($0) }) { message = T("Pista este blocată sau elementul nu poate fi șters.") }
        selection = nil; extra = []
    }
    /// Pastes after the main-track clip under the playhead (at the end if none); overlay/audio/title/callout items start at the playhead.
    func pasteClipboard() {
        guard !Self.clipboard.isEmpty else { return }
        let idx = project.clipID(at: time).flatMap { id in project.clips.firstIndex { $0.id == id } }.map { $0 + 1 } ?? project.clips.count
        var made: [UUID] = []
        apply { made = $0.paste(Self.clipboard, clipIndex: idx, at: self.time) }
        finishPaste(made)
    }
    func duplicateSelection() {
        let ids = selectedIDs; guard !ids.isEmpty else { return }
        var made: [UUID] = []
        apply { made = $0.duplicate(items: ids) }
        finishPaste(made)
    }
    private func finishPaste(_ made: [UUID]) {
        if made.isEmpty { message = T("Nu pot lipi: pista este blocată sau nu e loc liber."); return }
        extra = Set(made.dropFirst()); selection = made.first; message = ""
    }
    // MARK: moving a multiple selection (rule documented at `GroupMove`)
    /// Timed items that move together when `primary` is dragged inside a multiple selection (empty = a single-item drag).
    func groupMoveIDs(primary: UUID) -> [UUID] {
        guard !extra.isEmpty, isSelected(primary) else { return [] }
        let t = ProjectEditor(project: project).timedItems(in: selectedIDs)
        return t.contains(primary) ? t : []
    }
    func groupClamp(_ ids: [UUID], _ dx: Double) -> Double { ProjectEditor(project: project).clampedGroupDelta(ids, dx) }
    var selectionHasMainClips: Bool { selectedIDs.contains { id in project.clips.contains { $0.id == id } } }
    /// True when moving these items would touch a locked lane.
    func anyLocked(_ ids: [UUID]) -> Bool { ids.contains { lockedLane(of: $0) } }
    func commitGroupMove(_ ids: [UUID], dx: Double) {
        var r: GroupMove = .refused(.nothing); let mainSel = selectionHasMainClips
        apply { r = $0.moveGroup(ids, by: dx) }
        switch r {
        case .moved(_, let stayed): message = (stayed || mainSel) ? T("Clipurile din pista principală au rămas pe loc; se mută doar celelalte elemente.") : ""
        case .refused(.locked): message = T("Nu se poate muta: o pistă a selecției este blocată.")
        case .refused(.overlap): message = T("Nu se poate muta acolo: grupul s-ar suprapune cu un element care nu se mută.")
        case .refused(.nothing): break
        }
    }
    /// Main-track clips selected together move as one block; they must be adjacent.
    func commitBlockMove(by offset: Int) {
        var ok = false; let ids = selectedIDs
        apply { ok = $0.moveBlock(ids, byIndex: offset) }
        message = ok ? "" : T("Clipurile selectate trebuie să fie vecine și pista deblocată pentru a se muta împreună.")
    }
    func selectAll() {
        let all = project.clips.map(\.id) + project.layers.map(\.id) + project.texts.map(\.id) + project.callouts.map(\.id)
        guard let f = all.first else { return }
        selection = f; extra = Set(all.dropFirst())
    }
    func promptMarkerName(_ id: UUID) {
        guard let mk = project.markers.first(where: { $0.id == id }) else { return }
        let a = NSAlert(); a.messageText = T("Numele marcajului"); a.informativeText = T("Un nume gol păstrează doar poziția.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = mk.name; a.accessoryView = f
        a.addButton(withTitle: T("Redenumește")); a.addButton(withTitle: T("Anulează")); a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { renameMarker(id, f.stringValue) }
    }
    func promptRename() {
        guard let id = selection else { return }
        let cur = project.clips.first { $0.id == id }?.label ?? project.layers.first { $0.id == id }?.label
        guard project.clips.contains(where: { $0.id == id }) || project.layers.contains(where: { $0.id == id }) else { return }
        let a = NSAlert(); a.messageText = T("Redenumește elementul"); a.informativeText = T("Un nume gol readuce numele fișierului.")
        let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24)); f.stringValue = cur ?? ""; a.accessoryView = f
        a.addButton(withTitle: T("Redenumește")); a.addButton(withTitle: T("Anulează"))
        a.window.initialFirstResponder = f
        if a.runModal() == .alertFirstButtonReturn { let v = f.stringValue; apply(reload: false) { $0.rename(id, to: v) } }
    }
}

enum EditCommand {
    /// True when a command goes to the editor: the main window is key, no sheet/panel/plug-in window is in front and no text is being edited.
    /// Otherwise the standard AppKit action goes to the first responder (text field, dialog, plug-in window).
    @MainActor static func routesToEditor() -> Bool {
        let w = NSApp.keyWindow
        if let r = w?.firstResponder, r is NSText { return false }
        guard let w, w === NSApp.mainWindow, !w.isSheet, !(w is NSPanel) else { return false }
        return true
    }
    /// Ends text editing in the main window (commits the field): AppKit buttons and SwiftUI views do not take first responder on a click.
    @MainActor static func endTextEditing() {
        guard let w = NSApp.keyWindow, w === NSApp.mainWindow, !w.isSheet, !(w is NSPanel), w.firstResponder is NSText else { return }
        w.makeFirstResponder(nil)
    }
    /// Runs the editor action unless typing goes elsewhere: a text field being edited gets the standard AppKit action, and sheets, panels and
    /// plug-in windows (anything but the main window) are left alone, so a shortcut never reaches the timeline while the user types or adjusts an effect.
    @MainActor static func run(_ standard: Selector, _ editorAction: () -> Void) {
        if routesToEditor() { editorAction() } else { NSApp.sendAction(standard, to: nil, from: nil) }
    }
}

/// Where Undo/Redo go right now. A text field being edited keeps its own history while it has something to undo/redo; with nothing to undo there the
/// editor's history answers (main window only). Sheets, panels and plug-in windows are never routed to the editor.
@MainActor enum UndoTarget {
    case editor, standard
    static func resolve(redo: Bool) -> (target: UndoTarget, standardEnabled: Bool) {
        let w = NSApp.keyWindow
        let r = w?.firstResponder
        let um = (r as? NSResponder)?.undoManager ?? w?.undoManager
        let std = redo ? (um?.canRedo ?? false) : (um?.canUndo ?? false)
        if r is NSText { return (.standard, std) }          // while a text is edited, Undo/Redo stay in it (disabled once it has nothing left); the timeline is reached by leaving the field
        guard let w, w === NSApp.mainWindow, !w.isSheet, !(w is NSPanel) else { return (.standard, std) }
        return (.editor, std)
    }
}

/// What Edit ▸ Undo/Redo should offer right now. Refreshed on every event-loop pass; publishes only on change.
@MainActor final class UndoContext: ObservableObject {
    static let shared = UndoContext()
    @Published private(set) var undoToEditor = true
    @Published private(set) var redoToEditor = true
    @Published private(set) var standardCanUndo = false
    @Published private(set) var standardCanRedo = false
    private var token: NSObjectProtocol?
    init() { token = NotificationCenter.default.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } } }
    func refresh() {
        let u = UndoTarget.resolve(redo: false), r = UndoTarget.resolve(redo: true)
        let ue = u.target == .editor, re = r.target == .editor
        if ue != undoToEditor { undoToEditor = ue }
        if re != redoToEditor { redoToEditor = re }
        if u.standardEnabled != standardCanUndo { standardCanUndo = u.standardEnabled }
        if r.standardEnabled != standardCanRedo { standardCanRedo = r.standardEnabled }
    }
    /// Runs the editor action, or sends the standard action to the first responder.
    func perform(redo: Bool, _ standard: Selector, _ editorAction: () -> Void) {
        if UndoTarget.resolve(redo: redo).target == .editor { editorAction() } else { NSApp.sendAction(standard, to: nil, from: nil) }
    }
}
