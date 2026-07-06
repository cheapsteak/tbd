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

        let notification = try await db.notifications.create(
            worktreeID: terminal.worktreeID, type: .limitReached,
            message: message, terminalID: terminal.id)
        subscriptions.broadcast(delta: .notificationReceived(NotificationDelta(
            notificationID: notification.id, worktreeID: notification.worktreeID,
            type: notification.type, message: notification.message,
            terminalID: notification.terminalID)))
        return .ok()
    }

    /// Explicit user cancel ("Cancel scheduled resume" context-menu item).
    func handleCancelScheduledResume(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(CancelScheduledResumeParams.self, from: paramsData)
        _ = try await db.scheduledResumes.cancelPending(terminalID: params.terminalID)
        await limitResumeScheduler?.wake()
        return .ok()
    }
}
