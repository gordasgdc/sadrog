// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// The user manual: one PDF per interface language at a stable public address (the same files the site links to).
public enum UserManual {
    public static func url(_ lang: AppLanguage) -> URL {
        URL(string: "https://gordas.dev/sadrog/manual/SADROG-Manual-\(lang.rawValue.uppercased()).pdf")!
    }
}
