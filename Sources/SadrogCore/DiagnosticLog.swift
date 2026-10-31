// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation
import os

/// The single diagnostic log: os_log (subsystem = bundle ID) + ~/Library/Logs/SADROG.log (`timestamp level [category] message`,
/// rotated at ~5 MB to SADROG.log.1). Never passwords, keys, tokens, licence texts or file contents.
public struct DiagnosticLog: Sendable {
    public let category: String
    public init(_ category: String) { self.category = category }
    public static let fileURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/SADROG.log")
    private static let queue = DispatchQueue(label: "dev.gordas.sadrog.log")

    public func info(_ m: String) { write("INFO", m) }
    public func warning(_ m: String) { write("WARN", m) }
    public func error(_ m: String) { write("ERROR", m) }

    private func write(_ level: String, _ message: String) {
        Logger(subsystem: AppInfo.bundleID, category: category).log("\(level, privacy: .public) \(message, privacy: .public)")
        let line = "\(WireTime.format(Date())) \(level) [\(category)] \(message)\n"
        Self.queue.async {
            let fm = FileManager.default, url = Self.fileURL
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int), size > 5_000_000 {
                let old = url.appendingPathExtension("1"); try? fm.removeItem(at: old); try? fm.moveItem(at: url, to: old)
            }
            if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        }
    }
}
