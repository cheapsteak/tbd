import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "limitResume")

extension RPCRouter {

    /// A hard usage limit was detected by the StopFailure hook. Detection and
    /// notification always run; rotation and reset-time scheduling are gated.
    /// Spec §7: rotation on hard limit.
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

        let config = try? await db.config.get()
        let autoResumeEnabled = config?.autoResumeOnLimitReset ?? false
        let rotationEnabled = config?.limitRotationEnabled ?? false

        // §7.1: Always run — get suggested profile and build notification suffix
        var suggestedProfileID: UUID?
        var usageSuffix: String?
        var limitedProfileName: String?

        // Get the limited profile's name for notification
        if let profileID = terminal.profileID {
            limitedProfileName = (try? await db.modelProfiles.get(id: profileID))?.name
        }

        // Run picker with excluded account key (§7.1 always runs, even for ambient)
        if let source = profilePoolCandidateSource {
            do {
                // Get account key to exclude: the limited profile's account (or nil for ambient)
                var limitedAccountKey: String? = nil
                if let profileID = terminal.profileID {
                    limitedAccountKey = try await source.accountKey(forProfileID: profileID)
                }

                let candidates = try await source.candidates(
                    defaultProfileID: config?.defaultProfileID
                )
                let decision = ProfilePoolPicker.pick(
                    candidates: candidates,
                    excludingAccountKeys: limitedAccountKey.map { [$0] } ?? [],
                    now: Date()
                )
                if let chosen = decision.chosen {
                    let allSnapshots = (try? await db.oauthUsageSnapshots.loadAll()) ?? [:]
                    if let chosenSnapshot = allSnapshots[chosen] {
                        suggestedProfileID = chosen
                        usageSuffix = formatUsageForNotification(snapshot: chosenSnapshot)
                    }
                }
            } catch {
                logger.debug("handleRateLimitDetected: picker failed: \(String(describing: error), privacy: .public)")
            }
        }

        // §7.2: Gated — attempt automatic rotation if all conditions hold
        var rotationSucceeded = false
        if rotationEnabled, let suggested = suggestedProfileID {
            let eligibility = Self.rotationEligibility(terminal: terminal, flagOn: true, suggested: suggested)
            logger.info("handleRateLimitDetected rotation: \(String(describing: eligibility), privacy: .public)")

            if case .rotate(let newProfileID) = eligibility {
                do {
                    let swapParams = TerminalSwapProfileParams(
                        terminalID: terminal.id,
                        newProfileID: newProfileID,
                        mode: .inPlace
                    )
                    let swapParamsData = try encoder.encode(swapParams)
                    let actor = ActuationActor.daemon(rail: "limit-rotation")
                    let performer = rotationSwapPerformer ?? handleTerminalSwapProfile
                    let response = try await performer(swapParamsData, actor)

                    if response.success {
                        rotationSucceeded = true
                        // Schedule a continue at now with limitType "rotation"
                        if let scheduler = limitResumeScheduler {
                            _ = await scheduler.schedule(
                                terminalID: terminal.id, worktreeID: terminal.worktreeID,
                                claudeSessionID: terminal.claudeSessionID,
                                resetsAt: Date(), limitType: "rotation",
                                rawMessage: params.rawMessage
                            )
                        }
                    } else {
                        logger.warning("handleRateLimitDetected: swap failed: \(response.error ?? "unknown", privacy: .public)")
                    }
                } catch {
                    logger.warning("handleRateLimitDetected: swap error: \(String(describing: error), privacy: .public)")
                }
            }
        }

