// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// A key command shown on screen, `t` seconds into the recording (pauses excluded, like the media). Only the label of a COMMAND is kept (⌘K, ⌥⇧F, ⎋…);
/// ordinary typing is never stored, so a password or a sentence cannot end up in the file.
public struct KeyStroke: Codable, Equatable, Sendable {
    public var t: Double, label: String
    public init(t: Double, label: String) { self.t = t; self.label = label }
}

/// The key commands of one recording, kept next to the recording as `keys.json`. `syntheticFixture` marks a track made by a test, never by a person.
public struct KeyTrack: Codable, Equatable, Sendable {
    public static let fileName = "keys.json"
    public static let holdSeconds = 1.4
    public static let maxVisible = 3
    public var schema = 1
    public var syntheticFixture = false
    public var syncOffset = 0.0
    public var strokes: [KeyStroke]
    public init(strokes: [KeyStroke], syntheticFixture: Bool = false, syncOffset: Double = 0) { self.strokes = strokes.sorted { $0.t < $1.t }; self.syntheticFixture = syntheticFixture; self.syncOffset = syncOffset }

    /// Commands on screen at media time `t`, oldest first, at most `maxVisible`; each with how far into its life it is (0…1) for the fade.
    public func visible(at t: Double, hold: Double = KeyTrack.holdSeconds) -> [(label: String, age: Double)] {
        let u = t - syncOffset
        let live = strokes.filter { $0.t <= u && u - $0.t < hold }
        return live.suffix(Self.maxVisible).map { ($0.label, (u - $0.t) / hold) }
    }

    public static func url(besideMedia media: String) -> URL { URL(fileURLWithPath: media).deletingLastPathComponent().appendingPathComponent(fileName) }
    public static func load(besideMedia media: String) -> KeyTrack? {
        guard let d = try? Data(contentsOf: url(besideMedia: media)), let t = try? JSONDecoder().decode(KeyTrack.self, from: d), t.schema == 1, !t.strokes.isEmpty else { return nil }
        return t
    }
    public func save(to folder: URL) throws {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]
        try e.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }

    /// Names of the keys that have no printable character, by macOS virtual key code (ANSI keyboard); nil for an ordinary key.
    public static func specialName(keyCode: UInt16) -> String? {
        let map: [UInt16: String] = [49: "space", 36: "return", 76: "return", 48: "tab", 53: "escape", 51: "delete", 117: "forwarddelete", 123: "left", 124: "right", 125: "down", 126: "up",
                                     115: "home", 119: "end", 116: "pageup", 121: "pagedown", 122: "f1", 120: "f2", 99: "f3", 118: "f4", 96: "f5", 97: "f6", 98: "f7", 100: "f8", 101: "f9", 109: "f10", 103: "f11", 111: "f12"]
        return map[keyCode]
    }
    /// The label of a key command, or nil when the key press is ordinary typing (no ⌘, ⌃ or ⌥ and not a function/special key) — those are never kept.
    /// `key` is the unmodified key (a character like "k", or a special name: "space", "return", "tab", "escape", "delete", "left", "right", "up", "down", "f1"…).
    public static func label(key: String, command: Bool, control: Bool, option: Bool, shift: Bool) -> String? {
        let k = key.lowercased()
        guard !k.isEmpty else { return nil }
        let special: [String: String] = ["space": "␣", "return": "↩", "tab": "⇥", "escape": "⎋", "delete": "⌫", "forwarddelete": "⌦", "left": "←", "right": "→", "up": "↑", "down": "↓", "home": "↖", "end": "↘", "pageup": "⇞", "pagedown": "⇟"]
        let isFunction = k.count >= 2 && k.hasPrefix("f") && Int(k.dropFirst()) != nil
        let isSpecial = special[k] != nil || isFunction
        guard command || control || option || isFunction else { return nil }      // plain letters, digits and also bare Space/Return/arrows = typing or navigation, not a command to show
        guard k.count == 1 || isSpecial else { return nil }
        let name = special[k] ?? (isFunction ? k.uppercased() : k.uppercased())
        return (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (command ? "⌘" : "") + name
    }
}

/// The one place where a raw key event becomes (or does not become) a stored label. The operating system hands a global monitor EVERY key press, so the event is
/// read here for an instant; the decision is made at once and nothing but a command label can leave this function. While Secure Event Input is on (password
/// fields, some terminals) macOS withholds key events from other apps; this also drops anything that still arrives.
public enum KeyCapture {
    public static func label(keyCode: UInt16, characters: String?, command: Bool, control: Bool, option: Bool, shift: Bool, secureInput: Bool) -> String? {
        guard !secureInput else { return nil }
        let name = KeyTrack.specialName(keyCode: keyCode) ?? characters ?? ""
        return KeyTrack.label(key: name, command: command, control: control, option: option, shift: shift)
    }
}

/// Collects key commands ONLY between `start()` and `stop()` and only when the caller feeds it (the caller decides whether the setting is on and the system
/// permission is granted). Takes labels, not raw key events: the text typed never reaches this type. Time source injected for tests.
public final class KeyRecorder: @unchecked Sendable {
    private let lock = NSLock(), now: () -> Double
    private var strokes: [KeyStroke] = [], running = false, clockStart = 0.0, paused = false, pausedTotal = 0.0, pausedAt = 0.0
    public init(now: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) { self.now = now }
    public var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    public func start() { lock.lock(); running = true; clockStart = now(); strokes = []; paused = false; pausedTotal = 0; lock.unlock() }
    public func pause() { lock.lock(); if running, !paused { paused = true; pausedAt = now() }; lock.unlock() }
    public func resume() { lock.lock(); if paused { paused = false; pausedTotal += now() - pausedAt }; lock.unlock() }
    /// Records a command label (already filtered by `KeyTrack.label`); ignored when not running or paused.
    public func record(label: String) {
        lock.lock(); defer { lock.unlock() }
        guard running, !paused, !label.isEmpty else { return }
        strokes.append(KeyStroke(t: max(0, now() - clockStart - pausedTotal), label: label))
    }
    public func stop() -> KeyTrack { lock.lock(); running = false; let s = strokes; strokes = []; lock.unlock(); return KeyTrack(strokes: s) }
}

/// What the editor draws from a recording's key track, per clip: the commands as small keycaps at the bottom of the picture.
public struct KeyFX: Codable, Equatable, Sendable {
    public var show = false
    public init(show: Bool = false) { self.show = show }
}
