// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// Contract for every export that writes a file or a folder: nothing that already exists is touched unless the caller says so explicitly (`replaceExisting`),
/// the result is written to a temporary item owned by the operation (same folder, same volume) and only a COMPLETE result is published by one move/replace.
/// On error or cancellation only the temporary item is removed — never the destination, which may be someone else's file.
public enum SafePublish {
    public static func temporary(beside url: URL) -> URL {
        let name = ".\(url.lastPathComponent).sadrog-partial-\(UUID().uuidString.prefix(8))"
        var t = url.deletingLastPathComponent().appendingPathComponent(name)
        if !url.pathExtension.isEmpty { t = t.appendingPathExtension(url.pathExtension) }
        return t
    }
    /// Runs `body` with the temporary destination, then publishes it at `url`.
    public static func run(to url: URL, replaceExisting: Bool = false, _ body: (URL) async throws -> Void) async throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) && !replaceExisting { throw CocoaError(.fileWriteFileExists) }
        let tmp = temporary(beside: url)
        do {
            try await body(tmp)
            try Task.checkCancellation()
            guard fm.fileExists(atPath: tmp.path) else { throw CocoaError(.fileWriteUnknown) }
            if fm.fileExists(atPath: url.path) {
                guard replaceExisting else { throw CocoaError(.fileWriteFileExists) }      // it appeared while we were writing
                _ = try fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch { try? fm.removeItem(at: tmp); throw error }
    }
}
