// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// One keyboard combination. `key` is a lowercase character or one of the named keys below.
public struct KeyCombo: Codable, Hashable, Sendable {
    public var key: String
    public var command = false, shift = false, option = false, control = false
    public init(_ key: String, command: Bool = false, shift: Bool = false, option: Bool = false, control: Bool = false) {
        self.key = key.count == 1 ? key.lowercased() : key; self.command = command; self.shift = shift; self.option = option; self.control = control
    }
    public static let named: [String: String] = ["space": "Space", "left": "←", "right": "→", "up": "↑", "down": "↓", "delete": "⌫", "escape": "⎋", "return": "↩", "tab": "⇥"]
    /// Display text in the macOS order (⌃⌥⇧⌘ then the key).
    public var display: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + (Self.named[key] ?? key.uppercased())
    }
    /// A key with no modifier (or only ⇧) is an editing key: it must never act while a text field has the keyboard.
    public var isPlain: Bool { !command && !option && !control }
}

public enum CommandCategory: String, CaseIterable, Sendable { case file, view, edit, timeline, tools, keyframes, audio, inspector, playback }

public struct CommandDef: Sendable {
    public let id: String, title: String, category: CommandCategory, defaultCombo: KeyCombo?
    /// Standard system commands (undo, copy…) are shown but cannot be changed.
    public var locked = false
    public init(_ id: String, _ title: String, _ category: CommandCategory, _ combo: KeyCombo?, locked: Bool = false) { self.id = id; self.title = title; self.category = category; self.defaultCombo = combo; self.locked = locked }
}

/// The single list of commands that have a keyboard shortcut. Menus, tooltips, hidden editor keys and Settings ▸ Shortcuts all read THIS list and the user's overrides.
public enum Commands {
    public static let all: [CommandDef] = [
        CommandDef("file.new", "Document nou…", .file, KeyCombo("n", command: true)),
        CommandDef("file.open", "Deschide proiect…", .file, KeyCombo("o", command: true)),
        CommandDef("file.import", "Importă video sau sunet…", .file, KeyCombo("i", command: true, shift: true)),
        CommandDef("file.addRecording", "Adaugă înregistrare…", .file, KeyCombo("r", command: true, shift: true)),
        CommandDef("file.export", "Exportă…", .file, KeyCombo("e", command: true)),
        CommandDef("view.library", "Arată/ascunde biblioteca", .view, KeyCombo("s", command: true, control: true)),
        CommandDef("view.inspector", "Arată/ascunde inspectorul", .view, KeyCombo("i", command: true, option: true)),
        CommandDef("view.previewZoomIn", "Mărește previzualizarea", .view, KeyCombo("=", command: true)),
        CommandDef("view.previewZoomOut", "Micșorează previzualizarea", .view, KeyCombo("-", command: true)),
        CommandDef("view.previewFit", "Potrivire în fereastră", .view, KeyCombo("0", command: true)),
        CommandDef("timeline.zoomIn", "Mărește scara timeline-ului", .view, KeyCombo("=", control: true)),
        CommandDef("timeline.zoomOut", "Micșorează scara timeline-ului", .view, KeyCombo("-", control: true)),
        CommandDef("timeline.fit", "Potrivește tot proiectul în fereastră", .view, KeyCombo("0", control: true)),
        CommandDef("timeline.tracksTaller", "Piste mai înalte", .view, KeyCombo("=", option: true, control: true)),
        CommandDef("timeline.tracksShorter", "Piste mai joase", .view, KeyCombo("-", option: true, control: true)),
        CommandDef("edit.undo", "Anulează ultima modificare", .edit, KeyCombo("z", command: true), locked: true),
        CommandDef("edit.redo", "Refă modificarea", .edit, KeyCombo("z", command: true, shift: true), locked: true),
        CommandDef("edit.delete", "Șterge", .edit, KeyCombo("delete")),
        CommandDef("clip.duplicate", "Duplică", .edit, KeyCombo("d", command: true)),
        CommandDef("clip.rename", "Redenumește…", .edit, KeyCombo("r", command: true, option: true)),
        CommandDef("clip.detachAudio", "Detașează sunetul", .edit, KeyCombo("d", command: true, option: true)),
        CommandDef("timeline.split", "Taie la cursor", .timeline, KeyCombo("k", command: true)),
        CommandDef("timeline.splitSelected", "Taie elementele selectate la cursor", .timeline, KeyCombo("k", command: true, shift: true)),
        CommandDef("timeline.marker", "Adaugă marcaj", .timeline, KeyCombo("m", option: true)),
        CommandDef("timeline.markerNext", "Marcajul următor", .timeline, KeyCombo(".", option: true)),
        CommandDef("timeline.markerPrev", "Marcajul anterior", .timeline, KeyCombo(",", option: true)),
        CommandDef("timeline.freeze", "Îngheață cadrul", .timeline, KeyCombo("f", option: true)),
        CommandDef("range.in", "Setează In la cursor", .timeline, KeyCombo("i", option: true)),
        CommandDef("range.out", "Setează Out la cursor", .timeline, KeyCombo("o", option: true)),
        CommandDef("key.marker", "Marcaj la cursor (tastă simplă)", .timeline, KeyCombo("m")),
        CommandDef("key.in", "In la cursor (tastă simplă)", .timeline, KeyCombo("i")),
        CommandDef("key.out", "Out la cursor (tastă simplă)", .timeline, KeyCombo("o")),
        CommandDef("tool.select", "Unealta Selectare", .tools, KeyCombo("a")),
        CommandDef("tool.selectAlt", "Unealta Selectare (alternativ)", .tools, KeyCombo("v")),
        CommandDef("tool.blade", "Unealta Foarfecă", .tools, KeyCombo("b")),
        CommandDef("tool.volume", "Unealta Volum (automatizare)", .tools, KeyCombo("u")),
        CommandDef("tool.escape", "Înapoi la Selectare", .tools, KeyCombo("escape")),
        CommandDef("tool.snap", "Magnetism (snapping)", .tools, KeyCombo("s")),
        CommandDef("play.toggle", "Redă / pauză", .playback, KeyCombo("space")),
        CommandDef("play.stepBack", "Un cadru înapoi", .playback, KeyCombo("left")),
        CommandDef("play.stepForward", "Un cadru înainte", .playback, KeyCombo("right")),
        CommandDef("keyframe.add", "Cheie la cursor", .keyframes, KeyCombo("k", option: true)),
        CommandDef("keyframe.delete", "Șterge cheia selectată", .keyframes, KeyCombo("delete", option: true)),
        CommandDef("keyframe.next", "Cheia următoare", .keyframes, KeyCombo("]", option: true)),
        CommandDef("keyframe.prev", "Cheia anterioară", .keyframes, KeyCombo("[", option: true)),
        CommandDef("audio.fadeIn", "Fade-in până la cursor", .audio, KeyCombo("1", option: true, control: true)),
        CommandDef("audio.fadeOut", "Fade-out de la cursor", .audio, KeyCombo("2", option: true, control: true)),
        CommandDef("inspector.video", "Inspector: Video", .inspector, KeyCombo("1", option: true)),
        CommandDef("inspector.sound", "Inspector: Sunet", .inspector, KeyCombo("2", option: true)),
        CommandDef("inspector.time", "Inspector: Timp", .inspector, KeyCombo("3", option: true)),
        CommandDef("inspector.cursor", "Inspector: Cursor", .inspector, KeyCombo("4", option: true)),
    ]
    public static func def(_ id: String) -> CommandDef? { all.first { $0.id == id } }
    /// Combinations the system or the standard Edit menu own: they can not be assigned.
    public static let reserved: Set<KeyCombo> = [KeyCombo("c", command: true), KeyCombo("x", command: true), KeyCombo("v", command: true), KeyCombo("a", command: true),
        KeyCombo("q", command: true), KeyCombo("h", command: true), KeyCombo("w", command: true), KeyCombo("m", command: true), KeyCombo(",", command: true), KeyCombo("tab", command: true)]
}

