// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import AVFoundation
import AudioToolbox
import CryptoKit
import Foundation

/// Identity of an Audio Unit component (type / subtype / manufacturer four-char codes).
public struct AUComponentID: Codable, Hashable, Sendable {
    public var type: UInt32, subtype: UInt32, manufacturer: UInt32
    public init(type: UInt32, subtype: UInt32, manufacturer: UInt32) { self.type = type; self.subtype = subtype; self.manufacturer = manufacturer }
    public init(_ d: AudioComponentDescription) { self.init(type: d.componentType, subtype: d.componentSubType, manufacturer: d.componentManufacturer) }
    public var description: AudioComponentDescription { AudioComponentDescription(componentType: type, componentSubType: subtype, componentManufacturer: manufacturer, componentFlags: 0, componentFlagsMask: 0) }
    public static func fourCC(_ v: UInt32) -> String { String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .macOSRoman) ?? String(v) }
    public var code: String { "\(Self.fourCC(type)) \(Self.fourCC(subtype)) \(Self.fourCC(manufacturer))" }
}

/// One plugin in a source's chain. The name, maker and version are kept so a project still shows what it used when the plugin is missing;
/// `state` is the plugin's own full state (opaque, binary property list) — SADROG never interprets it.
public struct AudioEffect: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var component: AUComponentID
    public var name: String
    public var manufacturerName: String
    public var componentVersion: UInt32          // installed version when the state was last saved
    public var state: Data?
    public var bypassed: Bool
    public init(id: UUID = UUID(), component: AUComponentID, name: String, manufacturerName: String, componentVersion: UInt32, state: Data? = nil, bypassed: Bool = false) {
        self.id = id; self.component = component; self.name = name; self.manufacturerName = manufacturerName; self.componentVersion = componentVersion; self.state = state; self.bypassed = bypassed
    }
    /// Canonical bytes of a plugin state. XML, not binary: a binary property list writes dictionary keys in an unstable order, so the SAME
    /// state gave different bytes on every read (seen on 4 of the 5 4LO plugins) — false edits, undo steps and cache misses. XML is stable.
    public static func encode(state: [String: Any]?) -> Data? { state.flatMap { try? PropertyListSerialization.data(fromPropertyList: $0, format: .xml, options: 0) } }
    public var decodedState: [String: Any]? { state.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] } }
}

/// An installed effect Audio Unit, as macOS registers it.
public struct AUInfo: Hashable, Sendable, Identifiable {
    public var id: AUComponentID
    public var name: String, manufacturerName: String, version: UInt32
    public var isMusicEffect: Bool
    public var versionString: String { "\(version >> 16).\((version >> 8) & 0xFF).\(version & 0xFF)" }
}

