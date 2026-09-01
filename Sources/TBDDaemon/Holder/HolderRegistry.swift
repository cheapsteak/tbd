import Darwin
import Foundation
import TBDShared
import os

/// The daemon's single owner of every live `HolderReader`.
///
/// **A reader lives only in the memory of the daemon that made one**, and the
/// session it drains does not. That asymmetry is the whole reason this type
/// exists: a restarted daemon inherits holders and jobs that are still running
/// and has no reader for any of them, so nothing drains their pty masters —
/// which is not merely "no screen to show". A job cannot finish exiting while
/// anything it wrote is still queued on its terminal (XNU's `proc_exit` calls
/// `ttywait` before revoking it), so an undrained session silently piles up
/// half-exited jobs. Re-adoption is therefore a liveness obligation of startup,
/// not a convenience for rendering.
///
/// Two invariants shape the API:
///
///   - **One reader per session, ever.** Two drain loops on one pty master is
///     silent byte theft — each `read` takes bytes the other will never see,
///     and nothing anywhere reports it. Adoption is therefore idempotent
///     through the actor's own state: a second call for a session already being
///     adopted *awaits the first* rather than racing it.
///   - **Whoever owns a reader stops it.** After end of file a drain thread
///     parks on its wake pipe instead of exiting, deliberately — that is what
///     keeps the descriptor's close on the stop path, where no `write` can race
///     a reused fd number. So a reader that is dropped without `stop()` leaks a
///     thread and a descriptor, and this registry is the owner that must not do
///     that. See `release(terminalID:)`.
actor HolderRegistry {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holder")

    enum Error: LocalizedError, Equatable {
        /// The row does not carry a holder-backed session, so there is nothing
        /// at a rendezvous path to adopt.
        case notAHolderSession(terminalID: UUID)
        /// The holder answered, and named an installation that is not ours.
        /// It is left strictly alone: reachable-but-absent-from-my-database is
        /// exactly what another checkout's healthy session looks like.
        case foreignOwner(terminalID: UUID, holderOwner: String)
        /// A concurrent `release` (or a later adoption) took the slot while this
        /// adoption was still in flight, so its result was discarded rather than
        /// published. Everything it obtained — the reader, and with it the pty
        /// dup — was released before this was thrown.
        case superseded(terminalID: UUID)
        /// No `TBDHolder` binary could be located, so no session can be
        /// spawned onto this transport. Named rather than swallowed: the
        /// caller's fallback is to spawn onto tmux, and a silent fallback
        /// would make a flag that appears on look off.
        case holderExecutableUnavailable
        /// Something is already registered for this session. A spawn is for a
        /// session that does not exist yet, so this can only mean the caller
        /// minted a terminal ID that is already live — never a race to be
        /// waited out.
        case sessionAlreadyRegistered(terminalID: UUID)

        var errorDescription: String? {
            switch self {
            case .notAHolderSession(let terminalID):
                return "terminal \(terminalID.uuidString) is not a holder-backed session"
            case .foreignOwner(let terminalID, let holderOwner):
                return "the holder for terminal \(terminalID.uuidString) belongs to installation "
                    + "\(holderOwner); leaving it alone"
            case .superseded(let terminalID):
                return "the adoption of terminal \(terminalID.uuidString) was superseded while it "
                    + "was in flight; its reader was stopped rather than published"
            case .holderExecutableUnavailable:
                return "no TBDHolder binary was found beside the running daemon, so no session "
                    + "can be spawned onto the holder transport"
            case .sessionAlreadyRegistered(let terminalID):
                return "session \(terminalID.uuidString) already has a live holder reader"
            }
        }
    }

    /// A reader and the description the hand-over rode with.
    ///
    /// The description is not decoration: it is the one place a job that
    /// finished while no daemon was listening reports how it ended.
    private struct Adoption: Sendable {
        let reader: HolderReader
        let description: HolderChildDescription
    }

    /// What the registry knows about one session.
    ///
    /// **A slot is occupied for as long as a reader for that session exists —
    /// from before the pty dup is asked for until after the drain thread has
    /// actually gone.** That is the invariant, and every case here is one leg of
    /// it. There is deliberately no state that means "empty, but a reader is
    /// still draining": that state is what a fresh `adopt` would read as "nobody
    /// is on this pty", and it is how two drain loops end up on one master.
    ///
    /// Each occupied case holds the *task* that will vacate it, not a flag, so a
    /// caller who finds the slot busy has something to await rather than a state
    /// to poll — which is what makes "two concurrent adoptions produce one
    /// reader" a property of the type instead of a timing accident.
    ///
    ///   - `adopting` — an attach is in flight. A second `adopt` awaits it; a
    ///     `release` supersedes it.
    ///   - `adopted` — a reader is published and draining.
    ///   - `releasing` — a reader is being stopped. Its descriptor may still be
    ///     open and its thread still in `read`, so an `adopt` arriving here
    ///     *waits* rather than opening a second hand-over against it.
    private enum Slot {
        case adopting(Task<Adoption, Swift.Error>)
        case adopted(HolderReader)
        case releasing(Task<Void, Never>)
    }

    /// How long an adoption keeps retrying a holder that answers the busy
    /// sentinel. Comfortably longer than the holder's own poll slice, which is
    /// how long it can take to notice a dead daemon's connection has gone; short
    /// enough that a holder somebody really is attached to is reported as such
    /// rather than waited on.
    static let defaultBusyRetryBudget: Duration = .seconds(1)
    static let busyRetryInterval: Duration = .milliseconds(50)

    /// This installation's token, compared against every holder's before it is
    /// adopted.
    let owner: HolderOwnerToken
    /// The environment the rendezvous paths are derived from, the holder
    /// processes run under, and the jobs they fork inherit. Explicit rather
    /// than ambient so tests never reach the developer's real `~/tbd` — or the
    /// developer's real login shell. In production it *is* the daemon's own
    /// environment, which is also what a tmux pane inherits from the server the
    /// daemon started, so the two transports launch a job into the same place.
    ///
    /// Immutable and `Sendable`, so a caller composing a `HolderLaunchRequest`
    /// can read it without hopping onto the actor.
    nonisolated let environment: [String: String]
    private let listTerminals: @Sendable () async throws -> [Terminal]
    /// How a holder is started. `nil` when no `TBDHolder` binary could be
    /// located, which makes `spawn` refuse by name instead of the registry
    /// pretending it could have spawned one. Adoption does not need it: an
    /// already-running holder is reached through its socket.
    private let spawner: HolderSpawner?
    /// Whether this registry can start a holder at all — that is, whether
    /// `spawn` can do anything but throw `.holderExecutableUnavailable`.
    ///
    /// **The registry's existence is not the answer to that question, and the
    /// spawn gate must ask this instead.** A daemon whose `TBDHolder` binary is
    /// missing still builds a registry, because adoption needs no executable:
    /// a holder that is already running is reached through its socket, and a
    /// user whose sessions are live must not lose them because an upgrade moved
    /// the binary. So "registry present" and "can spawn" are genuinely
    /// different facts, and only the second one may gate a create.
    ///
    /// `nonisolated` and immutable so the gate can read it without hopping onto
    /// the actor — `spawner` is a `let`, so this is decided once, in `init`.
    nonisolated let canSpawn: Bool

    private var slots: [UUID: Slot] = [:]
    /// The last status a holder reported for a session, and the only home it
    /// has: no `terminal` column records an exit status, and the row's fate
    /// belongs to the holder reconciler Milestone B adds. Recorded here so a
    /// job that ended during an outage is *reported* rather than lost, and so
    /// an unreachable holder is recorded as `exitedStatusUnknown` — never as a
    /// fabricated code, which downstream could not tell from a real one.
    private var statuses: [UUID: HolderChildStatus] = [:]
    /// How many drain loops this registry has ever taken ownership of — that
    /// is, how many adoptions it has published.
    ///
    /// Test-facing, and the honest instrument for the invariant above: object
    /// identity alone cannot tell a registry that reused a reader from one that
    /// built a second and threw it away, and only the count sees the second
    /// drain loop that would have been stealing bytes.
    ///
    /// A superseded adoption is deliberately **not** counted. Its loop did
    /// start, and was stopped again before this call returned; counting it would
    /// make the number say "loops that ever ran" when what every assertion here
    /// asks is "loops this registry is on the hook for".
    private(set) var drainLoopsStarted = 0
    /// How many published drain loops are live right now.
    ///
    /// The decrement happens inside the releasing task, before anything awaiting
    /// that task resumes, so an adoption queued behind a release can never see
    /// its own publish overlap the reader it waited for.
    private var liveDrainLoops = 0
    /// The most drain loops that have ever been live at one time.
    ///
    /// Test-facing, and the direct instrument for "one reader per session,
    /// ever": `drainLoopsStarted` counts adoptions over all time and so cannot
    /// tell a registry that stopped one reader before starting the next from one
    /// that ran both at once. A peak above one is the byte theft itself, seen
    /// after the fact.
    private(set) var peakLiveDrainLoops = 0
    /// How many calls to `adopt` have got as far as consulting the slot.
    ///
    /// Test-facing, and the one instrument every interleaving reaches: it is
    /// incremented before the slot decision, so watching it go up proves a
    /// concurrent adoption has already run its whole synchronous prefix —
    /// whichever branch that prefix took. Tests use it to pin the instant at
    /// which the *other* counters are meaningful, without waiting on a wall
    /// clock.
    private(set) var adoptionCallsEntered = 0
    /// How many hand-over round trips this registry has opened against a
    /// holder — that is, how many times it has committed to taking a fresh
    /// `dup` of a pty master.
    ///
    /// Test-facing. Counted at the moment the attach task is created, because
    /// that is the commitment: everything after it is that task's own business,
    /// and a second one opened while a reader is still draining is the failure
    /// this registry exists to prevent, whether or not it is ever published.
    private(set) var attachRoundTripsStarted = 0

    private let busyRetryBudget: Duration
    private let clock: any Clock<Duration>

    /// Awaited inside `adopt` between the attach settling and the slot being
    /// published — the exact window a concurrent `release` interleaves in.
    ///
    /// A seam rather than a sleep: the interleaving this guards against is a
    /// continuation-ordering accident, and a test that reproduced it by timing
    /// would pass by luck and stop reproducing it the day the scheduler
    /// changed. Nil in production, where the cost is one nil check per
    /// adoption.
    private var publishBarrier: (@Sendable () async -> Void)?

    /// Awaited inside a release, immediately before the reader is stopped — the
    /// exact window a concurrent `adopt` interleaves in, and the one in which
    /// the released reader is still draining the pty.
    ///
    /// A seam for the same reason `publishBarrier` is one: the interleaving is a
    /// continuation-ordering accident, and a test that reproduced it by timing
    /// would pass by luck. Nil in production.
    private var releaseBarrier: (@Sendable () async -> Void)?

    init(
        owner: HolderOwnerToken,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        listTerminals: @escaping @Sendable () async throws -> [Terminal],
        spawner: HolderSpawner? = nil,
        busyRetryBudget: Duration = HolderRegistry.defaultBusyRetryBudget,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.owner = owner
        self.environment = environment
        self.listTerminals = listTerminals
        self.spawner = spawner
        self.canSpawn = spawner != nil
        self.busyRetryBudget = busyRetryBudget
        self.clock = clock
    }

    /// Installs the publish barrier described above. Test-facing; production
    /// never calls it.
    func setPublishBarrier(_ barrier: (@Sendable () async -> Void)?) {
        publishBarrier = barrier
    }

    /// Installs the release barrier described above. Test-facing; production
    /// never calls it.
    func setReleaseBarrier(_ barrier: (@Sendable () async -> Void)?) {
        releaseBarrier = barrier
    }

    // MARK: - Reading

    /// The live reader for a session, or nil if none has been adopted.
    ///
    /// A session still being adopted answers nil: there is no drain loop yet.
    /// So does one being released — its reader may still be draining, but it is
    /// on its way out and nothing new should be routed to it.
    func reader(for terminalID: UUID) -> HolderReader? {
        guard case .adopted(let reader) = slots[terminalID] else { return nil }
        return reader
    }

    /// The last status a holder reported for a session, if one ever has.
    func lastKnownStatus(for terminalID: UUID) -> HolderChildStatus? {
        statuses[terminalID]
    }

    // MARK: - Spawning

    /// Starts a holder for a brand-new session and begins draining it.
    ///
    /// **The spawner's own handshake connection is what takes the pty**, rather
    /// than a fresh one. A holder serves one client at a time and learns the
    /// previous one has gone only when its poll loop next reads end of file, so
    /// a caller that closed the handshake connection and reconnected would race
    /// that notice and be answered with the busy sentinel for a slot that is
    /// already free. `HolderSpawner` hands the live connection back precisely so
    /// that window cannot be entered; dropping it and reconnecting would put it
    /// straight back.
    ///
    /// The returned handle is what the caller persists. Nothing here writes a
    /// row: a holder that was spawned and then failed to be recorded is the
    /// caller's to `abandon`, because only the caller knows whether the record
    /// landed.
    func spawn(terminalID: UUID, launch: HolderLaunchRequest) async throws -> HolderHandle {
        guard let spawner else { throw Error.holderExecutableUnavailable }
        guard slots[terminalID] == nil else {
            throw Error.sessionAlreadyRegistered(terminalID: terminalID)
        }

        let spawned = try await spawner.spawn(
            sessionID: terminalID, launch: launch, owner: owner, environment: environment)

        let adoption: Adoption
        do {
            adoption = try await Self.take(
                terminalID: terminalID, over: spawned.client, expecting: owner)
        } catch {
            // The holder is up and supervising a job that no row will ever
            // name, so leaving it would orphan both. Best-effort, and the
            // standing guarantee is still a reconciler (Milestone B).
            await Self.dispose(handle: spawned.handle)
            throw error
        }

        slots[terminalID] = .adopted(adoption.reader)
        statuses[terminalID] = adoption.description.status
        drainLoopsStarted += 1
        Self.logger.info(
            """
            spawned and adopted a holder for session \(terminalID.uuidString, privacy: .public): \
            holder \(spawned.handle.holderPID, privacy: .public), child \
            \(spawned.handle.childPID, privacy: .public)
            """)
        return spawned.handle
    }

    /// Undoes a `spawn` whose session could not be recorded: stops the reader,
    /// tells the holder to let go, and kills the job.
    ///
    /// Best-effort by nature — every step talks to something that may already
    /// be gone — and creation-time cleanup only. The standing guarantee for a
    /// holder nobody owns is the reconciler Milestone B adds.
    func abandon(terminalID: UUID, handle: HolderHandle) async {
        await release(terminalID: terminalID)
        statuses[terminalID] = nil
        await Self.dispose(handle: handle)
    }

    /// `forget` then kill: the holder closes the pty master and winds down, and
    /// the job it was supervising is killed by pid. Both are named because
    /// holder death is deliberately **not** child death — a holder killed on
    /// its own leaves its job reparented to pid 1 with nobody to reclaim it.
    private static func dispose(handle: HolderHandle) async {
        let client = HolderClient(socketPath: handle.socketPath)
        try? await client.forget()
        await client.close()
        if handle.childPID > 0 { kill(handle.childPID, SIGKILL) }
    }

    // MARK: - Adoption

    /// Connects to the session's holder, takes a `dup` of its pty master, and
    /// starts draining it.
    ///
    /// Idempotent, and that is load-bearing rather than tidy — see the type's
    /// note on byte theft. A call for a session already adopted returns the same
    /// reader; a call for one mid-adoption awaits that adoption's own task; a
    /// call for one mid-*release* waits for the outgoing reader to have actually
    /// stopped before it opens a hand-over of its own.
    ///
    /// The loop is the shape the slot protocol demands. Every occupied state is
    /// vacated by awaiting a task, and an actor's methods are not atomic across
    /// suspension, so the slot is re-read after every await instead of being
    /// remembered across one.
    @discardableResult
    func adopt(terminal: Terminal) async throws -> HolderReader {
        guard terminal.transport == .holder else {
            throw Error.notAHolderSession(terminalID: terminal.id)
        }
        let terminalID = terminal.id
        adoptionCallsEntered += 1

        while true {
            switch slots[terminalID] {
            case .adopted(let reader):
                return reader
            case .adopting(let task):
                return try await joinInFlightAdoption(task, for: terminalID)
            case .releasing(let task):
                // A reader for this pty is still draining. Waiting for its stop
                // — rather than treating the release's suspension as an empty
                // slot — is what keeps "one reader per session, ever" true
                // across the whole of a release instead of only up to its first
                // await. Clearing the slot here rather than leaving it to the
                // releaser is what guarantees this loop makes progress.
                await task.value
                clearIfStillReleasing(task, for: terminalID)
                continue
            case nil:
                return try await beginAdoption(of: terminalID)
            }
        }
    }

    /// Waits for an adoption another caller already has in flight, and hands
    /// back its reader only if the registry is really standing behind it.
    ///
    /// The re-check is the point. The awaited task settles at the *attach*, one
    /// suspension before the publish decision, so a `release` arriving in
    /// between supersedes that adoption and stops its reader. Returning it
    /// anyway would hand this caller a reader whose drain thread has exited and
    /// whose pty dup is closed — a screen that never updates again, and writes
    /// that fail.
    private func joinInFlightAdoption(
        _ task: Task<Adoption, Swift.Error>, for terminalID: UUID
    ) async throws -> HolderReader {
        let adoption = try await task.value
        // Read and decide with no await in between, as everywhere else here.
        switch slots[terminalID] {
        case .adopted(let published) where published === adoption.reader:
            return published
        case .adopting(let current) where current == task:
            // Not published yet, but still this adoption's slot: nothing has
            // superseded it, and its reader is the one that will be published.
            return adoption.reader
        default:
            throw Error.superseded(terminalID: terminalID)
        }
    }

    /// The empty-slot path: opens a hand-over, publishes what it obtains.
    ///
    /// Reached only with the slot genuinely vacant — no reader adopted, none
    /// being adopted, and none still draining its way out of a release.
    private func beginAdoption(of terminalID: UUID) async throws -> HolderReader {
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: terminalID, environment: environment)
        let expected = owner
        let budget = busyRetryBudget
        let clock = self.clock
        let task = Task<Adoption, Swift.Error> {
            try await Self.attach(
                terminalID: terminalID,
                socketPath: socketPath,
                expecting: expected,
                busyRetryBudget: budget,
                clock: clock)
        }
        attachRoundTripsStarted += 1
        slots[terminalID] = .adopting(task)

        let settled = await task.result
        // The one suspension a test can steer. In production `publishBarrier` is
        // nil and this is a nil check.
        await publishBarrier?()

        let adoption: Adoption
        do {
            adoption = try settled.get()
        } catch {
            // Nothing was started, so nothing is owed a `stop()`. Clearing the
            // slot is what lets a later pass retry a holder that was merely
            // slow to answer — but only while the slot is still this call's to
            // clear. Past a supersession it belongs to whoever took it, and
            // clearing it would discard a live adoption's task and let the next
            // caller open a *second* attach on the same pty.
            if slotStillHolds(task, for: terminalID) {
                slots[terminalID] = nil
            }
            throw error
        }
        // The publish decision and the publish itself, with no `await` between
        // them. An actor's methods are not atomic across suspension: while this
        // call was parked awaiting the attach, a `release` could have cleared
        // the slot and stopped this very reader, or a later `adopt` could have put
        // its own task there. Writing unconditionally would then either
        // resurrect a stopped reader or orphan a live one — two drain loops on
        // one pty master, which is the byte theft this type exists to prevent.
        guard slotStillHolds(task, for: terminalID) else {
            // Superseded. Whatever took the slot is the current truth, so
            // nothing from this adoption is published — not the reader, and not
            // the description's status either, which would otherwise overwrite
            // a fresher observation with a staler one. The reader is a resource,
            // so it is released: `stop()` is what closes the pty dup and joins
            // the drain thread, and a reader dropped without one leaks both.
            await adoption.reader.stop()
            Self.logger.info(
                """
                discarded a superseded adoption of session \
                \(terminalID.uuidString, privacy: .public); its reader was stopped
                """)
            throw Error.superseded(terminalID: terminalID)
        }
        slots[terminalID] = .adopted(adoption.reader)
        statuses[terminalID] = adoption.description.status
        drainLoopsStarted += 1
        liveDrainLoops += 1
        peakLiveDrainLoops = max(peakLiveDrainLoops, liveDrainLoops)
        Self.logger.info(
            """
            adopted the holder for session \(terminalID.uuidString, privacy: .public): child \
            \(adoption.description.childPID, privacy: .public) is \
            \(String(describing: adoption.description.status), privacy: .public)
            """)
        return adoption.reader
    }

    /// Whether `terminalID`'s slot still holds the in-flight task that `adopt`
    /// started, rather than a later adoption's task, a published reader, or
    /// nothing at all.
    ///
    /// Synchronous on purpose, and every caller must use its answer with no
    /// `await` in between: the answer is only true of the instant it was read,
    /// and an actor's methods are not atomic across suspension.
    private func slotStillHolds(
        _ task: Task<Adoption, Swift.Error>, for terminalID: UUID
    ) -> Bool {
        guard case .adopting(let current) = slots[terminalID] else { return false }
        return current == task
    }

    /// Adopts every holder-backed row, once, at startup.
    ///
    /// Failures are per-session and never propagate: one unreachable holder
    /// must not stop the daemon adopting the rest, and a startup that threw
    /// here would leave every *other* live session undrained.
    func adoptAll() async {
        let terminals: [Terminal]
        do {
            terminals = try await listTerminals()
        } catch {
            Self.logger.error(
                """
                could not list terminals to re-adopt holder sessions: \
                \(error.localizedDescription, privacy: .public)
                """)
            return
        }

        for terminal in terminals where terminal.transport == .holder {
            do {
                _ = try await adopt(terminal: terminal)
            } catch let error as Error {
                // A holder that named another installation answered correctly;
                // it is simply not ours. Left running, and not recorded as
                // exited — it is somebody else's live session.
                Self.logger.info(
                    """
                    skipping session \(terminal.id.uuidString, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            } catch HolderClient.Error.rejected {
                // Somebody else holds the holder's one client slot. That is a
                // legitimate answer from a live holder — "not ours to adopt
                // right now" — not a failure to retry into the ground, and
                // certainly not evidence the job ended.
                Self.logger.info(
                    """
                    the holder for session \(terminal.id.uuidString, privacy: .public) already has a \
                    client; leaving it alone
                    """)
            } catch {
                // Nothing answered at the rendezvous. The session is over, and
                // the only honest thing to say about how it ended is that
                // nobody collected the status.
                statuses[terminal.id] = .exitedStatusUnknown
                Self.logger.info(
                    """
                    no holder answered for session \(terminal.id.uuidString, privacy: .public), so \
                    its job ended with an unknown status: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
    }

    /// The one round trip that re-adoption is made of.
    ///
    /// **The owner check happens on the hand-over's own answer, not on a
    /// `describe` before it, and that ordering is deliberate.** A holder whose
    /// job has already exited winds itself down the moment an answer carrying
    /// the terminal status reaches a client — so a separate `describe` would
    /// collect that status, end the holder, and take everything the job wrote
    /// and nobody read down with it. `handOverPTY` answers the same question
    /// *and* rescues the queued output, which is exactly why the holder keeps
    /// handing the master over after its child is gone.
    ///
    /// The cost is that a foreign holder briefly hands over a descriptor before
    /// being told no. That descriptor is closed here and never read, so nothing
    /// is stolen from it — see the byte-theft note on the type — and the holder
    /// and its job are left running.
    ///
    /// **A refusal is retried, briefly.** The holder serves one client at a time
    /// and learns the previous one has gone only when its poll loop next reads
    /// EOF, so for up to one poll slice after a daemon dies its holder still
    /// believes that dead daemon is attached and answers the busy sentinel.
    /// `HolderSpawner` never meets that window because it keeps the connection
    /// its handshake ran on; an adopter has no such connection and must instead
    /// outlast the window. The budget is small and finite on purpose: past it,
    /// a refusal means somebody really is attached, and the honest answer is
    /// "not ours to adopt right now" rather than a retry loop that never ends.
    private static func attach(
        terminalID: UUID,
        socketPath: String,
        expecting owner: HolderOwnerToken,
        busyRetryBudget: Duration,
        clock: any Clock<Duration>
    ) async throws -> Adoption {
        var waited: Duration = .zero
        while true {
            do {
                return try await attemptAttach(
                    terminalID: terminalID, socketPath: socketPath, expecting: owner)
            } catch HolderClient.Error.rejected(let version) {
                guard waited < busyRetryBudget else {
                    throw HolderClient.Error.rejected(version: version)
                }
                // Elapsed time is accumulated from the interval rather than
                // measured against a deadline: `any Clock<Duration>` pins
                // `Duration` but not `Instant`, so instant arithmetic does not
                // typecheck through the existential. Same idiom as
                // `HolderSpawner.awaitBinding`.
                try? await clock.sleep(for: Self.busyRetryInterval)
                waited += Self.busyRetryInterval
            }
        }
    }

    /// One connect-and-take, over a connection opened for the purpose.
    private static func attemptAttach(
        terminalID: UUID,
        socketPath: String,
        expecting owner: HolderOwnerToken
    ) async throws -> Adoption {
        try await take(
            terminalID: terminalID,
            over: HolderClient(socketPath: socketPath),
            expecting: owner)
    }

    /// The hand-over itself, over a connection the caller supplies.
    ///
    /// Split from `attemptAttach` so a freshly spawned session can take its pty
    /// over the connection the spawner's handshake already ran on — see
    /// `spawn(terminalID:launch:)` — instead of reconnecting into the holder's
    /// busy window. The connection is closed on every exit path either way: the
    /// holder serves one client at a time, so a connection kept past the
    /// hand-over would refuse every later verb, a `forget` on the deletion path
    /// above all.
    private static func take(
        terminalID: UUID,
        over client: HolderClient,
        expecting owner: HolderOwnerToken
    ) async throws -> Adoption {
        let description: HolderChildDescription
        let ptyFD: Int32
        do {
            (description, ptyFD) = try await client.handOverPTY()
        } catch {
            await client.close()
            throw error
        }
        await client.close()

        guard description.owner == owner else {
            Darwin.close(ptyFD)
            throw Error.foreignOwner(
                terminalID: terminalID, holderOwner: description.owner.rawValue)
        }

        let reader = HolderReader(
            sessionID: terminalID,
            ptyFD: ptyFD,
            columns: Int(description.launch.columns),
            rows: Int(description.launch.rows))
        do {
            try await reader.start()
        } catch {
            // `stop()` on a reader that never drained closes the descriptor
            // from the actor, which is safe precisely because no thread has
            // ever touched it.
            await reader.stop()
            throw error
        }
        return Adoption(reader: reader, description: description)
    }

    // MARK: - Release

    /// Stops a session's reader and forgets it.
    ///
    /// The `stop()` is the point: a reader dropped without one leaks its drain
    /// thread and the pty descriptor it owns, because after end of file that
    /// thread parks on its wake pipe rather than exiting.
    ///
    /// **The slot is not vacated until the stop has happened.** It is handed to
    /// a `releasing` task first, so that the suspension inside `stop()` — which
    /// is where this call spends nearly all its time, with the outgoing reader
    /// still on the pty — is a state a concurrent `adopt` can see and wait for,
    /// rather than an absence it would read as "nobody is on this master".
    func release(terminalID: UUID) async {
        switch slots[terminalID] {
        case nil:
            return
        case .releasing(let task):
            // Somebody is already stopping this reader; waiting for their stop
            // *is* this method's whole contract, so there is nothing to add.
            await task.value
            clearIfStillReleasing(task, for: terminalID)
        case .adopted(let reader):
            let task = Task<Void, Never> { await self.stopPublished(reader) }
            slots[terminalID] = .releasing(task)
            await task.value
            clearIfStillReleasing(task, for: terminalID)
        case .adopting(let attach):
            let task = Task<Void, Never> { await self.stopInFlight(attach) }
            slots[terminalID] = .releasing(task)
            await task.value
            clearIfStillReleasing(task, for: terminalID)
        }
    }

    /// Stops a reader this registry published, and drops it from the live count
    /// **before** anything awaiting the release resumes — which is what lets an
    /// adoption queued behind a release publish without ever overlapping the
    /// reader it waited for.
    private func stopPublished(_ reader: HolderReader) async {
        await releaseBarrier?()
        await reader.stop()
        liveDrainLoops -= 1
    }

    /// Stops whatever an in-flight adoption managed to obtain.
    ///
    /// Nothing is decremented: an adoption that never published was never
    /// counted, and the adoption itself will find its slot taken and discard the
    /// reader too. Both stops are harmless — `HolderReader.stop()` is
    /// idempotent — and neither may be skipped, because which of them runs first
    /// is exactly the ordering nobody here controls.
    private func stopInFlight(_ attach: Task<Adoption, Swift.Error>) async {
        // The attach performs no cancellation checks, so this waits for it to
        // finish rather than interrupting it — which is what we want: a reader
        // that was started while we were releasing would otherwise be exactly
        // the leak this method exists to prevent.
        attach.cancel()
        if let adoption = try? await attach.value {
            await adoption.reader.stop()
        }
    }

    /// Vacates a slot, but only while it still holds the release that finished.
    ///
    /// Both the releaser and every adoption that waited on it call this, and
    /// whichever arrives first wins; the losers find a slot that is no longer
    /// theirs and leave it alone. Synchronous, like `slotStillHolds`, and for
    /// the same reason.
    private func clearIfStillReleasing(_ task: Task<Void, Never>, for terminalID: UUID) {
        guard case .releasing(let current) = slots[terminalID], current == task else { return }
        slots[terminalID] = nil
    }

    /// Releases every reader. The holders and their jobs are untouched — that
    /// is the whole design: a session outlives the daemon that was reading it.
    func releaseAll() async {
        for terminalID in slots.keys {
            await release(terminalID: terminalID)
        }
    }
}

// MARK: - Installation identity

extension HolderRegistry {
    /// This installation's owner token, minted once and read forever after.
    ///
    /// It must identify the **installation**, not the process: a token minted
    /// per daemon would make every holder that daemon spawned look foreign to
    /// its own successor, and re-adoption — the entire point of the transport —
    /// would never adopt anything. So it lives in the singleton `config` row,
    /// with the rest of the daemon's structured installation-scoped settings.
    ///
    /// **The mint is a conditional UPDATE, not a read-then-write.** Two daemons
    /// starting at once on one `TBD_HOME` must agree on one token, so the
    /// decision is SQLite's: the second writer's UPDATE matches no row and the
    /// read-back in the same transaction hands it the token the first one
    /// wrote. That is the same guarantee the file-backed store got from an
    /// `O_EXCL` open, which is what this replaced.
    static func installationOwner(
        config: ConfigStore,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async -> HolderOwnerToken {
        do {
            let stored = try await config.ensureHolderOwnerToken(
                minting: UUID().uuidString.lowercased())
            return HolderOwnerToken(rawValue: stored)
        } catch {
            // The database is unwritable. A path-derived token is the least-bad
            // answer — it is at least stable for as long as the outage lasts,
            // where an ephemeral one would disown this daemon's own holders on
            // its very next boot.
            //
            // What it costs, plainly: a daemon that cannot persist its token is
            // running on an identity nothing else agrees to. Holders it spawns
            // during the outage are stamped with the path-derived token, so the
            // moment the database becomes writable again a real token is minted
            // and every one of those holders reads as `foreignOwner` — left
            // running, adopted by nobody, and reclaimed by nothing until the
            // holder reconciler lands.
            Self.logger.error(
                """
                could not mint or read the holder owner token from the config row \
                (\(error.localizedDescription, privacy: .public)); falling back to a \
                path-derived token, under which holders spawned now will read as foreign \
                once the database is writable again
                """)
            return HolderOwnerToken(
                rawValue: "tbd-home:\(TBDConstants.configDir(environment: environment).path)")
        }
    }
}
