// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

@main
struct SadrogApp: App {
    /// One recorder for the window, the menu bar and the floating panel (one state machine behind every control).
    @StateObject private var recorder = RecorderModel()
    @Environment(\.openWindow) private var openWindow
    init() {
        DiagnosticLog("app").info("Pornire SADROG \(AppInfo.fullVersion)")
        Task { @MainActor in _ = ActivationModel.shared; UpdateChecker.shared.checkAtLaunch() }
    }
    static func laneName(_ l: TrackLane) -> String {
        switch l { case .t: return T("Titluri"); case .c: return T("Evidențiere"); case .v2: return "Suprapus"; case .v1: return "Video"; case .a1: return T("Sunet"); case .a2: return "Audio" }
    }
    var body: some Scene {
        WindowGroup("SADROG") {
            Group { if ProcessInfo.processInfo.arguments.contains("--components") { ComponentsBoard() } else { RecorderView(m: recorder) } }.appTheme()
        }
            .windowResizability(.contentMinSize)
            .defaultSize(width: 880, height: 640)
            .commands {
                CommandGroup(replacing: .newItem) { FileMenuContent(recorder: recorder) }
                CommandGroup(replacing: .undoRedo) { UndoRedoMenuContent(recorder: recorder) }
                CommandGroup(replacing: .pasteboard) {
                    let e = recorder.editor
                    Button(T("Taie")) { EditCommand.run(#selector(NSText.cut(_:))) { e?.cutSelection() } }.keyboardShortcut("x", modifiers: .command)
                    Button(T("Copiază")) { EditCommand.run(#selector(NSText.copy(_:))) { e?.copySelection() } }.keyboardShortcut("c", modifiers: .command)
                    Button(T("Lipește")) { EditCommand.run(#selector(NSText.paste(_:))) { e?.pasteClipboard() } }.keyboardShortcut("v", modifiers: .command)
                    Button(T("Selectează tot")) { EditCommand.run(#selector(NSText.selectAll(_:))) { e?.selectAll() } }.keyboardShortcut("a", modifiers: .command)
                }
                CommandGroup(after: .pasteboard) { DeleteMenuItem(recorder: recorder) }
                CommandGroup(replacing: .toolbar) { ViewMenuContent(recorder: recorder) }
                CommandMenu(T("Clip")) { ClipMenuContent(recorder: recorder) }
                CommandMenu(T("Timeline")) { TimelineMenuContent(recorder: recorder) }
                CommandGroup(replacing: .appInfo) {
                    Button(T("Despre SADROG")) { openWindow(id: "about") }
                    Button(T("Caută actualizări…")) { UpdateChecker.shared.checkManually() }
                }
                CommandGroup(replacing: .help) { HelpMenuContent() }
            }
        Settings { SettingsView(m: recorder) }
        Window(T("Despre SADROG"), id: "about") { AboutView() }.windowResizability(.contentSize)
        MenuBarExtra { MenuBarControls(m: recorder) } label: {
            Image(systemName: recorder.phase == .recording ? "record.circle.fill" : (recorder.phase == .paused ? "pause.circle" : "record.circle"))
        }
    }
}


/// Edit ▸ Undo/Redo drive the editor's own history (not an NSUndoManager, which stayed empty and left the system items disabled). Text fields and
/// dialogs keep the standard AppKit undo through `EditCommand`; the state follows the open editor like the Clip menu.
struct UndoRedoMenuContent: View {
    @ObservedObject var recorder: RecorderModel
    @ObservedObject private var ctx = UndoContext.shared
    var body: some View {
        if let e = recorder.editor { EditorUndoRedo(e: e, ctx: ctx) }
        else { undoRedo(canUndo: ctx.standardCanUndo, canRedo: ctx.standardCanRedo, undo: {}, redo: {}) }
    }
}
struct EditorUndoRedo: View {
    @ObservedObject var e: EditorModel
    @ObservedObject var ctx: UndoContext
    var body: some View {
        undoRedo(canUndo: ctx.undoToEditor ? e.canUndo : ctx.standardCanUndo, canRedo: ctx.redoToEditor ? e.canRedo : ctx.standardCanRedo, undo: { e.undo() }, redo: { e.redo() })
    }
}
@ViewBuilder private func undoRedo(canUndo: Bool, canRedo: Bool, undo: @escaping () -> Void, redo: @escaping () -> Void) -> some View {
    Button(T("Anulează ultima modificare")) { UndoContext.shared.perform(redo: false, Selector(("undo:"))) { undo() } }.keyboardShortcut("z", modifiers: .command).disabled(!canUndo)
    Button(T("Refă modificarea")) { UndoContext.shared.perform(redo: true, Selector(("redo:"))) { redo() } }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(!canRedo)
}

/// The Clip menu follows the open editor and ITS selection/locks: a plain `Commands` body only watches the recorder, so the items would stay stale.
struct ClipMenuContent: View {
    @ObservedObject var recorder: RecorderModel
    var body: some View { if let e = recorder.editor { EditorClipMenu(e: e) } else { Button(T("Duplică")) {}.disabled(true) } }
}
/// Markers and In/Out follow the open editor; the same commands as the hidden keys (M, I, O) and the ruler.
struct TimelineMenuContent: View {
    @ObservedObject var recorder: RecorderModel
    var body: some View { if let e = recorder.editor { EditorTimelineMenu(e: e) } else { Button(T("Adaugă marcaj")) {}.disabled(true) } }
}
struct EditorTimelineMenu: View {
    @ObservedObject var e: EditorModel
    var body: some View {
        TrackMenuItems(e: e)
        Divider()
        Button(T("Adaugă marcaj")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.addMarkerHere() } }.keyboardShortcut("m", modifiers: .option)
        Button(T("Marcajul următor")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.goToMarker(next: true) } }.keyboardShortcut(".", modifiers: .option).disabled(e.project.markers.isEmpty)
        Button(T("Marcajul anterior")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.goToMarker(next: false) } }.keyboardShortcut(",", modifiers: .option).disabled(e.project.markers.isEmpty)
        Button(T("Îngheață cadrul")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.freezeHere() } }.keyboardShortcut("f", modifiers: .option)
        Divider()
        Button(T("Setează In la cursor")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.setIn() } }.keyboardShortcut("i", modifiers: .option)
        Button(T("Setează Out la cursor")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.setOut() } }.keyboardShortcut("o", modifiers: .option)
        Button(T("Șterge In și Out")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.clearRange() } }.disabled(e.project.rangeIn == nil && e.project.rangeOut == nil)
    }
}
struct EditorClipMenu: View {
    @ObservedObject var e: EditorModel
    var body: some View {
        Button(T("Duplică")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.duplicateSelection() } }.keyboardShortcut("d", modifiers: .command).disabled(!e.hasSelection)
        Button(T("Redenumește…")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.promptRename() } }.keyboardShortcut("r", modifiers: [.command, .option]).disabled(!e.hasSelection)
        Button(T("Detașează sunetul")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.detachAudio() } }.keyboardShortcut("d", modifiers: [.command, .option]).disabled(!e.canDetachAudio())
        Button(T("Reatașează sunetul")) { EditCommand.run(Selector(("sadrogNoop:"))) { e.reattachAudio() } }.disabled(!e.canReattachAudio())
        Divider()
        Menu(T("Blochează pista")) {
            ForEach([TrackLane.t, .c, .v2, .v1, .a2], id: \.self) { l in
                Button((e.isLocked(l) ? "✓ " : "") + SadrogApp.laneName(l)) { e.toggleLock(l) }
            }
        }
    }
}

/// Help ▸ User Manual: opens the PDF of the language chosen in SADROG (not the system's); the other two stay one step away.
struct HelpMenuContent: View {
    var body: some View {
        Button(T("Manual de utilizare…")) { NSWorkspace.shared.open(UserManual.url(.current)) }
        Menu(T("Manualul în altă limbă")) {
            ForEach(AppLanguage.allCases) { l in Button(l.name) { NSWorkspace.shared.open(UserManual.url(l)) } }
        }
    }
}