/// Every installed audio effect: plain effects (`aufx`) and music effects (`aumf`, e.g. 4LO Auto Comp). Read from the system registry — nothing
/// is loaded, installed or tied to one maker.
public enum AUCatalog {
    public static func effects() -> [AUInfo] {
        let types: Set<OSType> = [kAudioUnitType_Effect, kAudioUnitType_MusicEffect]
        return AVAudioUnitComponentManager.shared().components(passingTest: { c, _ in types.contains(c.audioComponentDescription.componentType) })
            .map { AUInfo(id: AUComponentID($0.audioComponentDescription), name: $0.name, manufacturerName: $0.manufacturerName, version: UInt32($0.version), isMusicEffect: $0.audioComponentDescription.componentType == kAudioUnitType_MusicEffect) }
            .sorted { ($0.manufacturerName.lowercased(), $0.name.lowercased()) < ($1.manufacturerName.lowercased(), $1.name.lowercased()) }
    }
    public static func installed(_ id: AUComponentID) -> AUInfo? {
        AVAudioUnitComponentManager.shared().components(matching: id.description).first.map {
            AUInfo(id: id, name: $0.name, manufacturerName: $0.manufacturerName, version: UInt32($0.version), isMusicEffect: id.type == kAudioUnitType_MusicEffect)
        }
    }
    /// Out-of-process ONLY (decision D-AU-LOAD, 2026-10-29): plugins signed by another team cannot load in SADROG's hardened process, and there
    /// is no silent in-process fallback. Times out instead of hanging when the plugin's process does not answer.
    public static func instantiate(_ id: AUComponentID, timeout: Double = 20) throws -> AVAudioUnit {
        let sem = DispatchSemaphore(value: 0)
        final class Out: @unchecked Sendable { var unit: AVAudioUnit?; var error: Error? }
        let out = Out()
        AVAudioUnit.instantiate(with: id.description, options: [.loadOutOfProcess]) { u, e in out.unit = u; out.error = e; sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut { throw EffectError.instantiate(L10n.f("procesul pluginului nu a răspuns în %@ s", "\(Int(timeout))")) }
        guard let u = out.unit else { throw EffectError.instantiate(out.error.map { ($0 as NSError).localizedDescription } ?? "necunoscut") }
        return u
    }
}

public enum EffectError: Error, Equatable, Sendable, CustomStringConvertible {
    case missing(String)                  // plugin not installed on this Mac
    case instantiate(String)              // the plugin's process could not start / did not answer
    case unsupportedRate(Double)
    case noTrack
    case stalled(Double)                  // no rendering progress for this many seconds
    case render(String)
    case cancelled
    public var description: String {
        switch self {
        case .missing(let n): return L10n.f("Pluginul „%@” nu e instalat pe acest Mac", "\(n)")
        case .instantiate(let w): return L10n.f("Pluginul nu a pornit: %@", "\(w)")
        case .unsupportedRate(let r): return String(format: T("Rata de eșantionare %.0f Hz nu e acceptată (doar 48 000 Hz)"), r)
        case .noTrack: return T("Sursa nu mai există în înregistrare")
        case .stalled(let s): return String(format: T("Procesarea s-a blocat (fără progres %.0f s) și a fost oprită"), s)
        case .render(let w): return L10n.f("Procesarea a eșuat: %@", "\(w)")
        case .cancelled: return T("Procesare anulată")
        }
    }
}

/// How the delay of one plugin was handled. Reported latency wins; otherwise a measured CONSTANT delay (the response of every impulse peaks at the
/// same sample) is compensated; a delay that cannot be determined is NOT guessed — it stays uncompensated and is shown.
public struct EffectDelay: Codable, Equatable, Sendable {
    public enum Source: String, Codable, Sendable { case reported, measured, none, undetermined }
    public var name: String
    public var samples: Int
    public var source: Source
}

public struct EffectReport: Codable, Equatable, Sendable {
    public var delays: [EffectDelay]
    public var compensationSamples: Int { delays.reduce(0) { $0 + $1.samples } }
    public var tailSeconds: Double
    public var renderSeconds: Double
    public var versionChanged: [String]           // plugins whose installed version differs from the one the state was saved with
}

/// One source of one recording that needs (or has) a processed copy.
public struct EffectJob: Sendable, Hashable {
    public var media: String
    public var track: Int
    public var chain: [AudioEffect]
    public var key: String
    public var output: URL
    public static func == (a: EffectJob, b: EffectJob) -> Bool { a.key == b.key && a.output == b.output }
    public func hash(into h: inout Hasher) { h.combine(key) }
}

/// What the project needs: processed files that already exist (`ready`, by `EffectRenderer.slot`) and those still to render (`jobs`).
public struct EffectPlan: Sendable {
    public init() {}
    public var ready: [String: URL] = [:]
    public var jobs: [EffectJob] = []
    public var sourcesPending: Set<Int> { Set(jobs.map(\.track)) }
}

public enum EffectRenderer {
    nonisolated(unsafe) static var testStallAfterStart = false
    nonisolated(unsafe) static var testBlockSeconds = 0.0          // tests only: a plugin call that is slow and ignores cancellation
    static let cancelGrace = 2.0
    public static let rendererVersion = 2          // 2: delay measured at the response onset (1 used the peak)
    public static let sampleRate = 48000.0
    public static func slot(_ media: String, _ track: Int) -> String { "\(media)#\(track)" }
    public static func cacheFolder(_ projectFolder: URL) -> URL { projectFolder.appendingPathComponent(".sadrog-fx", isDirectory: true) }

