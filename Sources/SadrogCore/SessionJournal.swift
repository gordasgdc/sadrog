// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// Small JSON file next to a recording; lets the app detect and offer recovery of sessions that never finished.
public struct SessionJournal: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case recording, finished, failed, recovered }
    public var id: String
    public var state: State
    public var startedAt: Date
    public var mediaFile: String
    public var fragmentSeconds: Double
    public var width: Int
    public var height: Int
    public var fps: Int
    public var note: String

    public init(id: String, state: State, startedAt: Date, mediaFile: String, fragmentSeconds: Double = 10, width: Int, height: Int, fps: Int, note: String = "") {
        self.id = id; self.state = state; self.startedAt = startedAt; self.mediaFile = mediaFile; self.fragmentSeconds = fragmentSeconds; self.width = width; self.height = height; self.fps = fps; self.note = note
    }
    public static let fileName = "session.json"

    public func write(to folder: URL) throws {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]; enc.dateEncodingStrategy = .iso8601
        try enc.encode(self).write(to: folder.appendingPathComponent(Self.fileName), options: .atomic)
    }
    public static func read(from folder: URL) throws -> SessionJournal {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        return try dec.decode(SessionJournal.self, from: Data(contentsOf: folder.appendingPathComponent(fileName)))
    }
    /// Finished or recovered sessions (ready to edit), newest first.
    public static func editable(under root: URL) -> [(folder: URL, journal: SessionJournal)] {
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return kids.compactMap { f in
            guard let j = try? read(from: f), j.state == .finished || j.state == .recovered else { return nil }
            return (f, j)
        }.sorted { $0.journal.startedAt > $1.journal.startedAt }
    }
    /// Sessions under `root` whose journal still says `recording` (app crashed / was killed).
    public static func unfinished(under root: URL) -> [(folder: URL, journal: SessionJournal)] {
        let kids = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        return kids.compactMap { f in
            guard let j = try? read(from: f), j.state == .recording else { return nil }
            return (f, j)
        }.sorted { $0.journal.startedAt < $1.journal.startedAt }
    }
}
