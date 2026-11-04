// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import SwiftUI
import SadrogCore

/// The user's keyboard shortcuts (defaults in `Commands`, changes in Settings ▸ Shortcuts). Every menu item, hidden editor key and tooltip reads from here,
/// so what a tooltip says is what the key does, also after customising. Stored as JSON in UserDefaults.
@MainActor final class Shortcuts: ObservableObject {
    static let shared = Shortcuts()
    static let key = "sadrog.shortcuts"
    @Published private(set) var map: ShortcutMap
    private init() { map = ShortcutMap.decoded(UserDefaults.standard.data(forKey: Self.key)) }
    private func save() { UserDefaults.standard.set(map.encoded(), forKey: Self.key) }
    func combo(_ id: String) -> KeyCombo? { map.combo(id) }
    func set(_ id: String, _ c: KeyCombo, replacing: Bool = false) -> ShortcutAssign { let r = map.set(id, c, replacing: replacing); if r == .ok { save() }; return r }
    func remove(_ id: String) { map.remove(id); save() }
    func reset(_ id: String) { map.reset(id); save() }
    func resetAll() { map.resetAll(); save() }
    /// "Text (⌘K)" with the combination that is really assigned (nothing appended when the command has none).
    func tip(_ text: String, _ id: String) -> String { combo(id).map { text + " (" + $0.display + ")" } ?? text }
    func ks(_ id: String, typing: Bool = false) -> KeyboardShortcut? {
        guard let c = combo(id), !(typing && c.isPlain) else { return nil }
        let k: KeyEquivalent
        switch c.key {
        case "space": k = .space; case "left": k = .leftArrow; case "right": k = .rightArrow; case "up": k = .upArrow; case "down": k = .downArrow
        case "delete": k = .delete; case "escape": k = .escape; case "return": k = .return; case "tab": k = .tab
        default: guard let ch = c.key.first else { return nil }; k = KeyEquivalent(ch)
        }
        var m: EventModifiers = []
        if c.command { m.insert(.command) }; if c.shift { m.insert(.shift) }; if c.option { m.insert(.option) }; if c.control { m.insert(.control) }
        return KeyboardShortcut(k, modifiers: m)
    }
}

private struct ShortcutModifier: ViewModifier {
    @ObservedObject var sc = Shortcuts.shared
    let id: String, typing: Bool
    func body(content: Content) -> some View { content.keyboardShortcut(sc.ks(id, typing: typing)) }
}
extension View {
    /// Binds the command's CURRENT combination (plain keys are off while `typing`).
    func shortcut(_ id: String, typing: Bool = false) -> some View { modifier(ShortcutModifier(id: id, typing: typing)) }
}