    /// Cache key: changes when the input file, the track, the order, a state, a bypass, an INSTALLED plugin version or this renderer changes.
    public static func key(media: String, track: Int, chain: [AudioEffect]) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: media)) ?? [:]
        var s = "v\(rendererVersion)|\(media)|\((a[.size] as? NSNumber)?.int64Value ?? -1)|\(Int(((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000))|t\(track)|sr\(Int(sampleRate))"
        for e in chain where !e.bypassed {
            s += "|\(e.component.code)|iv\(AUCatalog.installed(e.component)?.version ?? 0)|st\(SHA256.hash(data: e.state ?? Data()).map { String(format: "%02x", $0) }.joined())"
        }
        return SHA256.hash(data: Data(s.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Which processed files exist and which must be rendered, for every recording on the main track that has an active chain.
    public static func plan(_ p: SadrogProject, folder: URL) async -> EffectPlan {
        var plan = EffectPlan()
        let dir = cacheFolder(folder)
        for media in Array(Set(p.clips.map(\.media))).sorted() {
            let n = (try? await AVURLAsset(url: URL(fileURLWithPath: media)).loadTracks(withMediaType: .audio).count) ?? 0
            for k in 0..<n {
                let chain = p.activeEffects(ofSource: k, media: media); guard !chain.isEmpty else { continue }
                let key = key(media: media, track: k, chain: chain), url = dir.appendingPathComponent("\(key).caf")
                if FileManager.default.fileExists(atPath: url.path) { plan.ready[slot(media, k)] = url }
                else { plan.jobs.append(EffectJob(media: media, track: k, chain: chain, key: key, output: url)) }
            }
        }
        return plan
    }

    public static func report(for url: URL) -> EffectReport? {
        (try? Data(contentsOf: url.deletingPathExtension().appendingPathExtension("json"))).flatMap { try? JSONDecoder().decode(EffectReport.self, from: $0) }
    }

    /// Keeps the files `keep` plus the `spare` most recent others (so undo usually finds its result again); deletes the rest of the cache.
    public static func prune(folder: URL, keep: Set<URL>, spare: Int = 6) {
        let dir = cacheFolder(folder), fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let keepNames = Set(keep.map { $0.deletingPathExtension().lastPathComponent })
        let others = items.filter { $0.pathExtension == "caf" && !keepNames.contains($0.deletingPathExtension().lastPathComponent) }
            .sorted { ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) }
        for u in others.dropFirst(spare) { try? fm.removeItem(at: u); try? fm.removeItem(at: u.deletingPathExtension().appendingPathExtension("json")) }
        for u in items where u.lastPathComponent.contains(".partial") { try? fm.removeItem(at: u) }
    }

    // MARK: rendering

    final class Control: @unchecked Sendable {
        private let lock = NSLock()
        private var _cancelled = false, _beat = Date(), _cancelAt: Date?
        var cancelled: Bool { lock.withLock { _cancelled } }
        func cancel() { lock.withLock { if !_cancelled { _cancelAt = Date() }; _cancelled = true } }
        /// Seconds since cancellation was requested; nil while not cancelled.
        var sinceCancel: Double? { lock.withLock { _cancelAt.map { Date().timeIntervalSince($0) } } }
        func beat() { lock.withLock { _beat = Date() } }
        var sinceBeat: Double { lock.withLock { Date().timeIntervalSince(_beat) } }
    }
    final class Once<T>: @unchecked Sendable {
        private let lock = NSLock(); private var cont: CheckedContinuation<T, Error>?
        init(_ c: CheckedContinuation<T, Error>) { cont = c }
        func resume(_ r: Result<T, Error>) { lock.withLock { let c = cont; cont = nil; return c }?.resume(with: r) }
    }

    /// Renders the whole source track through the chain into `job.output` (32-bit float, 48 kHz, the track's channel count), aligned on the
    /// recording's own time: sample 0 = time 0 of the file, so the composition uses the SAME source ranges as for the original track.
    /// Fresh plugin instances (restored from their saved state) every time → the same input gives the same result (adaptive plugins included).
    /// Written to a `.partial` file and renamed only when complete: a cancelled, failed or stalled render never leaves a usable result.
    /// Runs on its own thread; a call into a plugin that never returns is detected by `stall` seconds without progress.
    public static func render(_ job: EffectJob, stall: Double = 20, progress: (@Sendable (Double) -> Void)? = nil) async throws -> EffectReport {
        let asset = AVURLAsset(url: URL(fileURLWithPath: job.media))
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard job.track < tracks.count else { throw EffectError.noTrack }
        let track = tracks[job.track]
        let range = try await track.load(.timeRange)
        let descs = try await track.load(.formatDescriptions)
        guard let asbd = descs.first.flatMap({ CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }) else { throw EffectError.noTrack }
        guard abs(asbd.mSampleRate - sampleRate) < 0.5 else { throw EffectError.unsupportedRate(asbd.mSampleRate) }
        let channels = AVAudioChannelCount(max(1, min(2, Int(asbd.mChannelsPerFrame))))
        let ctl = Control()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<EffectReport, Error>) in
                let once = Once(c)
                let worker = Thread {
                    do { once.resume(.success(try work(job, asset: asset, track: track, range: range, channels: channels, ctl: ctl, progress: progress))) }
                    catch { once.resume(.failure(error)) }
                }
                worker.stackSize = 4 << 20; worker.start()
                Thread {
                    while !worker.isFinished {
                        Thread.sleep(forTimeInterval: 0.5)
                        // A cancel the worker has not honoured (stuck inside a slow plugin call) is still a cancel for the caller: answered after a short grace, never as a stall.
                        if let c = ctl.sinceCancel, c > cancelGrace { once.resume(.failure(EffectError.cancelled)); return }
                        if ctl.sinceBeat > stall { let was = ctl.cancelled; ctl.cancel(); once.resume(.failure(was ? EffectError.cancelled : EffectError.stalled(stall))); return }
                    }
                }.start()
            }
        } onCancel: { ctl.cancel() }
    }

    static func work(_ job: EffectJob, asset: AVURLAsset, track: AVAssetTrack, range: CMTimeRange, channels: AVAudioChannelCount, ctl: Control, progress: (@Sendable (Double) -> Void)?) throws -> EffectReport {
        let t0 = Date()
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        var versionChanged: [String] = []
        // 1. plugins: present, started out of process, restored from their state
        var units: [AVAudioUnit] = []
        for e in job.chain {
            guard let info = AUCatalog.installed(e.component) else { throw EffectError.missing(e.name) }
            if info.version != e.componentVersion { versionChanged.append("\(e.name) \(info.versionString)") }
            let u = try AUCatalog.instantiate(e.component); ctl.beat()
            if let s = e.decodedState { u.auAudioUnit.fullState = s }
            units.append(u)
        }
        if ctl.cancelled { throw EffectError.cancelled }
        // 2. delay of each plugin (own fresh instance, so the main ones start untouched)
        var delays: [EffectDelay] = []
        for (e, u) in zip(job.chain, units) {
            let rep = Int((u.auAudioUnit.latency * sampleRate).rounded())
            if rep > 0 { delays.append(EffectDelay(name: e.name, samples: rep, source: .reported)); continue }
            let m = try measureDelay(e, channels: channels, ctl: ctl)
            delays.append(EffectDelay(name: e.name, samples: m ?? 0, source: m == nil ? .undetermined : (m == 0 ? .none : .measured)))
        }
        let comp = delays.reduce(0) { $0 + $1.samples }
        let tail = min(10, max(1, units.map(\.auAudioUnit.tailTime).max() ?? 0))
        // 3. the source track, read as float PCM, placed on the file's own time (silence before the track starts)
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
                                                                          AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
                                                                          AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: Int(channels)])
        out.alwaysCopiesSampleData = false
        reader.add(out); guard reader.startReading() else { throw EffectError.render(reader.error?.localizedDescription ?? "citire") }
        let lead = Int((max(0, range.start.seconds) * sampleRate).rounded())
        let trackFrames = Int((range.duration.seconds * sampleRate).rounded())
        let totalOut = lead + trackFrames + Int(tail * sampleRate)
        let C = Int(channels)
        var fifo = [Float](); var fifoPos = 0; var readerDone = false
        var inPos = 0                                                  // frames handed to the chain so far (file time + compensation)
        func nextSourceFrames(_ n: Int, into b: AVAudioPCMBuffer) {
            let d = b.floatChannelData!
            for i in 0..<n {
                let p = inPos + i
                if p < lead || p >= lead + trackFrames { for ch in 0..<C { d[ch][i] = 0 }; continue }
                if fifoPos >= fifo.count / C && !readerDone {
                    fifo.removeAll(keepingCapacity: true); fifoPos = 0
                    while fifo.isEmpty, !readerDone {
                        if let sb = out.copyNextSampleBuffer(), let bb = CMSampleBufferGetDataBuffer(sb) {
                            let len = CMBlockBufferGetDataLength(bb); var v = [Float](repeating: 0, count: len / 4)
                            CMBlockBufferCopyDataBytes(bb, atOffset: 0, dataLength: len, destination: &v); fifo = v
                        } else { readerDone = true }
                    }
                }
                if fifoPos < fifo.count / C { for ch in 0..<C { d[ch][i] = fifo[fifoPos * C + ch] }; fifoPos += 1 }
                else { for ch in 0..<C { d[ch][i] = 0 } }
            }
            inPos += n
        }
        // 4. offline engine: input → plugins in order → output (no audio device involved)
        let eng = AVAudioEngine()
        try eng.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!          // must outlive the callback: the engine reads it after we return
        let ok = eng.inputNode.setManualRenderingInputPCMFormat(fmt) { frames in
            inBuf.frameLength = frames; nextSourceFrames(Int(frames), into: inBuf); return UnsafePointer(inBuf.mutableAudioBufferList)
        }
        guard ok else { throw EffectError.render(T("format de intrare refuzat")) }
        var prev: AVAudioNode = eng.inputNode
        for u in units { eng.attach(u); eng.connect(prev, to: u, format: fmt); prev = u }
        eng.connect(prev, to: eng.mainMixerNode, format: fmt)
        eng.connect(eng.mainMixerNode, to: eng.outputNode, format: fmt)
        try eng.start()
        defer { eng.stop(); reader.cancelReading() }
        try FileManager.default.createDirectory(at: job.output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let partial = job.output.deletingPathExtension().appendingPathExtension("partial.caf")
        try? FileManager.default.removeItem(at: partial)
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: partial) } }
        if testBlockSeconds > 0 { Thread.sleep(forTimeInterval: testBlockSeconds) }
        if testStallAfterStart { while !ctl.cancelled { usleep(20_000) } }      // tests only: a plugin call that never returns
        do {
            let file = try AVAudioFile(forWriting: partial, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            let buf = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 4096)!
            var produced = 0, written = 0, waits = 0
            while written < totalOut {
                if ctl.cancelled { throw EffectError.cancelled }
                let n = min(4096, totalOut + comp - produced)
                let st = try eng.renderOffline(AVAudioFrameCount(n), to: buf)
                if st == .cannotDoInCurrentContext { waits += 1; usleep(1000); if waits % 1000 == 0 { ctl.beat() }; continue }
                guard st == .success else { throw EffectError.render("stare \(st.rawValue)") }
                ctl.beat()
                let got = Int(buf.frameLength)
                // drop the first `comp` frames (plugin delay), then keep exactly `totalOut`
                let skip = max(0, min(got, comp - produced)); produced += got
                let keep = min(got - skip, totalOut - written)
                if keep > 0 {
                    let w = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(keep))!; w.frameLength = AVAudioFrameCount(keep)
                    for ch in 0..<C { w.floatChannelData![ch].update(from: buf.floatChannelData![ch] + skip, count: keep) }
                    for ch in 0..<C { for i in 0..<keep where !w.floatChannelData![ch][i].isFinite { w.floatChannelData![ch][i] = 0 } }
                    try file.write(from: w); written += keep
                }
                progress?(Double(written) / Double(totalOut))
            }
        }
        let rep = EffectReport(delays: delays, tailSeconds: tail, renderSeconds: Date().timeIntervalSince(t0), versionChanged: versionChanged)
        if ctl.cancelled { throw EffectError.cancelled }
        try? FileManager.default.removeItem(at: job.output)
        try FileManager.default.moveItem(at: partial, to: job.output)
        completed = true
        try? JSONEncoder().encode(rep).write(to: job.output.deletingPathExtension().appendingPathExtension("json"))
        return rep
    }

    /// Constant delay of one plugin with its saved state: 8 impulses through a fresh instance; accepted only when every response STARTS at the
    /// same sample (±1) and peaks above −80 dBFS. Adaptive gain changes the HEIGHT of the responses, not their position, so it does not fool this.
    /// nil = cannot be determined (e.g. a gate removes the impulses) — then nothing is compensated.
    static func measureDelay(_ e: AudioEffect, channels: AVAudioChannelCount, ctl: Control) throws -> Int? {
        let u = try AUCatalog.instantiate(e.component); ctl.beat()
        if let s = e.decodedState { u.auAudioUnit.fullState = s }
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let step = Int(0.25 * sampleRate), first = step, count = 8, total = first + count * step
        let eng = AVAudioEngine()
        try eng.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
        var pos = 0
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: 4096)!
        _ = eng.inputNode.setManualRenderingInputPCMFormat(fmt) { frames in
            b.frameLength = frames
            for i in 0..<Int(frames) { let p = pos + i; let v: Float = p >= first && (p - first) % step == 0 && p < first + count * step ? 0.5 : 0; for c in 0..<Int(channels) { b.floatChannelData![c][i] = v } }
            pos += Int(frames); return UnsafePointer(b.mutableAudioBufferList)
        }
        eng.attach(u); eng.connect(eng.inputNode, to: u, format: fmt); eng.connect(u, to: eng.mainMixerNode, format: fmt); eng.connect(eng.mainMixerNode, to: eng.outputNode, format: fmt)
        try eng.start(); defer { eng.stop() }
        var y = [Float](); let buf = AVAudioPCMBuffer(pcmFormat: eng.manualRenderingFormat, frameCapacity: 4096)!
        while y.count < total {
            if ctl.cancelled { throw EffectError.cancelled }
            let st = try eng.renderOffline(AVAudioFrameCount(min(4096, total - y.count)), to: buf)
            if st == .cannotDoInCurrentContext { usleep(1000); continue }
            guard st == .success else { throw EffectError.render(L10n.f("măsurare întârziere: stare %@", "\(st.rawValue)")) }
            ctl.beat(); y += UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength))
        }
        // where each response STARTS (first sample above 10% of its own peak), not where it peaks: a filter moves the peak by a sample or two
        // through its phase without delaying the sound (DXB: peak +1 sample, voice cross-correlation 0).
        var lags: [Int] = []
        for k in 0..<count {
            let i = first + k * step, hi = min(y.count, i + Int(0.2 * sampleRate))
            guard let m = (i..<hi).max(by: { abs(y[$0]) < abs(y[$1]) }), abs(y[m]) > 1e-4,
                  let on = (i..<hi).first(where: { abs(y[$0]) > abs(y[m]) * 0.1 }) else { return nil }
            lags.append(on - i)
        }
        guard let lo = lags.min(), let hi = lags.max(), hi - lo <= 1 else { return nil }
        return lags.sorted()[lags.count / 2]
    }
}
