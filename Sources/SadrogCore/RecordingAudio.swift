// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// One audio track of a recording as the editor shows it: position in the file, a readable name, what it was captured from.
public struct AudioSourceInfo: Equatable, Sendable {
    public var index: Int                 // 0-based audio track in the media file
    public var name: String
    public var kind: AudioSourceKind?     // nil when the recording has no sources.json entry for it
}

/// Names the audio tracks of a media file from the sources.json written next to it by the recorder.
/// The manifest `index` (file order) decides the mapping, not the array order; tracks without an entry get a numbered name.
public enum RecordingAudio {
    public static func sources(media: String, trackCount: Int) -> [AudioSourceInfo] {
        let folder = URL(fileURLWithPath: media).deletingLastPathComponent()
        return sources(manifest: (try? SourcesManifest.read(from: folder))?.audioTracks, trackCount: trackCount)
    }

    public static func sources(manifest: [SourcesManifest.Track]?, trackCount: Int) -> [AudioSourceInfo] {
        var out = (0..<max(0, trackCount)).map { AudioSourceInfo(index: $0, name: L10n.f("Pista audio %@", "\($0 + 1)"), kind: nil) }
        for t in manifest ?? [] where out.indices.contains(t.index) {
            let n = t.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
            out[t.index].name = n.isEmpty ? (t.kind == .system ? "Sunetul calculatorului" : out[t.index].name) : n
            out[t.index].kind = t.kind
        }
        let counts = Dictionary(grouping: out, by: \.name).mapValues(\.count)
        for i in out.indices where (counts[out[i].name] ?? 0) > 1 { out[i].name += L10n.f(" · pista %@", "\(i + 1)") }
        return out
    }
}
