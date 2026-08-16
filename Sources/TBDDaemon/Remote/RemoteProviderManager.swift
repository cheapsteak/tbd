import Foundation
import TBDShared
import os

private let remoteLogger = Logger(subsystem: "com.tbd.daemon", category: "remote")

/// Owns the remote-backend feature at runtime: registry, describe cache,
/// per-provider poll loops, provider health, and pass-through invocations.
/// Source of truth for sessions is always the provider; this actor only
/// maintains the mirror + broadcasts.
public actor RemoteProviderManager {
    private let db: TBDDatabase
    private let subscriptions: StateSubscriptionManager
    /// Mints the worktree row for a session that resolves to a registered
    /// repo. Runs after the mirror upsert at both convergence points, so it
    /// reads the repo association the mirror just pinned.
    private let adopter: RemoteSessionAdopter
    private let runner: any RemoteProviderInvoking
    private let registryURL: URL
    /// Providers TBD compiles in rather than reading from the registry file.
    /// Empty unless the daemon wired one at boot. They are registered and
    /// described exactly like registry entries, so their health, negotiated
    /// major and poll loop all work the same way — a built-in provider is a
    /// provider.
    private let builtInProviders: [RemoteProviderConfig]
    private let clock: any Clock<Duration>
    /// Where the filing sync records the archives and revives it performs.
    /// Optional only so the many fixtures that construct this actor for
    /// mirror/adoption coverage need not supply one; the daemon always does.
    /// The sync FAILS CLOSED without it — an act nobody can record does not
    /// happen (`docs/specs/2026-08-16-remote-lane-archive-design.md`
    /// §"Never silent").
    private let actuationLog: ActuationLog?
    static let pollInterval: TimeInterval = 60

    private var providers: [String: RemoteProviderConfig] = [:]
    private var describes: [String: ProviderDescribe] = [:]
    /// The contract major negotiated per provider — the highest version both
    /// TBD and the provider declare. Absent until `describe` has succeeded,
    /// which is why `contractMajor(for:)` falls back rather than trapping.
    private var negotiatedMajors: [String: Int] = [:]
    private var health:
        [String: (state: ProviderHealth, message: String?, remediation: ProviderRemediation?)] = [:]
    /// Most recent complete inventory accepted for each provider. Kept
    /// independently from generic verb health: a successful `log`/`attach`
    /// proves that verb worked, not that the cached inventory is current.
    private var lastSuccessfulSnapshotAt: [String: Date] = [:]
    /// Providers whose persisted freshness row could not be READ. This is not
    /// the same condition as "no successful snapshot was ever recorded": there,
    /// the daemon knows the mirror was never authoritative and deliberately
    /// fails open (see `hasStaleSnapshot`); here it knows nothing at all, so it
    /// must not spend that ignorance on a mutation. Cleared as soon as a read
    /// succeeds or a live snapshot lands.
    private var snapshotFreshnessUnreadable: Set<String> = []
    private var loops: [String: Task<Void, Never>] = [:]
    private var supervisors: [String: ProviderEventsSupervisor] = [:]
    /// Guards `spawnPollLoops`'s compound stopAll()+startLoop() sequence
    /// against a second concurrent call to the same sequence (e.g. two
    /// overlapping `start()`s). See the comment on `spawnPollLoops` for the
    /// race this closes.
    private var reconfiguring = false
    private var reconfigureWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set by `shutdown()` while still holding the reconfigure lock, and
    /// never cleared — shutdown is terminal for this actor's lifetime. See
    /// `shutdown()`'s doc comment for the race this closes.
    private var shuttingDown = false
    /// Worktree id → the moment TBD last locally archived or revived that
    /// remote row. The stale-snapshot watermark: a provider response whose
    /// request began *before* one of these entries provably could not have
    /// accounted for it, so the filing sync abstains rather than reversing a
    /// decision the user just made.
    ///
    /// In memory on purpose. The window it defends is open only while a
    /// provider request is outstanding, and no such request survives a
    /// restart — after one, every request start is later than every prior
    /// decision, so there is nothing left to suppress
    /// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Stale
    /// snapshots"). Swept on every apply so it cannot grow without bound.
    private var filingDecisions: [UUID: Date] = [:]

    init(
        db: TBDDatabase, subscriptions: StateSubscriptionManager,
        runner: any RemoteProviderInvoking, registryURL: URL,
        actuationLog: ActuationLog? = nil,
        builtInProviders: [RemoteProviderConfig] = [],
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.db = db
        self.subscriptions = subscriptions
        self.adopter = RemoteSessionAdopter(db: db)
        self.runner = runner
        self.registryURL = registryURL
        self.actuationLog = actuationLog
        self.builtInProviders = builtInProviders
        self.clock = clock
        // RPC becomes available before `start()` runs, so seed the registry
        // synchronously. The first status or mutation-gate read can then recover
        // persisted freshness instead of briefly treating an existing mirror as
        // current while the initial provider poll is pending.
        for config in builtInProviders {
            providers[config.name] = config
            health[config.name] = (.ok, nil, nil)
        }
        if let configs = try? RemoteProviderRegistry.load(from: registryURL) {
            for config in configs {
                providers[config.name] = config
                health[config.name] = (.ok, nil, nil)
            }
        }
    }

    /// Full boot path: load the registry, describe every provider, then
    /// spawn poll loops for the ones that negotiated a usable contract.
    /// Composition of the two steps below — callers that only need
    /// registry/describe state (e.g. verb-routing tests) should call
    /// `loadRegistryAndDescribe()` alone so no background timer is armed.
    func start() async {
        await loadRegistryAndDescribe()
        await spawnPollLoops()
    }

    /// Loads the provider registry and runs `describe` against every entry,
    /// populating `providers`/`describes`/`health`. Spawns no poll loops —
    /// safe to call from tests that only want to exercise describe/invoke
    /// routing without racing a real 60s timer.
    ///
    /// Checks `Task.isCancelled` before each provider's `describe` so a
    /// caller cancelling the enclosing task (daemon shutdown racing boot)
    /// bounds this to at most one `describe` child process in flight rather
    /// than one per remaining provider.
    func loadRegistryAndDescribe() async {
        var configs: [RemoteProviderConfig] = builtInProviders
        do {
            let loaded = try RemoteProviderRegistry.loadEntries(from: registryURL)
            for name in loaded.skippedReservedNames {
                remoteLogger.error(
                    """
                    provider registry entry named \(name, privacy: .public) was skipped: \
                    that name is reserved for a provider compiled into TBD
                    """)
            }
            configs += loaded.configs
        } catch {
            remoteLogger.error(
                "provider registry unreadable: \(String(describing: error), privacy: .public)")
            // The built-ins are still described: a malformed registry FILE
            // says nothing about a provider that does not come from it.
        }
        for config in configs {
            guard !Task.isCancelled else { return }
            registerIfNeeded(config)
            await recoverLastSuccessfulSnapshotAtIfNeeded(provider: config.name, markStale: true)
            await describeProvider(config)
        }
        subscriptions.broadcast(delta: .remoteSessionsChanged)
    }

    /// Runs `describe` for one provider and records the outcome in
    /// `describes`/`health`. Auth failures (exit 4) and other classified
    /// failures route through the same `recordFailure` path `pollOnce` and
    /// `invoke` use, so a provider that rejects credentials on its very
    /// first contact still surfaces `needs_auth` with remediation instead of
    /// a generic error. Only spawn/parse problems — which no failure class
    /// can describe — fall back to a generic message, distinguished by text
    /// from "it ran and rejected us".
    private func describeProvider(_ config: RemoteProviderConfig) async {
        let result: ProviderResult
        do {
            result = try await runner.run(
                config, verb: ["describe"], stdin: nil, timeout: 10,
                contractVersion: contractMajor(for: config.name))
        } catch {
            remoteLogger.error(
                "describe \(config.name, privacy: .public) couldn't run: \(String(describing: error), privacy: .public)"
            )
            setHealth(provider: config.name, to: (.error, "couldn't run describe: \(error)", nil))
            return
        }
        if let failure = result.failureClass {
            recordFailure(provider: config.name, class: failure, result: result)
            return
        }
        guard let describe = try? result.decoded(ProviderDescribe.self) else {
            setHealth(
                provider: config.name, to: (.error, "describe returned an unparseable response", nil))
            return
        }
        // An INTERSECTION with TBD's own supported set, not a hard requirement
        // on major 1. A provider is free to declare only the versions it can
        // actually serve — `claude-cloud` declares `[2]` alone because nothing
        // exposed terminates a running cloud session, so it cannot implement
        // `stop`, which major 1 requires.
        guard let negotiated = Self.negotiate(declared: describe.contractVersions) else {
            setHealth(provider: config.name, to: (.error, "no common contract version", nil))
            return
        }
        negotiatedMajors[config.name] = negotiated
        describes[config.name] = describe
    }

    /// Contract majors this build of TBD can speak.
    static let supportedContractMajors: Set<Int> = [1, 2]

    /// The highest major both sides declare, or nil when they share none.
    static func negotiate(declared: [Int]) -> Int? {
        declared.filter { supportedContractMajors.contains($0) }.max()
    }

    /// Spawns/re-spawns the 60s poll loop for every provider with a valid
    /// `describe` on file. Cancels any existing loops (and stops any running
    /// events supervisors) first so a second call can't orphan one that
    /// `stopAll()` would no longer be able to reach (the stored handle would
    /// just get overwritten).
    /// The whole stopAll()+startLoop() sequence runs under `reconfiguring` so
    /// two concurrent calls (e.g. overlapping `start()`s) can never
    /// interleave. Without it: `startLoop` inserts a supervisor into
    /// `supervisors` and then suspends at `await supervisor.start()` — a
    /// different actor, so this actor's executor is released for that
    /// window. A second call's `stopAll()` could run entirely in that
    /// window: its `await supervisor.stop()` on the just-inserted supervisor
    /// returns instantly (nothing has started yet) and `removeAll()` drops
    /// it, then the first call resumes and arms `start()` on a supervisor
    /// nothing holds — the provider's child process respawns on backoff for
    /// the daemon's life with no handle able to stop it. The symmetric case
    /// (a supervisor inserted during one of `stopAll()`'s own awaits, then
    /// dropped by that call's `removeAll()`) is closed the same way, since
    /// the two call sequences now can't overlap at all.
    private func spawnPollLoops() async {
        await acquireReconfigureLock()
        defer { releaseReconfigureLock() }
        // A call already parked in the FIFO waiter queue when `shutdown()`
        // ran receives the baton right after `shutdown()` releases it — FIFO
        // ordering alone doesn't stop that hand-off, only this flag does.
        // Without it, this would respawn poll loops (and events supervisors)
        // on a manager the daemon believes it already tore down.
        guard !shuttingDown else { return }
        await stopAll()
        for name in describes.keys {
            guard let config = providers[name] else { continue }
            await startLoop(for: config)
        }
    }

    private func acquireReconfigureLock() async {
        if reconfiguring {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                reconfigureWaiters.append(continuation)
            }
        } else {
            reconfiguring = true
        }
    }

    private func releaseReconfigureLock() {
        if reconfigureWaiters.isEmpty {
            reconfiguring = false
        } else {
            reconfigureWaiters.removeFirst().resume()
        }
    }

    func stopAll() async {
        for task in loops.values { task.cancel() }
        loops.removeAll()
        for supervisor in supervisors.values { await supervisor.stop() }
        supervisors.removeAll()
    }

    /// Guarded daemon-shutdown entry point. `stopAll()` itself is not safe
    /// to call directly from outside `spawnPollLoops` — it's the FIFO
    /// reconfigure lock (see `spawnPollLoops`'s comment) that makes teardown
    /// and a concurrent spawn mutually exclusive, and `stopAll()` on its own
    /// doesn't take it.
    ///
    /// Taking the lock alone is NOT sufficient, and this does not merely
    /// guard against "a `start()` still in flight at shutdown": FIFO means a
    /// `spawnPollLoops()` call already parked in the waiter queue when this
    /// runs receives the baton right after `shutdown()` releases the lock —
    /// it would then respawn poll loops/supervisors on a manager the daemon
    /// believes is torn down. `shuttingDown` (set here, before `stopAll()`,
    /// and never cleared) makes shutdown terminal: every `spawnPollLoops()`
    /// call that resumes after this one — queued or future — is a no-op.
    func shutdown() async {
        await acquireReconfigureLock()
        defer { releaseReconfigureLock() }
        shuttingDown = true
        await stopAll()
    }

    /// The 60s `list` poll is the universal floor for every provider,
    /// events-capable or not — it keeps running even when a stream is up,
    /// since snapshot application is idempotent and this is what covers a
    /// stream that's down or restarting. Providers that declared the
    /// `events` capability in their cached `describe` additionally get a
    /// supervised low-latency NDJSON stream.
    private func startLoop(for config: RemoteProviderConfig) async {
        if describes[config.name]?.capabilities.contains("events") == true {
            let supervisor = ProviderEventsSupervisor(
                config: config, manager: self,
                contractVersion: contractMajor(for: config.name), clock: clock)
            supervisors[config.name] = supervisor
            // Awaiting `supervisor.start()` (a different actor) suspends this
            // actor's executor, which by itself does NOT close the race
            // described on `spawnPollLoops` — only that method's
            // `reconfiguring` guard does, by making it impossible for a
            // concurrent stopAll()/spawnPollLoops() call to run while this
            // one is still in flight.
            await supervisor.start()
        }
        loops[config.name] = Task { [weak self, clock] in
            while !Task.isCancelled {
                await self?.pollOnce(provider: config)
                try? await clock.sleep(for: .seconds(Self.pollInterval))
            }
        }
    }

    func pollOnce(provider: RemoteProviderConfig) async {
        // pollOnce must work standalone, without start() having registered
        // the provider first (mirror tests + Task 7's ad-hoc RPC lookups
        // both call it directly) — register on first use so providerStatuses()
        // reflects it.
        registerIfNeeded(provider)
        // Stamped BEFORE the provider is asked anything. `snapshotAt` below is
        // arrival — it says when this response landed, not when the question
        // was posed, and only the latter can prove a response could not have
        // accounted for a local filing decision. See `syncFilingDecisions`.
        let requestStartedAt = Date()
        do {
            let result = try await runner.run(
                provider, verb: ["list"], stdin: nil, timeout: 30,
                contractVersion: contractMajor(for: provider.name))
            if let failure = result.failureClass {
                await recordPollFailure(provider: provider.name, class: failure, result: result)
                return
            }
            let envelope = try result.decoded(
                RemoteSessionListEnvelope.self, provider: provider.name)
            let snapshotAt = Date()
            try await apply(
                snapshot: envelope.sessions, provider: provider.name,
                complete: envelope.complete, now: snapshotAt,
                requestStartedAt: requestStartedAt)
        } catch {
            // `.error`, not `.debug`: this is not a trace of one session going
            // quiet, it is the whole provider's inventory freezing at whatever
            // it last said. The sidebar does say so — `setHealth(.stale)` below
            // reaches the provider header's issue caption — but `.debug` is
            // silent unless someone turned it on first, which left the outage
            // unreadable to anyone diagnosing from logs rather than from the
            // screen. The mirror's own counters cannot cover for it either:
            // `missingCount` and `gone` advance only inside `applySnapshot`,
            // which a poll that failed here never reaches, so every staleness
            // counter reads clean for the whole outage.
            remoteLogger.error(
                "poll \(provider.name, privacy: .public) failed; its whole session inventory is now stale: \(String(describing: error), privacy: .public)"
            )
            await recoverLastSuccessfulSnapshotAtIfNeeded(provider: provider.name)
            setHealth(provider: provider.name, to: (.stale, String(describing: error), nil))
        }
    }

    /// Shared by the poll path and the events snapshot path.
    ///
    /// `complete` carries the contract's snapshot-completeness claim through
    /// to the mirror and to freshness. An INCOMPLETE snapshot still adopts
    /// what it sighted, still files the decisions those sightings imply, and
    /// still clears degraded health — the provider answered — while claiming
    /// no complete inventory in either store: not the in-memory stamp below,
    /// and not the persisted `tbd_meta` row `applySnapshot` writes. Defaulted
    /// to `true` so every caller that predates the field keeps its exact
    /// behavior.
    ///
    /// `now` is arrival — when this response landed. `requestStartedAt` is
    /// when the question behind it was posed: the poll stamps it before
    /// `runner.run`, and the events supervisor supplies the moment it opened
    /// the connection the `snapshot` event arrived on. The filing sync needs
    /// the second, not the first (see `syncFilingDecisions`). It defaults to
    /// arrival so a caller with a response that is fresh by construction —
    /// `applyUpsert`'s pushed `session` line — reads correctly without
    /// inventing a start time.
    func apply(
        snapshot sessions: [RemoteSessionPayload], provider: String,
        complete: Bool = true, now: Date = Date(),
        requestStartedAt: Date? = nil
    ) async throws {
        let outcome = try await db.remoteSessions.applySnapshot(
            provider: provider, sessions: sessions, complete: complete, now: now)
        // After the mirror, never before: adoption reads the repo association
        // `applySnapshot` just pinned rather than resolving `meta["repo"]` a
        // second time. Unconditional on `outcome.changed` — a session can
        // become adoptable without its payload changing at all, because the
        // mirror re-attempts resolution on every poll while its pin is null,
        // and the poll after the user registers the repo is exactly that case.
        // Also unconditional on `complete`: an incomplete snapshot is
        // authoritative about presence, so a session it sighted is adopted.
        broadcastAdoptions(await adopter.adopt(sessions: sessions, provider: provider))
        // After adoption, never before: a session first sighted in this very
        // snapshot already reporting `archived: true` must be filed on the
        // row adoption just minted, not skipped for lack of one.
        //
        // Unconditional on `complete`, for the same reason adoption is: this
        // reads each sighted session's own `archived` claim and never infers
        // anything from absence, so an incomplete snapshot is as authoritative
        // here as a complete one. Completeness gates only the absence-derived
        // and inventory-freshness conclusions below.
        await syncFilingDecisions(
            sessions: sessions, provider: provider,
            requestStartedAt: requestStartedAt ?? now, now: now)
        if complete {
            lastSuccessfulSnapshotAt[provider] = now
            // A live COMPLETE snapshot supersedes whatever the persisted row
            // would have said, so an earlier unreadable read no longer gates
            // anything. An incomplete one supersedes nothing — it wrote no
            // persisted row — so the unreadable flag is left where it stands.
            snapshotFreshnessUnreadable.remove(provider)
        }
        markHealthy(provider: provider)
        if outcome.changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        for session in outcome.attention {
            subscriptions.broadcast(
                delta: .remoteSessionAttention(
                    RemoteSessionAttentionDelta(
                        provider: provider, sessionID: session.id, title: session.title,
                        kind: session.agentState.rawValue, reason: session.agentStateReason,
                        exitCode: session.exitCode)))
        }
    }

    /// Single-session upsert from an events `session` line, or from the
    /// response to a create/stop/rename this daemon issued. No absence
    /// bookkeeping happens here — only `apply(snapshot:)` drives the
    /// two-absence rule, since only a full snapshot can tell what's missing.
    ///
    /// A pushed `session` line is fresh by construction — the provider wrote
    /// it because something changed just now — so the filing sync takes
    /// arrival as the request start. There is no earlier moment to appeal to
    /// and none is needed: nothing was in flight across a local decision.
    ///
    /// `date` is arrival, and it is **compared** rather than displayed — it is
    /// the request start the watermark is measured against — so it comes
    /// through the date seam rather than a bare `Date()`
    /// (`Tests/CLAUDE.md`, "Clock and date seams": `Duration` is behavior,
    /// `Date` is data). Defaulted, so no call site changes.
    ///
    /// `parentWorktreeID` is set only by `remote.create`, and only when the
    /// user started the lane from a worktree's nested `+`: it is the parent
    /// they asked for, handed to adoption as an override of whatever the
    /// provider stamped. See `RemoteSessionAdopter.adopt(session:provider:parentOverride:)`.
    func applyUpsert(
        _ session: RemoteSessionPayload, provider: String, parentWorktreeID: UUID? = nil,
        date: Date = Date()
    ) async {
        let arrivedAt = date
        let outcome: SnapshotOutcome
        do {
            outcome = try await db.remoteSessions.upsertOne(
                provider: provider, session: session, now: arrivedAt)
        } catch {
            remoteLogger.error(
                "events upsert failed for \(provider, privacy: .public)/\(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // Same ordering rule as the snapshot path: the mirror pins, then
        // adoption reads the pin. A session first sighted on the events stream
        // must not have to wait for the next full poll to get its row.
        broadcastAdoptions(
            await adopter.adopt(
                session: session, provider: provider, parentOverride: parentWorktreeID))
        await syncFilingDecisions(
            sessions: [session], provider: provider,
            requestStartedAt: arrivedAt, now: arrivedAt)
        if outcome.changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
        for session in outcome.attention {
            subscriptions.broadcast(
                delta: .remoteSessionAttention(
                    RemoteSessionAttentionDelta(
                        provider: provider, sessionID: session.id, title: session.title,
                        kind: session.agentState.rawValue, reason: session.agentStateReason,
                        exitCode: session.exitCode)))
        }
    }

    /// Tell subscribers what adoption changed. Both halves reuse the delta a
    /// user-driven equivalent broadcasts, so the sidebar needs no
    /// adoption-shaped case of its own: a minted row is a create, and a row
    /// that took its first parent is a move — which is what a viewer sees.
    /// Announcing the second as a create would put a lane the user already has
    /// through the new-worktree path.
    private func broadcastAdoptions(_ outcome: RemoteSessionAdopter.Outcome) {
        for worktree in outcome.created {
            subscriptions.broadcast(
                delta: .worktreeCreated(
                    WorktreeDelta(
                        worktreeID: worktree.id, repoID: worktree.repoID,
                        name: worktree.name, path: worktree.localPath,
                        status: worktree.status)))
        }
        for nesting in outcome.nested {
            subscriptions.broadcast(
                delta: .worktreeMoved(
                    WorktreeMovedDelta(
                        worktreeID: nesting.worktreeID, newParentID: nesting.parentID,
                        newSortOrder: nesting.sortOrder)))
        }
    }

    /// Explicit removal from an events `removed` line. The provider is
    /// authoritative about this — skip the two-absence rule entirely and
    /// mark the row gone immediately.
    func applyRemoval(sessionID: String, provider: String) async {
        let changed: Bool
        do {
            changed = try await db.remoteSessions.markGone(
                provider: provider, sessionID: sessionID)
        } catch {
            remoteLogger.error(
                "events removal failed for \(provider, privacy: .public)/\(sessionID, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        if changed {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
    }

    // MARK: - The filing decision travels back

    /// Records that TBD itself just archived or revived the remote row bound
    /// to `worktreeID`, so a provider response composed before `at` cannot
    /// undo it.
    ///
    /// Called by the worktree archive/revive handlers, the merge rail, and the
    /// filing sync's own two writing paths, after the row's status is written —
    /// every place TBD makes a filing decision of its own about a remote lane.
    /// The sync is not exempt from its own rule: a row it files is as
    /// reversible by a poll still in flight as one a gesture filed.
    /// **The map only ever moves forward.** The instants arriving here are not
    /// ordered by the order of the calls: the sync stamps a snapshot's
    /// *arrival*, which precedes its own write by an adoption and an actuation
    /// append, so a sync that started before a gesture can finish after it
    /// carrying the older instant. A blind assignment would then hand a
    /// still-outstanding poll a watermark it predates, which is exactly the
    /// window this map exists to close. Keeping the later of the two is always
    /// sound: every recorded instant belongs to a decision that really was
    /// made, and the newest one bounds them all.
    ///
    /// Returns whatever was on file before, so a caller whose decision then
    /// fails can put it back through `withdrawFilingDecision`.
    @discardableResult
    func noteFilingDecision(worktreeID: UUID, at date: Date) -> Date? {
        let prior = filingDecisions[worktreeID]
        if let prior, prior >= date { return prior }
        filingDecisions[worktreeID] = date
        return prior
    }

    /// Takes back a watermark recorded in anticipation of a decision that then
    /// did not happen — a retirement verb that failed, or a row write that
    /// threw — leaving the row untouched. Keeping it would suppress a
    /// legitimate snapshot-driven flip for two poll intervals over a decision
    /// TBD never made.
    ///
    /// **Restoring, not deleting.** A row can carry a watermark from an
    /// earlier decision that did happen, and that decision's window is still
    /// open; dropping the entry outright would reopen it because a later
    /// gesture failed, which has nothing to do with it.
    ///
    /// **And only while the map still holds what this caller wrote.** If
    /// another path has recorded its own decision in the meantime, that
    /// decision is newer than both and its watermark is the one that must
    /// survive — including the case where `noteFilingDecision` declined to
    /// write at all because a newer instant was already there.
    func withdrawFilingDecision(worktreeID: UUID, restoring prior: Date?, ifStillAt written: Date) {
        guard filingDecisions[worktreeID] == written else { return }
        if let prior {
            filingDecisions[worktreeID] = prior
        } else {
            filingDecisions.removeValue(forKey: worktreeID)
        }
    }

    /// Whether a response whose request began at `requestStartedAt` may still
    /// move this row: it may, unless TBD made a filing decision of its own
    /// *after* that request began. The boundary belongs to the response — a
    /// decision taken at the very instant the request began is one that
    /// request could have accounted for.
    private func filingDecisionAllowsFlip(_ worktreeID: UUID, requestStartedAt: Date) -> Bool {
        guard let decidedAt = filingDecisions[worktreeID] else { return true }
        return decidedAt <= requestStartedAt
    }

    /// Test seam: the watermark on file for one row, or nil when none is (or
    /// none survived the sweep). Nothing in production reads this.
    func filingDecision(for worktreeID: UUID) -> Date? {
        filingDecisions[worktreeID]
    }

    /// Test seam: awaited inside the check-then-act window, immediately before
    /// `recheckBeforeFiling` re-reads the row and the watermark. Nil in
    /// production; nothing outside the suite ever sets it.
    private var midFlipHook: (@Sendable () async -> Void)?

    /// Test seam: installs `midFlipHook`.
    ///
    /// The window it opens onto is reachable only from *inside* the sync, and
    /// every other seam within it — the actuation log's `write` syscall, its
    /// `now` closure — is synchronous, so a test that waited from one would
    /// park a cooperative-pool thread until a second task released it. Under a
    /// narrow pool shared with the rest of the suite, nothing is left to do the
    /// releasing and the run wedges with no failing test. A gesture run inline
    /// on the sync's own task needs no second task at all, so it is exactly as
    /// deterministic and cannot starve.
    func setMidFlipHook(_ hook: (@Sendable () async -> Void)?) {
        midFlipHook = hook
    }

    /// Applies the provider's own `archived` claims to the worktree rows
    /// bound to its sessions, so a lane retired on the provider's surface or
    /// from another machine leaves TBD's active list too, and one returned to
    /// the inventory comes back
    /// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"The filing
    /// decision travels back").
    ///
    /// Three gates, none of them removable:
    ///
    /// - **Capability.** `archived` is read only from a provider that
    ///   declares `archive`. The contract makes an absent field read as
    ///   `false`, so without this a provider with no archiving concept would
    ///   carry an implicit "not archived" on every snapshot and drag archived
    ///   rows back into the active list about once a minute, forever.
    /// - **Presence.** A provider that declares the capability and omits the
    ///   field anyway made no claim, and silence must not overwrite the
    ///   user's own filing decision. Display still reads absent as `false`
    ///   via `isArchived`; only the sync abstains.
    /// - **Watermark.** A response whose request began before a local filing
    ///   decision provably could not have accounted for it, in either
    ///   direction, so it is dropped rather than allowed to reverse the user.
    ///
    /// `state` is never touched here. Filing and liveness are separate axes,
    /// and the mirror already owns the second.
    private func syncFilingDecisions(
        sessions: [RemoteSessionPayload], provider: String,
        requestStartedAt: Date, now: Date
    ) async {
        defer { sweepFilingDecisions(now: now) }
        guard describes[provider]?.capabilities.contains("archive") == true else { return }
        guard let actuationLog else {
            remoteLogger.debug(
                "filing sync skipped for \(provider, privacy: .public): no actuation log on this manager"
            )
            return
        }
        for session in sessions {
            // Presence gate: nil is "no claim", which is not the same fact as
            // an explicit `false` and must not move anything.
            guard let archived = session.archived else { continue }
            let row: Worktree?
            do {
                row = try await db.worktrees.findRemote(provider: provider, sessionID: session.id)
            } catch {
                remoteLogger.error(
                    "filing sync could not resolve \(provider, privacy: .public)/\(session.id, privacy: .public): \(String(describing: error), privacy: .public)"
                )
                continue
            }
            guard let row else { continue }
            // A row whose files are on this machine takes its status from TBD
            // alone, whatever a provider reports about it.
            guard !row.location.isLocal else { continue }
            guard filingDecisionAllowsFlip(row.id, requestStartedAt: requestStartedAt) else {
                remoteLogger.debug(
                    "filing sync skipped \(row.id.uuidString, privacy: .public): response predates the local decision"
                )
                continue
            }
            if archived, row.status == .active {
                await fileRowArchived(
                    row, provider: provider, log: actuationLog,
                    requestStartedAt: requestStartedAt, now: now)
            } else if !archived, row.status == .archived {
                await returnRowToActive(
                    row, provider: provider, log: actuationLog,
                    requestStartedAt: requestStartedAt, now: now)
            }
        }
    }

    /// What the re-read immediately before a filing write found.
    private enum FlipRecheck {
        /// The world still looks the way it did when the flip was decided.
        case proceed
        /// It does not, and the flip must be abandoned rather than restated.
        /// Carries the vocabulary term and the free-text detail for the record.
        case abandon(RefusedReason, String)
        /// The row could not be read back at all.
        case unreadable(any Error)
    }

    /// Narrows the check-then-act window between `syncFilingDecisions` reading
    /// a row and one of the two filing paths writing it.
    ///
    /// Between those two moments the sync suspends twice — once resolving the
    /// row, once appending the request row to the record — and a user gesture
    /// landing in that window writes both the status and a watermark. Acting on
    /// state read three suspensions ago would reverse the user's own action, so
    /// both facts are read again here, immediately before the write, and a flip
    /// that no longer holds is abandoned.
    ///
    /// **It narrows the window rather than closing it.** `db.worktrees.archive`
    /// is itself a suspension point on this actor, so a gesture can still land
    /// between this re-read and that write — what shrinks is the exposure, from
    /// two awaits plus a record append down to one DB write. The watermark is
    /// what makes the remainder safe: a gesture landing in that last sliver
    /// stamps a decision later than this response's request start, and the poll
    /// carrying the reversal is refused at the outer gate on its next arrival.
    ///
    /// `expecting` is the status the flip was decided against — still holding
    /// it means nobody else has filed this row in the meantime — and `becoming`
    /// is the status it was going to write, which is what tells an idempotent
    /// no-op apart from a row this act may not touch at all.
    private func recheckBeforeFiling(
        _ worktreeID: UUID, expecting expected: WorktreeStatus, becoming target: WorktreeStatus,
        requestStartedAt: Date
    ) async -> FlipRecheck {
        await midFlipHook?()
        let current: Worktree?
        do {
            current = try await db.worktrees.get(id: worktreeID)
        } catch {
            return .unreadable(error)
        }
        guard let current else {
            return .abandon(.notFound, "the worktree row no longer exists")
        }
        guard current.status == expected else {
            // Only the flip's own target is a genuine no-op — somebody else
            // did exactly what this flip was about to do. `main`, `creating`
            // and `failed` are not that: they are states the sync may not file
            // at all, and recording them as `noop` would put "already done" in
            // the record over a row that was never eligible.
            guard current.status == target else {
                return .abandon(
                    .notEligible, "the row is \(current.status.rawValue), which the sync may not file")
            }
            return .abandon(.noop, "the row is already \(current.status.rawValue)")
        }
        guard filingDecisionAllowsFlip(worktreeID, requestStartedAt: requestStartedAt) else {
            return .abandon(
                .notEligible, "a local filing decision landed while this flip was being recorded")
        }
        return .proceed
    }

    /// The provider reports this lane retired: file the row, and say so.
    ///
    /// A lane that leaves the active list without a gesture has to explain
    /// itself, so this writes a notification record as well as broadcasting
    /// the delta — the shape `AutoArchiveOnMergeCoordinator` established for
    /// the other case where a worktree is retired without the user asking at
    /// that moment. The daemon-rail actuation row is written first and
    /// fail-closed, for the reason that coordinator spells out: an
    /// unrecordable archive does not happen, and the next snapshot retries it.
    private func fileRowArchived(
        _ row: Worktree, provider: String, log: ActuationLog,
        requestStartedAt: Date, now: Date
    ) async {
        var request = ActuationRow(
            actor: .daemon(rail: ActuationRail.remoteFilingSync), kind: .dispose)
        request.target = ActuationTarget(worktree: row.id.uuidString)
        let actuationID: String
        do {
            actuationID = try await log.appendRequest(request)
        } catch {
            remoteLogger.warning(
                "filing sync skipped \(row.id.uuidString, privacy: .public) (record unwritable): \(String(describing: error), privacy: .public)"
            )
            return
        }
        switch await recheckBeforeFiling(
            row.id, expecting: .active, becoming: .archived,
            requestStartedAt: requestStartedAt) {
        case .proceed:
            break
        case .abandon(let reason, let detail):
            await log.appendOutcome(
                confirms: actuationID, result: .refused(reason), error: detail)
            remoteLogger.debug(
                "filing sync abandoned archiving \(row.id.uuidString, privacy: .public): \(detail, privacy: .public)"
            )
            return
        case .unreadable(let error):
            await log.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            remoteLogger.error(
                "filing sync could not re-read \(row.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        do {
            try await db.worktrees.archive(id: row.id)
        } catch {
            await log.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            remoteLogger.error(
                "filing sync could not archive \(row.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // The watermark goes on before anything else observes the write, so a
        // poll already in flight with the provider's pre-archive word cannot
        // un-file what this sync just filed. Every write to a remote row's
        // status is watermarked, whichever path made it.
        noteFilingDecision(worktreeID: row.id, at: now)
        await log.appendOutcome(confirms: actuationID, result: .dispatched)
        subscriptions.broadcast(delta: .worktreeArchived(WorktreeIDDelta(worktreeID: row.id)))
        do {
            let notification = try await db.notifications.create(
                worktreeID: row.id, type: .taskComplete,
                message: "Archived \(row.displayName) — \(provider) reports this session retired",
                terminalID: nil)
            subscriptions.broadcast(
                delta: .notificationReceived(
                    NotificationDelta(
                        notificationID: notification.id, worktreeID: notification.worktreeID,
                        type: notification.type, message: notification.message,
                        terminalID: notification.terminalID, activate: false)))
        } catch {
            remoteLogger.error(
                "filing sync archived \(row.id.uuidString, privacy: .public) but could not record a notification: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// The provider reports this lane back in its working inventory: return
    /// the row to the active list.
    ///
    /// No notification: a lane reappearing in the list is visible on its own,
    /// and the obligation the spec places on this sync is on the direction
    /// that makes a lane vanish. The actuation row is still written — the
    /// daemon acted, and the record names acts it performed.
    private func returnRowToActive(
        _ row: Worktree, provider: String, log: ActuationLog,
        requestStartedAt: Date, now: Date
    ) async {
        var request = ActuationRow(
            actor: .daemon(rail: ActuationRail.remoteFilingSync), kind: .spawn)
        request.target = ActuationTarget(worktree: row.id.uuidString)
        let actuationID: String
        do {
            actuationID = try await log.appendRequest(request)
        } catch {
            remoteLogger.warning(
                "filing sync skipped \(row.id.uuidString, privacy: .public) (record unwritable): \(String(describing: error), privacy: .public)"
            )
            return
        }
        switch await recheckBeforeFiling(
            row.id, expecting: .archived, becoming: .active,
            requestStartedAt: requestStartedAt) {
        case .proceed:
            break
        case .abandon(let reason, let detail):
            await log.appendOutcome(
                confirms: actuationID, result: .refused(reason), error: detail)
            remoteLogger.debug(
                "filing sync abandoned returning \(row.id.uuidString, privacy: .public) to active: \(detail, privacy: .public)"
            )
            return
        case .unreadable(let error):
            await log.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            remoteLogger.error(
                "filing sync could not re-read \(row.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        do {
            try await db.worktrees.revive(id: row.id)
        } catch {
            await log.appendOutcome(
                confirms: actuationID, result: .transportFailed, error: "\(error)")
            remoteLogger.error(
                "filing sync could not revive \(row.id.uuidString, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return
        }
        // Same watermark obligation as the archive direction: the un-filing is
        // a local filing decision too, and an in-flight poll carrying the
        // provider's pre-return word must not reverse it.
        noteFilingDecision(worktreeID: row.id, at: now)
        await log.appendOutcome(confirms: actuationID, result: .dispatched)
        subscriptions.broadcast(
            delta: .worktreeRevived(
                WorktreeDelta(
                    worktreeID: row.id, repoID: row.repoID, name: row.name,
                    path: row.localPath, status: .active)))
    }

    /// Drops watermarks older than two poll intervals. Nothing needs them
    /// past that: a provider request outstanding for longer has already
    /// timed out (`list` is bounded at 30s), so no response can still be in
    /// flight from before them.
    private func sweepFilingDecisions(now: Date) {
        let cutoff = now.addingTimeInterval(-2 * Self.pollInterval)
        filingDecisions = filingDecisions.filter { $0.value >= cutoff }
    }

    /// Test seam: whether a supervisor currently exists for `name` — used
    /// only to make the events-vs-poll capability gate in `startLoop`
    /// observable from tests without exposing `supervisors` itself.
    func hasSupervisor(named name: String) -> Bool {
        supervisors[name] != nil
    }

    /// Test seam: `snapshotFreshnessUnreadable`'s raw value for `name`, with
    /// no recovery attempt in between. Every *production* reader
    /// (`providerStatuses()`, `hasStaleSnapshot(provider:)`) calls
    /// `recoverLastSuccessfulSnapshotAtIfNeeded` first, which — whenever
    /// `lastSuccessfulSnapshotAt[name]` is still nil — unconditionally
    /// re-derives this flag from a fresh `tbd_meta` read and overwrites
    /// whatever `apply(snapshot:provider:complete:now:)` just left there. That
    /// is correct production behavior (the freshest read should win) but it
    /// means those accessors cannot discriminate a regression in `apply`'s own
    /// gate: whether or not the incomplete branch clears the flag, the very
    /// next status read silently recomputes the same answer from the
    /// database. This seam reads the field directly so a test can observe
    /// `apply`'s effect before any recovery call has a chance to launder it.
    func freshnessUnreadableForTests(provider name: String) -> Bool {
        snapshotFreshnessUnreadable.contains(name)
    }

    /// Runs `describe` for every registered provider without arming poll loops
    /// or event supervisors. Exists so the negotiation rule is testable without
    /// a running actor's background tasks — the same reason `hasSupervisor`
    /// exists.
    func describeAllForTests() async {
        for config in providers.values.sorted(by: { $0.name < $1.name }) {
            await describeProvider(config)
        }
    }

    func invoke(
        providerName: String, verb: [String], stdin: Data?,
        timeout: TimeInterval
    ) async throws -> ProviderResult {
        guard let config = providers[providerName] ?? loadAdHoc(named: providerName) else {
            throw RemoteProviderError.unknownProvider(providerName)
        }
        let result = try await runner.run(
            config, verb: verb, stdin: stdin, timeout: timeout,
            contractVersion: contractMajor(for: providerName))
        if let failure = result.failureClass {
            recordFailure(provider: providerName, class: failure, result: result)
        }
        return result
    }

    /// Tests (and a pre-`start()` RPC call) can address providers straight
    /// from the registry file.
    private func loadAdHoc(named name: String) -> RemoteProviderConfig? {
        guard let configs = try? RemoteProviderRegistry.load(from: registryURL),
            let config = configs.first(where: { $0.name == name })
        else { return nil }
        registerIfNeeded(config)
        return config
    }

    /// Registers a provider config (if not already known) and seeds a
    /// default `ok` health entry (if not already present). Shared by every
    /// entry point that can be a provider's first contact with this actor
    /// (`loadRegistryAndDescribe`, `pollOnce`, `loadAdHoc`).
    private func registerIfNeeded(_ config: RemoteProviderConfig) {
        if providers[config.name] == nil { providers[config.name] = config }
        if health[config.name] == nil { health[config.name] = (.ok, nil, nil) }
    }

    /// The capability set a provider declared in its cached `describe`
    /// response, or the empty set when no describe was ever recorded for that
    /// name (an unknown provider, or one whose describe failed).
    ///
    /// A caller MUST NOT invoke a verb whose capability a provider has not
    /// declared (`docs/remote-provider-contract.md`), so this is the one read
    /// every capability gate goes through — the router's `remote.*` handlers
    /// and the remote lane's archive/revive routing alike. Failing closed on
    /// an absent describe is deliberate: an unknown capability set is not
    /// permission to try the verb and see.
    func declaredCapabilities(provider: String) -> Set<String> {
        Set(describes[provider]?.capabilities ?? [])
    }

    /// The contract major to announce for one provider: the negotiated value
    /// once `describe` has landed, and the conservative fallback before that —
    /// `describe` itself is the one invocation that necessarily precedes
    /// negotiation.
    func contractMajor(for provider: String) -> Int {
        negotiatedMajors[provider] ?? Self.fallbackContractMajor
    }

    /// The negotiated major, or nil when this provider has no valid `describe`
    /// on file. Exposed so `providerStatuses()` and tests read one value rather
    /// than re-deriving the rule.
    func negotiatedContractMajor(for provider: String) -> Int? {
        negotiatedMajors[provider]
    }

    /// What TBD announces before it has negotiated anything — the conservative
    /// reading, and the value the runner emitted unconditionally before.
    static let fallbackContractMajor = 1

    func providerStatuses() async -> [RemoteProviderStatus] {
        for name in providers.keys {
            await recoverLastSuccessfulSnapshotAtIfNeeded(provider: name, markStale: true)
        }
        return providers.values.sorted { $0.name < $1.name }.map { config in
            let h = health[config.name] ?? (.ok, nil, nil)
            return RemoteProviderStatus(
                config: config, describe: describes[config.name],
                health: h.state,
                errorMessage: Self.boundedDisplayMessage(
                    h.message,
                    hasSuccessfulSnapshot: lastSuccessfulSnapshotAt[config.name] != nil
                ),
                remediationLabel: h.remediation?.label,
                remediationCommand: h.remediation?.command,
                lastSuccessfulSnapshotAt: lastSuccessfulSnapshotAt[config.name],
                freshnessUnreadable: snapshotFreshnessUnreadable.contains(config.name),
                contractVersion: negotiatedMajors[config.name])
        }
    }

    /// Whether mutations that depend on the cached inventory should be
    /// suppressed. Read-only inspection (`attach`, `log`) remains useful
    /// during an inventory outage; create/stop/send/rename do not have a
    /// trustworthy current-state basis once a previously-good snapshot is
    /// stale.
    func hasStaleSnapshot(provider name: String) async -> Bool {
        await recoverLastSuccessfulSnapshotAtIfNeeded(provider: name, markStale: true)
        // Same rule the wire DTO and every UI call site use, so the mutation
        // gate and the display projection cannot disagree. Fails open only on
        // positive knowledge that no snapshot was ever accepted; an unreadable
        // read carries no such proof and gates.
        return RemoteProviderStatus.isStaleSnapshot(
            health: health[name]?.state ?? .ok,
            lastSuccessfulSnapshotAt: lastSuccessfulSnapshotAt[name],
            freshnessUnreadable: snapshotFreshnessUnreadable.contains(name))
    }

    /// Correlates a locally-spawned `attach` exit (the app execs the provider
    /// on a terminal's own TTY, so its exit code never passes through this
    /// actor's runner) with provider health.
    ///
    /// `attach`'s stdout is a PTY byte stream and MUST NOT be parsed
    /// (`docs/remote-provider-contract.md` § `attach`), so the exit code is
    /// the only signal — hence `error: nil` in the classification below.
    ///
    /// - Non-auth classes are deliberately ignored: an attach that died for
    ///   transport reasons is already covered app-side by pending-reconnect
    ///   backoff, and letting every dropped connection rewrite provider
    ///   health would make one flaky viewer speak for the whole provider.
    /// - The auth class marks the provider `.needsAuth` while PRESERVING any
    ///   message/remediation already on file: an attach exit carries none of
    ///   its own, and clobbering a parsed remediation with `nil` would
    ///   downgrade a good CTA to a bare "authentication needed". Preservation
    ///   is limited to an already-`.needsAuth` provider, for the reason
    ///   spelled out in `recordFailure`'s auth branch — text written under
    ///   `.stale`/`.error` explains a different condition and must not be
    ///   relabelled as an authentication explanation. Carrying it here would
    ///   also survive the probe below, which inherits from the state this
    ///   line writes.
    /// - It then triggers exactly ONE out-of-band `list` so the state is
    ///   either confirmed with a freshly parsed remediation or cleared
    ///   outright by a success. That probe is bounded by the
    ///   already-`.needsAuth` check: at most one extra `list` per health
    ///   transition, so a session flapping through repeated auth exits can
    ///   never turn into a poll flood.
    func recordAttachExit(provider name: String, exitCode: Int32) async throws {
        guard let config = providers[name] ?? loadAdHoc(named: name) else {
            throw RemoteProviderError.unknownProvider(name)
        }
        guard ProviderFailureClass.classify(exitCode: exitCode, error: nil) == .authNeeded else {
            return
        }
        let previous = health[name]
        let inheritable = previous?.state == .needsAuth ? previous : nil
        setHealth(provider: name, to: (.needsAuth, inheritable?.message, inheritable?.remediation))
        guard previous?.state != .needsAuth else { return }
        await pollOnce(provider: config)
    }

    /// Exactly ONE out-of-band `list` after a locally-observed create.
    ///
    /// The row for a created session arrives by adoption on a snapshot rather
    /// than being minted by the create call, and the poll loop's interval is
    /// 60 seconds, so without this a lane created from the `+` menu can sit
    /// invisible for up to a minute after a create that already succeeded.
    /// Bounded exactly as `recordAttachExit`'s probe is: one extra `list` per
    /// create, never a loop, and only on a create that succeeded.
    func refreshAfterCreate(provider name: String) async {
        guard let config = providers[name] else { return }
        await pollOnce(provider: config)
    }

    private func recordFailure(
        provider: String, class failureClass: ProviderFailureClass,
        result: ProviderResult
    ) {
        let error = result.decodedError
        switch failureClass {
        case .authNeeded:
            // Preserve what's already on file when the new error supplies
            // nothing — but ONLY while staying within `.needsAuth`.
            //
            // Why inherit at all: `recordAttachExit` deliberately keeps the
            // existing message/remediation (an attach exit carries none of
            // its own) and then fires a `list` probe through here — a probe
            // that itself exits 4 with unparseable stdout would otherwise
            // clobber that preserved remediation back to `nil`, downgrading
            // a good CTA to a bare "authentication needed". A freshly parsed
            // value still wins, so recovery-with-new-detail is unaffected.
            //
            // Why the asymmetry: text on file under `.ok`/`.stale`/`.error`
            // describes a DIFFERENT condition. Inheriting it across a
            // transition INTO `.needsAuth` would render, say, a transport
            // timeout as the provider's authentication explanation — wrong
            // words in the one string this CTA exists to deliver. On such a
            // transition the fields go `nil` and the app renders its neutral
            // fallback CTA instead. This still covers the path the
            // inheritance was added for: `recordAttachExit` sets `.needsAuth`
            // BEFORE firing its probe, so the probe's `recordFailure` sees a
            // previous state of `.needsAuth`.
            //
            // Only this class inherits at all: `.stale`/`.error` messages
            // describe THIS invocation and go stale the moment it changes.
            let previous = health[provider]
            let inheritable = previous?.state == .needsAuth ? previous : nil
            setHealth(
                provider: provider,
                to: (
                    .needsAuth,
                    error?.message ?? inheritable?.message,
                    error?.remediation ?? inheritable?.remediation
                ))
        case .transient:
            setHealth(provider: provider, to: (.stale, error?.message ?? result.stderr, nil))
        case .permanent, .contractBug:
            setHealth(provider: provider, to: (.error, error?.message ?? result.stderr, nil))
        }
    }

    /// Poll failures need one extra piece of bookkeeping beyond generic
    /// provider failures: if this manager restarted after the last success,
    /// recover that timestamp from the mirror's last-seen rows before
    /// publishing stale health. This keeps a persisted cached snapshot from
    /// becoming confidently timeless after a daemon restart.
    private func recordPollFailure(
        provider: String, class failureClass: ProviderFailureClass,
        result: ProviderResult
    ) async {
        await recoverLastSuccessfulSnapshotAtIfNeeded(provider: provider)
        recordFailure(provider: provider, class: failureClass, result: result)
    }

    private func recoverLastSuccessfulSnapshotAtIfNeeded(
        provider: String,
        markStale: Bool = false
    ) async {
        guard lastSuccessfulSnapshotAt[provider] == nil else { return }
        let recovered: Date?
        do {
            recovered = try await db.remoteSessions.lastSuccessfulSnapshotAt(provider: provider)
        } catch {
            // Unreadable, not absent. Record the distinction so the mutation
            // gate can fail closed, and say so in the surfaced health text —
            // "could not be read" is a different user-facing condition from
            // "has not refreshed".
            snapshotFreshnessUnreadable.insert(provider)
            remoteLogger.error(
                """
                freshness recovery failed for provider \(provider, privacy: .public): \
                \(String(describing: error), privacy: .public)
                """)
            if markStale, health[provider]?.state == .ok {
                setHealth(
                    provider: provider,
                    to: (
                        .stale,
                        "Provider freshness state could not be read.",
                        nil
                    ))
            }
            return
        }
        snapshotFreshnessUnreadable.remove(provider)
        guard let recovered else { return }
        lastSuccessfulSnapshotAt[provider] = recovered
        if markStale, health[provider]?.state == .ok {
            setHealth(
                provider: provider,
                to: (
                    .stale,
                    "Provider inventory has not refreshed since daemon restart.",
                    nil
                ))
        }
    }

    /// The provider may return the entire truncated inventory inside its
    /// error message. Keep the manager's internal health record unchanged for
    /// diagnostics, but never put an unbounded wall of JSON on the RPC/UI
    /// wire. The known
    /// truncation shape receives safe copy rather than leaking a prompt from
    /// the beginning of the embedded payload.
    static func boundedDisplayMessage(
        _ message: String?,
        hasSuccessfulSnapshot: Bool = true,
        limit: Int = 240
    ) -> String? {
        guard let message else { return nil }
        if message.localizedCaseInsensitiveContains("--output truncated--")
            || message.localizedCaseInsensitiveContains("unparseable remote output")
        {
            if hasSuccessfulSnapshot {
                return
                    "Provider inventory was truncated or malformed; showing the last successful snapshot."
            }
            return
                "Provider inventory was truncated or malformed; no successful snapshot is available yet."
        }
        guard message.count > limit else { return message }
        let kept = max(0, limit - 1)
        return String(message.prefix(kept)) + "…"
    }

    private func markHealthy(provider: String) {
        setHealth(provider: provider, to: (.ok, nil, nil))
    }

    /// Records a provider's health and broadcasts when ANY of the three
    /// fields the app renders changed — state, message, or remediation.
    ///
    /// State alone is not enough: the auth path routinely transitions
    /// `.needsAuth` → `.needsAuth` while ADDING detail (`recordAttachExit`
    /// flips health off a bare exit code with no message, then its probe
    /// lands the parsed message + remediation). Broadcasting on state alone
    /// dropped that payload on the floor and left the app rendering a
    /// command-less fallback CTA for the whole outage, since every later
    /// poll is also `.needsAuth` → `.needsAuth`.
    ///
    /// Equally deliberately, it does NOT broadcast unconditionally: a
    /// healthy provider re-setting `(.ok, nil, nil)` every 60s poll would
    /// otherwise put a delta on the wire per provider per minute forever.
    private func setHealth(
        provider: String,
        to new: (ProviderHealth, String?, ProviderRemediation?)
    ) {
        let old = health[provider]
        health[provider] = new
        if old?.state != new.0 || old?.message != new.1 || old?.remediation != new.2 {
            subscriptions.broadcast(delta: .remoteSessionsChanged)
        }
    }
}

enum RemoteProviderError: LocalizedError {
    case unknownProvider(String)

    var errorDescription: String? {
        switch self {
        case .unknownProvider(let id):
            return "no remote provider is configured with id '\(id)'"
        }
    }
}
