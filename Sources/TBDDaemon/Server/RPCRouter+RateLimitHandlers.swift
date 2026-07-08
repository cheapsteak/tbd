import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

extension RPCRouter {

    /// A hard usage limit was detected by the StopFailure hook. Detection and
    /// notification always run; only the scheduled send is gated on
    /// `autoResumeOnLimitReset` (spec §Constraints "Gated, default OFF").
    ///
    /// Latch: when the terminal already has a pending resume (a repeat
    /// StopFailure while parked), do nothing — no duplicate notification.
    func handleRateLimitDetected(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(RateLimitDetectedParams.self, from: paramsData)
        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            // Fire-and-forget hook caller — soft no-op like sessionEvent.
            logger.debug("rateLimitDetected: unknown terminal \(params.terminalID.uuidString, privacy: .public) — ignoring")
            return .ok()
        }

        let enabled = (try? await db.config.get())?.autoResumeOnLimitReset ?? false
        let message: String

        if enabled, let scheduler = limitResumeScheduler {
            guard let scheduled = await scheduler.schedule(
                terminalID: terminal.id, worktreeID: terminal.worktreeID,
                claudeSessionID: terminal.claudeSessionID,
                resetsAt: params.resetsAt, limitType: params.limitType,
                rawMessage: params.rawMessage)
            else {
                return .ok()   // latch: already pending — no duplicate notification
            }
            message = "Session limit hit — auto-resume scheduled for \(ResumeTimeFormatter.string(from: scheduled.fireAt))"
        } else {
            // Gate off: record the detection for audit, notify with the reset
            // time, schedule nothing (spec Testing→Gate: "row recorded +
            // notification, no send scheduled").
            let audit = ScheduledResume(
                terminalID: terminal.id, worktreeID: terminal.worktreeID,
                claudeSessionID: terminal.claudeSessionID,
                resetsAt: params.resetsAt,
                fireAt: params.resetsAt.addingTimeInterval(LimitResumeScheduler.slack),
                limitType: params.limitType, rawMessage: params.rawMessage,
                status: .cancelled)
            do {
                try await db.scheduledResumes.insertAudit(audit)
            } catch {
                logger.warning("handleRateLimitDetected: audit insert failed for terminal \(terminal.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            message = "Session limit hit — resets \(ResumeTimeFormatter.string(from: params.resetsAt))"
        }

        try await notify(terminal: terminal, type: .limitReached, message: message)
        return .ok()
    }

    /// A transient API error killed a turn (spec 2026-07-08). Gate OFF → not
    /// handled: the CLI keeps its legacy error print, behavior unchanged.
    /// Gate ON → schedule an auto-continue with backoff, or give up past the
    /// cap. `handled` tells the CLI whether the daemon owns user messaging.
    func handleTransientApiErrorDetected(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(TransientApiErrorDetectedParams.self, from: paramsData)
        guard let terminal = try await db.terminals.get(id: params.terminalID) else {
            logger.debug("transientApiErrorDetected: unknown terminal \(params.terminalID.uuidString, privacy: .public) — ignoring")
            return try RPCResponse(result: TransientApiErrorDetectedResult(handled: false))
        }
        let enabled = (try? await db.config.get())?.autoResumeOnApiError ?? false
        guard enabled, let scheduler = limitResumeScheduler else {
            return try RPCResponse(result: TransientApiErrorDetectedResult(handled: false))
        }

        let attempts = (try? await db.scheduledResumes.countRecentApiErrorAttempts(
            terminalID: terminal.id,
            since: Date().addingTimeInterval(-TransientResumeBackoff.lookback))) ?? 0

        guard let delay = TransientResumeBackoff.delay(consecutiveAttempts: attempts) else {
            try await notify(terminal: terminal, type: .attentionNeeded,
                message: "Auto-continue gave up after \(TransientResumeBackoff.maxAttempts) attempts — \(params.rawMessage)")
            return try RPCResponse(result: TransientApiErrorDetectedResult(handled: true))
        }
        guard let _ = await scheduler.scheduleTransient(
            terminalID: terminal.id, worktreeID: terminal.worktreeID,
            claudeSessionID: terminal.claudeSessionID,
            delay: delay, rawMessage: params.rawMessage)
        else {
            return try RPCResponse(result: TransientApiErrorDetectedResult(handled: true)) // latch: no duplicate notification
        }
        try await notify(terminal: terminal, type: .error,
            message: "\(params.rawMessage) — auto-continue in \(TransientResumeBackoff.copy(forDelay: delay)) (attempt \(attempts + 1)/\(TransientResumeBackoff.maxAttempts))")
        return try RPCResponse(result: TransientApiErrorDetectedResult(handled: true))
    }

    /// Create a notification and broadcast its delta — the create+broadcast
    /// block shared by the rate-limit and transient-API-error handlers.
    private func notify(terminal: Terminal, type: NotificationType, message: String) async throws {
        let notification = try await db.notifications.create(
            worktreeID: terminal.worktreeID, type: type,
            message: message, terminalID: terminal.id)
        subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id, worktreeID: notification.worktreeID,
            type: notification.type, message: notification.message,
            terminalID: notification.terminalID)))
    }

    /// Explicit user cancel ("Cancel scheduled resume" context-menu item).
    func handleCancelScheduledResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(CancelScheduledResumeParams.self, from: paramsData)
        _ = try await db.scheduledResumes.cancelPending(terminalID: params.terminalID)
        await limitResumeScheduler?.wake()
        return .ok()
    }
}