/// Settings ▸ Shortcuts: search, categories, capture of the wanted combination, conflict detection, change / remove / reset (one or all).
struct ShortcutsSettings: View {
    @ObservedObject private var sc = Shortcuts.shared
    @State private var query = ""
    @State private var category: CommandCategory?
    @State private var capturing: String?
    @State private var monitor = KeyMonitorBox()
    @State private var message: String?
    @State private var pending: (id: String, combo: KeyCombo, others: [String])?
    private func title(_ c: CommandCategory) -> String {
        switch c { case .file: return T("Fișier"); case .view: return T("Vizualizare"); case .edit: return T("Editare"); case .timeline: return T("Timeline"); case .tools: return T("Unelte")
        case .keyframes: return T("Chei"); case .audio: return T("Sunet"); case .inspector: return T("Inspector"); case .playback: return T("Redare") }
    }
    private var shown: [CommandDef] {
        Commands.all.filter { d in
            (category == nil || d.category == category) && (query.isEmpty || T(d.title).localizedCaseInsensitiveContains(query) || (sc.combo(d.id)?.display.localizedCaseInsensitiveContains(query) ?? false))
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                AppTextField(placeholder: T("Caută o comandă sau o combinație"), text: $query).frame(maxWidth: 240)
                Picker("", selection: $category) {
                    Text(T("Toate")).tag(CommandCategory?.none)
                    ForEach(CommandCategory.allCases, id: \.self) { Text(title($0)).tag(CommandCategory?.some($0)) }
                }.labelsHidden().fixedSize().accessibilityLabel(T("Categoria comenzilor"))
                Spacer()
                Button(T("Resetează toate")) { sc.resetAll(); message = nil }.buttonStyle(.gloss(.secondary, compact: true)).disabled(sc.map == ShortcutMap())
                    .help(sc.map == ShortcutMap() ? T("Nicio combinație nu a fost schimbată") : T("Readuce toate combinațiile la valorile implicite"))
            }
            if let message { Text(message).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true) }
            if let p = pending {
                HStack(spacing: 8) {
                    Text(L10n.f("%@ este deja folosită de: %@.", p.combo.display, p.others.compactMap { Commands.def($0).map { T($0.title) } }.joined(separator: ", "))).font(Theme.F.caption).foregroundStyle(Theme.C.warn).fixedSize(horizontal: false, vertical: true)
                    Button(T("Înlocuiește")) { _ = sc.set(p.id, p.combo, replacing: true); pending = nil; message = nil }.buttonStyle(.gloss(.primary, compact: true))
                    Button(T("Renunță")) { pending = nil }.buttonStyle(.gloss(.ghost, compact: true))
                }
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.id) { d in
                        HStack(spacing: 8) {
                            Text(T(d.title)).font(Theme.F.body).lineLimit(1)
                            Spacer(minLength: 4)
                            Button { capturing == d.id ? stop() : start(d.id) } label: {
                                Text(capturing == d.id ? T("Apasă combinația…") : (sc.combo(d.id)?.display ?? T("fără")))
                                    .font(Theme.F.monoSmall).frame(minWidth: 96).padding(.vertical, 3)
                            }.buttonStyle(.gloss(capturing == d.id ? .primary : .secondary, compact: true)).disabled(d.locked)
                                .help(d.locked ? T("Comandă standard de sistem: nu se schimbă") : T("Clic, apoi apasă combinația dorită (Esc renunță)"))
                                .accessibilityLabel(T(d.title)).accessibilityValue(sc.combo(d.id)?.display ?? T("fără"))
                            Button { sc.remove(d.id) } label: { Image(systemName: "xmark").font(Theme.F.iconSmall).frame(width: 22, height: 22).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(Theme.C.textDim).disabled(d.locked || sc.combo(d.id) == nil)
                                .help(T("Elimină combinația acestei comenzi")).accessibilityLabel(L10n.f("Elimină combinația: %@", T(d.title)))
                            Button { sc.reset(d.id) } label: { Image(systemName: "arrow.counterclockwise").font(Theme.F.iconSmall).frame(width: 22, height: 22).contentShape(Rectangle()) }
                                .buttonStyle(.plain).foregroundStyle(Theme.C.textDim).disabled(!sc.map.isCustomised(d.id))
                                .help(T("Revine la combinația implicită")).accessibilityLabel(L10n.f("Resetează combinația: %@", T(d.title)))
                        }.padding(.vertical, 3)
                        HairlineDivider().opacity(0.5)
                    }
                    if shown.isEmpty { Text(T("Nicio comandă găsită.")).font(Theme.F.caption).foregroundStyle(Theme.C.textFaint).padding(.top, 8) }
                }
            }.frame(minHeight: 260, maxHeight: 340)
        }
        .onDisappear { stop() }
    }
    private func stop() { capturing = nil; monitor.stop() }
    private func start(_ id: String) {
        stop(); capturing = id; message = nil; pending = nil
        monitor.token = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard let id = capturing else { return e }
            if e.keyCode == 53 { stop(); return nil }                                    // Esc cancels the capture
            guard let c = Self.combo(from: e) else { return nil }
            stop()
            switch sc.set(id, c) {
            case .ok: message = nil
            case .reserved: message = L10n.f("%@ este rezervată de sistem sau de meniul Editare.", c.display)
            case .locked: message = T("Comandă standard de sistem: nu se schimbă.")
            case .conflict(let others): pending = (id, c, others)
            }
            return nil
        }
    }
    static func combo(from e: NSEvent) -> KeyCombo? {
        let f = e.modifierFlags
        let named: [UInt16: String] = [49: "space", 123: "left", 124: "right", 125: "down", 126: "up", 51: "delete", 36: "return", 48: "tab"]
        let key: String
        if let n = named[e.keyCode] { key = n } else if let ch = e.charactersIgnoringModifiers?.lowercased(), ch.count == 1 { key = ch } else { return nil }
        return KeyCombo(key, command: f.contains(.command), shift: f.contains(.shift), option: f.contains(.option), control: f.contains(.control))
    }
}