        // Build notification message and broadcast delta
        var suggestedProfileName: String? = nil
        if let suggestedID = suggestedProfileID {
            suggestedProfileName = (try? await db.modelProfiles.get(id: suggestedID))?.name
        }
        var message: String
        if rotationSucceeded {
            if let limited = limitedProfileName, let suggested = suggestedProfileName, let suffix = usageSuffix {
                message = "Session limit hit on \(limited) — switched to \(suggested) (\(suffix))"
            } else if let limited = limitedProfileName {
                message = "Session limit hit on \(limited) — switched"
            } else {
                message = "Session limit hit — switched"
            }
        } else if autoResumeEnabled, let scheduler = limitResumeScheduler {
            guard let scheduled = await scheduler.schedule(
                terminalID: terminal.id, worktreeID: terminal.worktreeID,
                claudeSessionID: terminal.claudeSessionID,
                resetsAt: params.resetsAt, limitType: params.limitType,
                rawMessage: params.rawMessage)
            else {
                return .ok()   // latch: already pending — no duplicate notification
            }
            message = "Session limit hit — auto-resume scheduled for \(ResumeTimeFormatter.string(from: scheduled.fireAt))"
            // §7.1: Always append suggestion suffix to auto-resume branch too
            if let limited = limitedProfileName, let suggested = suggestedProfileName, let suffix = usageSuffix {
                message = "Session limit hit on \(limited) — resets \(ResumeTimeFormatter.string(from: scheduled.fireAt)). \(suggested) has room (\(suffix))"
            } else if let limited = limitedProfileName {
                message = "Session limit hit on \(limited) — resets \(ResumeTimeFormatter.string(from: scheduled.fireAt))"
            }
        } else {
            // Gate off: record the detection for audit, notify with the reset time
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
            if let limited = limitedProfileName {
                message = "Session limit hit on \(limited) — resets \(ResumeTimeFormatter.string(from: params.resetsAt))"
            } else {
                message = "Session limit hit — resets \(ResumeTimeFormatter.string(from: params.resetsAt))"
            }
            // §7.1: Always append suggestion suffix (ambient: no limited name)
            if let suggested = suggestedProfileName, let suffix = usageSuffix {
                message.append(". \(suggested) has room (\(suffix))")
            }
        }

        // Broadcast terminalLimitHit delta
        let delta = StateDelta.terminalLimitHit(TerminalLimitHitDelta(
            terminalID: terminal.id,
            worktreeID: terminal.worktreeID,
            profileID: terminal.profileID,
            resetsAt: params.resetsAt,
            limitType: params.limitType,
            suggestedProfileID: suggestedProfileID,
            rotatedToProfileID: rotationSucceeded ? suggestedProfileID : nil
        ))
        subscriptions.broadcast(delta: delta)

        try await notify(terminal: terminal, type: .limitReached, message: message)
        return .ok()
    }

    /// Eligibility verdict for attempting a profile rotation on limit hit.
    enum RotationVerdict: Sendable, CustomStringConvertible {
        case rotate(UUID)
        case flagOff
        case ambient
        case parked
        case holderTransport
        case noSession
        case noCandidate

        var description: String {
            switch self {
            case .rotate(let id): return "rotate(\(id.uuidString))"
            case .flagOff: return "flagOff"
            case .ambient: return "ambient"
            case .parked: return "parked"
            case .holderTransport: return "holderTransport"
            case .noSession: return "noSession"
            case .noCandidate: return "noCandidate"
            }
        }
    }

    /// Check whether a terminal is eligible for automatic profile rotation.
    /// Pure function: testable without tmux or database.
    static func rotationEligibility(
        terminal: Terminal,
        flagOn: Bool,
        suggested: UUID?
    ) -> RotationVerdict {
        guard flagOn else { return .flagOff }
        guard terminal.profileID != nil else { return .ambient }
        guard !terminal.isParked else { return .parked }
        guard terminal.transport == .tmux else { return .holderTransport }
        guard terminal.claudeSessionID != nil else { return .noSession }
        guard let suggestedID = suggested else { return .noCandidate }
        return .rotate(suggestedID)
    }

    /// Format a ProfileUsageSnapshot's 5h and weekly percents for notification.
    private func formatUsageForNotification(snapshot: ProfileUsageSnapshot) -> String? {
        var parts: [String] = []
        if let sessionBucket = snapshot.buckets.first(where: { $0.kind == "session" }) {
            parts.append("5h \(Int(sessionBucket.percent))%")
        }
        if let weeklyBucket = snapshot.buckets.first(where: { $0.kind == "weekly_all" }) {
            parts.append("week \(Int(weeklyBucket.percent))%")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
