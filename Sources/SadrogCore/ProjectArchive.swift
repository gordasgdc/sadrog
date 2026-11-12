// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// Project + media archive: ONE folder `<name>.sadrogproj` that holds `project.json` and a copy of every media file the project uses
/// (`Media/<NN>/<file>`, with the recording's `sources.json` beside it so the audio sources keep their names). The original project and
/// media are never changed. The archive opens like any project; paths are explicit relative references resolved against the folder that is opened (`ProjectStore.load`), never against another archive.
public enum ProjectArchive {
    public struct Result: Equatable, Sendable { public var folder: URL; public var copied: Int; public var bytes: Int64; public var missing: [String] }
    public enum ArchiveError: Error, Equatable { case exists(URL), noSpace(needed: Int64, free: Int64), missing([String]) }

    /// Every media file the project refers to, in a stable order (timeline, overlays, library).
    public static func mediaFiles(_ p: SadrogProject) -> [String] {
        var seen = Set<String>(); return (p.clips.map(\.media) + p.layers.map(\.media) + p.library).filter { seen.insert($0).inserted }
    }
    /// Space the copy needs (existing files only).
    public static func requiredBytes(_ p: SadrogProject) -> Int64 {
        mediaFiles(p).reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1)[.size] as? Int64) ?? 0) }
    }
    /// Writes the archive into `parent`. Missing media aborts BEFORE anything is written (`ArchiveError.missing`); nothing existing is overwritten; the archive is marked `archived` and holds relative `Media/NN/file` paths, so a copy or move of the folder is self-contained.
    @discardableResult public static func create(_ p: SadrogProject, in parent: URL, named: String? = nil, progress: ((Double) -> Void)? = nil) throws -> Result {
        let fm = FileManager.default
        let safe = (named ?? p.name).replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let folder = parent.appendingPathComponent((safe.isEmpty ? "SADROG" : safe) + ".sadrogproj")
        if fm.fileExists(atPath: folder.path) { throw ArchiveError.exists(folder) }
        let lost = mediaFiles(p).filter { !fm.fileExists(atPath: $0) }
        if !lost.isEmpty { throw ArchiveError.missing(lost) }       // an archive is complete or it does not exist
        let need = requiredBytes(p)
        if let free = try? Destination(url: parent).availableBytes(), free < need + 50_000_000 {   // same rule as export: external disks report 0 "important" capacity
            throw ArchiveError.noSpace(needed: need, free: free)
        }
        let tmp = parent.appendingPathComponent(".\(UUID().uuidString).partial")
        try fm.createDirectory(at: tmp.appendingPathComponent("Media"), withIntermediateDirectories: true)
        var map: [String: String] = [:], copied = 0, bytes: Int64 = 0, missing: [String] = []
        let files = mediaFiles(p)
        do {
            for (i, src) in files.enumerated() {
                try Task.checkCancellation()
                guard fm.fileExists(atPath: src) else { missing.append(src); continue }
                let dirName = String(format: "%02d", i + 1), dir = tmp.appendingPathComponent("Media/\(dirName)")
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                let url = URL(fileURLWithPath: src)
                try fm.copyItem(at: url, to: dir.appendingPathComponent(url.lastPathComponent))
                let manifest = url.deletingLastPathComponent().appendingPathComponent(SourcesManifest.fileName)
                if fm.fileExists(atPath: manifest.path) { try? fm.copyItem(at: manifest, to: dir.appendingPathComponent(SourcesManifest.fileName)) }
                let mouse = MouseTrack.url(besideMedia: src)         // the pointer track travels with the recording it belongs to
                if fm.fileExists(atPath: mouse.path) { try? fm.copyItem(at: mouse, to: dir.appendingPathComponent(MouseTrack.fileName)) }
                let keys = KeyTrack.url(besideMedia: src)
                if fm.fileExists(atPath: keys.path) { try? fm.copyItem(at: keys, to: dir.appendingPathComponent(KeyTrack.fileName)) }
                let win = WindowTrack.url(besideMedia: src)           // so does the front-window track
                if fm.fileExists(atPath: win.path) { try? fm.copyItem(at: win, to: dir.appendingPathComponent(WindowTrack.fileName)) }
                map[src] = "Media/\(dirName)/\(url.lastPathComponent)"      // relative: the archive owns its media
                copied += 1; bytes += (try? fm.attributesOfItem(atPath: src)[.size] as? Int64) ?? 0
                progress?(Double(i + 1) / Double(max(1, files.count)))
            }
            var q = p; q.archived = true
            q.mapMedia { map[$0] ?? $0 }
            try ProjectStore.writeRaw(q, to: tmp)
            try fm.moveItem(at: tmp, to: folder)          // the archive appears whole or not at all
        } catch { try? fm.removeItem(at: tmp); throw error }
        return Result(folder: folder, copied: copied, bytes: bytes, missing: missing)
    }
}

extension SadrogProject {
    mutating func mapMedia(_ f: (String) -> String) {
        for i in clips.indices { clips[i].media = f(clips[i].media) }
        for i in layers.indices { layers[i].media = f(layers[i].media) }
        for i in library.indices { library[i] = f(library[i]) }
        // the sound settings are keyed by media path: they travel with the file
        var moved: [String: RecordingSounds] = [:]
        for (k, v) in recordings { moved[f(k)] = v }
        recordings = moved
    }
}

extension ProjectStore {
    /// In an archive, media inside `<folder>/Media/` is stored relative (`Media/NN/file`); anything else (a file added later) stays absolute.
    static func relativeToArchive(_ path: String, folder: URL) -> String {
        let prefix = folder.standardizedFileURL.path + "/"
        return path.hasPrefix(prefix + "Media/") ? String(path.dropFirst(prefix.count)) : path
    }
    static func absoluteInArchive(_ path: String, folder: URL) -> String {
        path.hasPrefix("/") ? path : folder.standardizedFileURL.appendingPathComponent(path).path
    }
}
