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
/// **Switch and fork restart or copy a session under other credentials,**
/// running or parked, so both act only on a session the phone can see and can do
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
    /// `ProfilesListResult` (`PhoneFrameFit`). A profile that does not fit is
    /// left out and the next one tried, so one cannot hide the profiles after
    /// it. Leaving any out takes far more profiles than anyone keeps, since a
    /// name is cut to `PhoneText.fieldLimit` bytes.
    static func fittedProfiles(_ profiles: [PhoneProfile], budget: Int = profilesResultBytes) -> ProfilesListResult {
        let empty = (try? PhoneAppCoding.makeEncoder().encode(ProfilesListResult(profiles: [])).count) ?? 0
        let kept = PhoneFrameFit.fitted(profiles, used: empty, budget: budget, onMisfit: .skip)
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
        let terminal = try await swappableTerminal(params.session, needing: { $0.switchProfile })
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
    /// **A parked session forks too,** without being woken first. The swap's
    /// fork copies the conversation from the parked session's transcript into
    /// the new tab, which starts awake, and leaves the parked session as it
    /// is: parked, on its own profile.
    nonisolated func sessionFork(_ params: SessionForkParams, _ context: DeviceContext) async throws -> SessionRefResult {
        let terminal = try await swappableTerminal(params.session, needing: { $0.fork })
        if let profileID = params.profileID, try await db.modelProfiles.get(id: profileID) == nil {
            throw PhoneAppError(code: .notFound, message: Self.noSuchProfileReason)
        }
        return try await swapProfile(
            terminal.id, to: params.profileID ?? terminal.profileID, mode: .fork, deviceID: context.peer.deviceID)
    }

    // MARK: - Shared

    /// The terminal row behind `session`, when it is a session switch and
    /// fork may act on: a local Claude session in a local worktree that the
    /// phone can see, whose `needed` capability is available
    /// (`phoneCapableClaudeTerminal`). Each method reads its own capability,
    /// `switchProfile` or `fork`, as the sessions list shows it. Neither
    /// follows the setting for answering prompts, and neither method reads
    /// the config row.
    ///
    /// A remote session is `unsupported` with the reason the sessions list
    /// gives; a session the phone cannot see (`phoneVisibleTerminal`) is
    /// `not_found`; a session whose `needed` capability is unavailable (a
    /// Codex session, a tab in a remote lane) is `unsupported` with that
    /// capability's reason; any other session the list does not show as
    /// Claude (a shell, or a row with no kind and no Claude session) is
    /// `unsupported`.
    private nonisolated func swappableTerminal(
        _ session: PhoneSessionRef, needing needed: @Sendable (PhoneCapabilities) -> PhoneCapability
    ) async throws -> TBDShared.Terminal {
        guard case .local(let terminalID) = session else {
            throw PhoneAppError(code: .unsupported, message: PhoneSessionStatus.remoteOnlyReason)
        }
        return try await phoneCapableClaudeTerminal(
            terminalID, needing: needed, notClaude: Self.notAClaudeSessionReason).terminal
    }

    /// `terminal.swapProfile` for `terminalID`, onto `profileID` (nil for the
    /// laptop's own login), in `mode`, under the phone `deviceID`, and the
    /// reference of the terminal row it returns: the session's own row for
    /// `inPlace`, the new tab's for `fork`, parked or not. A refusal is
    /// `refused` with the daemon's reason; a result that is not a terminal
    /// row is `internal`. A revoke noticed before the swap stops it.
    private nonisolated func swapProfile(
        _ terminalID: UUID, to profileID: UUID?, mode: TerminalSwapMode, deviceID: UUID
    ) async throws -> SessionRefResult {
        try Task.checkCancellation()
        let response = try await actions.phoneSwapProfile(
            TerminalSwapProfileParams(terminalID: terminalID, newProfileID: profileID, mode: mode),
            deviceID: deviceID)
        let row = try Self.succeeded(TBDShared.Terminal.self, from: response, method: "terminal.swapProfile")
        return SessionRefResult(session: .local(terminalID: row.id))
    }
}
