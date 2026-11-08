import Foundation
import os
import TBDShared

/// `profiles.list`, `session.switchProfile` and `session.fork` (spec section
/// 4.4, and section 5's "Switch profile and fork").
///
/// **`profiles.list` is an allowlist.** Each `PhoneProfile` is built field by
/// field from a `ModelProfile`: its ID, its name, its credential kind, and
/// whether it is the default. Nothing else a profile holds (its endpoint,
/// model, AWS profile, environment overrides) and nothing of the global
/// environment overrides can reach the phone, because nothing here encodes a
/// `ModelProfile` or reads `modelProfile.list`'s result. A field added to
/// `ModelProfile` later stays off the phone until someone adds it here.
///
/// **Switch and fork restart or copy a live session under other
/// credentials,** so both act only on a session the phone can see and can do
/// this to: a local Claude session in a local worktree, by the sessions
/// list's own reading (`phoneVisibleTerminal`, `PhoneSnapshotBuilder.agent(of:)`
/// and `PhoneSessionStatus.localCapabilities`). A remote session, a Codex
/// session, a shell and a tab in a remote lane are `unsupported`, with the
/// reason the sessions list shows where it has one. A profile the phone
/// names must exist, or the request is `not_found`, and so is a session the
/// phone cannot see. Both read these rows themselves before calling the
/// swap, which checks them again.
///
/// Both go through `phoneSwapProfile`, `terminal.swapProfile` under the
/// verified pairing's device, `context.peer.deviceID`. A refusal is `refused`
/// with the daemon's reason; a success whose result is not a terminal row is
/// `internal`, never a success. Both are in the request memory
/// (`remembersReplies(of:)`), so a resend acts once and gets the first reply.
/// Their record's target is the session reference, never a profile.
extension PhoneAppService {
    static let noSuchProfileReason = "That profile is no longer on this laptop."
    static let notAClaudeSessionReason = "Only a Claude session can switch profiles or fork."
    /// The sessions list marks a parked session's fork unavailable with the
    /// same words.
    static let parkedForkReason = PhoneSessionStatus.parkedForkReason
    static let forkMovedReason =
        "The session was parked before the fork started, so it moved to that profile instead. Open it to continue."
    /// The most bytes a `profiles.list` result may encode to, leaving the
    /// rest of one frame for the reply's envelope.
    static let profilesResultBytes = PhoneFrameBudget.eventDataBytes

    // MARK: - profiles.list

    /// The user's model profiles, in the laptop's order, as `PhoneProfile`s
    /// (`phoneProfile(_:defaultID:)`), as many as fit one frame
    /// (`fittedProfiles(_:budget:)`).
    nonisolated func profilesList(_ params: PhoneEmpty, _ context: DeviceContext) async throws -> ProfilesListResult {
        let profiles = try await db.modelProfiles.list()
        let defaultID = try await db.config.get().defaultProfileID
        return Self.fittedProfiles(profiles.map { profile in Self.phoneProfile(profile, defaultID: defaultID) })
    }

    /// What the phone sees of `profile`: its ID, its name cut to
    /// `PhoneText.fieldLimit` bytes, its credential kind's raw value, and
    /// whether it is the default (`defaultID`). Nothing else.
    static func phoneProfile(_ profile: ModelProfile, defaultID: UUID?) -> PhoneProfile {
        PhoneProfile(
            id: profile.id,
            name: PhoneText.capped(profile.name),
            kind: profile.kind.rawValue,
            isDefault: profile.id == defaultID)
    }

    /// `profiles` in order, as many as fit `budget` bytes once encoded as a
    /// `ProfilesListResult`. The rest are dropped from the end, which takes
    /// far more profiles than anyone keeps, since a name is cut to
    /// `PhoneText.fieldLimit` bytes.
    static func fittedProfiles(_ profiles: [PhoneProfile], budget: Int = profilesResultBytes) -> ProfilesListResult {
        let encoder = PhoneAppCoding.makeEncoder()
        var used = (try? encoder.encode(ProfilesListResult(profiles: [])).count) ?? 0
        var kept: [PhoneProfile] = []
        for profile in profiles {
            // A profile's bytes, and a comma unless it is the first.
            let cost = ((try? encoder.encode(profile).count) ?? Int.max / 2) + (kept.isEmpty ? 0 : 1)
            guard used + cost <= budget else { break }
            used += cost
            kept.append(profile)
        }
        if kept.count < profiles.count {
            Self.logger.notice(
                "Phone profiles: \(profiles.count - kept.count, privacy: .public) of \(profiles.count, privacy: .public) profiles left out to fit one frame")
        }
        return ProfilesListResult(profiles: kept)
    }

    // MARK: - session.switchProfile

    /// Restarts a local Claude session under `params.profileID` in the same
    /// tab: `terminal.swapProfile` in `inPlace` mode. A parked session takes
    /// the swap's cold path, which moves the parked row to the profile and
    /// does not wake it. The reply is the session's reference, read from the
    /// row the swap returns.
    nonisolated func sessionSwitchProfile(
        _ params: SessionSwitchProfileParams, _ context: DeviceContext
    ) async throws -> SessionRefResult {
        let (terminal, _) = try await swappableTerminal(params.session)
        guard try await db.modelProfiles.get(id: params.profileID) != nil else {
            throw PhoneAppError(code: .notFound, message: Self.noSuchProfileReason)
        }
        return try await swapProfile(
            terminal.id, to: params.profileID, mode: .inPlace, deviceID: context.peer.deviceID)
    }

