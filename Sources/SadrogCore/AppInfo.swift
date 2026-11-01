// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

public enum AppInfo {
    public static let name = "SADROG"
    public static let version = "1.1.0"
    public static let bundleID = "dev.gordas.sadrog"
    /// Build number and source identifier written into Info.plist by scripts/build_app.sh (commit count; short commit hash, „+modificări”
    /// when the tree had uncommitted changes). A build run from Xcode/swift run has neither.
    public static var build: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "dev" }
    public static var sourceID: String { Bundle.main.object(forInfoDictionaryKey: "SADROGSourceID") as? String ?? "local" }
    public static var buildDate: String { Bundle.main.object(forInfoDictionaryKey: "SADROGBuildDate") as? String ?? "" }
    /// One line for the UI: „0.1.0 · build 61 · sursa 1a2b3c4”.
    /// Where this app keeps its own small data files: "SADROG" for the product (`dev.gordas.sadrog*` intermediates included), and a separate "SADROG-<bundle id>"
    /// for any other bundle id (e.g. a verification bundle), so a test copy never reads or writes the data of the app in use. `SADROG_DATA_DIR` overrides it entirely.
    public static var supportFolder: URL {
        if let o = ProcessInfo.processInfo.environment["SADROG_DATA_DIR"], !o.isEmpty { return URL(fileURLWithPath: o) }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let id = Bundle.main.bundleIdentifier ?? bundleID
        return base.appendingPathComponent(id == bundleID ? "SADROG" : "SADROG-" + id)
    }
    public static var fullVersion: String { L10n.f("%@ · build %@ · sursa %@", "\(version)", "\(build)", "\(sourceID)") }
}
