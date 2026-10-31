// SADROG — Copyright (C) 2026 Dumitru Cristinel Gordas and contributors. GPL-3.0-or-later.
import Foundation

/// The Record button's state machine, separate from the real capturer so it can be tested with a simulated one.
/// idle → preparing (fresh source listing + validation) → countdown(n) → starting → recording → stopping → idle.
/// Every asynchronous step carries a generation number: Cancel (or any newer press) invalidates it, so a source refresh, a countdown tick
/// or a sleep that finishes AFTER the cancel can never start a capture. Identification frames are closed on the press and right before start.
@MainActor
public final class RecordFlow {
    public enum Phase: Equatable, Sendable { case idle, preparing, countdown(Int), starting, recording, paused, stopping }
    public private(set) var phase: Phase = .idle { didSet { if phase != oldValue { onPhase?(phase) } } }
    public var onPhase: ((Phase) -> Void)?
    public private(set) var message = ""
    public var countdownSeconds: Int

    /// Fresh listing + validation; returns a blocking message, or nil when recording may start.
    private let prepare: () async -> String?
    /// Starts the real (or simulated) capture.
    private let startCapture: () async throws -> Void
    private let stopCapture: (StopCause, String?) async -> Void
    /// Pause / resume of the WHOLE capture (every source at once). Optional: a flow without them cannot pause.
    public var pauseCapture: (() -> Void)?
    public var resumeCapture: (() -> Void)?
    /// Called when a pending start is cancelled or fails (e.g. to stop cameras prepared for it).
    public var onStartAbandoned: (() -> Void)?
    private let closeIdentification: () -> Void
    private let sleep: (UInt64) async throws -> Void
    private var generation = 0
    private var task: Task<Void, Never>?

    public init(countdownSeconds: Int, prepare: @escaping () async -> String?, startCapture: @escaping () async throws -> Void, stopCapture: @escaping (StopCause, String?) async -> Void,
                closeIdentification: @escaping () -> Void, sleep: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.countdownSeconds = countdownSeconds; self.prepare = prepare; self.startCapture = startCapture; self.stopCapture = stopCapture
        self.closeIdentification = closeIdentification; self.sleep = sleep
    }

    /// The Record/Stop button. Idle starts; preparing or counting down cancels; recording stops; starting/stopping ignore the press.
    public func press() {
        switch phase {
        case .idle: begin()
        case .preparing, .countdown: cancel()
        case .recording, .paused: stopReason = T("Oprit din buton; înregistrarea a fost salvată."); stopCause = .button; stopRequest = nil; stop()
        case .starting, .stopping: break
        }
    }

    /// Pause ⇄ resume of every source together (the menu bar, the floating panel and the window all call this one place).
    public func togglePause() {
        switch phase {
        case .recording: guard let p = pauseCapture else { return }; p(); phase = .paused
        case .paused: resumeCapture?(); phase = .recording
        default: break
        }
    }

    /// Cancels a pending start. Nothing started earlier can start a capture after this returns.
    public func cancel() {
        guard phase == .preparing || { if case .countdown = phase { return true }; return false }() else { return }
        generation += 1; task?.cancel(); task = nil
        onStartAbandoned?()
        message = T("Pornirea a fost anulată; nu s-a înregistrat nimic."); phase = .idle     // message first: observers read it on the phase change
    }

    /// The capture stopped on its own (error, source gone): back to idle without calling stop again.
    public func captureEnded(_ why: String) { guard phase == .recording || phase == .paused else { return }; message = why; phase = .idle }
    /// Why the next stop happens (guard, duration limit, button); kept in `message` once back to idle.
    public func stop(reason: String, cause: StopCause, request: String? = nil) { guard phase == .recording || phase == .paused else { return }; stopReason = reason; stopCause = cause; stopRequest = request; stop() }
    private var stopReason: String?
    private var stopCause: StopCause = .button
    private var stopRequest: String?

    /// Waits for the pending start (tests).
    public func settle() async { await task?.value }

    private func begin() {
        closeIdentification()
        generation += 1; let g = generation
        message = ""; phase = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            let blocker = await self.prepare()
            guard self.isCurrent(g) else { return }
            if let b = blocker { self.onStartAbandoned?(); self.message = b; self.phase = .idle; return }
            var n = self.countdownSeconds
            while n > 0 {
                self.phase = .countdown(n)
                do { try await self.sleep(1_000_000_000) } catch { return }
                guard self.isCurrent(g) else { return }
                n -= 1
            }
            guard self.isCurrent(g) else { return }
            self.phase = .starting
            self.closeIdentification()
            do {
                try await self.startCapture()
                self.phase = .recording
            } catch {
                self.onStartAbandoned?()
                self.message = L10n.f("Nu am putut porni: %@", "\(error.localizedDescription)"); self.phase = .idle
            }
        }
    }

    private func stop() {
        phase = .stopping
        task = Task { [weak self] in
            guard let self else { return }
            await self.stopCapture(self.stopCause, self.stopRequest)
            if let r = self.stopReason { self.message = r; self.stopReason = nil }
            self.phase = .idle
        }
    }

    private func isCurrent(_ g: Int) -> Bool { g == generation && !Task.isCancelled }
}
