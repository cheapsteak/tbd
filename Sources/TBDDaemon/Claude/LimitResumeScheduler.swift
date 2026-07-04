import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

/// What one actuation attempt concluded (produced by `LimitResumeActuating`).
public enum ResumeActuationOutcome: Equatable, Sendable {
    /// Send verified — Claude is working again.
    case sent
    /// Transcript grew after the limit record — user continued manually.
    case userAlreadyContinued
    /// Terminal deleted/suspended/window dead — cancel silently.
    case terminalGone
    /// `#{pane_in_mode}` was set; typing would land in copy-mode and
    /// cancelling copy-mode would yank the user out of scrollback.
    case paneInCopyMode
    /// Hard failure (Claude not foreground, send verify timed out, …).
    case failed(String)
}

/// Seam between the scheduler (timing) and the actuator (tmux side effects).
public protocol LimitResumeActuating: Sendable {
    func actuate(_ resume: ScheduledResume) async -> ResumeActuationOutcome
}

/// Terminal outcome surfaced to the user (notification copy lives in the
/// daemon wiring's onOutcome closure).
public enum LimitResumeOutcome: Equatable, Sendable {
    case sent
    case failed(String)
}

/// Fires scheduled session-limit resumes. Clone of `ClaudeUsagePoller`'s
/// loop shape: injected clock, min-deadline cancellable sleep, `wake()` on
/// insert/cancel, idle continuation when no rows are pending.
///
/// Restart-safe by construction: the loop re-reads `store.pending()` every
/// iteration, so rows inserted before a daemon restart reload automatically
/// and past-due rows fire immediately (`clock.sleep(until: past)` returns
/// at once). Spec §Scheduler, §State.
public actor LimitResumeScheduler {

    // MARK: - Constants (spec §Scheduler / §Actuation 3)

    public static let slack: TimeInterval = 60
    public static let jitterMax: TimeInterval = 30
    public static let copyModeRetryDelay: TimeInterval = 120
    public static let maxCopyModeAttempts = 15

    // MARK: - Dependencies

    private let store: ScheduledResumeStore
    private let config: ConfigStore
    private let actuator: any LimitResumeActuating
    private let clock: PollerClock
    private let jitterProvider: @Sendable () -> TimeInterval
    private let onOutcome: @Sendable (ScheduledResume, LimitResumeOutcome) async -> Void

    // MARK: - State

    private var loopTask: Task<Void, Never>?
    private var idleWakeContinuation: CheckedContinuation<Void, Never>?
    private var currentSleepTask: Task<Void, Error>?

    public init(
        store: ScheduledResumeStore,
        config: ConfigStore,
        actuator: any LimitResumeActuating,
        clock: PollerClock,
        jitterProvider: (@Sendable () -> TimeInterval)? = nil,
        onOutcome: @escaping @Sendable (ScheduledResume, LimitResumeOutcome) async -> Void
    ) {
        self.store = store
        self.config = config
        self.actuator = actuator
        self.clock = clock
        self.jitterProvider = jitterProvider ?? { Double.random(in: 0..<Self.jitterMax) }
        self.onOutcome = onOutcome
    }

    // MARK: - Lifecycle

    /// Launch the loop. Idempotent. Pending rows (including past-due ones)
    /// are picked up on the first iteration — that IS the startup reload.
    public func start() async {
        guard loopTask == nil else { return }
        loopTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
        currentSleepTask?.cancel()
        currentSleepTask = nil
        if let cont = idleWakeContinuation {
            idleWakeContinuation = nil
            cont.resume()
        }
    }

    /// Interrupt the current sleep / idle wait so the loop re-reads pending
    /// rows. Called on insert, cancel, and toggle changes.
    public func wake() {
        if let cont = idleWakeContinuation {
            idleWakeContinuation = nil
            cont.resume()
        }
        currentSleepTask?.cancel()
        currentSleepTask = nil
    }

    // MARK: - Scheduling

    /// Insert a pending row for a detected limit. Computes
    /// `fireAt = resetsAt + slack + jitter` ONCE (never re-derived from
    /// display text). Returns nil when the terminal already has a pending
    /// row (the double-send latch).
    public func schedule(
        terminalID: UUID, worktreeID: UUID, claudeSessionID: String?,
        resetsAt: Date, limitType: String, rawMessage: String
    ) async -> ScheduledResume? {
        let fireAt = resetsAt.addingTimeInterval(Self.slack + jitterProvider())
        let row = ScheduledResume(
            terminalID: terminalID, worktreeID: worktreeID,
            claudeSessionID: claudeSessionID,
            resetsAt: resetsAt, fireAt: fireAt,
            limitType: limitType, rawMessage: rawMessage,
            createdAt: clock.now())
        // `try?` on a `-> ScheduledResume?` API yields a double optional:
        // outer nil = threw, inner nil = latch rejected. Flatten with `?? nil`.
        let insertResult: ScheduledResume?? = try? await store.insertPending(row)
        guard let inserted = insertResult ?? nil else {
            logger.info("schedule: no pending row created for terminal \(terminalID.uuidString, privacy: .public) (latch or store error)")
            return nil
        }
        logger.info("schedule: resume for terminal \(terminalID.uuidString, privacy: .public) at \(fireAt.description, privacy: .public) (type \(limitType, privacy: .public))")
        wake()
        return inserted
    }

    // MARK: - Loop

    private func runLoop() async {
        while !Task.isCancelled {
            let rows = (try? await store.pending()) ?? []
            guard let next = rows.first else {   // pending() is fireAt-ordered
                await waitIdle()
                if Task.isCancelled { return }
                continue
            }

            let clock = self.clock
            let deadline = next.fireAt
            let sleepTask = Task<Void, Error> {
                try await clock.sleep(until: deadline)
            }
            currentSleepTask = sleepTask
            _ = try? await sleepTask.value
            currentSleepTask = nil
            if Task.isCancelled { return }

            let now = clock.now()
            let due = ((try? await store.pending()) ?? []).filter { $0.fireAt <= now }
            for row in due {
                await fire(row)
            }
        }
    }

    private func waitIdle() async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            idleWakeContinuation = cont
        }
    }

    // MARK: - Fire

    private func fire(_ row: ScheduledResume) async {
        // Belt-and-braces gate check: toggle-off should already have
        // cancelled pending rows; if one slipped through, cancel silently.
        let enabled = (try? await config.get())?.autoResumeOnLimitReset ?? false
        guard enabled else {
            try? await store.setStatus(id: row.id, status: .cancelled)
            return
        }

        let outcome = await actuator.actuate(row)
        switch outcome {
        case .sent:
            try? await store.setStatus(id: row.id, status: .sent)
            logger.info("fire: sent continue to terminal \(row.terminalID.uuidString, privacy: .public)")
            await onOutcome(row, .sent)

        case .userAlreadyContinued, .terminalGone:
            try? await store.setStatus(id: row.id, status: .cancelled)
            logger.info("fire: cancelled (\(String(describing: outcome), privacy: .public)) for terminal \(row.terminalID.uuidString, privacy: .public)")

        case .paneInCopyMode:
            let attempts = row.attemptCount + 1
            if attempts >= Self.maxCopyModeAttempts {
                try? await store.setStatus(id: row.id, status: .failed)
                logger.warning("fire: copy-mode retry cap hit for terminal \(row.terminalID.uuidString, privacy: .public)")
                await onOutcome(row, .failed("pane stayed in copy-mode/scrollback for ~30 minutes"))
            } else {
                // Don't cancel their scroll — retry in 2 minutes (spec §Actuation 3).
                let nextFire = clock.now().addingTimeInterval(Self.copyModeRetryDelay)
                try? await store.reschedule(id: row.id, fireAt: nextFire, attemptCount: attempts)
                logger.info("fire: pane in copy-mode; rescheduled attempt \(attempts, privacy: .public) for terminal \(row.terminalID.uuidString, privacy: .public)")
            }

        case .failed(let reason):
            try? await store.setStatus(id: row.id, status: .failed)
            logger.warning("fire: failed for terminal \(row.terminalID.uuidString, privacy: .public): \(reason, privacy: .public)")
            await onOutcome(row, .failed(reason))
        }
    }
}
