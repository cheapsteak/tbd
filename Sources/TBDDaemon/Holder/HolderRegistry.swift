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
        /// A viewer owns this session's pty, so the daemon must not put a
        /// reader on it. The fail-closed answer to every request that would
        /// otherwise make a second reader.
        case attachedToViewer(terminalID: UUID)
        /// There is no reader to hand over — the session was never adopted, or
        /// its reader has been released. An attach cannot be built out of
        /// nothing: the pty this would vend is one only a reader holds.
        case noLiveReader(terminalID: UUID)
        /// The attach being acknowledged is not the one this session is
        /// waiting on. A stale viewer's ack arriving after a successor's
        /// attach, or an ack for one already confirmed or cancelled.
        case attachSuperseded(terminalID: UUID, generation: UInt64)
        /// An attach for this session is already outstanding, so a second one
        /// is refused rather than superseding it.
        ///
        /// **Supersession is not available on this path, and that is the whole
        /// reason for the case.** A superseded adoption can be undone because
        /// everything it obtained is still inside this process; a superseded
        /// attach cannot, because its descriptor has been handed to another
        /// process and nothing can take it back. So the only safe posture is
        /// not to hand out the second one.
        case attachAlreadyPending(terminalID: UUID, generation: UInt64)
        /// A handback names an attach this session is not held by: no viewer
        /// claim at all, or a claim recorded for a different attach. Refused
        /// rather than applied, for the same reason every other stale message
        /// here is — a closing viewer's detach can arrive after a successor's
        /// attach has taken the pty, and clearing the successor's claim would
        /// put the daemon on a descriptor another process is reading.
        case handbackSuperseded(terminalID: UUID, generation: UInt64)

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
            case .attachedToViewer(let terminalID):
                return "a viewer owns the pty for session \(terminalID.uuidString); the daemon "
                    + "must not read it while that is true"
            case .noLiveReader(let terminalID):
                return "session \(terminalID.uuidString) has no live holder reader to hand over"
            case .attachSuperseded(let terminalID, let generation):
                return "attach \(generation) for session \(terminalID.uuidString) is no longer "
                    + "the one this session is waiting on"
            case .attachAlreadyPending(let terminalID, let generation):
                return "attach \(generation) for session \(terminalID.uuidString) has already "
                    + "been vended and not yet acknowledged; its descriptor cannot be taken back, "
                    + "so a second attach is refused"
            case .handbackSuperseded(let terminalID, let generation):
                return "attach \(generation) for session \(terminalID.uuidString) is not the one "
                    + "holding that session's pty, so its detach hands nothing back"
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

    /// How long one adoption waits for a holder to answer.
    ///
    /// Deliberately **not** `HolderClient.defaultReceiveTimeout`. That budget is
    /// sized for a connection a session keeps for its whole life, where the
    /// question is "has this holder died", and ten seconds of patience costs
    /// nothing because nobody is waiting on the answer. An adoption is the
    /// opposite: it is one handshake, on a local socket, on the daemon's
    /// startup path, and every second of it is a second the daemon cannot
    /// answer anyone. The GC collector reached the same number from the same
    /// reasoning — a handshake is not a long operation.
    ///
    /// It bounds the *reachable but silent* holder specifically. A dead one
    /// fails at `connect` with `ECONNREFUSED` and never reaches a receive.
    static let adoptionReceiveTimeout: Duration = .seconds(2)

    /// How long the whole startup adoption phase may take before it stops and
    /// hands the rest back to its caller.
    ///
    /// Per-holder bounding alone is not enough: `adoptAll` is serial, so N
    /// silent holders still cost N times the per-holder budget, and the phase
    /// runs before the socket bind. The total budget makes the daemon's silence
    /// independent of how many holders are wedged — worst case one budget plus
    /// the row that was already in flight when it expired.
    ///
    /// Five seconds is sized against the healthy case rather than the broken
    /// one: a reachable holder answers a local-socket handshake in
    /// milliseconds, so a fleet of hundreds finishes far inside it and the
    /// budget never bites. Only a holder that has stopped answering spends the
    /// budget at all.
    static let defaultAdoptAllBudget: Duration = .seconds(5)

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

    /// An attach whose descriptor has been vended and whose acknowledgement has
    /// not arrived. The reader is held rather than released because this attach
    /// may still be cancelled, and only the reader that suspended itself can be
    /// put back on the pty.
    private struct PendingAttach {
        let generation: UInt64
        let reader: HolderReader
    }

    /// Attaches vended and not yet acknowledged, by session. At most one per
    /// session: a second `beginAttach` supersedes the first, whose ack is then
    /// refused by generation.
    ///
    /// **Invariant, jointly with `viewerAttachments`: for one session, a
    /// pending entry and a viewer claim are never simultaneously live.** No
    /// single line enforces it, so it is written down here rather than left to
    /// be re-derived. `confirmAttach` clears the pending entry and then records
    /// the claim; `cancelPendingAttach(.unacknowledged)` records the claim and
    /// then clears the pending entry — both pairs synchronous, with no `await`
    /// between, so neither leaves an instant in which both are set;
    /// `beginAttach` refuses to record a pending entry over a standing claim
    /// and re-reads the claim after its suspension.
    ///
    /// Unreachability arguments elsewhere in this type rest on it — notably
    /// `confirmAttach`'s second guard, which is argued dead by enumerating the
    /// writers of `slots`. **A new writer of `slots` or of either map has to
    /// keep this true**, because the next reader will reach the guard long
    /// before reaching the chain that makes it unreachable.
    private var pendingAttaches: [UUID: PendingAttach] = [:]
    /// Sessions whose pty a viewer owns, and the attach generation that owns
    /// it. **The daemon reads none of these**, and `adopt` refuses them, which
    /// is what keeps "one reader per pty" true across the app boundary rather
    /// than only inside this process.
    ///
    /// Never live at the same time as this session's `pendingAttaches` entry —
    /// the invariant is stated in full there.
    private var viewerAttachments: [UUID: UInt64] = [:]
    /// Mints attach generations. Monotonic for the daemon's life, so an ack or
    /// a cancel naming an older attach can always be told from one naming the
    /// current attach.
    private var lastAttachGeneration: UInt64 = 0

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
    private let adoptAllBudget: Duration
    private let clock: any Clock<Duration>

    /// Set by `adoptAll`'s budget timer, read by its loop between holders.
    ///
    /// Instance state rather than a local box because the timer has to reach it
    /// across an actor hop, and the hop is what makes the write safe. It is
    /// reset at the top of every pass, which is sound because `adoptAll` runs
    /// once, at startup, from a single caller — two concurrent passes would
    /// share one flag, and there are none.
    private var adoptAllBudgetExpired = false

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

    /// Awaited inside `beginAttach`, immediately after the drain has quiesced
    /// and before anything is published — the window in which that call is
    /// holding a fresh `dup` of a pty and has decided nothing about it yet.
    ///
    /// A seam for the same reason as the two above, and it guards the worst of
    /// the three interleavings: a second attach, or an acknowledgement of the
    /// first, landing while a descriptor is in flight. The real window is a
    /// suspension inside `jiggle`, which is a deliberate 10 ms sleep — wide,
    /// but racing it is not a test.
    private var attachBarrier: (@Sendable () async -> Void)?

    /// Awaited inside `cancelPendingAttach`, immediately before a cancelled
    /// attach's reader is put back on its pty — the mirror of `attachBarrier`,
    /// and the window in which that reader's drain state is mid-transition.
    ///
    /// A seam for the same reason as the others: reproducing this by timing
    /// would mean racing a single `await` on an actor. Nil in production.
    private var cancelBarrier: (@Sendable () async -> Void)?

    init(
        owner: HolderOwnerToken,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        listTerminals: @escaping @Sendable () async throws -> [Terminal],
        spawner: HolderSpawner? = nil,
        busyRetryBudget: Duration = HolderRegistry.defaultBusyRetryBudget,
        adoptAllBudget: Duration = HolderRegistry.defaultAdoptAllBudget,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.owner = owner
        self.environment = environment
        self.listTerminals = listTerminals
        self.spawner = spawner
        self.canSpawn = spawner != nil
        self.busyRetryBudget = busyRetryBudget
        self.adoptAllBudget = adoptAllBudget
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

    /// Installs the attach barrier described above. Test-facing; production
    /// never calls it.
    func setAttachBarrier(_ barrier: (@Sendable () async -> Void)?) {
        attachBarrier = barrier
    }

    /// Installs the cancel barrier described above. Test-facing; production
    /// never calls it.
    func setCancelBarrier(_ barrier: (@Sendable () async -> Void)?) {
        cancelBarrier = barrier
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

    // MARK: - Sizing

    /// Applies a viewer's desired size to one holder-backed session, and
    /// decides which half of the resize is still the daemon's to make.
    ///
    /// **While a viewer holds the pty, the viewer owns `TIOCSWINSZ`.** It has a
    /// writable duplicate of the master and sets the size on it as its own view
    /// resizes — before it tells the daemon anything — so a daemon that issued
    /// the ioctl as well would signal the child a second time for one resize,
    /// and in the window where the two disagree would signal it to a geometry
    /// nobody is painting at. `viewerAttachment` is the instrument for that,
    /// deliberately: it reads true for a timed-out attach as well as a
    /// confirmed one, and both mean the same thing here — the viewer may be
    /// live on that descriptor.
    ///
    /// **The grid is not part of that trade.** The daemon's emulator is what a
    /// re-adoption and `terminal.output` render, so it tracks the viewer either
    /// way; a grid left at the size the viewer arrived at wraps everything the
    /// session prints from then on at a width nobody is painting. That is the
    /// defect the adoption path was fixed for once already, seen from the other
    /// side.
    ///
    /// A session with no reader is skipped silently: there is no grid to
    /// reshape and no descriptor to size. That is the ordinary state of a
    /// *confirmed* attach — the daemon released its reader at the
    /// acknowledgement — and there the viewer's own ioctl is the whole resize,
    /// with the pty itself carrying the geometry into the next adoption.
    func applyViewerResize(terminalID: UUID, columns: Int, rows: Int) async {
        guard let reader = reader(for: terminalID) else { return }
        if viewerAttachment(for: terminalID) != nil {
            await reader.resizeGrid(columns: columns, rows: rows)
        } else {
            await reader.resize(columns: columns, rows: rows)
        }
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
                terminalID: terminalID,
                over: spawned.client,
                expecting: owner,
                onEndOfOutput: endOfOutputNotifier(for: terminalID))
        } catch {
            // The holder is up and supervising a job that no row will ever
            // name, so leaving it would orphan both. Best-effort, and the
            // standing guarantee is still a reconciler (Milestone B).
            await dispose(handle: spawned.handle)
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
        await dispose(handle: handle)
    }

    /// Tears down the holder behind a row that is about to lose its DB record,
    /// deriving the rendezvous from this registry's own environment. Returns a
    /// description of what was left running, or nil when the whole teardown was
    /// attempted.
    ///
    /// **Every teardown path that deletes terminal rows must call this for a
    /// holder row, and the `killWindow` beside it is not an adequate
    /// substitute.** A holder row's `tmuxWindowID` is the empty string by
    /// construction, so that kill is not merely a no-op for this transport — it
    /// IS the leak: it addresses a coordinate naming nothing while the holder
    /// process, the job it forked, and the socket and lock files at its
    /// rendezvous all outlive the row. The row was the only record of those
    /// pids, so the moment before it is deleted is the last moment anything can
    /// reclaim them; until Milestone B's holder reconciler lands, no sweep will
    /// ever find them again.
    ///
    /// `abandon` is best-effort by nature — every step talks to something that
    /// may already be gone — so it reports nothing, and the only failures
    /// nameable here are the ones that stop it being *attempted*: an
    /// unrepresentable rendezvous path, or a row that never recorded the child
    /// pid. Each one leaks a live process, so each is reported rather than
    /// swallowed.
    func abandon(terminal: Terminal) async -> String? {
        let socketPath: String
        do {
            socketPath = try HolderRendezvous.socketPath(
                sessionID: terminal.id, environment: environment)
        } catch {
            return "\(error)"
        }
        // `holderPID` is not needed to reclaim anything: `abandon` reaches the
        // holder over its socket and kills the job by CHILD pid, so a row whose
        // holder pid was never recorded is still fully reclaimable. `childPID`
        // is the one that matters, and 0 is the sentinel `dispose` refuses to
        // signal — deliberately, since `kill(0, …)` would signal the daemon's
        // own process group.
        await abandon(
            terminalID: terminal.id,
            handle: HolderHandle(
                holderPID: terminal.holderPID ?? 0,
                childPID: terminal.childPID ?? 0,
                socketPath: socketPath))
        guard terminal.childPID != nil else {
            return "terminal \(terminal.id) recorded no child pid, so its holder was told to "
                + "let go but the job it forked was not killed"
        }
        return nil
    }

    /// `forget`, kill, reap: the holder closes the pty master and winds down,
    /// the job it was supervising is killed by pid, and the holder's corpse is
    /// collected. All three are named because each is owed to a different
    /// party.
    ///
    /// The kill is separate from the forget because the holder's death does not
    /// reliably end the job. Closing the last descriptor on the pty master hangs
    /// the job up, and a job whose `SIGHUP` is at its default disposition dies of
    /// that — but one that ignores `SIGHUP`, which any job is free to do, would
    /// be left reparented to pid 1 with nobody to reclaim it.
    ///
    /// The reap is owed to this process. A holder is `posix_spawn`ed by the
    /// daemon, so it is the daemon's own child and **nobody else can collect
    /// it**: a teardown that stopped at the kill left one zombie per session
    /// torn down, for the life of the daemon. `HolderSpawner`'s never-bound
    /// failure path has always reaped for exactly this reason; this is the same
    /// obligation on the path that runs every time.
    private func dispose(handle: HolderHandle) async {
        // Resolved BEFORE the holder is told to let go, and that ordering is the
        // whole fix. `forget` closes the pty master, which hangs up the
        // foreground process group and usually kills the job outright — after
        // which `getpgid` on it answers `ESRCH` and the group can no longer be
        // named, while a member that ignored `SIGHUP` is still sitting in it.
        // Reading the group first is what lets the kill below reach that member.
        let group = Self.jobProcessGroup(childPID: handle.childPID)
        let client = HolderClient(socketPath: handle.socketPath)
        try? await client.forget()
        await client.close()
        Self.killJob(childPID: handle.childPID, group: group)
        await reap(holderPID: handle.holderPID)
    }

    /// The process group id to signal for a holder's job, or nil when no group
    /// may be signalled and only the pid itself is safe to kill.
    ///
    /// The job is the session leader of the pty's own session, courtesy of
    /// `forkpty`, so its group id is its own pid — the closure the design spec
    /// names for the sibling holder-death path. That is **verified here rather
    /// than assumed**: a group id that is not the job's own pid names a group
    /// this daemon did not create, and signalling it would reach processes
    /// nobody asked us to kill.
    ///
    /// The `> 1` guards are not defensive padding. `kill(0, …)` and
    /// `killpg(0, …)` signal the **caller's** group — the daemon itself and
    /// every process it owns — so a `0` that reached the negation below would
    /// take down the fleet, and `getpgid` returns `-1` for a pid that is
    /// already gone.
    /// Internal rather than private because `ProductionRowlessHolderReclaimer`
    /// must kill a holder's job by exactly these rules. Reimplementing them
    /// beside a second caller is how the `> 1` guards and the resolve-before-
    /// hang-up ordering get quietly dropped.
    static func jobProcessGroup(childPID: Int32) -> Int32? {
        guard childPID > 1 else { return nil }
        let pgid = getpgid(childPID)
        guard pgid > 1, pgid == childPID else { return nil }
        return pgid
    }

    /// Kills the job the holder forked: its process group where one could be
    /// named, and the pid itself always.
    ///
    /// The group is what makes this a reclamation rather than a courtesy.
    /// Closing the pty master hangs the foreground group up, and a job at
    /// `SIGHUP`'s default disposition dies of that — but `nohup`, a daemonizing
    /// agent, or a shell with `huponexit` off simply declines, and was left
    /// reparented to pid 1 with nothing on any sweep that would ever find it
    /// again (`WorktreeLifecycle+Reconcile` skips holder rows by construction).
    /// `SIGKILL` to the group cannot be declined.
    ///
    /// A descendant that deliberately *leaves* the group — `setsid`, a double
    /// fork — is outside this closure and survives, exactly as it survives a
    /// tmux pane kill today. That is a standing fleet-wide problem belonging to
    /// `AgentReaper`, and the design spec puts it out of scope here.
    ///
    /// Both signals are best-effort: a teardown must never fail because
    /// something it meant to kill was already gone.
    /// Internal for the same reason as `jobProcessGroup` above: one
    /// implementation of the kill, two callers.
    static func killJob(childPID: Int32, group: Int32?) {
        guard childPID > 1 else { return }
        if let group { _ = kill(-group, SIGKILL) }
        _ = kill(childPID, SIGKILL)
    }

    /// Collects a holder that has been told to let go, bounded.
    ///
    /// **Bounded, and `WNOHANG`, because this runs on the actor.** A blocking
    /// `waitpid` on a holder that is slow to exit — or that never answered the
    /// `forget` at all — would park every other session's adoption and release
    /// behind it for as long as it took. The budget is generous next to what a
    /// forgotten holder actually needs (it breaks its poll loop the moment it
    /// has answered, so the usual case is collected on the first attempt or the
    /// one after it) and finite next to the wait it replaces.
    ///
    /// A negative return ends it immediately rather than after the budget:
    /// `ECHILD` means the pid is not ours — a holder this daemon adopted from a
    /// previous one, which no `waitpid` here can ever collect — and waiting out
    /// the budget on one would delay every teardown after a daemon restart.
    ///
    /// What is left when the budget expires is a live holder, not a leak this
    /// created: it is named in the log, and reclaiming a holder that outlives
    /// its teardown belongs to the holder reconciler Milestone B adds.
    private func reap(holderPID: Int32) async {
        guard holderPID > 0 else { return }
        var waited: Duration = .zero
        while true {
            var status: Int32 = 0
            let collected = waitpid(holderPID, &status, WNOHANG)
            if collected == holderPID { return }
            if collected < 0 && errno != EINTR { return }
            guard waited < Self.reapBudget else { break }
            // Accumulated from the interval rather than measured against a
            // deadline, for the same reason as everywhere else here: `any
            // Clock<Duration>` pins `Duration` but not `Instant`.
            try? await clock.sleep(for: Self.reapPollInterval)
            waited += Self.reapPollInterval
        }
        Self.logger.error(
            """
            holder pid \(holderPID, privacy: .public) had not exited \
            \(String(describing: Self.reapBudget), privacy: .public) after being told to let go, \
            so it was left unreaped
            """)
    }

    /// How long a teardown waits for a forgotten holder to exit before giving
    /// up on collecting it.
    static let reapBudget: Duration = .seconds(2)
    static let reapPollInterval: Duration = .milliseconds(20)

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
            // Re-read on every pass, not once at the top: an actor's methods
            // are not atomic across suspension, and every branch below awaits.
            // An attach that completed while this call was parked must be seen
            // here rather than adopted over — putting a second reader on a pty
            // a viewer is already reading is the one failure this type exists
            // to prevent, and it is silent.
            guard viewerAttachments[terminalID] == nil else {
                throw Error.attachedToViewer(terminalID: terminalID)
            }
            // An attach in flight has already quiesced this session's reader,
            // so `.adopted` no longer implies "draining". Handing that reader
            // back would answer "yes, adopted and reading" about a session
            // nobody is reading — and, if the attach then completes, about one
            // a viewer owns.
            if let outstanding = pendingAttaches[terminalID] {
                throw Error.attachAlreadyPending(
                    terminalID: terminalID, generation: outstanding.generation)
            }
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
    private func beginAdoption(
        of terminalID: UUID, seedingScreenWith preamble: Data = Data()
    ) async throws -> HolderReader {
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: terminalID, environment: environment)
        let expected = owner
        let budget = busyRetryBudget
        let clock = self.clock
        let notifyEndOfOutput = endOfOutputNotifier(for: terminalID)
        let task = Task<Adoption, Swift.Error> {
            try await Self.attach(
                terminalID: terminalID,
                socketPath: socketPath,
                expecting: expected,
                busyRetryBudget: budget,
                receiveTimeout: Self.adoptionReceiveTimeout,
                clock: clock,
                onEndOfOutput: notifyEndOfOutput,
                seedingScreenWith: preamble)
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

    /// Adopts every holder-backed row, once, at startup, within a total budget.
    ///
    /// Failures are per-session and never propagate: one unreachable holder
    /// must not stop the daemon adopting the rest, and a startup that threw
    /// here would leave every *other* live session undrained.
    ///
    /// **The budget is what keeps a wedged holder from looking like a dead
    /// daemon.** This runs before the socket bind, so its duration is the
    /// daemon's silence; a holder that accepts a connection and then says
    /// nothing costs `adoptionReceiveTimeout` every time, and serially that is
    /// the whole fleet's worth of silence. The budget is checked *between*
    /// holders — never mid-hand-over, where abandoning a call would mean
    /// walking away from a descriptor in flight — so the phase costs at most
    /// one budget plus the row that was already running when it expired.
    ///
    /// **Rows the budget did not reach are returned, not dropped**, and the
    /// caller is obliged to finish them: nothing else in the daemon ever calls
    /// `adopt`, so a row abandoned here would stay undrained for the process's
    /// whole life — and an undrained pty master does not merely cost a screen,
    /// it stops the job on it from finishing its exit. `Daemon` resumes them
    /// immediately after the socket is bound, where the wait costs no RPC
    /// caller — `adoptRemaining` documents what it does still cost. The result
    /// is deliberately **not** `@discardableResult`, so the obligation is one
    /// the compiler holds rather than one a reader has to notice.
    ///
    /// Nothing is recorded about a row that was not reached. A missing status
    /// reads as `.running`, which is the honest answer for a holder nobody
    /// asked; `exitedStatusUnknown` would be a claim about an answer that was
    /// never sought.
    func adoptAll() async -> [Terminal] {
        let terminals: [Terminal]
        do {
            terminals = try await listTerminals()
        } catch {
            Self.logger.error(
                """
                could not list terminals to re-adopt holder sessions: \
                \(error.localizedDescription, privacy: .public)
                """)
            return []
        }

        let rows = terminals.filter { $0.transport == .holder }
        guard !rows.isEmpty else { return [] }

        adoptAllBudgetExpired = false
        let budget = adoptAllBudget
        let budgetTimer = Task { [clock] in
            do {
                try await clock.sleep(for: budget)
            } catch {
                // Cancelled because the phase finished inside its budget.
                return
            }
            await self.expireAdoptAllBudget()
        }
        defer { budgetTimer.cancel() }

        var deferredRows: [Terminal] = []
        for (index, terminal) in rows.enumerated() {
            if adoptAllBudgetExpired {
                deferredRows = Array(rows[index...])
                break
            }
            await adoptOne(terminal)
        }

        if !deferredRows.isEmpty {
            Self.logger.error(
                """
                the startup adoption budget expired with \(deferredRows.count, privacy: .public) of \
                \(rows.count, privacy: .public) holder sessions unreached; they will be adopted \
                once the daemon is answering
                """)
        }
        return deferredRows
    }

    /// Adopts rows a budgeted pass left behind, with no budget of its own.
    ///
    /// Called once the socket is bound, where a slow holder delays no RPC
    /// caller. **It is serial, so a slow row delays the rows behind it** — but
    /// by a bounded amount, not indefinitely. A row costs `busyRetryBudget`
    /// plus one `adoptionReceiveTimeout`: the connect that opens it is not
    /// covered by `SO_RCVTIMEO`, yet needs no cover, because a Darwin
    /// `connect(2)` on an `AF_UNIX` path never waits on a listener — it is
    /// answered or refused in microseconds
    /// (`HolderClientTests.aSaturatedRendezvousIsRefusedImmediatelyRatherThan`
    /// `Blocking`). The receive is the only part of a round trip that waits,
    /// and it is bounded.
    ///
    /// Serial anyway, because the alternative is worse: this client's I/O is
    /// blocking, so a task per row would park a cooperative-pool thread per row
    /// for up to that receive timeout, and a wedged fleet would starve every
    /// RPC *handler* — `SocketRPCHandler.channelRead` hands each request into a
    /// `Task` on the cooperative pool — leaving a daemon that accepts
    /// connections, reads their bytes and answers none of them.
    ///
    /// Hence the log lines. A rescue that started and never finished is the
    /// only evidence of a stranded tail, so both ends of the pass are recorded
    /// at `.info`; the per-row line is `.debug` — silent until somebody streams
    /// the subsystem — and names the row a stall stopped on.
    func adoptRemaining(_ terminals: [Terminal]) async {
        let rows = terminals.filter { $0.transport == .holder }
        guard !rows.isEmpty else { return }
        Self.logger.info(
            """
            finishing the startup adoption of \(rows.count, privacy: .public) holder sessions the \
            budget did not reach
            """)
        for (index, terminal) in rows.enumerated() {
            Self.logger.debug(
                """
                adopting deferred holder session \(terminal.id.uuidString, privacy: .public) \
                (\(index + 1, privacy: .public) of \(rows.count, privacy: .public))
                """)
            await adoptOne(terminal)
        }
        Self.logger.info(
            """
            finished the deferred adoption of all \(rows.count, privacy: .public) holder sessions
            """)
    }

    /// Marks the startup adoption budget spent. Actor-isolated so the timer's
    /// write and the loop's read cannot race.
    private func expireAdoptAllBudget() {
        adoptAllBudgetExpired = true
    }

    /// One row's adoption, with every failure classified and none propagated.
    ///
    /// **A failure is only branded when it is evidence of absence, and that
    /// distinction is load-bearing rather than tidy.** What is written here is
    /// remembered as `lastKnownStatus`, and a remembered terminal status is
    /// taken as established *without a further round trip* by two readers:
    /// `reclaimIfSessionEnded`, which releases the reader on it, and the
    /// reconcile arm's gate 4
    /// (`WorktreeLifecycle.holderRowVerdict(for:)`), which deletes the row and
    /// its tab on it — leaving a still-living holder rowless for
    /// `RowlessHolderCollector` to SIGKILL. That deletion is itself gated on
    /// the child's pid being unrecorded or dead, so a blanket brand would not
    /// reach a job that is still running; what it would put on that path is a
    /// holder that was merely *slow to answer* — a receive timeout, `EMFILE`,
    /// a hang-up mid-frame — whose child had already exited, losing its row,
    /// its tab, and the undrained gravestone screen. Ending a genuinely live
    /// agent session would additionally require the childPID gate to miss —
    /// a null `childPID`, or a liveness probe reading false — before
    /// `RowlessHolderCollector` ever gets to describe it.
    ///
    /// So the classification is `exitProbeOutcome`'s, exactly as the reconcile
    /// probe's is: only `ENOENT` and `ECONNREFUSED` at the rendezvous mean the
    /// holder is gone. Everything else is this daemon's failure to complete a
    /// round trip, says nothing about the child, and leaves no memory behind —
    /// so the row is judged by a fresh probe rather than by a remembered
    /// guess.
    private func adoptOne(_ terminal: Terminal) async {
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
            switch Self.exitProbeOutcome(for: error) {
            case .established(let status):
                // Nothing is bound at the rendezvous, so the holder is gone.
                // The session is over, and the only honest thing to say about
                // how it ended is that nobody collected the status.
                statuses[terminal.id] = status
                Self.logger.info(
                    """
                    no holder answered for session \(terminal.id.uuidString, privacy: .public), so \
                    its job ended with an unknown status: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            case .retry, .keep:
                // The round trip failed; the holder may well be alive and
                // wedged. Nothing is remembered, so the reconcile arm reaches
                // its own probe instead of short-circuiting on this.
                Self.logger.info(
                    """
                    could not complete a hand-over for session \
                    \(terminal.id.uuidString, privacy: .public), and nothing about it says the \
                    job ended; leaving the row unjudged: \
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
        receiveTimeout: Duration,
        clock: any Clock<Duration>,
        onEndOfOutput: (@Sendable () -> Void)?,
        seedingScreenWith preamble: Data = Data()
    ) async throws -> Adoption {
        var waited: Duration = .zero
        while true {
            do {
                return try await attemptAttach(
                    terminalID: terminalID,
                    socketPath: socketPath,
                    expecting: owner,
                    receiveTimeout: receiveTimeout,
                    onEndOfOutput: onEndOfOutput,
                    seedingScreenWith: preamble)
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
        expecting owner: HolderOwnerToken,
        receiveTimeout: Duration,
        onEndOfOutput: (@Sendable () -> Void)?,
        seedingScreenWith preamble: Data = Data()
    ) async throws -> Adoption {
        try await take(
            terminalID: terminalID,
            over: HolderClient(socketPath: socketPath, receiveTimeout: receiveTimeout),
            expecting: owner,
            onEndOfOutput: onEndOfOutput,
            seedingScreenWith: preamble)
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
        expecting owner: HolderOwnerToken,
        onEndOfOutput: (@Sendable () -> Void)? = nil,
        seedingScreenWith preamble: Data = Data()
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

        // **The pty is the authority on the grid, not the launch request.**
        // `HolderLaunchRequest` records the size a session was asked for once,
        // at spawn, and nothing ever updates it; every resize since — the app's
        // `setMainAreaSize` fan-out reaching `HolderReader.resize` — moved the
        // terminal itself with `TIOCSWINSZ`. Rebuilding the emulator from the
        // request would hand a re-adopted session a grid the child stopped
        // drawing into long ago: a job laying out 123 columns wraps every line
        // into an 80-column emulator, and nothing in the daemon would say so.
        // The request is the fallback for the one case the ioctl cannot answer.
        let launched = (columns: Int(description.launch.columns), rows: Int(description.launch.rows))
        let grid = HolderReader.windowSize(ptyFD: ptyFD) ?? launched
        if grid != launched {
            Self.logger.debug(
                """
                session \(terminalID.uuidString, privacy: .public) was resized since it was \
                launched; building its emulator at \(grid.columns, privacy: .public)x\
                \(grid.rows, privacy: .public) rather than the launch request's \
                \(launched.columns, privacy: .public)x\(launched.rows, privacy: .public)
                """)
        }
        let reader = HolderReader(
            sessionID: terminalID,
            ptyFD: ptyFD,
            columns: grid.columns,
            rows: grid.rows,
            onEndOfOutput: onEndOfOutput)
        // BEFORE the drain starts, and that ordering is the whole of the
        // handback's fidelity: the preamble's reset prelude erases the display
        // and the scrollback, so a live byte parsed ahead of it would be wiped
        // — output the viewer never saw, thrown away by the screen that was
        // meant to preserve it. Nothing is reading this descriptor yet, so
        // there is no other feed to race.
        await reader.ingest(preamble: preamble)
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

    // MARK: - Handing a session to a viewer

    /// Quiesces the session's drain, serializes its screen, and hands back a
    /// `dup` of its pty for a viewer to read.
    ///
    /// **The daemon stops reading here, at the vend, and not at the
    /// acknowledgement.** From the moment the descriptor leaves this process
    /// the app may be reading it, and two readers on one pty is silent byte
    /// theft that nothing reports; a window in which *nobody* reads costs
    /// queued output and delays the exit of a job that finishes inside it, and
    /// is recoverable. The design spec's rule — "the failure direction is
    /// always toward reading nothing until liveness says otherwise" — is this
    /// choice, and it is why the preamble has no hole in it either: everything
    /// up to the quiesce is in the snapshot, everything after it is still
    /// queued on the tty for the viewer, and nothing falls between.
    ///
    /// What the acknowledgement decides is *ownership*, not who reads: until
    /// `confirmAttach`, this reader is still held and can be put back on the
    /// pty by `cancelPendingAttach` — but only for a reason that establishes
    /// the viewer never got the descriptor.
    ///
    /// The returned descriptor belongs to the caller, which closes it once it
    /// has been passed on.
    func beginAttach(
        terminalID: UUID, maxScrollbackLines: Int = HolderReader.scrollbackLines
    ) async throws -> HolderAttachVend {
        guard viewerAttachments[terminalID] == nil else {
            throw Error.attachedToViewer(terminalID: terminalID)
        }
        // Refused, not superseded. Every other contested state in this type is
        // resolved by letting the newer caller win, because everything the
        // loser obtained is still inside this process and can be released. A
        // vended descriptor is not: it is in another process's table and
        // nothing here can take it back. So while one is outstanding, the only
        // safe answer to "hand me that pty as well" is no.
        if let outstanding = pendingAttaches[terminalID] {
            throw Error.attachAlreadyPending(
                terminalID: terminalID, generation: outstanding.generation)
        }
        guard case .adopted(let reader) = slots[terminalID] else {
            throw Error.noLiveReader(terminalID: terminalID)
        }

        // Claimed BEFORE the first suspension, and that ordering is the guard
        // above doing its job. An actor's methods are not atomic across
        // `await`, so a claim recorded at the END would leave every concurrent
        // caller looking at an empty slot and each one vending its own live
        // `dup` — two readers on one pty, arrived at by two callers who each
        // checked correctly.
        lastAttachGeneration += 1
        let generation = lastAttachGeneration
        pendingAttaches[terminalID] = PendingAttach(generation: generation, reader: reader)

        let ptyFD: Int32
        do {
            ptyFD = try await reader.suspendDraining()
        } catch {
            clearPendingAttach(terminalID: terminalID, generation: generation)
            throw error
        }
        // The one suspension a test can steer. In production this is a nil
        // check; see `attachBarrier`.
        await attachBarrier?()

        let preamble = await reader.snapshotPreamble(maxScrollbackLines: maxScrollbackLines)
        // Re-read EVERYTHING this call decided on, after the last await and
        // with no await before the return. Three things can have changed while
        // it was parked, and each one makes this descriptor unfit to hand out:
        // this attach was cancelled; a release took the slot (the reader was
        // stopped, so this is a `dup` of a number the kernel may have
        // reissued); or an acknowledgement landed and a viewer now owns the pty.
        //
        // The ownership clause is layered, not load-bearing today: while the
        // claim above stands, an acknowledgement can only have cleared this
        // call's own pending entry, so the middle clause catches that case
        // first. It is kept because it is the one clause that still holds if
        // the claim is ever relaxed — `confirmAttach` records ownership
        // *before* it suspends in `jiggle` precisely so this can see it — and
        // because the failure it guards against is the unrecoverable one.
        guard viewerAttachments[terminalID] == nil,
              pendingAttaches[terminalID]?.generation == generation,
              case .adopted(let current) = slots[terminalID], current === reader
        else {
            Darwin.close(ptyFD)
            clearPendingAttach(terminalID: terminalID, generation: generation)
            throw Error.superseded(terminalID: terminalID)
        }
        Self.logger.info(
            """
            vended the pty for session \(terminalID.uuidString, privacy: .public) to a viewer as \
            attach \(generation, privacy: .public); the daemon has stopped reading it and will not \
            resume without an answer about that viewer
            """)
        return HolderAttachVend(
            ptyFD: ptyFD, generation: generation, snapshotPreamble: preamble)
    }

    /// The viewer's acknowledgement: it is reading the descriptor, so this
    /// session is now its to read and the daemon's reader is released for good.
    ///
    /// The jiggle goes here rather than at the vend, and that ordering is the
    /// point of it: a program repaints on `SIGWINCH` into the tty, and the ack
    /// is the first moment anybody is certainly there to receive the repaint.
    /// It happens before the reader is stopped because the reader owns the
    /// descriptor the ioctl rides on.
    ///
    /// Generation-checked. A stale ack — a superseded viewer's, or a duplicate
    /// — is refused rather than allowed to release a reader a live attach is
    /// relying on.
    ///
    /// **A refused ack records no claim, and that is examined rather than
    /// assumed.** The viewer sending one has the descriptor, so a refusal that
    /// clears the pending entry without recording a claim would leave a pty
    /// nothing in this registry accounts for — R15's family, and the reason it
    /// was handed to the app-death arbitration to rule on. The ruling is that
    /// neither arm needs one:
    ///
    /// - The **second** guard (the slot no longer holds this attach's reader)
    ///   is unreachable. Every writer of `slots` that can change the reader
    ///   under a live pending entry clears `pendingAttaches` first (`release`),
    ///   and the two that would install a different reader refuse outright
    ///   while a pending entry exists (`adopt`, `beginAttach`).
    /// - The **first** guard (the pending entry is already gone) is reachable
    ///   only through a clearer that has itself settled the question:
    ///   `cancelPendingAttach(.unacknowledged)` records the claim,
    ///   `.descriptorNeverDelivered` is by definition an attach whose
    ///   descriptor never left this process, and `release` is tearing the
    ///   session down — where a claim would be the brick `release`'s own
    ///   comment exists to prevent, refusing every later adoption of a session
    ///   that is going away.
    ///
    /// So the state is bounded by who *clears*, not by what this method
    /// records, and adding a claim here would brick sessions rather than
    /// protect them.
    func confirmAttach(terminalID: UUID, generation: UInt64) async throws {
        guard let pending = pendingAttaches[terminalID], pending.generation == generation else {
            throw Error.attachSuperseded(terminalID: terminalID, generation: generation)
        }
        guard case .adopted(let reader) = slots[terminalID], reader === pending.reader else {
            clearPendingAttach(terminalID: terminalID, generation: generation)
            throw Error.attachSuperseded(terminalID: terminalID, generation: generation)
        }
        clearPendingAttach(terminalID: terminalID, generation: generation)
        // Recorded BEFORE anything that suspends — the jiggle below is a
        // deliberate 10 ms sleep, and the stop after it is longer again. Two
        // callers resume inside that window and both must find the session
        // already marked as the viewer's: an `adopt` waiting on the release,
        // and a `beginAttach` parked between its quiesce and its guard, which
        // would otherwise hand out a second live descriptor for a pty this
        // acknowledgement has just given away.
        viewerAttachments[terminalID] = generation

        await reader.jiggle()

        let task = Task<Void, Never> { await self.stopPublished(reader) }
        slots[terminalID] = .releasing(task)
        await task.value
        clearIfStillReleasing(task, for: terminalID)
        Self.logger.info(
            """
            attach \(generation, privacy: .public) for session \
            \(terminalID.uuidString, privacy: .public) was acknowledged; the daemon's reader is \
            released and the viewer owns the pty
            """)
    }

    /// Why an attach that was vended is being taken back.
    ///
    /// The two arms differ in exactly one respect, and it decides whether the
    /// daemon may read the pty again: whether the viewer can possibly have the
    /// descriptor. Nothing else about the failure matters.
    enum AttachCancelReason: Sendable, Equatable {
        /// The descriptor never reached the viewer — the vend itself failed, so
        /// this process still holds the only copy that was ever made. Nobody
        /// else can be reading, and the drain resumes.
        case descriptorNeverDelivered
        /// The viewer has the descriptor and has not acknowledged. A lost ack
        /// and a lost app are indistinguishable on the wire, and the viewer may
        /// already be live on its dup, so this does **not** license a resume:
        /// the daemon stays off the pty, and hands out no further descriptor
        /// for it, until something establishes that the viewer is gone.
        case unacknowledged
    }

    /// Takes back an attach that was vended and never acknowledged.
    ///
    /// Generation-checked, and a no-op for an attach that has already been
    /// confirmed or superseded — the ready-timeout that calls this can fire
    /// long after either.
    ///
    /// **Only one reason resumes the drain**, and the enum above says why. The
    /// other arm deliberately leaves the session unread: that is the fail-closed
    /// direction, and it is not free, because a job that exits with unread
    /// output cannot finish exiting. Resuming is licensed by evidence that the
    /// viewer is gone — either its own detach (`acceptHandback`) or an
    /// app-liveness verdict (`seizeFromDeadApp`), and by nothing weaker.
    func cancelPendingAttach(
        terminalID: UUID, generation: UInt64, reason: AttachCancelReason
    ) async {
        guard let pending = pendingAttaches[terminalID], pending.generation == generation else {
            return
        }
        switch reason {
        case .descriptorNeverDelivered:
            guard case .adopted(let reader) = slots[terminalID], reader === pending.reader else {
                clearPendingAttach(terminalID: terminalID, generation: generation)
                return
            }
            do {
                // The claim is HELD ACROSS THE RESUME and cleared only after it
                // has landed — the mirror image of `beginAttach` holding it
                // across the suspend, and the same window seen from the other
                // end. Clearing first would open an instant in which both maps
                // say "nobody is attaching" while this reader is mid-transition:
                // a concurrent `beginAttach` would pass every guard, quiesce a
                // reader that is about to be resumed, and hand out a fresh
                // `dup` — and then the resume lands and the daemon is draining
                // a pty the app is also on. That the descriptor from the FAILED
                // vend never left this process is what makes resuming safe; it
                // says nothing about the descriptor a concurrent attach makes.
                //
                // The invariant, stated once for all three sites: no window may
                // exist in which the maps say nobody is attaching while a
                // suspend or a resume is still in flight.
                try await resumeAfterCancellation(reader)
                clearPendingAttach(terminalID: terminalID, generation: generation)
                Self.logger.info(
                    """
                    attach \(generation, privacy: .public) for session \
                    \(terminalID.uuidString, privacy: .public) never reached a viewer, so the \
                    daemon resumed draining its pty
                    """)
            } catch {
                // The resume failed, so nothing is reading this pty — but
                // nothing else holds a descriptor for it either (the vend never
                // delivered one), so an attach is a legitimate recovery and the
                // claim must not outlive the attempt.
                clearPendingAttach(terminalID: terminalID, generation: generation)
                Self.logger.error(
                    """
                    could not resume draining session \(terminalID.uuidString, privacy: .public) \
                    after a failed vend, so its job cannot finish exiting: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        case .unacknowledged:
            // The claim is KEPT, not dropped, and that is the whole of this
            // arm. The viewer has a descriptor for this pty and may be reading
            // it; forgetting that would leave a session which passes every
            // guard, so the next attach hands out a second live `dup` of a pty
            // somebody is already on — reached by a plain sequence, with no
            // race in it at all. The map already means exactly "a viewer may
            // hold this pty", and both `beginAttach` and `adopt` refuse on it.
            //
            // Refusing to read the pty while cheerfully duplicating it for
            // somebody else would be the same evidence answered two ways.
            // What clears it is the viewer's own detach, or the app-liveness
            // verdict the design spec names for app death — `seizeFromDeadApp`.
            // Recorded before the claim is dropped, so the two hand off with
            // nothing between them — not even a synchronous instant in which
            // both maps are empty.
            viewerAttachments[terminalID] = generation
            clearPendingAttach(terminalID: terminalID, generation: generation)
            Self.logger.error(
                """
                attach \(generation, privacy: .public) for session \
                \(terminalID.uuidString, privacy: .public) was never acknowledged. Its viewer has \
                the pty and may be reading it, so the daemon stays off that descriptor and hands \
                out no other: nothing is draining this session, and a job that exits now cannot \
                finish exiting until that viewer detaches or is confirmed gone
                """)
        }
    }

    /// Puts a cancelled attach's reader back on its pty, through the one
    /// suspension a test can steer on this path.
    ///
    /// Wrapped rather than inlined so the barrier travels **with** the resume.
    /// The ordering this method's caller has to get right is "clear the claim
    /// after the resume, never before", and a seam sitting on its own line
    /// above the resume would still be above the clear if somebody moved it —
    /// so the window would close in the test while staying open in production.
    /// Inside the call, it cannot be separated from what it stands for.
    private func resumeAfterCancellation(_ reader: HolderReader) async throws {
        await cancelBarrier?()
        try await reader.resumeDraining()
    }

    /// Drops a pending attach, but only while it is still the one named.
    ///
    /// Synchronous and generation-checked, like every other "still mine?" here:
    /// a cancellation resuming after a suspension must not discard the claim a
    /// later attach has since recorded, which would let a third one in beside
    /// it.
    private func clearPendingAttach(terminalID: UUID, generation: UInt64) {
        guard pendingAttaches[terminalID]?.generation == generation else { return }
        pendingAttaches[terminalID] = nil
    }

    /// Drops a viewer's claim on a pty, but only while it is still the one
    /// named — the `clearPendingAttach` of the other map, and generation-checked
    /// for the same reason: a clear that resumes after a suspension must not
    /// discard a claim a later attach has since recorded.
    private func clearViewerAttachment(terminalID: UUID, generation: UInt64) {
        guard viewerAttachments[terminalID] == generation else { return }
        viewerAttachments[terminalID] = nil
    }

    /// The attach generation a viewer holds this session's pty under, if one
    /// may. Test-facing, and the honest instrument for "who owns this pty": the
    /// absence of a reader cannot tell a vended session from a released one.
    ///
    /// "May" rather than "does", deliberately. It is set by an acknowledgement,
    /// which is proof, and also by an attach that timed out, which is not — but
    /// the two are indistinguishable from here and both mean the same thing to
    /// every caller: the daemon neither reads this pty nor duplicates it again.
    func viewerAttachment(for terminalID: UUID) -> UInt64? {
        viewerAttachments[terminalID]
    }

    // MARK: - Taking a session back from a viewer

    /// The viewer has stopped reading and closed its descriptor: take the
    /// session back, with the screen it was showing.
    ///
    /// The mirror of `beginAttach` + `confirmAttach`, and the reason a closed
    /// tab does not brick its session. Until this exists, `viewerAttachments`
    /// is only ever cleared by `release`, so a viewer that goes away leaves a
    /// claim that both `adopt` and `beginAttach` refuse on: nothing drains the
    /// pty, no injection can be written, and reopening the tab fails too.
    ///
    /// **The caller must have closed its descriptor before sending this.** That
    /// ordering is the app's to keep and cannot be checked from here — a
    /// notify-first detach would put this drain on the fd while the viewer's
    /// last `read()` is still outstanding, which is the double-reader
    /// corruption in miniature.
    ///
    /// Two states arrive here, and they differ in what "resume" means:
    ///
    /// - **An acknowledged attach** released the daemon's reader for good
    ///   (`confirmAttach`), so the slot is empty and the session is taken back
    ///   through a fresh hand-over from its holder. The holder `dup`s on every
    ///   `handOverPTY`, so there is always another descriptor to be had.
    /// - **An attach that timed out unacknowledged** kept its reader, suspended
    ///   (`AttachCancelReason.unacknowledged`) — the viewer may have been
    ///   reading all along, and it evidently was, because it is detaching. That
    ///   reader is put back on the pty it never let go of.
    ///
    /// **The claim is held across the resume and cleared only after it lands**,
    /// the same invariant `cancelPendingAttach`'s resuming arm states: no window
    /// may exist in which the maps say nobody is attached while a resume is
    /// still in flight, or a concurrent `beginAttach` would pass every guard and
    /// vend a second live descriptor for a pty this call is putting a drain
    /// back on.
    ///
    /// Generation-checked, and refused rather than forced: a closing viewer's
    /// detach can arrive after a successor's attach owns the pty.
    func acceptHandback(
        terminal: Terminal, generation: UInt64, preamble: Data
    ) async throws {
        guard terminal.transport == .holder else {
            throw Error.notAHolderSession(terminalID: terminal.id)
        }
        try await takeBackFromViewer(
            terminalID: terminal.id, generation: generation, preamble: preamble)
    }

    /// Takes a session back from a viewer, with or without the viewer's help.
    ///
    /// One implementation, two callers, because the two differ in exactly one
    /// respect and share every hazard: `acceptHandback` arrives with the
    /// viewer's screen and `seizeFromDeadApp` arrives with nothing, and
    /// `preamble == nil` is that difference. Everything else — the generation
    /// check, the two arms, the claim held across the resume and dropped on the
    /// failure path, the jiggle after the resume — is identical, and a second
    /// copy of it would be a second place for the single-reader invariant to
    /// rot.
    ///
    /// With no preamble there is simply nothing to ingest: the suspended reader
    /// still holds the screen it had before the attach, a fresh adoption seeds
    /// from the holder's hand-over as any adoption does, and the jiggle is what
    /// gets a repainting program to redraw the rest.
    private func takeBackFromViewer(
        terminalID: UUID, generation: UInt64, preamble: Data?
    ) async throws {
        guard viewerAttachments[terminalID] == generation else {
            throw Error.handbackSuperseded(terminalID: terminalID, generation: generation)
        }

        let reader: HolderReader
        do {
            switch slots[terminalID] {
            case .adopted(let suspended):
                // The unacknowledged-attach arm. The reader never left the
                // descriptor, so the screen goes in before the drain restarts
                // and the resume is a restart of its thread.
                if let preamble { await suspended.ingest(preamble: preamble) }
                try await suspended.resumeDraining()
                reader = suspended
            case nil:
                reader = try await beginAdoption(
                    of: terminalID, seedingScreenWith: preamble ?? Data())
            case .adopting, .releasing:
                // Unreachable while the claim above stands — `adopt` and
                // `release` are the only writers of those states and the first
                // refuses on the claim outright, while the second clears it
                // before it takes the slot. Refused rather than assumed away:
                // whatever put a task in that slot owns this session now, and a
                // resume beside it would be the second reader.
                throw Error.superseded(terminalID: terminalID)
            }
        } catch {
            // The take-back failed — a holder busy past its retry budget, an
            // adoption that timed out, a missing rendezvous socket, a `pipe()`
            // that would not open. The claim must not outlive the attempt, for
            // the reason `cancelPendingAttach`'s failed-resume arm states: the
            // app closed its descriptor before it sent this, by the contract
            // that licenses the resume at all, so nothing else holds one and an
            // attach is a legitimate recovery. Leaving the claim standing is
            // the exact brick this method exists to prevent — undrained,
            // unwritable, and refused by `beginAttach` until the session is
            // torn down — and the app has already closed both descriptors and
            // will never send another detach.
            //
            // Generation-checked like every other clear here: a `release` or a
            // successor attach racing the failure above may already own this
            // session, and discarding its claim would let a second reader in.
            clearViewerAttachment(terminalID: terminalID, generation: generation)
            throw error
        }
        // Cleared only now, and only while it is still this attach's to clear:
        // a `release` racing the adoption above may already have taken the
        // session, and re-clearing a claim a later attach has since recorded
        // would let a third reader in beside it.
        clearViewerAttachment(terminalID: terminalID, generation: generation)
        // After the resume, never before: a repaint provoked while nothing is
        // draining sits in the tty queue instead of reaching the screen it was
        // asked for. It heals only programs that repaint, which is why the
        // preamble carries everything else.
        await reader.jiggle()
        Self.logger.info(
            """
            attach \(generation, privacy: .public) for session \
            \(terminalID.uuidString, privacy: .public) was taken back from its viewer; the daemon \
            is draining the pty again and its screen carries the \
            \(preamble?.count ?? 0, privacy: .public) bytes the viewer handed over
            """)
    }

    // MARK: - Taking a session back from an app that died

    /// Takes one session back from a viewer that is **confirmed gone**.
    ///
    /// The uncooperative mirror of `acceptHandback`, and the reason a crashed
    /// app does not brick every session it had open. Where the handback is
    /// licensed by the viewer's own detach — which proves it closed its
    /// descriptor first — this is licensed by an app-liveness verdict reached
    /// from the recorded pid, its start time and its executable
    /// (`AppLivenessArbiter`). A dead process closes its descriptors as it
    /// dies, so the same thing the detach proves is true here; nothing else in
    /// the take-back changes.
    ///
    /// **Nothing in this registry establishes the death.** It is a caller's
    /// verdict, and calling this on a live app's session is exactly the
    /// double-reader corruption the transport exists to prevent — which is why
    /// the arbitration is a separate, testable type rather than something this
    /// method could be tempted to do for itself.
    ///
    /// Generation-checked, and that matters more here than on the handback, not
    /// less: the arbitration is asynchronous, so a verdict about a dead app can
    /// land after a live one has attached the same session.
    func seizeFromDeadApp(terminalID: UUID, generation: UInt64) async throws {
        try await takeBackFromViewer(
            terminalID: terminalID, generation: generation, preamble: nil)
    }

    /// Reverts every session a confirmed-dead app was holding to daemon-read,
    /// and answers with the ones it took back.
    ///
    /// The claims are snapshotted before the loop because each take-back
    /// suspends, and `viewerAttachments` is written across every one of those
    /// suspensions; iterating the live map would be iterating a collection that
    /// mutates under it. The generation snapshotted with each session is what
    /// makes a stale entry harmless — `takeBackFromViewer` refuses any claim
    /// that has moved on since, so a session re-attached by a *new* app while
    /// this loop ran is left to that app.
    ///
    /// A take-back that fails is logged and skipped rather than aborting the
    /// pass: the sessions are independent, and one unreachable holder must not
    /// strand every other session the dead app was holding. It drops its claim
    /// on the way out regardless, so nothing stays bricked either way.
    @discardableResult
    func reclaimSessionsFromADeadApp() async -> [UUID] {
        let claims = viewerAttachments
        guard !claims.isEmpty else { return [] }
        Self.logger.info(
            """
            an app that held \(claims.count, privacy: .public) session(s) is confirmed gone; \
            taking them back
            """)
        var reclaimed: [UUID] = []
        for (terminalID, generation) in claims {
            do {
                try await seizeFromDeadApp(terminalID: terminalID, generation: generation)
                reclaimed.append(terminalID)
            } catch {
                Self.logger.error(
                    """
                    could not take session \(terminalID.uuidString, privacy: .public) back from a \
                    dead app's attach \(generation, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return reclaimed
    }

    // MARK: - Reclaiming a finished session

    /// How long the reclaimer keeps asking a holder whose pty has gone quiet
    /// whether its child has actually exited.
    ///
    /// End of file on the master and the holder's `waitpid` are two different
    /// observations of one event, made by two processes: the slave closes as
    /// the job's descriptors are released, and the holder learns of the exit on
    /// its next poll slice. So the first ask can legitimately answer "alive",
    /// and a reclaimer that gave up on it would keep the reader forever. The
    /// budget is comfortably longer than the holder's 50 ms poll slice and
    /// finite next to the ten-second window a holder keeps its rendezvous bound
    /// after its child dies.
    static let exitConfirmationBudget: Duration = .seconds(2)
    static let exitConfirmationInterval: Duration = .milliseconds(50)

    /// The callback a reader announces its exhausted drain on.
    ///
    /// Weak, and that is not a formality: the reader is owned by this registry,
    /// so a strong capture here would be a cycle keeping every reader — and its
    /// thread, its emulator and its pty dup — alive for as long as the process
    /// runs, which is the leak this whole section exists to close. The hop onto
    /// a `Task` is what keeps the drain thread free: it is the thread the
    /// release will have to join.
    private func endOfOutputNotifier(for terminalID: UUID) -> @Sendable () -> Void {
        { [weak self] in
            guard let self else { return }
            Task { await self.reclaimIfSessionEnded(terminalID) }
        }
    }

    /// **The reclaimer for a reader whose session is over.**
    ///
    /// A reader is not free. It owns a dedicated thread with a 1 MB stack, a
    /// 64 KB read buffer, an emulator holding thousands of lines of scrollback,
    /// and a dup of the pty master — and after end of file its drain thread
    /// parks on the wake pipe rather than exiting, deliberately, so that the
    /// descriptor's close stays on the stop path. Nothing but a `release`
    /// unwinds that, so without this the daemon's memory tracked sessions
    /// *adopted since it started*, not sessions alive.
    ///
    /// Two conditions, and both are load-bearing:
    ///
    ///   - **The drain has reached the end of the output.** A holder hands its
    ///     master over even after its child has exited, precisely so the bytes
    ///     the job wrote and nobody read can still be drained; releasing on the
    ///     exit alone would throw away exactly what that rule rescues. The
    ///     exhausted edge is the proof that nothing is left queued.
    ///   - **The holder says the child exited.** End of file means the last
    ///     slave closed, which is nearly always the job exiting — but a job that
    ///     closes its terminal and keeps running is entitled to, and its session
    ///     row is still live. So the holder is asked, and a child it still
    ///     reports as alive keeps its reader.
    ///
    /// The second condition is only a condition if it takes an *answer*. A
    /// holder that could not be reached has told us nothing, and a probe that
    /// failed must never be read as one that succeeded — otherwise a single
    /// dropped connection at the instant the drain runs dry collapses the two
    /// conditions back to the first, which is the shape that throws a live
    /// session's scrollback away. `exitProbeOutcome` is where each way a probe
    /// can fail is ruled on.
    ///
    /// Idempotent and safe to call for any session: it re-reads the slot on
    /// both sides of every suspension and does nothing unless the reader it
    /// finds is one that has genuinely finished.
    func reclaimIfSessionEnded(_ terminalID: UUID) async {
        guard case .adopted(let reader) = slots[terminalID] else { return }
        guard await reader.hasReachedEndOfOutput else { return }
        // Re-read after the suspension, as everywhere else here: an actor's
        // methods are not atomic across `await`, and a release or a re-adoption
        // could have taken this slot while the reader was answering.
        guard case .adopted(let stillAdopted) = slots[terminalID],
            stillAdopted === reader
        else { return }

        let status: HolderChildStatus?
        switch statuses[terminalID] {
        case .exited, .exitedStatusUnknown:
            // Already established — a job that ended before this daemon adopted
            // it reports its status on the hand-over itself.
            status = statuses[terminalID]
        case .alive, nil:
            guard
                let socketPath = try? HolderRendezvous.socketPath(
                    sessionID: terminalID, environment: environment)
            else { return }
            status = await Self.confirmChildExit(
                socketPath: socketPath,
                expecting: owner,
                budget: Self.exitConfirmationBudget,
                clock: clock)
        }

        // A child that is still running, a holder somebody else is attached to,
        // or one that answered for another installation: nothing here
        // establishes that this session is over, so its reader stays.
        guard let status else { return }
        guard case .adopted(let current) = slots[terminalID], current === reader else { return }

        statuses[terminalID] = status
        await release(terminalID: terminalID)
        Self.logger.info(
            """
            released the reader for session \(terminalID.uuidString, privacy: .public): its \
            output is drained and its job is \(String(describing: status), privacy: .public)
            """)
    }

    /// Asks a holder whether its child has exited, briefly retrying while the
    /// answer is "alive".
    ///
    /// Returns the terminal status when one is established, and nil when this
    /// registry must keep its reader — a child still running, a holder serving
    /// somebody else, or one that turns out to belong to another installation.
    ///
    /// **`describe` is safe here and nowhere earlier.** A holder winds itself
    /// down the moment an answer carrying the terminal status reaches a client,
    /// which is why adoption asks for the hand-over instead: a `describe` before
    /// the master had been taken would end the holder and take everything the
    /// job wrote and nobody read down with it. This runs only past the exhausted
    /// edge, where there is nothing left to lose — and winding the holder down
    /// is then the right outcome rather than a cost.
    ///
    /// **A failed probe is not an answer.** Only a holder that says so, or a
    /// rendezvous that provably has nobody behind it, establishes that this
    /// session is over; every other way a round trip can fail is retried within
    /// the same budget and then kept. See `exitProbeOutcome`.
    ///
    /// **A push is an answer, even when the round trip that carried it failed.**
    /// The holder pushes the exit at whichever client is connected and winds
    /// down in the same breath, so a probe that connected a moment before the
    /// child was reaped is handed the status and then finds the socket gone
    /// underneath it. That push answers no request, so `HolderClient`'s barrier
    /// retires it — into `lastPushedDescription`, which exists for exactly this
    /// and is what is read here. Without it the reclaimer discards the very
    /// fact it asked for, asks again at a rendezvous the holder has already
    /// unlinked, reads the `ENOENT` as absence, and records
    /// `exitedStatusUnknown` for a child that exited perfectly ordinarily.
    private static func confirmChildExit(
        socketPath: String,
        expecting owner: HolderOwnerToken,
        budget: Duration,
        clock: any Clock<Duration>
    ) async -> HolderChildStatus? {
        var waited: Duration = .zero
        while true {
            let client = HolderClient(socketPath: socketPath)
            do {
                let description = try await client.describe()
                await client.close()
                guard description.owner == owner else { return nil }
                switch description.status {
                case .exited, .exitedStatusUnknown:
                    return description.status
                case .alive:
                    // An exit can be pushed in the same breath as an answer
                    // that was already on the wire; the `close()` above retires
                    // it. It is about the same child and it is newer than the
                    // answer it trailed, so it supersedes it.
                    if let pushed = pushedTerminalStatus(
                        await client.lastPushedDescription, expecting: owner) {
                        return pushed
                    }
                }
            } catch {
                await client.close()
                switch exitProbeOutcome(
                    for: error,
                    pushedByTheHolder: await client.lastPushedDescription,
                    expecting: owner
                ) {
                case .established(let status):
                    return status
                case .keep:
                    return nil
                case .retry:
                    break
                }
            }
            guard waited < budget else {
                Self.logger.debug(
                    """
                    keeping the reader for a session at \(socketPath, privacy: .public): its \
                    holder never established that the job had exited within \
                    \(String(describing: budget), privacy: .public)
                    """)
                return nil
            }
            try? await clock.sleep(for: Self.exitConfirmationInterval)
            waited += Self.exitConfirmationInterval
        }
    }

    /// What one failed exit probe bears on the question "is this session over?".
    ///
    /// Three outcomes rather than two, because "the round trip failed" and "the
    /// holder is gone" are different facts and only the second one is evidence.
    enum ExitProbeOutcome: Equatable {
        /// The session is over, and this is how it ended.
        case established(HolderChildStatus)
        /// This attempt failed in a way another one might not. Ask again, on
        /// the same budget the "alive" answer is retried on.
        case retry
        /// Nothing here says the session ended. The reader stays.
        case keep
    }

    /// What a probe knows when its round trip failed **and** the holder had
    /// already pushed a status down that same connection.
    ///
    /// The push outranks the failure, and nothing else here changes. A holder
    /// that pushes has answered: it observed its own child, said how it ended,
    /// and then wound down — which is precisely why the connection the push
    /// arrived on is dead by the time the caller looks at it. Reading the
    /// failure instead would retry, find the rendezvous unlinked, and record
    /// `exitedStatusUnknown` for a status the daemon was holding all along.
    ///
    /// A push from another installation's holder is ignored, on the same rule
    /// the answered path applies to `description.owner`; so is one that says
    /// the child is still alive, which the holder never sends but which must
    /// not be read as a terminal status if it ever did.
    ///
    /// Pure, and separate from the errno classification below so that both stay
    /// pinnable case by case without standing up a holder for each one.
    static func exitProbeOutcome(
        for error: Swift.Error,
        pushedByTheHolder pushed: HolderChildDescription?,
        expecting owner: HolderOwnerToken
    ) -> ExitProbeOutcome {
        if let status = pushedTerminalStatus(pushed, expecting: owner) {
            return .established(status)
        }
        return exitProbeOutcome(for: error)
    }

    /// The terminal status in a holder's unsolicited push, if it carries one
    /// this registry may act on.
    static func pushedTerminalStatus(
        _ pushed: HolderChildDescription?, expecting owner: HolderOwnerToken
    ) -> HolderChildStatus? {
        guard let pushed, pushed.owner == owner else { return nil }
        switch pushed.status {
        case .exited, .exitedStatusUnknown:
            return pushed.status
        case .alive:
            return nil
        }
    }

    /// How a thrown `describe` bears on releasing a reader.
    ///
    /// **The two conditions are only two if the second one takes positive
    /// evidence.** A release is irreversible and asymmetric: it stops the drain
    /// thread, closes the pty dup, and drops an emulator holding everything the
    /// session ever printed, while a reader kept in error costs one emulator
    /// until its session row is closed or the daemon restarts. So a probe that
    /// merely failed must never stand in for a holder that answered — otherwise
    /// one dropped connection at the instant the drain runs dry silently
    /// collapses "end of output **and** confirmed exit" back to "end of
    /// output", which is the condition that would throw away a job that closed
    /// its terminal and kept running.
    ///
    /// Exhaustive on purpose: a new `HolderClient.Error` case must be classified
    /// here rather than inheriting a catch-all.
    ///
    /// Internal rather than private so the classification can be pinned case by
    /// case without standing up a holder for each one.
    static func exitProbeOutcome(for error: Swift.Error) -> ExitProbeOutcome {
        guard let clientError = error as? HolderClient.Error else {
            // Nothing else is thrown on this path today. Whatever a future one
            // throws, it is not an answer from a holder, so it cannot license a
            // release.
            return .keep
        }
        switch clientError {
        case .rejected:
            // A live holder, busy serving somebody else. That is evidence of
            // liveness and explicitly not of exit — the same reading `adoptAll`
            // and the row-less sweep both take of a refusal.
            return .keep

        case .cannotConnect(_, let code) where code == ENOENT || code == ECONNREFUSED:
            // Nothing is listening at the rendezvous, so the holder process is
            // gone. These are the only two errnos that mean absence rather than
            // this daemon's own failure to reach a socket, and they are read
            // that way in exactly one other place already —
            // `RowlessHolderCollector.productionHandshake` and
            // `HolderRendezvousCollector.probeForListener` — which must not
            // disagree with this one.
            //
            // Established rather than retried, because absence is monotone
            // here: this session's holder provably bound the path once, since a
            // hand-over came over it, and a holder that has gone does not come
            // back. Recorded the way `adoptAll` records the same observation —
            // `exitedStatusUnknown`, never a fabricated code, which downstream
            // could not tell from a real one.
            return .established(.exitedStatusUnknown)

        case .cannotConnect:
            // Any other errno describes *this* process failing to open a
            // connection — `EINTR`, `EMFILE`/`ENFILE` under descriptor
            // pressure, `ENOBUFS`/`ENOMEM`, `ETIMEDOUT` — and says nothing
            // whatever about the child.
            return .retry

        case .peerClosed, .transportFailed:
            // The socket was reached and the round trip failed: a hang-up
            // between the accept and the answer, `EPIPE`, `ECONNRESET`, or the
            // receive timeout expiring. A holder winding down looks exactly
            // like this, and so does one killed mid-frame — and neither says
            // whether the child exited. The next attempt either finds no
            // listener, which is established above, or gets a real answer.
            return .retry

        case .unexpectedResponse:
            // A frame that is not the description that was asked for. Retried
            // because the client's queue can carry an unsolicited push that
            // crossed the wire with somebody else's answer, and kept if it
            // persists: a protocol disagreement is a reason to stop trusting
            // the answer, never a reason to believe the job is dead.
            return .retry

        case .socketPathTooLong:
            // Deterministic, so retrying is pointless — and nothing was ever
            // asked, so there is nothing to conclude either.
            return .keep

        case .noDescriptor, .notConnected:
            // Neither is reachable from a `describe` over a client built for
            // this one call: `noDescriptor` belongs to the hand-over, and
            // `notConnected` to a client that has already been closed. Named so
            // that they are classified rather than swept into a fall-through,
            // and classified as keeps for the same reason as everything else
            // here.
            return .keep
        }
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
        // A viewer's claim does not outlive the session it was made against.
        // Every caller here is tearing the session down or handing it back, and
        // a claim left behind would refuse every later adoption of a terminal
        // ID that no longer means anything.
        pendingAttaches[terminalID] = nil
        viewerAttachments[terminalID] = nil
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
        for terminalID in Set(slots.keys).union(viewerAttachments.keys) {
            await release(terminalID: terminalID)
        }
    }
}

// MARK: - The hand-over

/// What a viewer is given when it attaches: the session's pty, the screen that
/// was already on it, and the generation that names this attach.
///
/// A value type carrying a descriptor, which is the one thing in it that has to
/// be *closed*: `ptyFD` is a fresh `dup`, and the caller owns it from the moment
/// this is returned — through the vend, and on every failure path around it.
struct HolderAttachVend: Sendable {
    /// A `dup` of the session's pty master. The caller closes it once the
    /// kernel has copied it into the viewer's descriptor table.
    let ptyFD: Int32
    /// Names this attach, so an acknowledgement or a cancellation arriving
    /// late cannot act on the attach that replaced it.
    let generation: UInt64
    /// The escape-sequence stream that reconstructs the session's screen —
    /// scrollback, modes, cursor — in the viewer's own terminal.
    let snapshotPreamble: Data
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