    // MARK: - session.fork

    /// Copies a local Claude session's conversation into a new tab:
    /// `terminal.swapProfile` in `fork` mode, under `params.profileID`, or
    /// the session's own profile when that is nil. A session with no profile
    /// runs on the laptop's own login, and the swap reads a nil profile as
    /// that same login, so a fork of it with no profile named stays on it.
    /// The reply is the new tab's reference, read from the new row the swap
    /// returns.
    ///
    /// **A parked session is refused.** The swap moves a parked row to the
    /// profile in place whatever the mode asks, so a fork of one would open
    /// no tab and would move the session itself to the other profile, the
    /// opposite of a fork, which leaves the session where it is. The phone
    /// wakes it first by sending it a message. The sessions list already
    /// marks such a fork unavailable; this guard answers a request that raced
    /// the park, as `refused`, a state the phone can change, where the list's
    /// other reasons are kinds of session it cannot fork, `unsupported`. A
    /// session that parks between this check and the swap's own read takes
    /// the swap's cold path, which `swapProfile` reports.
    nonisolated func sessionFork(_ params: SessionForkParams, _ context: DeviceContext) async throws -> SessionRefResult {
        let (terminal, capabilities) = try await swappableTerminal(params.session)
        guard !terminal.isParked else {
            throw PhoneAppError(code: .refused, message: Self.parkedForkReason)
        }
        try Self.requireCapability(capabilities.fork, orElse: Self.notAClaudeSessionReason)
        if let profileID = params.profileID, try await db.modelProfiles.get(id: profileID) == nil {
            throw PhoneAppError(code: .notFound, message: Self.noSuchProfileReason)
        }
        return try await swapProfile(
            terminal.id, to: params.profileID ?? terminal.profileID, mode: .fork, deviceID: context.peer.deviceID)
    }

    // MARK: - Shared

    /// The terminal row behind `session`, with its capabilities as the
    /// sessions list shows them, when it is a session switch and fork may act
    /// on: a local Claude session in a local worktree that the phone can see.
    ///
    /// A remote session is `unsupported` with the reason the sessions list
    /// gives; a session the phone cannot see (`phoneVisibleTerminal`) is
    /// `not_found`; a session whose `switchProfile` capability is unavailable
    /// (a Codex session, a tab in a remote lane) is `unsupported` with that
    /// capability's reason; any other session the list does not show as
    /// Claude (a shell, or a row with no kind and no Claude session) is
    /// `unsupported`. `switchProfile` is read for both methods because it is
    /// what the session is; `fork` differs from it only on a parked session,
    /// which `sessionFork` answers itself.
    private nonisolated func swappableTerminal(
        _ session: PhoneSessionRef
    ) async throws -> (terminal: TBDShared.Terminal, capabilities: PhoneCapabilities) {
        guard case .local(let terminalID) = session else {
            throw PhoneAppError(code: .unsupported, message: PhoneSessionStatus.remoteOnlyReason)
        }
        let (terminal, worktree) = try await phoneVisibleTerminal(terminalID)
        let capabilities = PhoneSessionStatus.localCapabilities(
            terminal: terminal, isRemoteWorktree: !worktree.location.isLocal)
        try Self.requireCapability(capabilities.switchProfile, orElse: Self.notAClaudeSessionReason)
        guard PhoneSnapshotBuilder.agent(of: terminal) == .claude else {
            throw PhoneAppError(code: .unsupported, message: Self.notAClaudeSessionReason)
        }
        return (terminal, capabilities)
    }

    /// `terminal.swapProfile` for `terminalID`, onto `profileID` (nil for the
    /// laptop's own login), in `mode`, under the phone `deviceID`, and the
    /// reference of the terminal row it returns. A refusal is `refused` with
    /// the daemon's reason; a result that is not a terminal row is
    /// `internal`. A revoke noticed before the swap stops it.
    ///
    /// **A fork that returns the session's own row moved it.** The session
    /// parked after `sessionFork` checked it, and the swap's cold path moved
    /// the parked row to the profile in place, opening no tab. That is not a
    /// fork, so the reply is `refused` with `forkMovedReason`, which says
    /// what happened, never a success that names the old session as the new
    /// one.
    private nonisolated func swapProfile(
        _ terminalID: UUID, to profileID: UUID?, mode: TerminalSwapMode, deviceID: UUID
    ) async throws -> SessionRefResult {
        try Task.checkCancellation()
        let response = try await actions.phoneSwapProfile(
            TerminalSwapProfileParams(terminalID: terminalID, newProfileID: profileID, mode: mode),
            deviceID: deviceID)
        let row = try Self.succeeded(TBDShared.Terminal.self, from: response, method: "terminal.swapProfile")
        if mode == .fork, row.id == terminalID {
            Self.logger.notice(
                "Phone session.fork: terminal \(terminalID, privacy: .public) parked before the swap, which moved it in place")
            throw PhoneAppError(code: .refused, message: Self.forkMovedReason)
        }
        return SessionRefResult(session: .local(terminalID: row.id))
    }
}
