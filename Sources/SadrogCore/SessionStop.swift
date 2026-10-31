// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// Why a recording ended. Written with the session, so the cause never has to be guessed from which files exist.
public enum StopCause: String, Codable, Sendable { case button, guardRequest = "guard", durationLimit = "limit", lowSpace = "low_space", sourceLost = "source_lost", error }

/// Append-only event log of one session (`events.jsonl` next to capture.mov). Times: `uptime` = ProcessInfo.systemUptime, the same clock in every
/// process (app, guard), so request → receipt → finalisation → confirmation are directly comparable. Only technical fields — no titles, paths or names.
public struct SessionEvent: Codable, Equatable, Sendable {
    public var uptime: Double, wall: String, session: String, event: String
    public var cause: String?, request: String?
    public init(session: String, event: String, cause: String? = nil, request: String? = nil, uptime: Double = ProcessInfo.processInfo.systemUptime, wall: Date = Date()) {
        self.uptime = uptime; self.wall = ISO8601DateFormatter().string(from: wall); self.session = session; self.event = event; self.cause = cause; self.request = request
    }
}
public enum SessionEventLog {
    public static let fileName = "events.jsonl"
    public static func append(_ e: SessionEvent, to folder: URL) {
        let url = folder.appendingPathComponent(fileName)
        guard var line = try? JSONEncoder().encode(e) else { return }
        line.append(0x0A)
        if let h = try? FileHandle(forWritingTo: url) { defer { try? h.close() }; _ = try? h.seekToEnd(); try? h.write(contentsOf: line) }
        else { try? line.write(to: url) }
    }
    public static func read(_ folder: URL) -> [SessionEvent] {
        guard let d = try? String(contentsOf: folder.appendingPathComponent(fileName), encoding: .utf8) else { return [] }
        return d.split(separator: "\n").compactMap { try? JSONDecoder().decode(SessionEvent.self, from: Data($0.utf8)) }
    }
    /// The finalisation record, if the session is completely finished (file closed AND sources.json written).
    public static func finalized(_ folder: URL) -> SessionEvent? { read(folder).last { $0.event == "finalized" } }
}

/// The ONE way a session ends, whatever the cause (button, guard, limit, low space, lost source): finish the file, write sources.json,
/// then log `finalized` with the cause. Runs at most once per session, so two causes racing (e.g. a guard stop while the window closes)
/// produce one consistent result; the first cause wins and the second is logged as `stop_ignored`.
public final class SessionFinalizer: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false
    public let session: String, folder: URL
    public init(session: String, folder: URL) { self.session = session; self.folder = folder }
    private func claim() -> Bool { lock.withLock { let f = !started; started = true; return f } }

    @discardableResult
    public func finalize(cause: StopCause, request: String? = nil, finish: () async throws -> Void, writeManifest: () throws -> Void) async -> Bool {
        let first = claim()
        guard first else { SessionEventLog.append(SessionEvent(session: session, event: "stop_ignored", cause: cause.rawValue, request: request), to: folder); return false }
        SessionEventLog.append(SessionEvent(session: session, event: "finalizing", cause: cause.rawValue, request: request), to: folder)
        var ok = true
        do { try await finish() } catch { ok = false }
        do { try writeManifest() } catch { ok = false }
        SessionEventLog.append(SessionEvent(session: session, event: ok ? "finalized" : "finalized_with_error", cause: cause.rawValue, request: request), to: folder)
        return true
    }
}

/// App side of a guard stop request (delivered by the existing distributed notification). Honoured only while the guard switched it on.
/// Recording → stop with cause `guard`; preparing/countdown → cancel; anything else (already stopping, idle) → ignored. Every request is logged.
@MainActor
public final class GuardStopReceiver {
    public enum Disposition: Equatable, Sendable { case stopping, cancelledStart, ignored(String), disabled }
    private let flow: RecordFlow
    private let enabled: () -> Bool
    private let log: (String, String) -> Void          // (event, request id)
    public init(flow: RecordFlow, enabled: @escaping () -> Bool, log: @escaping (String, String) -> Void) { self.flow = flow; self.enabled = enabled; self.log = log }
    @discardableResult
    public func receive(request: String) -> Disposition {
        guard enabled() else { log("guard_request_disabled", request); return .disabled }
        switch flow.phase {
        case .recording:
            log("guard_request_received", request)
            flow.stop(reason: T("Oprit de garda probei; înregistrarea a fost salvată."), cause: .guardRequest, request: request); return .stopping
        case .preparing, .countdown: log("guard_request_cancel_start", request); flow.cancel(); return .cancelledStart
        default: log("guard_request_ignored", request); return .ignored("\(flow.phase)")
        }
    }
}

/// Guard side: ask, wait for the app's `finalized` record, and only then close the probe (closing it first would end the stream by itself).
/// Without confirmation within `timeout` the probe is still closed, and the outcome says the stop was NOT confirmed.
public struct GuardStopProtocol: Sendable {
    public enum Outcome: Equatable, Sendable { case confirmed(after: Double, cause: String?), notConfirmed }
    public var timeout = 20.0, poll = 0.1
    public init(timeout: Double = 20, poll: Double = 0.1) { self.timeout = timeout; self.poll = poll }
    public func run(request: String, post: (String) -> Void, finalized: () -> SessionEvent?, closeProbe: () -> Void, sleep: (Double) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1e9)) }) async -> Outcome {
        let t0 = ProcessInfo.processInfo.systemUptime
        post(request)
        var waited = 0.0
        while waited < timeout {
            if let f = finalized() { closeProbe(); return .confirmed(after: ProcessInfo.processInfo.systemUptime - t0, cause: f.cause) }
            await sleep(poll); waited += poll
        }
        closeProbe(); return .notConfirmed
    }
}
