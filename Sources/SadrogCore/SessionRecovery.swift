// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation

public enum RecoveryResult: Sendable, Equatable {
    case playable(duration: Double, hasVideo: Bool, hasAudio: Bool)
    case unreadable(String)
}

/// Checks a session left in state `recording` (crash / kill). Fragmented MOV stays readable up to the last written fragment
/// (probe P2: ~91% kept after kill -9). Never deletes or rewrites the media; only updates the journal.
public enum SessionRecovery {
    public static func inspect(folder: URL) async -> RecoveryResult {
        guard let j = try? SessionJournal.read(from: folder) else { return .unreadable(T("jurnal lipsă sau ilizibil")) }
        let asset = AVURLAsset(url: folder.appendingPathComponent(j.mediaFile))
        do {
            let v = try await asset.loadTracks(withMediaType: .video), a = try await asset.loadTracks(withMediaType: .audio)
            let d = try await asset.load(.duration).seconds
            guard !v.isEmpty, d > 0 else { return .unreadable(T("fără video redabil")) }
            return .playable(duration: d, hasVideo: true, hasAudio: !a.isEmpty)
        } catch { return .unreadable(error.localizedDescription) }
    }

    @discardableResult
    public static func resolve(folder: URL) async throws -> (SessionJournal, RecoveryResult) {
        var j = try SessionJournal.read(from: folder)
        let r = await inspect(folder: folder)
        switch r {
        case .playable(let d, _, _): j.state = .recovered; j.note = String(format: T("Recuperat după oprire bruscă: %.1f s redabile."), d)
        case .unreadable(let why): j.state = .failed; j.note = "Nerecuperabil: \(why)"
        }
        try j.write(to: folder)
        return (j, r)
    }
}
