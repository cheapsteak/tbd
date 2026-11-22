import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modelProfileResolver")

public struct ResolvedModelProfile: Sendable, Equatable {
    public let profileID: UUID
    public let name: String
    public let kind: CredentialKind
    public let baseURL: String?
    public let model: String?
    public let secret: String?
    public let awsRegion: String?
    public let awsProfile: String?
    /// Ordered fallback model ids for the Claude `fallbackModel` setting.
    /// nil/empty = no fallback configured for this profile.
    public let fallbackModels: [String]?
    /// Free-form env overrides carried by this profile (profile scope). Merged
    /// into the spawned session's env under `global < repo < profile` precedence.
    public let envOverrides: [String: String]
    /// The balanced pick's reservation on the shared ledger, when this profile
    /// came from one. The spawn hands it back through
    /// `ModelProfileResolver.settleReservation` once its terminal row is
    /// inserted. Nil for every other step of the chain.
    public let reservationID: UUID?

    public init(
        profileID: UUID,
        name: String,
        kind: CredentialKind,
        baseURL: String?,
        model: String?,
        secret: String?,
        awsRegion: String?,
        awsProfile: String?,
        fallbackModels: [String]?,
        envOverrides: [String: String],
        reservationID: UUID? = nil
    ) {
        self.profileID = profileID
        self.name = name
        self.kind = kind
        self.baseURL = baseURL
        self.model = model
        self.secret = secret
        self.awsRegion = awsRegion
        self.awsProfile = awsProfile
        self.fallbackModels = fallbackModels
        self.envOverrides = envOverrides
        self.reservationID = reservationID
    }

    /// The same profile carrying `reservationID`.
    func withReservation(_ id: UUID?) -> ResolvedModelProfile {
        ResolvedModelProfile(
            profileID: profileID, name: name, kind: kind, baseURL: baseURL,
            model: model, secret: secret, awsRegion: awsRegion,
            awsProfile: awsProfile, fallbackModels: fallbackModels,
            envOverrides: envOverrides, reservationID: id)
    }
}

/// A Fable spawn found no account it may run on: every profile balancing
/// could have used is out of Fable usage credits. The spawn fails with this
/// rather than quietly running another model or an out account.
public struct FableUnavailableError: LocalizedError, Sendable, Equatable {
    /// The profiles that were out, by name.
    public let profileNames: [String]

    public init(profileNames: [String]) { self.profileNames = profileNames }

    public var errorDescription: String? {
        let tried = profileNames.isEmpty ? "no profile" : profileNames.joined(separator: ", ")
        return "Fable is out of usage credits on every account tried (\(tried)). "
            + "TBD did not start the session on another model. Add usage credits, wait for "
            + "them to renew, or choose another model."
    }
}

public struct ModelProfileResolver: Sendable {
    let profiles: ModelProfileStore
    let repos: RepoStore
    let config: ConfigStore
    let keychain: @Sendable (String) throws -> String?
    let candidateSource: ProfilePoolCandidateSource?
    /// Makes the balanced pick atomic across concurrent spawns. Nil picks
    /// straight from the stores, as tests that exercise one spawn at a time
    /// do; the daemon always passes its single shared instance.
    let reservations: ProfilePickReservations?
    /// Surfaces an account a balanced pick skips for a stale reading (design
    /// §6.1). Nil surfaces nothing; the daemon always passes its single
    /// shared instance, so the once-per-profile latch holds across spawns.
    let staleAlerts: StaleAccountAlerts?
    /// Surfaces a balanced pick that found nothing eligible and fell back
    /// (design §6.3). Nil surfaces nothing; the daemon always passes its
    /// single shared instance, so the per-episode latch holds across spawns.
    let fallbackAlerts: BalancingFallbackAlerts?
    let now: @Sendable () -> Date
    /// Latest Fable readings and the on-demand probe. Nil means a Fable spawn
    /// is balanced like any other (nothing is known to be out).
    let fable: FableAvailabilityStore?

    /// How long a Fable spawn waits for probes of unchecked profiles before it
    /// places the session on what it knows. A profile still unchecked then is
    /// eligible but unverified.
    static let fableProbeDeadline: TimeInterval = 45

    public init(
        profiles: ModelProfileStore,
        repos: RepoStore,
        config: ConfigStore,
        keychain: @Sendable @escaping (String) throws -> String? = { try ModelProfileKeychain.load(id: $0) },
        candidateSource: ProfilePoolCandidateSource? = nil,
        reservations: ProfilePickReservations? = nil,
        staleAlerts: StaleAccountAlerts? = nil,
        fallbackAlerts: BalancingFallbackAlerts? = nil,
        now: @Sendable @escaping () -> Date = { Date() },
        fable: FableAvailabilityStore? = nil
    ) {
        self.fable = fable
        self.profiles = profiles
        self.repos = repos
        self.config = config
        self.keychain = keychain
        self.candidateSource = candidateSource
        self.reservations = reservations
        self.staleAlerts = staleAlerts
        self.fallbackAlerts = fallbackAlerts
        self.now = now
    }

