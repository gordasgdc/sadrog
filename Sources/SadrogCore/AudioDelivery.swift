// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation

/// Audio delivery: the full mix and one file per active stem (each recording source of A1, the A2 lane), all rendered from the SAME composition
/// and audio mix as preview/video export, over the WHOLE document (0 … timelineEnd), so every file starts together and has the same length
/// (silence where the stem has nothing). Native format only: AAC in .m4a (AVAssetExportPresetAppleM4A). Master volume → full mix only.
public enum AudioDelivery {
    public struct Item: Equatable, Sendable { public let selection: BuiltComposition.MixSelection; public let label: String; public let fileName: String }

    /// One recording of the project with the names of its audio tracks.
    public struct Recording: Sendable { public let media: String; public let title: String; public let sources: [AudioSourceInfo]
        public init(media: String, title: String, sources: [AudioSourceInfo]) { self.media = media; self.title = title; self.sources = sources } }

    /// What would be written, in order (the full mix first). Muted sources / muted lanes / items with no sound are left out.
    /// A single recording: the files keep their plain names. Several recordings: one set of stems each, the recording named in the file.
    public static func plan(_ p: SadrogProject, sources: [AudioSourceInfo], baseName: String) -> [Item] {
        plan(p, recordings: [Recording(media: p.primaryMedia, title: "", sources: sources)], baseName: baseName)
    }
    public static func plan(_ p: SadrogProject, recordings: [Recording], baseName: String) -> [Item] {
        func safe(_ s: String) -> String { String(s.map { "/:\\".contains($0) ? "-" : $0 }).trimmingCharacters(in: .whitespaces) }
        var out = [Item(selection: .all, label: "Mix complet", fileName: "\(safe(baseName)) - mix.m4a")]
        if !p.mutedLanes.contains(.a1), !p.clips.isEmpty {
            let many = recordings.count > 1
            for (r, rec) in recordings.enumerated() {
                for s in rec.sources where !p.isMuted(source: s.index, media: rec.media) {
                    let tag = many ? "R\(r + 1)-" : ""
                    let label = many ? "A1 · \(rec.title) · \(s.name)" : "A1 · \(s.name)"
                    out.append(Item(selection: many ? .recording(rec.media, s.index) : .source(s.index), label: label,
                                    fileName: "\(safe(baseName)) - A1-\(tag)\(s.index + 1) \(safe(s.name)).m4a"))
                }
            }
        }
        if !p.mutedLanes.contains(.a2), p.layers.contains(where: { $0.kind == .audio && !$0.keepsSource && !($0.audio?.muted ?? false) }) {
            out.append(Item(selection: .a2, label: "A2 · sunet separat", fileName: "\(safe(baseName)) - A2.m4a"))
        }
        return out
    }

    public enum DeliveryError: Error, Equatable { case exists([String]), noSound }

    /// Digital silence, AAC stereo 48 kHz, written in 1 s blocks (an hour stays small on disk).
    static func writeSilence(seconds: Double, to url: URL) throws {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        let f = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2], commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 48000)!
        var left = Int((seconds + 0.25) * 48000)
        while left > 0 { let n = min(48000, left); block.frameLength = AVAudioFrameCount(n); try f.write(from: block); left -= n }
    }

    /// Writes every item into `folder`. Refuses if any target exists (nothing is overwritten). On failure or cancellation every file this
    /// call created is removed, so an incomplete set is never left looking finished. Progress 0…1 over the whole set.
    public static func export(_ p: SadrogProject, items: [Item], to folder: URL, effects: EffectPlan? = nil, progress: (@Sendable (Double) -> Void)? = nil) async throws -> [URL] {
        try ProjectExporter.requireProcessed(p, effects)
        let urls = items.map { folder.appendingPathComponent($0.fileName) }
        let clash = urls.filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
        guard clash.isEmpty else { throw DeliveryError.exists(clash) }
        let built = try await CompositionBuilder.buildFull(p, fx: effects?.ready ?? [:])
        guard !built.composition.tracks(withMediaType: .audio).isEmpty else { throw DeliveryError.noSound }
        // an AAC export ends with the last audio sample; a silent track spanning the whole document makes every file exactly as long
        // as the document (aligned start AND end). Written next to the files, hidden, removed afterwards.
        let silence = folder.appendingPathComponent(".sadrog-silence-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: silence) }
        try writeSilence(seconds: p.timelineEnd, to: silence)
        let sAsset = AVURLAsset(url: silence)
        if let st = try await sAsset.loadTracks(withMediaType: .audio).first, let pad = built.composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
            let d = min(try await st.load(.timeRange).duration, CMTime(seconds: p.timelineEnd, preferredTimescale: 48000))
            try pad.insertTimeRange(CMTimeRange(start: .zero, duration: d), of: st, at: .zero)
        }
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: p.timelineEnd, preferredTimescale: 48000))
        var written: [URL] = []
        do {
            for (i, (item, url)) in zip(items, urls).enumerated() {
                try Task.checkCancellation()
                guard let s = AVAssetExportSession(asset: built.composition, presetName: AVAssetExportPresetAppleM4A) else { throw CocoaError(.fileWriteUnknown) }
                s.timeRange = range; s.audioTimePitchAlgorithm = built.pitch
                // a mix is always given (even neutral) so every stem silences the other tracks
                s.audioMix = built.audioMix(for: p, selection: item.selection) ?? AVMutableAudioMix()
                let n = Double(items.count)
                let watcher = Task { for await st in s.states(updateInterval: 0.2) { if case .exporting(let pr) = st { progress?((Double(i) + pr.fractionCompleted) / n) } } }
                defer { watcher.cancel() }
                written.append(url)
                try await s.export(to: url, as: .m4a)
                progress?(Double(i + 1) / n)
            }
            return urls
        } catch {
            for u in written { try? FileManager.default.removeItem(at: u) }
            throw error
        }
    }
}
