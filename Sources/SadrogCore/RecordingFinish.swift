// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// What happens when a recording ends outside "Add recording…": the user picks a name and a destination document; these are the pure parts of that choice.
public enum RecordingFinish {
    /// "<prefix> 2026-10-31 03.07": readable, sortable, and free of characters a folder name cannot hold.
    public static func defaultName(for date: Date, prefix: String, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = timeZone; f.dateFormat = "yyyy-MM-dd HH.mm"
        return "\(prefix) \(f.string(from: date))"
    }
    /// Trimmed, without path separators or colons, single spaces; an empty result falls back.
    public static func cleanName(_ s: String, fallback: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:")
        let kept = String(s.unicodeScalars.filter { !bad.contains($0) })
        let name = kept.split(whereSeparator: { $0 == " " || $0 == "\t" }).joined(separator: " ")
        return name.isEmpty ? fallback : name
    }
    /// The new document follows the recording (even sides, the recording's frame rate), so nothing is scaled until the user asks for it.
    public static func format(width: Int, height: Int, fps: Double) -> DocumentFormat {
        DocumentFormat(width: max(2, width - width % 2), height: max(2, height - height % 2), fps: fps > 0 ? fps : 30)
    }

    /// Folder layout of a document made here: `<destination>/SADROG-Proiect-xxxxxxxx/project.sadrogproj/project.json`.
    public static let documentFile = "project.sadrogproj"
    /// A new, empty document (name + canvas) in a fresh folder of `destination`. Returns the document folder.
    public static func createDocument(name: String, format: DocumentFormat, in destination: URL) throws -> URL {
        let folder = destination.appendingPathComponent("SADROG-Proiect-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        var p = SadrogProject(name: name); p.canvas = format
        do { try ProjectStore.save(p, to: folder.appendingPathComponent(documentFile)) }
        catch { try? FileManager.default.removeItem(at: folder); throw error }       // nothing but the folder we just made
        return folder
    }
    /// Removes a temporary document that never received anything: the folder holds only the untouched empty project this app made.
    /// It goes to the Trash (recoverable), never deleted outright; anything else in the folder, or any content in the project, keeps it.
    /// The recording itself lives in its own session folder and is never touched here. Returns true when the document was moved to the Trash.
    @discardableResult public static func discardIfUnused(_ folder: URL, toTrash: Bool = true) -> Bool {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path), names == [documentFile] || names.isEmpty,
              let p = try? ProjectStore.load(from: folder.appendingPathComponent(documentFile)),
              p.clips.isEmpty, p.layers.isEmpty, p.texts.isEmpty, p.callouts.isEmpty, p.library.isEmpty, p.markers.isEmpty else { return false }
        // tests pass toTrash: false so their scratch documents do not pile up in the user's Trash
        if toTrash { return (try? fm.trashItem(at: folder, resultingItemURL: nil)) != nil }
        return (try? fm.removeItem(at: folder)) != nil
    }
}