    /// Load a profile by explicit ID, bypassing the precedence chain.
    /// Used by per-terminal pinning (resume) and mid-conversation swap.
    /// Returns nil if the row is missing. For .apiKey profiles, also returns
    /// nil if the keychain secret is missing or empty. OAuth and bedrock
    /// profiles carry no TBD-stored secret and always succeed if the row
    /// exists; an .oauthToken profile carries one but still resolves without
    /// it (see `loadResolved`).
    ///
    /// `touchLastUsed: false` is for a read that is not a use of the profile
    /// (a Fable probe), so it does not move the profile's last-used time.
    public func loadByID(_ id: UUID, touchLastUsed: Bool = true) async throws -> ResolvedModelProfile? {
        try await loadResolved(id: id, touchLastUsed: touchLastUsed)
    }

    private func loadResolved(id: UUID, touchLastUsed: Bool = true) async throws -> ResolvedModelProfile? {
        guard let row = try await profiles.get(id: id) else { return nil }

        let secret: String?
        switch row.kind {
        case .apiKey:
            // An api-key profile is nothing but its key: with no secret there
            // is no credential to spawn under at all, so the row resolves to
            // nil and the caller falls through the precedence chain.
            guard let s = try keychain(id.uuidString), !s.isEmpty else { return nil }
            secret = s
        case .oauthToken:
            // A token profile carries a TBD-stored secret like `.apiKey`, but
            // a MISSING one deliberately does NOT fail resolution. The profile
            // still owns an isolated config dir, so spawning without the token
            // yields an unauthenticated pane that asks for a login — visible
            // and recoverable. Falling through the chain instead would
            // silently run the session under some other account.
            let stored = try keychain(id.uuidString)
            if let stored, !stored.isEmpty {
                secret = stored
            } else {
                logger.warning("token profile \(row.id, privacy: .public) has no stored secret; spawning without CLAUDE_CODE_OAUTH_TOKEN")
                secret = nil
            }
        case .oauth, .bedrock:
            secret = nil   // no TBD-stored secret
        }

        if touchLastUsed { try await profiles.touchLastUsed(id: row.id) }
        return ResolvedModelProfile(
            profileID: row.id,
            name: row.name,
            kind: row.kind,
            baseURL: row.baseURL,
            model: row.model,
            secret: secret,
            awsRegion: row.awsRegion,
            awsProfile: row.awsProfile,
            fallbackModels: row.fallbackModels,
            envOverrides: row.envOverrides
        )
    }

    /// Whether a terminal spawn may take a balanced pick. A resumed
    /// conversation belongs to the account holding its transcript, which the
    /// history row does not record, so a resume keeps the stable
    /// pre-balancing resolution; a load-sensitive pick could land it on an
    /// account without the transcript.
    public static func balances(resumeSessionID: String?) -> Bool {
        resumeSessionID == nil
    }

    /// Whether a worktree-create spawn may take a balanced pick: never when
    /// it restores archived conversations or carries one over, for the same
    /// reason as `balances(resumeSessionID:)` — those resume transcripts that
    /// live under whichever account wrote them.
    public static func balancesWorktreeSpawn(
        restoringArchivedSessions: Bool,
        carryingOver: Bool
    ) -> Bool {
        !restoringArchivedSessions && !carryingOver
    }

    /// Settle a balanced pick's reservation: the spawn's terminal row has
    /// been inserted and now carries the load in the live counts. Call it
    /// with `resolved?.reservationID` right after the row lands; nil (any
    /// non-balanced resolution) and a resolver without a ledger are no-ops.
    public func settleReservation(_ id: UUID?) async {
        guard let id, let reservations else { return }
        await reservations.release(id)
    }

