// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

public extension ProjectEditor {
    /// End of the main track: where a recording added from the editor goes (explicit and predictable: nothing already on the timeline moves).
    var endOfMain: Double { project.clipSpans.last?.end ?? 0 }

    /// Adds a captured session to THIS project as one undo step: the screen recording joins the main track after the last clip; cameras and extra screens go on free V2 rows
    /// at the offset measured on the session clock (shifted by the insertion point), cameras as presenter circles. Recordings stay on disk whatever happens to the edit;
    /// the project's canvas and everything else are untouched. Returns the ids (main clip first), nil when nothing was added.
    @discardableResult func addRecordingSession(media: String, duration: Double, journal: SessionJournal) -> [UUID]? {
        guard duration >= Self.minClip else { return nil }
        let at = endOfMain
        var made: [UUID] = []
        let src = SadrogProject.forRecording(name: "", media: media, duration: duration, journal: journal)
        commit { p in
            for c in src.clips { var c = c; c.id = UUID(); p.clips.append(c); made.append(c.id) }
            for var l in src.layers {
                l.id = UUID(); l.start += at; l.track = nil
                var row = 0
                while Self.overlaps(l, in: p) { row += 1; l.track = row }
                p.layers.append(l); made.append(l.id)
            }
            for f in src.library where !p.library.contains(f) { p.library.append(f) }
            if !p.library.contains(media) { p.library.append(media) }
            return !made.isEmpty
        }
        return made.isEmpty ? nil : made
    }
}