public enum ShortcutAssign: Equatable, Sendable { case ok, reserved, locked, conflict([String]) }

/// The user's changes on top of the default list. Value type: persisted as JSON, fully testable.
public struct ShortcutMap: Codable, Equatable, Sendable {
    public var custom: [String: KeyCombo] = [:]
    public var removed: Set<String> = []
    public init() {}
    public func combo(_ id: String) -> KeyCombo? {
        if removed.contains(id) { return nil }
        return custom[id] ?? Commands.def(id)?.defaultCombo
    }
    public func isCustomised(_ id: String) -> Bool { custom[id] != nil || removed.contains(id) }
    /// Commands (other than `id`) that currently use `combo`.
    public func users(of combo: KeyCombo, excluding id: String) -> [String] { Commands.all.filter { $0.id != id && self.combo($0.id) == combo }.map(\.id) }
    /// Assigns `combo`; with a conflict nothing changes unless `replacing` is true (the others then lose it).
    @discardableResult public mutating func set(_ id: String, _ combo: KeyCombo, replacing: Bool = false) -> ShortcutAssign {
        guard let d = Commands.def(id) else { return .locked }
        if d.locked { return .locked }
        if Commands.reserved.contains(combo) { return .reserved }
        let others = users(of: combo, excluding: id)
        if !others.isEmpty {
            if !replacing { return .conflict(others) }
            for o in others { remove(o) }
        }
        removed.remove(id)
        if combo == d.defaultCombo { custom[id] = nil } else { custom[id] = combo }
        return .ok
    }
    public mutating func remove(_ id: String) { guard let d = Commands.def(id), !d.locked else { return }; custom[id] = nil; removed.insert(id) }
    public mutating func reset(_ id: String) { custom[id] = nil; removed.remove(id) }
    public mutating func resetAll() { custom = [:]; removed = [] }
    /// A map is valid when no two commands share a combination (defaults are checked by a test).
    public var conflicts: [KeyCombo: [String]] {
        var by: [KeyCombo: [String]] = [:]
        for d in Commands.all { if let c = combo(d.id) { by[c, default: []].append(d.id) } }
        return by.filter { $0.value.count > 1 }
    }
    public func encoded() -> Data? { try? JSONEncoder().encode(self) }
    public static func decoded(_ d: Data?) -> ShortcutMap { d.flatMap { try? JSONDecoder().decode(ShortcutMap.self, from: $0) } ?? ShortcutMap() }
}