    /// Resolve the model profile for a spawn.
    ///
    /// `override` is an explicit per-creation profile id (e.g. chosen in the
    /// sidebar `+` profile picker). When non-nil AND it resolves, it wins over
    /// EVERY tier of the precedence chain below. A nil `override` (the default)
    /// preserves the exact pre-existing precedence: repo override → scratch
    /// override → global default → none.
    ///
    /// `balance: false` keeps that pre-balancing chain even when
    /// `profileBalancingEnabled` is on: the global-default step returns the
    /// default (or nil), with no pick and no reservation. Spawns that resume
    /// an existing conversation pass it — see `balances(resumeSessionID:)`.
    ///
    /// `worktreeID` names the spawning worktree, so a balanced pick that skips
    /// an account for a stale reading can say so there (design §6.1). Nil
    /// surfaces nothing.
    public func resolve(
        repoID: UUID?,
        override overrideID: UUID? = nil,
        balance: Bool = true,
        worktreeID: UUID? = nil,
        model: String? = nil
    ) async throws -> ResolvedModelProfile? {
        // A spawn that asks for a Fable model (`model` is the per-spawn
        // request) is never balanced onto a profile known to be out of Fable
        // credits, and throws `FableUnavailableError` rather than land on one.
        // An explicit pin (steps 0 to 1.5) is the person's choice and is not
        // second-guessed.
        let requiresFable = FableModel.isFable(model) && fable != nil
        // Step 0: explicit per-creation override — highest priority. If the
        // row/keychain is missing we log and fall through to the normal chain
        // rather than fail the spawn.
        if let overrideID {
            if let resolved = try await loadResolved(id: overrideID) {
                return resolved
            }
            logger.warning("explicit profile override \(overrideID, privacy: .public) is missing; falling back to precedence chain")
        }

        // Step 1: per-repo override.
        if let repoID, let repo = try await repos.get(id: repoID),
           let overrideID = repo.profileOverrideID {
            if let resolved = try await loadResolved(id: overrideID) {
                return resolved
            }
            logger.warning("profile override \(overrideID, privacy: .public) for repo \(repoID, privacy: .public) is missing; falling back to global default")
        }

        let cfg = try await config.get()

        // Step 1.5: scratch override. `repoID == nil` is the sole signal for a
        // scratch (repo-less) spawn — see resolve(repoID:) call sites. Repo-scoped
        // calls (repoID != nil) never consult scratchProfileOverrideID.
        if repoID == nil, let scratchOverrideID = cfg.scratchProfileOverrideID {
            if let resolved = try await loadResolved(id: scratchOverrideID) {
                return resolved
            }
            logger.warning("scratch profile override \(scratchOverrideID, privacy: .public) is missing; falling back to global default")
        }

        // Step 2: global default, or balanced pick if enabled.
        if balance, cfg.profileBalancingEnabled, let source = candidateSource {
            // Balancing is enabled and we have a source: build candidates and ask the picker.
            var reservationID: UUID?
            let policy = cfg.profileBalancingPolicy
            do {
                let candidates: [ProfilePoolCandidate]
                let decision: ProfilePoolDecision
                if requiresFable { await probeFablePool(source: source, defaultProfileID: cfg.defaultProfileID) }
                let pickTime = now()
                if let reservations {
                    // Every read happens first, and then one non-suspending
                    // call picks and reserves, so a concurrent spawn into
                    // another worktree sees this pick even before its
                    // terminal row exists.
                    let stored = try await source.candidates(defaultProfileID: cfg.defaultProfileID)
                    let outcome = await reservations.pickAndReserve(
                        candidates: stored, pickTime: pickTime, policy: policy,
                        requiresFable: requiresFable)
                    candidates = outcome.candidates
                    decision = outcome.decision
                    reservationID = outcome.reservationID
                } else {
                    candidates = try await source.candidates(defaultProfileID: cfg.defaultProfileID)
                    decision = ProfilePoolPicker.pick(
                        candidates: candidates,
                        excludingAccountKeys: [],
                        now: pickTime,
                        policy: policy,
                        requiresFable: requiresFable
                    )
                }

                // Every candidate the pick could use is out of Fable credits:
                // fail plainly, naming them.
                if requiresFable, decision.chosen == nil, decision.fallback == nil {
                    var names: [String] = []
                    for candidate in candidates where decision.verdicts[candidate.profileID] == .fableOut {
                        if let name = try? await profiles.get(id: candidate.profileID)?.name {
                            names.append(name)
                        }
                    }
                    if !names.isEmpty {
                        if let reservationID, let reservations { await reservations.release(reservationID) }
                        throw FableUnavailableError(profileNames: names.sorted())
                    }
                }

                // Tell the person about any account skipped for a stale
                // reading, and about a fallback. Neither throws, and a failed
                // post only logs.
                let profileName: @Sendable (UUID) async -> String? = { [profiles] id in
                    try? await profiles.get(id: id)?.name
                }
                if let staleAlerts {
                    await staleAlerts.observe(
                        candidates: candidates, decision: decision,
                        worktreeID: worktreeID, now: pickTime,
                        profileName: profileName)
                }
                if let fallbackAlerts {
                    await fallbackAlerts.observe(
                        candidates: candidates, decision: decision, policy: policy,
                        worktreeID: worktreeID, now: pickTime,
                        profileName: profileName)
                }

                if let chosenID = decision.chosen {
                    if let resolved = try await loadResolved(id: chosenID) {
                        // Log the balanced decision.
                        let chosenCandidate = candidates.first(where: { $0.profileID == chosenID })
                        let headroom = chosenCandidate.flatMap { candidate in
                            decision.verdicts[candidate.profileID]
                                .flatMap { verdict in
                                    if case let .eligible(_, hr, accountLoad) = verdict {
                                        return (hr, accountLoad)
                                    }
                                    return nil
                                }
                        }

                        if let (hr, accountLoad) = headroom {
                            logger.info("balanced pick: profile \(chosenID, privacy: .public), headroom \(String(format: "%.1f%%", hr * 100)), account live sessions \(accountLoad)")
                        } else {
                            logger.info("balanced pick: profile \(chosenID, privacy: .public)")
                        }

                        // Log rejected candidates.
                        for candidate in candidates where candidate.profileID != chosenID {
                            if let verdict = decision.verdicts[candidate.profileID] {
                                let reason: String
                                switch verdict {
                                case .eligible:
                                    reason = "eligible but lower rank"
                                case .wrongKind:
                                    reason = "wrongKind"
                                case .noCredential:
                                    reason = "noCredential"
                                case .optedOut:
                                    reason = "optedOut"
                                case .sameAccount:
                                    reason = "sameAccount"
                                case .noFreshReading:
                                    reason = "noFreshReading"
                                case .exhausted:
                                    reason = "exhausted"
                                case .fableOut:
                                    reason = "fableOut"
                                }
                                logger.debug("rejected candidate \(candidate.profileID, privacy: .public): \(reason)")
                            }
                        }

                        return resolved.withReservation(reservationID)
                    }
                    logger.warning("balanced pick \(chosenID, privacy: .public) did not load; falling back to default")
                } else if let fallback = decision.fallback {
                    // Nothing was eligible, but some account in the pool was
                    // turned away only for its reading: place the session on
                    // the least bad of those rather than on whatever the
                    // global default happens to be, which may be the fullest
                    // account of all. Never silent — `fallbackAlerts` tells
                    // the person, and this logs every one.
                    if let resolved = try await loadResolved(id: fallback.profileID) {
                        logger.warning("balancing found no eligible candidate; fell back to profile \(fallback.profileID, privacy: .public) (\(String(describing: fallback.reason), privacy: .public)) under a \(policy.usageCeilingPercent)% ceiling")
                        return resolved.withReservation(reservationID)
                    }
                    logger.warning("balancing fallback \(fallback.profileID, privacy: .public) did not load; falling back to default")
                } else {
                    logger.info("balancing found no candidate in the pool; falling back to default")
                }
            } catch let error as FableUnavailableError {
                throw error
            } catch {
                // Either the candidate source or loading the chosen profile
                // (its keychain read) can throw here; the log names both.
                logger.error("balancing threw (candidate source or loading the pick); falling back to default: \(error, privacy: .public)")
            }
            // Reaching here means the pick placed nothing; its reservation
            // must not count against the profile.
            if let reservationID, let reservations {
                await reservations.release(reservationID)
            }
        }

        // Fallback to step 2 / step 3: global default or nothing.
        if let defaultID = cfg.defaultProfileID {
            if requiresFable, let fable {
                // The default is a place the session may land too; it is not
                // exempt from the Fable rule. Probe it if it is unchecked.
                _ = await fable.refresh([defaultID], deadline: Self.fableProbeDeadline)
                if let reading = await fable.current(defaultID), reading.isOut(now: now()) {
                    let name = (try? await profiles.get(id: defaultID)?.name) ?? defaultID.uuidString
                    throw FableUnavailableError(profileNames: [name])
                }
            }
            if let resolved = try await loadResolved(id: defaultID) {
                return resolved
            }
            logger.warning("global default profile \(defaultID, privacy: .public) is missing; no env will be injected")
            return nil
        }

        // Step 3: nothing applies.
        return nil
    }

    /// Probe every pool profile whose Fable reading is missing or past its
    /// TTL, waiting at most `fableProbeDeadline`. Best effort: a profile still
    /// unchecked afterwards stays eligible, unverified.
    private func probeFablePool(source: ProfilePoolCandidateSource, defaultProfileID: UUID?) async {
        guard let fable,
              let candidates = try? await source.candidates(defaultProfileID: defaultProfileID)
        else { return }
        let ids = candidates
            .filter { ($0.kind == .oauth || $0.kind == .oauthToken) && $0.hasCredential && !$0.poolOptOut }
            .map(\.profileID)
        await fable.refresh(ids, deadline: Self.fableProbeDeadline)
    }
}
