// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// Interface languages. Romanian is the source language: every key of the catalog is the Romanian text itself.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case ro, en, es
    public var id: String { rawValue }
    public var name: String { switch self { case .ro: "Română"; case .en: "English"; case .es: "Español" } }
    /// The chosen language (Settings), else the system's first supported language, else English.
    public static var current: AppLanguage {
        if let s = UserDefaults.standard.string(forKey: "sadrog.language"), let l = AppLanguage(rawValue: s) { return l }
        for p in Locale.preferredLanguages { if let l = AppLanguage(rawValue: String(p.prefix(2))) { return l } }
        return .en
    }
}

/// The ONE catalog of the app's own texts (`L10nCatalog.entries`, generated from `Localization/catalog.tsv`).
/// Technical identifiers, file names and third-party plugin interfaces are never translated.
public enum L10n {
    /// Text in the current language; a key missing from the catalog falls back to Romanian (listed by `scripts/l10n_check.py`).
    public static func t(_ ro: String, _ lang: AppLanguage = .current) -> String {
        guard lang != .ro, let e = L10nCatalog.entries[ro] else { return ro }
        let v = lang == .en ? e.0 : e.1
        return v.isEmpty ? ro : v
    }
    /// Text with `%@` / `%d` placeholders filled in (same order in every language).
    /// A file size in the APP language (not the system's): "2.7 MB" in English, "2,7 MB" in Romanian and Spanish — the decimal mark follows the interface language.
    public static func bytes(_ b: Int64, _ lang: AppLanguage = .current) -> String {
        b.formatted(.byteCount(style: .file).locale(Locale(identifier: lang == .en ? "en_US" : lang == .es ? "es_ES" : "ro_RO")))
    }
    /// A date and time in the APP language (not the system's): "30 oct. 2026, 14:05" / "Oct 30, 2026 at 2:05 PM" / "30 oct 2026, 14:05".
    public static func date(_ d: Date, time: Bool = true, _ lang: AppLanguage = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: lang.rawValue); f.dateStyle = .medium; f.timeStyle = time ? .short : .none
        return f.string(from: d)
    }
    public static func f(_ ro: String, _ args: CVarArg...) -> String { String(format: t(ro), locale: Locale(identifier: AppLanguage.current.rawValue), arguments: args) }
}

/// Short form used across the UI.
public func T(_ ro: String) -> String { L10n.t(ro) }
