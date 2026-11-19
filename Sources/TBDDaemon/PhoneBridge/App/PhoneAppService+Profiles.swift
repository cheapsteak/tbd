import Foundation
import os
import TBDShared

/// `profiles.list`, `session.switchProfile` and `session.fork` (spec section
/// 4.4, and section 5's "Switch profile and fork").
///
/// **`profiles.list` is an allowlist.** Each `PhoneProfile` is built field by
/// field from a `ModelProfile`: its ID, its name, its credential kind, and
/// whether it is the default. When the phone names a repo, as the New sheet
/// does, each also says whether it can start a session and, when it cannot,
/// why, in one of a few fixed phrases of TBD's own; the reply names the
/// profile a new worktree in that repo would start on. Nothing else a profile
/// holds (its endpoint, model, AWS profile, environment overrides, stored
/// secret, login account) and nothing of the global environment overrides
/// can reach the phone, because nothing here encodes a `ModelProfile` or
/// reads `modelProfile.list`'s result, and a reason is never the check's own
/// refusal text. A field added to `ModelProfile` later stays off the phone
/// until someone adds it here.
///
/// **Switch and fork put a session under other credentials.** A switch
/// restarts a running session under the profile, in its own tab, and moves a
/// parked one to the profile, where it stays parked until its next wake. A
/// running session still on the tmux transport cannot be switched, because
/// TBD no longer starts processes there, so its switch is `unsupported` with
/// `PhoneSessionStatus.switchOnTmuxReason`, as the sessions list says. A
/// fork copies the conversation, running or parked, into a new tab under the
/// profile and leaves the session as it is. Both act only on a session the
/// phone can see and can do this to: a local Claude session in a local
/// worktree, by the sessions list's own reading (`phoneVisibleTerminal`,
/// `PhoneSnapshotBuilder.agent(of:)` and
/// `PhoneSessionStatus.localCapabilities`). A remote session, a Codex
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
    /// Why a profile cannot start a session, as `profiles.list` says it: a
    /// few words for the New sheet's row, never the create's refusal, which
    /// names laptop commands a phone cannot run.
    static let notLoggedInReason = "Not logged in"
    static let noTokenReason = "No token stored"
    static let noAPIKeyReason = "No API key stored"
    static let credentialsUnreadableReason = "Credentials could not be read"
    /// The most bytes a `profiles.list` result may encode to, leaving the
    /// rest of one frame for the reply's envelope.
    static let profilesResultBytes = PhoneFrameBudget.eventDataBytes

    // MARK: - profiles.list

    /// The user's model profiles, in the laptop's order, as `PhoneProfile`s
    /// (`phoneProfile(_:defaultID:unusableReason:)`), as many as fit one
    /// frame (`fittedProfiles(_:repoProfileID:budget:)`).
    ///
    /// **With `params.repoID`**, for the New sheet, the list also says what a
    /// new worktree in that repo would meet:
    /// - **Each profile's usability**, from the check `worktree.create` runs on
    ///   an explicit profile (`profileCheck`, through
    ///   `ExplicitProfileCheck.missingCredential(of:)`), so a profile is shown
    ///   unusable exactly when a create naming it would be refused. Its reason
    ///   is one of the fixed phrases above (`unusableReason(_:)`). A profile
    ///   whose stored secret cannot be read is unusable too, with
    ///   `credentialsUnreadableReason`, since the create's check would throw
    ///   on it.
    /// - **The repo's profile** (`repoProfileID(repo:defaultID:profiles:missing:)`).
    ///
    /// A repo that is gone or hidden is `not_found`, as it is for
    /// `remote.providers` and `worktree.create`. Without a repo the list is
    /// the profiles alone, which the Switch account and Fork sheets read.
    nonisolated func profilesList(
        _ params: ProfilesListParams, _ context: DeviceContext
    ) async throws -> ProfilesListResult {
        let profiles = try await db.modelProfiles.list()
        let defaultID = try await db.config.get().defaultProfileID
        guard let repoID = params.repoID else {
            return Self.fittedProfiles(profiles.map { profile in Self.phoneProfile(profile, defaultID: defaultID) })
        }
        let repo = try await visibleRepo(repoID)
        var shown: [PhoneProfile] = []
        var missing: [UUID: ExplicitProfileCheck.MissingCredential] = [:]
        for profile in profiles {
            let reason: String?
            do {
                let lacking = try profileCheck.missingCredential(of: profile)
                missing[profile.id] = lacking
                reason = lacking.map { lack in Self.unusableReason(lack) }
            } catch {
                Self.logger.error(
                    "Phone profiles: could not read the credentials of profile \(profile.id, privacy: .public): \(Self.errorType(error), privacy: .public)")
                reason = Self.credentialsUnreadableReason
            }
            shown.append(Self.phoneProfile(profile, defaultID: defaultID, unusableReason: reason))
        }
        return Self.fittedProfiles(
            shown,
            repoProfileID: Self.repoProfileID(repo: repo, defaultID: defaultID, profiles: profiles, missing: missing))
    }

    /// What the phone sees of `profile`: its ID, its name cut to
    /// `PhoneText.fieldLimit` bytes, its credential kind's raw value, and
    /// whether it is the default (`defaultID`). With an `unusableReason`, it
    /// also carries `usable: false` and that reason; without one, neither
    /// field. Nothing else.
    static func phoneProfile(
        _ profile: ModelProfile, defaultID: UUID?, unusableReason: String? = nil
    ) -> PhoneProfile {
        PhoneProfile(
            id: profile.id,
            name: PhoneText.capped(profile.name),
            kind: profile.kind.rawValue,
            isDefault: profile.id == defaultID,
            usable: unusableReason == nil ? nil : false,
            unusableReason: unusableReason)
    }

    /// The phrase `profiles.list` gives for what a profile lacks.
    static func unusableReason(_ missing: ExplicitProfileCheck.MissingCredential) -> String {
        switch missing {
        case .login:
            return notLoggedInReason
        case .token:
            return noTokenReason
        case .apiKey:
            return noAPIKeyReason
        }
    }

    /// The profile a new worktree in `repo` would start on, as
    /// `ModelProfileResolver.resolve` picks it for a repo with balancing left
    /// out: the repo's own profile, then the global default (`defaultID`),
    /// the first of them that loads. A profile loads when it is among
    /// `profiles` and is not an API-key profile with no key (`missing`): the
    /// resolver passes over a profile that is gone and an API-key profile with
    /// no key, and takes any other profile whatever its credentials. Nil when
    /// neither loads.
    ///
    /// With balancing on, a create that names no profile may start on another
    /// account. The phone sends no profile unless the user picks one, so the
    /// laptop still balances that create.
    static func repoProfileID(
        repo: Repo, defaultID: UUID?, profiles: [ModelProfile],
        missing: [UUID: ExplicitProfileCheck.MissingCredential]
    ) -> UUID? {
        let present = Set(profiles.map(\.id))
        return [repo.profileOverrideID, defaultID]
            .compactMap { id in id }
            .first { id in present.contains(id) && missing[id] != .apiKey }
    }

    /// `profiles` in order, as many as fit `budget` bytes once encoded as a
    /// `ProfilesListResult` with `repoProfileID` (`PhoneFrameFit`). A profile
    /// that does not fit is left out and the next one tried, so one cannot
    /// hide the profiles after it. Leaving any out takes far more profiles
    /// than anyone keeps, since a name is cut to `PhoneText.fieldLimit`
    /// bytes. `repoProfileID` is kept only when its profile is, so the reply
    /// never names a profile it does not list.
    static func fittedProfiles(
        _ profiles: [PhoneProfile], repoProfileID: UUID? = nil, budget: Int = profilesResultBytes
    ) -> ProfilesListResult {
        let empty = (try? PhoneAppCoding.makeEncoder().encode(
            ProfilesListResult(profiles: [], repoProfileID: repoProfileID)).count) ?? 0
        let kept = PhoneFrameFit.fitted(profiles, used: empty, budget: budget, onMisfit: .skip)
        if kept.count < profiles.count {
            Self.logger.notice(
                "Phone profiles: \(profiles.count - kept.count, privacy: .public) of \(profiles.count, privacy: .public) profiles left out to fit one frame")
        }
        let listed = kept.contains { profile in profile.id == repoProfileID }
        return ProfilesListResult(profiles: kept, repoProfileID: listed ? repoProfileID : nil)
    }

    // MARK: - session.switchProfile

    /// Restarts a local Claude session under `params.profileID` in the same
    /// tab: `terminal.swapProfile` in `inPlace` mode. A parked session takes
    /// the swap's cold path, which moves the parked row to the profile and
    /// does not wake it. The reply is the session's reference and whether it
    /// is parked, both read from the row the swap returns, so the phone says
    /// what the laptop did rather than what the phone's list showed before
    /// the tap.
    nonisolated func sessionSwitchProfile(
        _ params: SessionSwitchProfileParams, _ context: DeviceContext
    ) async throws -> SessionSwitchProfileResult {
        let terminal = try await swappableTerminal(params.session, needing: { $0.switchProfile })
        guard try await db.modelProfiles.get(id: params.profileID) != nil else {
            throw PhoneAppError(code: .notFound, message: Self.noSuchProfileReason)
        }
        let row = try await swapProfile(
            terminal.id, to: params.profileID, mode: .inPlace, deviceID: context.peer.deviceID)
        return SessionSwitchProfileResult(session: .local(terminalID: row.id), parked: row.isParked)
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
        let row = try await swapProfile(
            terminal.id, to: params.profileID ?? terminal.profileID, mode: .fork, deviceID: context.peer.deviceID)
        return SessionRefResult(session: .local(terminalID: row.id))
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
            terminalID, needing: needed, notClaude: Self.notAClaudeSessionReason)
    }

    /// `terminal.swapProfile` for `terminalID`, onto `profileID` (nil for the
    /// laptop's own login), in `mode`, under the phone `deviceID`, and the
    /// terminal row it returns: the session's own row for `inPlace`, the new
    /// tab's for `fork`, parked or not. A refusal is `refused` with the
    /// daemon's reason; a result that is not a terminal row is `internal`. A
    /// revoke noticed before the swap stops it.
    private nonisolated func swapProfile(
        _ terminalID: UUID, to profileID: UUID?, mode: TerminalSwapMode, deviceID: UUID
    ) async throws -> TBDShared.Terminal {
        try Task.checkCancellation()
        let response = try await actions.phoneSwapProfile(
            TerminalSwapProfileParams(terminalID: terminalID, newProfileID: profileID, mode: mode),
            deviceID: deviceID)
        return try Self.succeeded(TBDShared.Terminal.self, from: response, method: "terminal.swapProfile")
    }
}
