// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// File menu: the same commands as the editor bar and the start page (one action behind each control). Items that need the editor follow it and its state.
struct FileMenuContent: View {
    @ObservedObject var recorder: RecorderModel
    var body: some View {
        Button(T("Document nou…")) { recorder.requestNewDocument() }.shortcut("file.new").disabled(recorder.phase != .idle)
        Button(T("Deschide proiect…")) { recorder.openProjectFromDisk() }.shortcut("file.open").disabled(recorder.phase != .idle)
        Menu(T("Deschide recent")) {
            if recorder.documents.isEmpty { Button(T("Niciun proiect recent")) {}.disabled(true) }
            ForEach(Array(recorder.documents.prefix(10).enumerated()), id: \.offset) { _, d in Button(d.name) { Task { await recorder.openDocument(d.folder) } } }
        }.disabled(recorder.phase != .idle)
        Divider()
        if let e = recorder.editor { EditorFileItems(recorder: recorder, e: e) }
        else {
            Button(T("Importă video sau sunet…")) {}.disabled(true)
            Button(T("Adaugă înregistrare…")) {}.disabled(true)
            Button(T("Exportă…")) {}.disabled(true)
        }
    }
}
struct EditorFileItems: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject var e: EditorModel
    var body: some View {
        Button(T("Importă video sau sunet…")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.importMaterials() } }.shortcut("file.import")
        Button(T("Adaugă înregistrare…")) { EditCommand.run(Selector(("sadrogNoop:"))) { recorder.beginAddRecording() } }.shortcut("file.addRecording").disabled(recorder.phase != .idle)
        Divider()
        Button(T("Exportă…")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.openExport() } }.shortcut("file.export").disabled(e.project.clips.isEmpty || !e.missing.isEmpty)
    }
}

/// View menu: panels and the viewer's zoom. The panel toggles use the same stored switches as the editor, so menu and bar always agree.
struct ViewMenuContent: View {
    @ObservedObject var recorder: RecorderModel
    @AppStorage("editor.showLibrary") private var showLib = true
    @AppStorage("editor.showInspector") private var showInsp = true
    var body: some View {
        let e = recorder.editor
        Button(showLib ? T("Ascunde biblioteca") : T("Arată biblioteca")) { showLib.toggle() }.shortcut("view.library").disabled(e == nil)
        Button(showInsp ? T("Ascunde inspectorul") : T("Arată inspectorul")) { showInsp.toggle() }.shortcut("view.inspector").disabled(e == nil)
        Divider()
        Button(T("Mărește previzualizarea")) { EditCommand.run(Selector(("sadrogNoop:"))) { e?.stepView(true) } }.shortcut("view.previewZoomIn").disabled(e == nil)
        Button(T("Micșorează previzualizarea")) { EditCommand.run(Selector(("sadrogNoop:"))) { e?.stepView(false) } }.shortcut("view.previewZoomOut").disabled(e == nil)
        Button(T("Potrivire în fereastră")) { EditCommand.run(Selector(("sadrogNoop:"))) { e?.fitView() } }.shortcut("view.previewFit").disabled(e == nil)
    }
}

/// Edit ▸ Delete: the standard action in a text field, the selected items in the editor.
struct DeleteMenuItem: View {
    @ObservedObject var recorder: RecorderModel
    var body: some View {
        if let e = recorder.editor { Inner(e: e) } else { Button(T("Șterge")) {}.disabled(true) }
    }
    struct Inner: View {
        @ObservedObject var e: EditorModel
        var body: some View { Button(T("Șterge")) { EditCommand.run(Selector(("delete:"))) { e.deleteSelectedItems() } }.shortcut("edit.delete").disabled(!e.hasSelection) }
    }
}

/// Track commands of the Timeline menu, acting on the selected overlay's lane/row (the same operations as the track header menu).
struct TrackMenuItems: View {
    @ObservedObject var e: EditorModel
    private var lane: TrackLane? { guard let l = e.selectedLayer else { return nil }; return l.kind == .video ? .v2 : .a2 }
    var body: some View {
        Button(T("Taie la cursor")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.split() } }.shortcut("timeline.split")
        Button(T("Taie elementele selectate la cursor")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.splitSelected() } }.shortcut("timeline.splitSelected").disabled(e.selectedIDs.isEmpty)
        Divider()
        Menu(T("Pistă")) {
            Button(T("Adaugă pistă video suprapusă")) { e.addTrack(.v2) }
            Button(T("Adaugă pistă audio")) { e.addTrack(.a2) }
            Button(T("Adaugă pistă de efecte")) { e.addTrack(.c) }
            Divider()
            Button(T("Mută elementul pe rândul de deasupra")) { if let l = e.selectedLayer { e.moveLayerRow(l.id, by: 1) } }.disabled(e.selectedLayer == nil)
            Button(T("Mută elementul pe rândul de dedesubt")) { if let l = e.selectedLayer { e.moveLayerRow(l.id, by: -1) } }.disabled(e.selectedLayer == nil)
            Button(T("Redenumește pista elementului…")) { if let l = e.selectedLayer, let ln = lane { e.renameTrack(ln, l.row) } }.disabled(e.selectedLayer == nil)
        }
    }
}
