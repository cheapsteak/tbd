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
        /// The daemon is shutting down: `releaseAll` has begun, so no session
        /// may be adopted or attached. A reader adopted behind that release
        /// would never be stopped, and a pty vended now would go to an app this
        /// daemon is about to stop serving. The session itself is untouched
        /// and keeps running; the next daemon adopts it. `spawn` is the one
        /// path that still builds a reader — see `isShuttingDown`.
        case daemonShuttingDown(terminalID: UUID)
        /// This registry told the session's holder to let go, and the adoption
        /// asked not to adopt such a session (`adopt(terminal:refusingLetGo:)`):
        /// the startup pass refuses every let-go, a wake a teardown's.
        case sessionLetGo(terminalID: UUID)

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
            case .daemonShuttingDown(let terminalID):
                return "the daemon is shutting down, so it can neither attach nor adopt session "
                    + "\(terminalID.uuidString); the session keeps running, and the next daemon "
                    + "will adopt it"
            case .sessionLetGo(let terminalID):
                return "this daemon told the holder of session \(terminalID.uuidString) to let go, "
                    + "so this adoption leaves it alone"
            }
        }
    }

    /// A reader, the description the hand-over rode with, and the pid of the
    /// holder that answered it.
    ///
    /// The description is not decoration: it is the one place a job that
    /// finished while no daemon was listening reports how it ended.
    ///
    /// The holder pid is read off the socket rather than off the wire — see
    /// `HolderClient.peerPID` — so it is known for every adoption, including
    /// one this daemon inherited from a previous one. It is optional because
    /// the kernel may decline to answer, and because nothing here depends on
    /// having it: the child pid is the anchor every reclaimer uses.
    private struct Adoption: Sendable {
        let reader: HolderReader
        let description: HolderChildDescription
        let holderPID: Int32?
    }

    /// The processes behind a session this registry currently holds a reader
    /// for.
    ///
    /// First-hand rather than inferred: both numbers come from the hand-over
    /// that produced the reader, so a caller holding one of these is holding
    /// what the *registry* observed, not what a row happens to say. That is
    /// what makes it usable to repair a row whose pids were lost — a wake
    /// interrupted between `spawn` publishing its reader and the row recording
    /// its pids leaves exactly that, and after a restart `adoptAll` re-adopts
    /// the holder anyway, so the reader is back while the row still names
    /// nothing.
    struct HolderAdoptedProcess: Sendable, Equatable {
        /// The holder process, when the kernel would name it.
        let holderPID: Int32?
        /// The job the holder forked. The anchor every reclaimer sweeps by.
        let childPID: Int32
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
    ///
    /// The default for the `adoptionReceiveTimeout` init parameter, which
    /// exists so a test of a wedged holder can wait a fraction of a second
    /// rather than this whole budget per row.
    static let defaultAdoptionReceiveTimeout: Duration = .seconds(2)

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

    /// How long an attach waits for the adoption it asked for before going on
    /// without one (`adoptForAttach`).
    ///
    /// An adoption the attach opens is bounded already — `busyRetryBudget` of
    /// busy answers plus one `adoptionReceiveTimeout` — so this sits above
    /// that, and bites only on what the attach cannot see the end of: an
    /// adoption it joined rather than started, or one wedged past its own
    /// bounds. It is what keeps `attach.request` from waiting on a holder
    /// indefinitely.
    static let defaultAttachAdoptionBudget: Duration = .seconds(5)

    /// The ceiling a registry's attach generations stay under: 2^48, far
    /// enough below `UInt64.max` that the count never wraps, and below 2^53,
    /// so a generation stays exact even through a `Double`.
    static let attachGenerationBaseLimit: UInt64 = 1 << 48

    /// A fresh base for one registry's attach generations, drawn uniformly
    /// from [2^32, 2^48 − 2^32).
    ///
    /// The floor is `AttachRequestResult.uniqueGenerationFloor`, so every
    /// generation this daemon mints says on its face that it came from a
    /// randomizing daemon — the contract that floor offers clients, which may
    /// safely resend a handback only for such a generation.
    /// The 2^32 of headroom under `attachGenerationBaseLimit` is four billion
    /// attaches, which no daemon process will ever mint. Why the base is
    /// random at all is on `lastAttachGeneration`.
    static func randomAttachGenerationBase() -> UInt64 {
        let lowest = AttachRequestResult.uniqueGenerationFloor
        return UInt64.random(in: lowest..<(attachGenerationBaseLimit - lowest))
    }

    /// This installation's token, compared against every holder's before it is
    /// adopted.
    let owner: HolderOwnerToken
    /// The environment the rendezvous paths are derived from and the holder
    /// processes run under. Explicit rather than ambient so tests never reach
    /// the developer's real `~/tbd` — or the developer's real login shell. In
    /// production it *is* the daemon's own environment; the base environment of
    /// the job a holder forks is derived from it by `SpawnBaseEnvironment`
    /// (see there).
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
    /// How this registry asks the kernel about, and signals, a pid.
    ///
    /// Injected rather than reached for statically because the one path that
    /// *verifies* a pid before signalling it — `abandonVerifiedJob` — is only
    /// testable if the process table can be scripted: the whole point of that
    /// check is what it does about a pid the kernel has handed to somebody
    /// else, and that is not a state a test can arrange with real processes.
    private let signaller: any ProcessSignaller
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
        /// The app's number for the `attach.request` this attach answers
        /// (`AttachRequestParams.attachSeq`), carried into the claim it
        /// becomes. Nil for an app that sends none, and a claim without one is
        /// never swept (`reconcileClaims`).
        let attachSeq: UInt64?
        let reader: HolderReader
        /// The app the descriptor was delivered to, once the attach handler
        /// has said so (`recordAttachRecipient`). Carried into the claim this
        /// attach becomes, acknowledged or timed out — see `ViewerClaim`.
        ///
        /// Nil until that record lands, and for good when the sidecar never
        /// identified its peer. Either way nothing here can say whose table
        /// the descriptor is in, so `sessionsHeld(by:)` counts a nil recipient
        /// for every app.
        var recipient: ProcessIdentity?
    }

    /// A viewer's claim on one session's pty: the attach that holds it, and
    /// the app that attach's descriptor was delivered to.
    ///
    /// **The owner is what scopes an app's death to that app.** A confirmed
    /// death licenses taking back the descriptors *that process* held — its
    /// `dup`s closed with it — and says nothing about any other process. When
    /// an old app's death is confirmed after a new app has attached its own
    /// tabs, the new app's claims are on ptys a live process is reading, and
    /// taking them back would put the daemon's drain beside it: the double
    /// reader. So the take-back selects by owner, and a claim whose owner is
    /// unknown — the sidecar could not identify its peer — is selected by no
    /// death at all, which is the posture `AppLivenessVerdict.undetermined`
    /// takes for the same reason. `reclaimSessions(heldBy:)` says what clears
    /// such a claim instead.
    ///
    /// The `attachSeq` is the pending attach's, kept so that the app's own
    /// statement of what it holds can be ordered against this attach
    /// (`reconcileClaims`).
    private struct ViewerClaim {
        let generation: UInt64
        let attachSeq: UInt64?
        var owner: ProcessIdentity?
    }

    /// Attaches vended and not yet acknowledged, by session. At most one per
    /// session: a second `beginAttach` supersedes the first, whose ack is then
    /// refused by generation.
    ///
    /// **Invariant, jointly with `viewerAttachments`: for one session, a
    /// pending entry and a viewer claim are never simultaneously live.** No
    /// single line enforces it, so it is written down here rather than left to
    /// be re-derived. `confirmAttach` clears the pending entry and then records
    /// the claim; `settleAsUnacknowledged` (the one path for
    /// `cancelPendingAttach(.unacknowledged)`, a dead app's
    /// `reclaimSessions(heldBy:)`, a late delivery's `recordAttachRecipient`
    /// and the claim sweep's `reconcileClaims`) records the claim and then
    /// clears the pending entry — both pairs synchronous, with no `await`
    /// between, so neither leaves an observable instant in which both are set;
    /// `beginAttach` refuses to record a pending entry over a standing claim
    /// and re-reads the claim after its suspension.
    ///
    /// Unreachability arguments elsewhere in this type rest on it — notably
    /// `confirmAttach`'s second guard, which is argued dead by enumerating the
    /// writers of `slots`. That enumeration is `spawn`, `beginAdoption` (which
    /// `adopt`, `adoptForAttach` and the take-back's no-reader arm all reach),
    /// `release` and its `clearIfStillReleasing`, and it does **not** include
    /// `confirmAttach`:
    /// an acknowledgement leaves the slot exactly as it found it, `.adopted`
    /// with a suspended reader. **A new writer of `slots` or of
    /// either map has to keep this true**, because the next reader will reach
    /// the guard long before reaching the chain that makes it unreachable.
    private var pendingAttaches: [UUID: PendingAttach] = [:]
    /// Sessions whose pty a viewer owns: the attach generation that owns it,
    /// and the app that attach was delivered to (`ViewerClaim`). **The daemon
    /// reads none of these**, and `adopt` refuses them, which is what keeps
    /// "one reader per pty" true across the app boundary rather than only
    /// inside this process.
    ///
    /// Never live at the same time as this session's `pendingAttaches` entry —
    /// the invariant is stated in full there.
    private var viewerAttachments: [UUID: ViewerClaim] = [:]
    /// Every app this registry has been told is confirmed gone, so that an
    /// attach naming one of them *after* its take-back ran is taken back as
    /// soon as it names it — that attach alone (`recordAttachRecipient`).
    ///
    /// The recipient of a vend is recorded one actor hop after the descriptor
    /// left — `recordAttachRecipient` follows the sidecar send — and the
    /// disconnect arbitration runs concurrently with that hop. A death
    /// confirmed inside it sweeps claims that do not name the dead app yet, and
    /// the name recorded a moment later would then hold its session for the
    /// daemon's whole life with nothing left to clear it. Remembering the death
    /// closes that window without ordering two actors against each other.
    ///
    /// Grows by one per app death this daemon confirms, which is at most one
    /// per app launch. An identity carries its start time, so a later process
    /// that reuses a remembered pid is a different entry, never a match.
    private var appsConfirmedGone: Set<ProcessIdentity> = []
    /// How many confirmed deaths this registry has acted on: one per
    /// `reclaimSessions(heldBy:)` pass.
    ///
    /// Test-facing. A delivery recorded after its recipient's death was acted
    /// on takes back the one attach it names, and runs no second pass for a
    /// death that happened once; this count is the instrument that tells the
    /// two apart, since both leave the late attach taken back.
    private(set) var confirmedDeathPasses = 0
    /// Take-backs under way, each naming the session and the attach generation
    /// it is taking back (`takeBackFromViewer`). An entry stands from that
    /// call's generation check until it returns, on every path.
    ///
    /// The claim is held across the resume by design, so the generation check
    /// alone would admit a second take-back of the same attach while the first
    /// is suspended — a viewer's handback and a seizure on its app's death
    /// arrive together when an app closes a tab and quits straight after. Two
    /// take-backs would resume one reader twice: the second would record the
    /// daemon as starting to read a pty it is already reading, which the census
    /// counts as a double reader, and would jiggle the job a second time. The
    /// generation is part of the key because a take-back of a later attach of
    /// the same session is a different take-back, and must not be turned away
    /// by one still finishing for an earlier attach.
    private var takeBacksInFlight: Set<TakeBack> = []
    private struct TakeBack: Hashable {
        let terminalID: UUID
        let generation: UInt64
    }
    /// How many take-backs have put a reader back on its pty and jiggled its
    /// job. Test-facing: one take-back of a session and two leave the same
    /// claim cleared and the same reader draining, and this count is what
    /// tells them apart.
    private(set) var takeBacksCompleted = 0
    /// The attaches a claim sweep with the flag off has already logged as ones
    /// it would take back, so each is logged once for the daemon's life rather
    /// than on every poll tick (`reportClaims`). With the flag off a
    /// candidate is never taken back, so it stays a candidate on every tick,
    /// and logging it each time would be some 1,800 persisted lines an hour
    /// for one stuck session. The sweep's result still names it every time.
    ///
    /// Bounded by pruning at the start of every sweep: an entry whose attach
    /// is no longer recorded, as a pending attach or a claim, is dropped.
    /// Generations are minted once per daemon life, so such an attach can
    /// never be selected again, and the set never holds more than the
    /// attaches that stood at the last sweep.
    private var wouldTakeBacksLogged: Set<TakeBack> = []
    /// How many "would take back" notices this registry has logged.
    /// Test-facing: two sweeps over one stuck candidate both return it, and
    /// this count is what shows the second did not log it again.
    private(set) var wouldTakeBackNotices = 0
    /// How many attaches `wouldTakeBacksLogged` remembers. Test-facing: it is
    /// what shows the pruning keeps the set bounded.
    var wouldTakeBacksRemembered: Int { wouldTakeBacksLogged.count }
    /// Mints attach generations. Monotonic for the daemon's life, so an ack or
    /// a cancel naming an older attach can always be told from one naming the
    /// current attach.
    ///
    /// **It starts at a random base, not at zero, so generations do not repeat
    /// across daemon processes.** An `attach.ready` or a `pane.detach` is
    /// addressed by generation alone, and one sent to a daemon can be
    /// delivered to its successor — a detach in flight across a restart, or an
    /// app resending a handback after it reconnects. Were every daemon to
    /// count from zero, that message could name a claim the successor minted
    /// with the same number and hand it back while a panel is still reading
    /// it: two readers on one pty. A base drawn from 48 bits makes such a
    /// collision vanishingly unlikely, and leaves the count far from both
    /// `UInt64`'s ceiling and the 2^53 past which a `Double` stops holding it
    /// exactly. The base is never below `AttachRequestResult.uniqueGenerationFloor`,
    /// which daemons that count from 1 never reach, so a generation also says
    /// which kind of daemon minted it. See `randomAttachGenerationBase()`.
    private var lastAttachGeneration: UInt64

    /// The most recent attach generation minted, or the registry's base when
    /// none has been. Test-facing: it is how a test sees the base without a
    /// holder to attach to.
    var lastMintedAttachGeneration: UInt64 { lastAttachGeneration }

    private var slots: [UUID: Slot] = [:]

    /// Set when `releaseAll` begins, and never cleared: the daemon is shutting
    /// down. From then on these refuse with `daemonShuttingDown`: `adopt` (on
    /// every pass of its loop), `beginAdoption` (so the take-back's no-reader
    /// arm too), `adoptForAttach` and `beginAttach`; and `adoptRemaining`
    /// stops. `releaseAll` releases the slots it found when it began, so a
    /// reader adopted after that would be stopped by nothing.
    ///
    /// **`spawn` is deliberately not refused.** A session created during
    /// shutdown gets its holder like any other, and the holder outlives this
    /// daemon by design — the successor adopts it at startup. The reader that
    /// spawn publishes is the one reader built after `releaseAll` begins, and
    /// it is left unstopped in a process that is about to exit.
    ///
    /// The window it covers is real and wide. `Daemon.stop()` releases every
    /// reader long before it stops the fd sidecar and the RPC socket, and an
    /// app relaunched by an update reaches the dying daemon inside it. Its
    /// attach is refused either way; the refusal has to say the daemon is
    /// going away, because `noLiveReader` reads as a session this daemon lost.
    private(set) var isShuttingDown = false

    /// Sessions whose holder this registry has told to let go — the session
    /// was torn down, or its job was ended for a park — with nothing adopted
    /// or spawned for them since. `abandon` and `abandonVerifiedJob` add a
    /// session before they release its reader. `publish` removes any mark
    /// for a freshly spawned holder, a new process for the session, but only
    /// a park's mark for an adoption, which is the same holder the mark was
    /// about (see `publish`); `clearLetGo` removes a park's mark for the wake
    /// that deliberately revives a parked session it could not adopt.
    ///
    /// Two readers refuse these sessions: an attach's on-demand adoption
    /// (`attachAdoption`) and the startup pass (`adoptOne`, through
    /// `adopt(terminal:refusingLetGo:)`), and the wake refuses a teardown's
    /// (the same call, `.teardown`). The general `adopt` does not, because
    /// a wake adopts a parked row's live holder on purpose. `abandon` empties
    /// the slot and forgets the session's status before it reaches the holder,
    /// so without this mark a session being torn down would read exactly like
    /// one whose adoption merely failed, and an adoption arriving in between
    /// would take the pty of a holder about to be told to forget it. Grows by
    /// one per holder session torn down for good, which is bounded by the
    /// sessions one daemon ever runs.
    ///
    /// Each entry carries the mark it was given (`letGoMarks`), so a caller
    /// that read the mark before suspending can tell a newer let-go from the
    /// one it saw (`clearLetGo(terminalID:ifUnchangedSince:)`), and the reason
    /// it was let go (`LetGoReason`), so a wake can tell the park it is undoing
    /// from a teardown it must not.
    private var sessionsLetGo: [UUID: LetGo] = [:]

    /// One entry of `sessionsLetGo`: when, in mark order, and why.
    struct LetGo: Sendable, Equatable {
        let mark: UInt64
        let reason: LetGoReason
    }

    /// Why this registry told a session's holder to let go.
    enum LetGoReason: Sendable, Equatable {
        /// A park ended the session's job, or a wake undid its own spawn and
        /// left the row parked. The one let-go a wake may undo: a wake exists
        /// to bring a parked session back.
        case park
        /// The session is being torn down — a delete, an archive, a transport
        /// move, a create's spawn undone, a hook tab closed. No adoption may
        /// bring it back, and a wake that finds this keeps the row parked;
        /// only a fresh spawn for the same terminal clears it (`publish`).
        case teardown
    }

    /// Mints let-go marks: one per insert into `sessionsLetGo`, increasing for
    /// the daemon's life, so no two inserts share a mark.
    private var letGoMarks: UInt64 = 0

    /// The sessions whose remembered `.exitedStatusUnknown` was recorded
    /// because nothing answered at the rendezvous — `ENOENT` or `ECONNREFUSED`
    /// on the startup pass's connect — rather than because a holder said so.
    ///
    /// Kept beside `statuses` because the two answers are not the same
    /// evidence. A holder that reports an unknown status has observed its own
    /// child and is winding down; a refused connect is also what a live holder
    /// with a full accept backlog or a stalled accept loop looks like, so only
    /// this source may be second-guessed by an attach (`attachAdoption`).
    /// Written only through `recordStatus`, which keeps the two in step.
    private var statusesFromAbsentRendezvous: Set<UUID> = []

    /// What the hand-over said about each published session's processes.
    ///
    /// Keyed and cleared exactly like `slots`' `.adopted` case, in `publish`
    /// and `release`, so it cannot outlive the reader it describes and point a
    /// caller at pids this daemon stopped observing.
    private var adoptedProcesses: [UUID: HolderAdoptedProcess] = [:]
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
    ///
    /// **A suspended reader stays counted, and both suspending paths agree on
    /// that.** An attach that timed out unacknowledged keeps its reader
    /// suspended and its loop counted; so does an attach that was
    /// acknowledged, which retains the same reader for the same reason. Only a
    /// release decrements. The number therefore means "loops this registry is
    /// on the hook for", which is what the one-reader invariant needs it to
    /// mean — a suspended reader is one this registry may put back on a pty,
    /// and a second one built beside it would be the byte theft `peakLiveDrainLoops`
    /// exists to see.
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

    /// The daemon's explicit per-session reader state, and the always-on
    /// double-reader detector built on it.
    ///
    /// **It is deliberately one ledger rather than a counter per path.** This
    /// type's reader state was previously spread across three facts that have
    /// to be read together to answer "who is on this pty" — a slot that holds
    /// a reader which may be suspended, a pending attach, and a viewer claim —
    /// and the counters beside it (`liveDrainLoops`, `peakLiveDrainLoops`)
    /// count drain loops rather than readers, so they cannot see a viewer at
    /// all. The census is the single place that says, per session, who is
    /// reading: `.daemon`, `.viewer(attach:)`, or nobody.
    ///
    /// Every transition into reading goes through `beganReading`, which asserts
    /// the session's count was zero and reports a violation rather than
    /// trusting the arbitration above to be correct. See `HolderReaderCensus`
    /// for why a violation logs instead of trapping.
    private var readerCensus = HolderReaderCensus()

    private let busyRetryBudget: Duration
    private let adoptAllBudget: Duration
    /// How long one adoption waits for a holder to answer; see
    /// `defaultAdoptionReceiveTimeout`.
    private let adoptionReceiveTimeout: Duration
    /// How long the reclaimer keeps asking whether a child has exited; see
    /// `defaultExitConfirmationBudget`.
    private let exitConfirmationBudget: Duration
    private let attachAdoptionBudget: Duration
    /// Where every reader this registry builds sends its Program Status
    /// Protocol (OSC 7501) reports, and whose gate decides whether it answers
    /// the probe. nil (tests that do not exercise the protocol) leaves OSC 7501
    /// unhandled in the daemon's emulators.
    private let programStatus: ProgramStatusStore?
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

    /// Awaited inside a take-back from a viewer, immediately before the
    /// retained reader is handed the viewer's screen and put back on its pty —
    /// the window in which the claim still stands while a take-back of it is
    /// already under way, which is where a second take-back of the same attach
    /// arrives (`takeBacksInFlight`).
    ///
    /// A seam for the same reason as the others: the real window is a single
    /// `await` on the reader's actor. Nil in production.
    private var takeBackBarrier: (@Sendable () async -> Void)?

    /// Told about a session whose job has ended: after its exit status is
    /// established and before its reader is released — the last moment the
    /// daemon's emulator holds the session's final screen. Dev servers save
    /// that screen through it (docs/specs/2026-10-11-dev-servers-design.md,
    /// "Exited servers keep their last output").
    ///
    /// It observes and nothing more: an observer can delay a reclaim but never
    /// prevent one. The release that follows skips only when the slot no
    /// longer holds the observed reader — somebody else already released it,
    /// or a re-adoption replaced it. An actor re-entrancy note: while it runs,
    /// a second `reclaimIfSessionEnded` for the same session can pass the same
    /// guards and call it again; the dev-server recorder's writes are
    /// idempotent per terminal id, so that costs one redundant save. Nil until
    /// the daemon wires it, and in every test that does not.
    private var sessionEndedObserver: (@Sendable (UUID, HolderChildStatus, HolderReader) async -> Void)?

    init(
        owner: HolderOwnerToken,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        listTerminals: @escaping @Sendable () async throws -> [Terminal],
        spawner: HolderSpawner? = nil,
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        busyRetryBudget: Duration = HolderRegistry.defaultBusyRetryBudget,
        adoptAllBudget: Duration = HolderRegistry.defaultAdoptAllBudget,
        adoptionReceiveTimeout: Duration = HolderRegistry.defaultAdoptionReceiveTimeout,
        exitConfirmationBudget: Duration = HolderRegistry.defaultExitConfirmationBudget,
        attachAdoptionBudget: Duration = HolderRegistry.defaultAttachAdoptionBudget,
        attachGenerationBase: UInt64 = HolderRegistry.randomAttachGenerationBase(),
        programStatus: ProgramStatusStore? = nil,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.programStatus = programStatus
        self.owner = owner
        self.environment = environment
        self.listTerminals = listTerminals
        self.spawner = spawner
        self.signaller = signaller
        self.canSpawn = spawner != nil
        self.busyRetryBudget = busyRetryBudget
        self.adoptAllBudget = adoptAllBudget
        self.adoptionReceiveTimeout = adoptionReceiveTimeout
        self.exitConfirmationBudget = exitConfirmationBudget
        self.attachAdoptionBudget = attachAdoptionBudget
        self.lastAttachGeneration = attachGenerationBase
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

    /// Installs the take-back barrier described above. Test-facing; production
    /// never calls it.
    func setTakeBackBarrier(_ barrier: (@Sendable () async -> Void)?) {
        takeBackBarrier = barrier
    }

    /// Installs the session-ended observer described above. The daemon calls
    /// it once at startup, before adoption, so a session that ended during an
    /// outage — its status riding the hand-over — is seen too.
    func setSessionEndedObserver(
        _ observer: (@Sendable (UUID, HolderChildStatus, HolderReader) async -> Void)?
    ) {
        sessionEndedObserver = observer
    }

    // MARK: - Reading

    /// The reader this registry holds for a session, or nil if it holds none.
    ///
    /// **A returned reader may be suspended**, and most attached sessions'
    /// readers are: `beginAttach` suspends the drain, and neither the
    /// acknowledgement nor a timed-out attach resumes or discards it. So this
    /// answers "which emulator is this session's" rather than "who is on the
    /// pty". Writing through a suspended reader is fine — the one-reader
    /// invariant is about readers, and several writers on a pty master are not
    /// a hazard. Anything that needs the *drain* must ask `isDraining`, and
    /// anything that needs to know who owns the pty must ask
    /// `viewerAttachment(for:)`.
    ///
    /// A session still being adopted answers nil: there is no reader yet. So
    /// does one being released — its reader may still be draining, but it is
    /// on its way out and nothing new should be routed to it.
    func reader(for terminalID: UUID) -> HolderReader? {
        guard case .adopted(let reader) = slots[terminalID] else { return nil }
        return reader
    }

    /// The processes behind a session this registry holds a published reader
    /// for, or nil when it holds none.
    ///
    /// Answers for exactly the sessions `reader(for:)` answers for, because it
    /// is written and cleared in the same two places. A caller that has just
    /// seen a live reader can therefore rely on this answering, and one that
    /// has not must be prepared for nil.
    func adoptedProcess(for terminalID: UUID) -> HolderAdoptedProcess? {
        adoptedProcesses[terminalID]
    }

    /// The last status a holder reported for a session, if one ever has.
    func lastKnownStatus(for terminalID: UUID) -> HolderChildStatus? {
        statuses[terminalID]
    }

    /// Records a status for a session exactly as a holder's own report would
    /// have. Test-facing; production never calls it.
    ///
    /// It exists because `.exited(code:)` is otherwise out of reach of a unit
    /// test. Production writes this map in three places and each needs a real
    /// holder on the other end of a socket: the adoption hand-over, the
    /// startup sweep, and `reclaimIfSessionEnded`'s exit probe. A rendezvous
    /// with nothing bound at it reaches `.exitedStatusUnknown` without a
    /// holder — that is how `HolderReconcileInventoryTests` gets its status —
    /// but a *confirmed* exit code requires a holder that answers, which is a
    /// live test. So the readers that branch on `.exited` had no way to be
    /// pinned at this level against the other three answers they must let
    /// through.
    ///
    /// `nil` clears the entry, which is the distinct "no holder ever reported"
    /// state rather than a fourth status.
    ///
    /// `fromAbsentRendezvous: true` records it as the startup pass records an
    /// `ENOENT` or `ECONNREFUSED` at the rendezvous — the one source an attach
    /// may second-guess (`statusesFromAbsentRendezvous`).
    func recordStatusForTesting(
        _ status: HolderChildStatus?, for terminalID: UUID, fromAbsentRendezvous: Bool = false
    ) {
        recordStatus(status, for: terminalID, fromAbsentRendezvous: fromAbsentRendezvous)
    }

    /// The one writer of `statuses`, so `statusesFromAbsentRendezvous` can
    /// never describe a status that has since been replaced.
    private func recordStatus(
        _ status: HolderChildStatus?, for terminalID: UUID, fromAbsentRendezvous: Bool = false
    ) {
        statuses[terminalID] = status
        if fromAbsentRendezvous {
            statusesFromAbsentRendezvous.insert(terminalID)
        } else {
            statusesFromAbsentRendezvous.remove(terminalID)
        }
    }

    /// The mark this session was let go under, or nil when it is not let go
    /// (`sessionsLetGo`). A caller that suspends before acting on a let-go
    /// reads this first and passes it to `clearLetGo(terminalID:ifUnchangedSince:)`.
    func letGoMark(for terminalID: UUID) -> UInt64? {
        sessionsLetGo[terminalID]?.mark
    }

    /// The let-go this session is under — its mark and its reason — or nil.
    func letGo(for terminalID: UUID) -> LetGo? {
        sessionsLetGo[terminalID]
    }

    /// Marks a session let go under a fresh mark, for `reason`.
    private func markLetGo(_ terminalID: UUID, reason: LetGoReason) {
        letGoMarks += 1
        sessionsLetGo[terminalID] = LetGo(mark: letGoMarks, reason: reason)
    }

    /// Records the processes behind a session as an adoption's publish
    /// would, without a reader. Test-facing; production never calls it. It
    /// exists for the same reason as `recordStatusForTesting`: an adopted
    /// process is otherwise reachable only through a live holder hand-over.
    func recordAdoptedProcessForTesting(_ process: HolderAdoptedProcess?, for terminalID: UUID) {
        adoptedProcesses[terminalID] = process
    }

    // MARK: - The reader-count assertion

    /// Who the daemon's explicit reader state says is on a session's pty right
    /// now — the daemon, a named viewer's attach, or nobody.
    ///
    /// **The one honest answer to that question in this type.** `reader(for:)`
    /// answers for a suspended reader as well as a draining one, and
    /// `viewerAttachment(for:)` answers "a viewer *may* hold this pty",
    /// deliberately conflating an acknowledged attach with one that timed out.
    /// Neither is "who is reading", and a caller that needs that was previously
    /// obliged to compose it out of both plus `isDraining`.
    func ptyReader(for terminalID: UUID) -> PtyReaderRole? {
        readerCensus.reader(of: terminalID)
    }

    /// How many transitions into reading have found this session's pty already
    /// being read — the double-reader violation count, monotonic for the
    /// daemon's life.
    ///
    /// Zero is the only acceptable value. It is what the transport's graduation
    /// reads, and it is asserted on directly rather than through log output,
    /// because a detector whose only interface is a log line is a detector no
    /// test can pin.
    var readerCensusViolations: Int { readerCensus.violations }

    /// The most recent violation, for a caller that wants to name the two
    /// readers rather than merely count them.
    var lastReaderCensusViolation: HolderReaderCensus.Violation? {
        readerCensus.lastViolation
    }

    /// The census line as it is logged. Test-facing, and the thing a soak
    /// reader greps for.
    var readerCensusSummary: String { readerCensus.summary }

    /// How often the census summary is logged.
    ///
    /// Hourly, matching `OrphanGC`'s cadence, and sized against the question it
    /// answers rather than against any event: "did the soak see any
    /// violations?" is asked weeks later, of the log archive, so what matters
    /// is that a persisted line exists in every window a reader might look at —
    /// not that it is fresh. One `.notice` per hour per daemon is a rounding
    /// error in that archive, and `.notice` is the lowest level macOS persists
    /// to disk by default, which is what makes the record durable at all.
    static let readerCensusReportInterval: Duration = .seconds(3600)

    /// Logs the census summary once.
    ///
    /// `.notice` rather than `.info` deliberately: only `.notice` and above are
    /// persisted by default, and a summary that lives in an in-memory ring
    /// buffer cannot answer a question asked weeks after the soak.
    func logReaderCensusSummary() {
        // A local first: `Logger`'s interpolation is an escaping autoclosure,
        // and reading an actor-isolated property through one needs an explicit
        // `self` capture that would outlive this turn.
        let line = readerCensus.summary
        Self.logger.notice("\(line, privacy: .public)")
    }

    /// Logs the census summary now and then on a tick, until cancelled.
    ///
    /// The durable half of the detector. The per-violation `.error` line says
    /// what went wrong; this says that something was watching and what it has
    /// seen in total — which is the half an absence of errors cannot supply.
    ///
    /// Sleeps on the registry's injected clock, so a test can drive a whole
    /// reporting schedule without waiting on a wall clock.
    func reportReaderCensusPeriodically(
        every interval: Duration = HolderRegistry.readerCensusReportInterval
    ) async {
        logReaderCensusSummary()
        while !Task.isCancelled {
            try? await clock.sleep(for: interval)
            guard !Task.isCancelled else { break }
            logReaderCensusSummary()
        }
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
    /// **The grid tracks the viewer for the whole of an attach**, confirmed or
    /// not, because the reader is retained across both. So a session a viewer
    /// is resizing keeps a daemon-side emulator at the width the viewer is
    /// painting at, which is what makes the fallback screen (`staleDaemon`) and
    /// the next adoption's re-render read correctly instead of wrapping every
    /// later line at a width nobody is looking at.
    ///
    /// A session with no reader is skipped silently: there is no grid to
    /// reshape and no descriptor to size. That is a session being adopted or
    /// released, not an attached one.
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
    ///
    /// Not refused while the daemon shuts down, unlike adoption — see
    /// `isShuttingDown`.
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
                // The job has only just been forked, and nothing has read its
                // pty yet, so whatever it says about its modes on startup lands
                // in this emulator — and so does every cell it ever paints,
                // which is what makes this emulator's screen the child's own.
                observedChildFromStart: true,
                onEndOfOutput: endOfOutputNotifier(for: terminalID),
                programStatus: programStatusTap(for: terminalID))
        } catch {
            // The holder is up and supervising a job that no row will ever
            // name, so leaving it would orphan both. Best-effort, and the
            // standing guarantee is still a reconciler (Milestone B).
            await dispose(handle: spawned.handle)
            throw error
        }

        publish(adoption, for: terminalID, spawned: true)
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
    ///
    /// Marked let go (`sessionsLetGo`) before anything suspends, so an
    /// attach's on-demand adoption cannot reach for the holder in the gap
    /// between the release and the `forget`. `reason` defaults to
    /// `.teardown`, the let-go nothing may undo; only a park passes `.park`.
    func abandon(
        terminalID: UUID, handle: HolderHandle, reason: LetGoReason = .teardown
    ) async {
        markLetGo(terminalID, reason: reason)
        await release(terminalID: terminalID)
        recordStatus(nil, for: terminalID)
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
    func abandon(terminal: Terminal, reason: LetGoReason = .teardown) async -> String? {
        await abandon(
            terminalID: terminal.id,
            holderPID: terminal.holderPID,
            childPID: terminal.childPID,
            reason: reason)
    }

    /// The same teardown for a caller that no longer has a row to read the pids
    /// back from.
    ///
    /// The pre-session hook tab is the case: its worktree row can be cascaded
    /// away mid-wait, taking every terminal row with it, and what is left is
    /// the descriptor phase 2b returned. The rendezvous still comes from this
    /// registry's own environment, so the caller needs nothing but the pids it
    /// was handed at spawn.
    func abandon(
        terminalID: UUID, holderPID: Int32?, childPID: Int32?, reason: LetGoReason = .teardown
    ) async -> String? {
        let socketPath: String
        do {
            socketPath = try HolderRendezvous.socketPath(
                sessionID: terminalID, environment: environment)
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
            terminalID: terminalID,
            handle: HolderHandle(
                holderPID: holderPID ?? 0,
                childPID: childPID ?? 0,
                socketPath: socketPath),
            reason: reason)
        guard childPID != nil else {
            return "terminal \(terminalID) recorded no child pid, so its holder was told to "
                + "let go but the job it forked was not killed"
        }
        return nil
    }

    /// The hook-tab spelling of the teardown above: the same `forget`, the
    /// same reap, and a job kill that happens **only** once the pid has been
    /// proved to still name the process this session recorded.
    ///
    /// A hook tab is the one holder session whose job has usually already
    /// exited by the time anything tears it down — the setup tab's auto-close
    /// fires *because* the hook finished — so the window between the job's
    /// death and this teardown is wide open, and a pid the kernel reissued in
    /// it is the pid `dispose` would signal. `jobProcessGroup`'s `pgid ==
    /// childPID` test does not close that: a reissued pid that is its own
    /// session leader (any shell a stranger's `forkpty` made) passes it, and
    /// the group-widening `SIGKILL` then takes that whole stranger's session.
    ///
    /// So the identity check the reaper's holder leg and the park ladder both
    /// apply is applied here too, against the same anchor and the same window,
    /// and with the same asymmetry: **every answer but `.same` keeps.** A
    /// missed job is one process a later sweep can still find; a wrong kill
    /// destroys somebody else's work on a machine running dozens of sessions.
    ///
    /// It is deliberately *not* `dispose`'s behaviour, and must not be folded
    /// into it. `isHolderChildExecutable` admits agents and login shells only,
    /// so a plain holder terminal whose shell exec'd into `htop` would never be
    /// killed on `terminal.delete` if the general path adopted this gate. Hook
    /// tabs are narrower by construction: their job is the shell wrapper this
    /// daemon composed, and it is the only thing that may ever run there.
    ///
    /// The holder is told to let go, and reaped, on every path — including the
    /// ones that decline to kill. Leaving the daemon holding a pty whose job it
    /// cannot identify would keep a reader alive over a session nobody can
    /// describe, and the holder is this daemon's own child, so nothing else can
    /// collect it.
    ///
    /// Returns a description of what was left running, or nil when the whole
    /// teardown was carried out.
    func abandonVerifiedJob(
        terminalID: UUID, holderPID: Int32?, childPID: Int32?, childStartedAt: Date?
    ) async -> String? {
        let socketPath: String
        do {
            socketPath = try HolderRendezvous.socketPath(
                sessionID: terminalID, environment: environment)
        } catch {
            return "\(error)"
        }
        // Let go before anything suspends, as in `abandon`. A hook tab's
        // teardown is never undone.
        markLetGo(terminalID, reason: .teardown)
        await release(terminalID: terminalID)
        recordStatus(nil, for: terminalID)

        let client = HolderClient(socketPath: socketPath)
        try? await client.forget()
        await client.close()

        // `dispose` resolves the job's process group *before* the `forget`, so
        // that a group member which ignored the hangup is still reachable after
        // the leader died of it. There is no such pre-resolve here, and there
        // cannot be: this path may only signal a pid it has identified, and a
        // group whose leader is gone is a group whose members it cannot
        // identify at all. `signaller.forceKill` widens to the group on its own
        // when the pid is still there to name one, which is every case this
        // path is allowed to kill in.
        let left = killVerifiedJob(
            terminalID: terminalID, childPID: childPID, childStartedAt: childStartedAt)
        await reap(holderPID: holderPID ?? 0)
        return left
    }

    /// The decision half of `abandonVerifiedJob`: whether this pid may be
    /// signalled, and what to say when it may not.
    ///
    /// Split out so the ladder reads top to bottom in the order its gates
    /// actually fail — no pid, no anchor, a corpse, a stranger — and so the
    /// `forget`/reap either side of it stay unconditional.
    private func killVerifiedJob(
        terminalID: UUID, childPID: Int32?, childStartedAt: Date?
    ) -> String? {
        guard let childPID, childPID > 1 else {
            // `0` is the sentinel a row that never recorded a pid decodes to,
            // and signalling it would reach the daemon's own process group —
            // the hazard `jobProcessGroup` guards in the same words.
            return "terminal \(terminalID) recorded no child pid, so its holder was told to "
                + "let go but the job it forked was not killed"
        }
        guard let childStartedAt else {
            Self.logger.warning(
                """
                hook terminal \(terminalID, privacy: .public) recorded no child start time, so \
                pid \(childPID, privacy: .public) could not be identified and was left alone
                """)
            return "terminal \(terminalID) recorded no child start time, so the job at pid "
                + "\(childPID) could not be proved to be ours and was left running"
        }
        // A corpse first, and for the reason `holderChildDisposition` asks it
        // first: `ps` prints a zombie's command in parentheses, which the
        // executable gate below would read as a stranger's. A zombie is past
        // its last instruction and its number cannot be reissued while the
        // entry stands, so there is nothing here to kill and nothing to fear.
        if signaller.stat(childPID)?.hasPrefix("Z") == true { return nil }
        let verdict = ProcessIdentityCheck.verify(
            pid: childPID,
            startedWithin: AgentReaper.defaultHolderIdentityWindow,
            of: childStartedAt,
            executableIsAcceptable: AgentReaper.isHolderChildExecutable,
            signaller: signaller)
        switch verdict {
        case .same:
            // `forceKill` widens to the process group exactly as `killJob`
            // does — `ProductionProcessSignaller.signal` group-kills when the
            // pid is its own group leader, which a `forkpty` job always is —
            // so a job that declined the hangup is still reclaimed with its
            // descendants.
            signaller.forceKill(childPID)
            return nil
        case .notRunning:
            // The job exited on its own, which on the auto-close path is the
            // ordinary case rather than an exception.
            return nil
        case .startTimeUnreadable, .startTimeMismatch, .commandUnreadable, .foreignExecutable:
            Self.logger.warning(
                """
                hook terminal \(terminalID, privacy: .public) left pid \
                \(childPID, privacy: .public) running: it did not verify as this session's job \
                (\(String(describing: verdict), privacy: .public))
                """)
            return "terminal \(terminalID) left its job running: pid \(childPID) did not verify "
                + "(\(String(describing: verdict)))"
        }
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
    ///
    /// Refused once the daemon is shutting down (`isShuttingDown`), on every
    /// pass: a call that waited out a release has very likely waited out
    /// `releaseAll`'s.
    ///
    /// A session this registry told to let go is adopted all the same; the
    /// callers that must refuse one pass `refusingLetGo`.
    @discardableResult
    func adopt(terminal: Terminal) async throws -> HolderReader {
        try await adopt(terminal: terminal, refusingLetGo: .none)
    }

    /// Which let-go marks an adoption refuses (`sessionsLetGo`).
    enum LetGoRefusal: Sendable, Equatable {
        /// None: the general `adopt`.
        case none
        /// A teardown's only. The wake that adopts a parked row's live holder
        /// may revive a park's let-go — undoing a park is what it is for —
        /// but never a teardown's.
        case teardown
        /// Every let-go: the startup pass.
        case any
    }

    /// `adopt`, refusing the let-go marks `refusingLetGo` names, on every pass
    /// of the loop, with `sessionLetGo`.
    ///
    /// The startup pass refuses `.any`: it adopts from a row list read when it
    /// began, and `adoptRemaining` runs after the socket is bound, so a
    /// terminal deleted or parked in the meantime is still on its list. The
    /// wake refuses `.teardown`: a delete or an archive takes no hibernation
    /// claim and can overlap it. Either way, adopting would take the pty of a
    /// holder being told to forget it. Checked inside the loop rather than
    /// once by the caller, because a call that waits out a release can find
    /// the mark set by the teardown that release belonged to.
    ///
    /// Internal rather than private only so a test can see the refusal by
    /// name: the startup pass (`adoptOne`) logs and swallows every error.
    @discardableResult
    func adopt(terminal: Terminal, refusingLetGo: LetGoRefusal) async throws -> HolderReader {
        guard terminal.transport == .holder else {
            throw Error.notAHolderSession(terminalID: terminal.id)
        }
        let terminalID = terminal.id
        adoptionCallsEntered += 1

        while true {
            guard !isShuttingDown else {
                throw Error.daemonShuttingDown(terminalID: terminalID)
            }
            if let letGo = sessionsLetGo[terminalID] {
                switch refusingLetGo {
                case .any:
                    throw Error.sessionLetGo(terminalID: terminalID)
                case .teardown where letGo.reason == .teardown:
                    throw Error.sessionLetGo(terminalID: terminalID)
                case .teardown, .none:
                    break
                }
            }
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
    ///
    /// Refused while the daemon shuts down, here as well as in its callers,
    /// so that no adoption — the take-back's no-reader arm included — can open
    /// a hand-over behind `releaseAll`. (`spawn` takes its hand-over without
    /// coming through here; `isShuttingDown` says why it is not refused.)
    private func beginAdoption(
        of terminalID: UUID, seedingScreenWith preamble: Data = Data()
    ) async throws -> HolderReader {
        guard !isShuttingDown else { throw Error.daemonShuttingDown(terminalID: terminalID) }
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: terminalID, environment: environment)
        let expected = owner
        let budget = busyRetryBudget
        let receiveTimeout = adoptionReceiveTimeout
        let clock = self.clock
        let notifyEndOfOutput = endOfOutputNotifier(for: terminalID)
        let statusTap = self.programStatusTap(for: terminalID)
        let task = Task<Adoption, Swift.Error> {
            try await Self.attach(
                terminalID: terminalID,
                socketPath: socketPath,
                expecting: expected,
                busyRetryBudget: budget,
                receiveTimeout: receiveTimeout,
                clock: clock,
                // The child has been running without this emulator — since the
                // last daemon, or since a viewer took the pty — so its mode
                // setup was consumed by somebody else and the fresh terminal
                // this builds starts on defaults, permanently. Its grid starts
                // blank for the same reason, and a TUI above it repaints only
                // the cells it is changing, so the screen this reader projects
                // holds the child's text only where the child has since written
                // it. A preamble, when there is one, restores the values and
                // not their provenance: the viewer that captured it was itself
                // seeded by this session's attach preamble, so it can hand back
                // no more than the daemon gave it.
                observedChildFromStart: false,
                onEndOfOutput: notifyEndOfOutput,
                programStatus: statusTap,
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
        publish(adoption, for: terminalID, spawned: false)
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
    /// caller is obliged to finish them. Outside startup a session is adopted
    /// only when something asks for it — an attach (`adoptForAttach`), or a
    /// wake that finds the session's holder already running — so a row
    /// abandoned here that nobody opens would stay undrained for the process's
    /// whole life, and an undrained pty master does not merely cost a screen,
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
            // A shutdown refuses every adoption, so the rest of the pass would
            // only log one refusal per row. The next daemon adopts them.
            guard !isShuttingDown else {
                Self.logger.info(
                    """
                    stopped the deferred adoption with \(rows.count - index, privacy: .public) \
                    holder sessions left: the daemon is shutting down
                    """)
                return
            }
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
            _ = try await adopt(terminal: terminal, refusingLetGo: .any)
        } catch let error as Error {
            // A holder that named another installation answered correctly;
            // it is simply not ours. Left running, and not recorded as
            // exited — it is somebody else's live session. A session let go
            // since the pass began, and a shutdown, land here too.
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
                recordStatus(status, for: terminal.id, fromAbsentRendezvous: true)
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
        observedChildFromStart: Bool,
        onEndOfOutput: (@Sendable () -> Void)?,
        programStatus: HolderProgramStatusTap? = nil,
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
                    observedChildFromStart: observedChildFromStart,
                    onEndOfOutput: onEndOfOutput,
                    programStatus: programStatus,
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
        observedChildFromStart: Bool,
        onEndOfOutput: (@Sendable () -> Void)?,
        programStatus: HolderProgramStatusTap? = nil,
        seedingScreenWith preamble: Data = Data()
    ) async throws -> Adoption {
        try await take(
            terminalID: terminalID,
            over: HolderClient(socketPath: socketPath, receiveTimeout: receiveTimeout),
            expecting: owner,
            observedChildFromStart: observedChildFromStart,
            onEndOfOutput: onEndOfOutput,
            programStatus: programStatus,
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
    ///
    /// - Parameter observedChildFromStart: whether the reader this builds will
    ///   have seen every byte its child ever wrote — `true` for a session this
    ///   daemon just spawned, whose startup `DECSET`s are still queued in the
    ///   pty, and `false` for one adopted while it was already running, whose
    ///   mode setup was read by somebody else long ago and whose screen this
    ///   emulator therefore starts blank underneath. It rides all the way to
    ///   `TerminalScreen.modesObserved` and `TerminalScreen.contentObserved` —
    ///   one fact, both consequences — and it is named at every call site
    ///   rather than defaulted, because a default is right on one of these two
    ///   paths and a silent lie on the other.
    private static func take(
        terminalID: UUID,
        over client: HolderClient,
        expecting owner: HolderOwnerToken,
        observedChildFromStart: Bool,
        onEndOfOutput: (@Sendable () -> Void)? = nil,
        programStatus: HolderProgramStatusTap? = nil,
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
        // Read while the connection is still open — `LOCAL_PEERPID` is a
        // property of the socket, not of the path — and after a verb has been
        // answered, so it names a peer that has provably spoken the protocol.
        let holderPID = await client.peerPID()
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
            onEndOfOutput: onEndOfOutput,
            programStatus: programStatus,
            observedChildFromStart: observedChildFromStart)
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
        return Adoption(reader: reader, description: description, holderPID: holderPID)
    }

    // MARK: - Adopting for an attach

    /// Adopts a session an attach is asking for, when this registry is not
    /// reading it yet and nothing says it should not be read.
    ///
    /// **Startup is not the only moment a session can be found unadopted.**
    /// `adoptAll` walks away from a holder that is busy past its budget,
    /// silent past its receive timeout, or unreachable for a reason that says
    /// nothing about the job (`EMFILE`, a hang-up mid-frame); its budget
    /// defers the rest to `adoptRemaining`; and a take-back whose hand-over
    /// failed leaves a session with no reader at all. Each of those is a live
    /// session nobody drains, and `beginAttach` can only refuse it as
    /// `noLiveReader`. An attach is somebody asking to see that session, which
    /// makes it the moment to try again.
    ///
    /// It never builds a reader for a session that is on its way out. Each
    /// refusal is a quiet return rather than a throw, so `beginAttach` reports
    /// `noLiveReader` — which the attach handler already turns into "ended"
    /// when the holder is gone. `attachAdoption(for:holderIsLive:)` lists
    /// them; they are asked synchronously, before any task, timer or
    /// continuation exists, so the common answers — already adopted above all
    /// — cost this call nothing more.
    ///
    /// `rowPermits` is the caller's own refusal, asked only before this call
    /// would open a hand-over of its own: the attach handler passes the
    /// row-level check only it can make (`mayAdoptForAttach`), so an
    /// already-adopted session never pays for it, and joining an adoption
    /// already in flight — a wake's, the startup pass's — never asks it,
    /// because a join opens no hand-over. `holderIsLive` says
    /// whether a pid names a running `TBDHolder`; `attachAdoption` says which
    /// refusal it can lift.
    ///
    /// **Bounded.** The attach waits `attachAdoptionBudget` at most. An
    /// adoption still running then is not abandoned: it finishes in its own
    /// task and publishes as any adoption does, so the next attach finds its
    /// reader. This one goes on without it.
    ///
    /// Throws `daemonShuttingDown`, and `notAHolderSession` for a row on
    /// another transport. Any other failure to adopt is logged and left for
    /// `beginAttach` to report.
    func adoptForAttach(
        terminal: Terminal,
        holderIsLive: @escaping @Sendable (Int32) -> Bool = { _ in false },
        rowPermits: @Sendable () async -> Bool = { true }
    ) async throws {
        let terminalID = terminal.id
        guard terminal.transport == .holder else {
            throw Error.notAHolderSession(terminalID: terminalID)
        }
        guard !isShuttingDown else { throw Error.daemonShuttingDown(terminalID: terminalID) }
        let rowPermitted: Bool
        switch attachAdoption(for: terminal, holderIsLive: holderIsLive) {
        case .notNeeded:
            return
        case .declined(let reason):
            Self.logger.debug(
                """
                an attach did not adopt session \(terminalID.uuidString, privacy: .public): \
                \(reason, privacy: .public)
                """)
            return
        case .join:
            // Joining an adoption already in flight opens no hand-over, so
            // the row gate has nothing to refuse: the wake or the startup pass
            // that started it already decided this session may be read.
            rowPermitted = false
        case .begin:
            guard await rowPermits() else { return }
            rowPermitted = true
        }

        let attempt = Task {
            try await self.adoptUnlessLeaving(
                terminal, holderIsLive: holderIsLive, mayBegin: rowPermitted)
        }
        let budget = attachAdoptionBudget
        guard let settled = await Self.settlement(of: attempt, within: budget, clock: clock) else {
            Self.logger.notice(
                """
                an attach waited \(String(describing: budget), privacy: .public) for session \
                \(terminalID.uuidString, privacy: .public) to be adopted and went on without it; \
                the adoption finishes on its own
                """)
            return
        }
        switch settled {
        case .success(let declined):
            guard let declined else { return }
            Self.logger.debug(
                """
                an attach did not adopt session \(terminalID.uuidString, privacy: .public): \
                \(declined, privacy: .public)
                """)
        case .failure(let error):
            if let refusal = error as? Error, case .daemonShuttingDown = refusal {
                throw refusal
            }
            Self.logger.info(
                """
                an attach could not adopt session \(terminalID.uuidString, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// What an attach's on-demand adoption should do about one session.
    private enum AttachAdoption {
        /// A reader is published; there is nothing to adopt.
        case notNeeded
        /// Something says this session must not be adopted now, and why.
        case declined(String)
        /// Another caller's adoption is in flight, past its own gates; join it.
        case join(Task<Adoption, Swift.Error>)
        /// The slot is vacant and nothing stands in the way; open a hand-over.
        case begin
    }

    /// Every synchronous gate of the on-demand path, in one place, so that
    /// `adoptForAttach` can answer the common cases before it builds anything
    /// and `adoptUnlessLeaving` can re-ask the same questions in the stretch
    /// that acts on them.
    ///
    ///   - A viewer claim or a pending attach: `beginAttach` refuses by name.
    ///   - A reader being **released**: a teardown, a reclaim or a shutdown is
    ///     stopping it.
    ///   - A holder this registry **told to let go** (`sessionsLetGo`), with
    ///     nothing adopted or spawned for the session since.
    ///   - A job that has **ended** (`statuses`). A holder whose child has
    ///     exited still hands its master over, to rescue the output nobody
    ///     read, so an adoption would build a reader over a finished session.
    ///
    /// `.exited` is the holder's own report and always refuses, and so does
    /// an `.exitedStatusUnknown` the holder reported: it observed its own
    /// child, and is winding down. One exception, for the one status that is
    /// not a report: an `.exitedStatusUnknown` the startup pass recorded
    /// because nothing answered at the rendezvous
    /// (`statusesFromAbsentRendezvous`). Darwin refuses a connect at once when
    /// a live holder's accept backlog is full or its accept loop has stalled,
    /// so read as final, that one refusal would make a running session
    /// un-adoptable for the daemon's whole life. It is lifted only while the
    /// row's holder pid verifiably names this session's running holder
    /// (`holderVerifiablyRunning`); if the hand-over then fails as unreachable
    /// too, the attach is refused exactly as before.
    private func attachAdoption(
        for terminal: Terminal, holderIsLive: (Int32) -> Bool
    ) -> AttachAdoption {
        let terminalID = terminal.id
        if viewerAttachments[terminalID] != nil { return .declined("a viewer holds its pty") }
        if pendingAttaches[terminalID] != nil {
            return .declined("an attach of it is already pending")
        }
        switch slots[terminalID] {
        case .adopted:
            return .notNeeded
        case .releasing:
            return .declined("its reader is being released")
        case .adopting(let task):
            return .join(task)
        case nil:
            if sessionsLetGo[terminalID] != nil {
                return .declined("this daemon told its holder to let go")
            }
            switch statuses[terminalID] {
            case .exited:
                return .declined("its holder reported the job exited")
            case .exitedStatusUnknown:
                guard statusesFromAbsentRendezvous.contains(terminalID) else {
                    return .declined("its holder reported the job ended")
                }
                guard holderVerifiablyRunning(terminal, holderIsLive: holderIsLive) else {
                    return .declined("its job has ended and its holder is not running")
                }
            case .alive, nil:
                break
            }
            return .begin
        }
    }

    /// The acting half of `adoptForAttach`: every gate again, then the
    /// adoption, in one stretch on the actor, so nothing can change between
    /// the gates and the slot they decide on. Answers why it adopted nothing,
    /// or nil once the session has a published reader.
    ///
    /// Run from `adoptForAttach`'s own task rather than inline, which is why
    /// it re-asks everything that call already asked: by the time the task is
    /// scheduled, a release, an abandonment or a shutdown may have begun.
    ///
    /// `mayBegin` is whether the caller's row gate was asked and permitted an
    /// adoption. A call that set out to join one in flight never asked it, so
    /// if that adoption has ended by now it opens no hand-over of its own.
    private func adoptUnlessLeaving(
        _ terminal: Terminal, holderIsLive: (Int32) -> Bool, mayBegin: Bool
    ) async throws -> String? {
        let terminalID = terminal.id
        guard !isShuttingDown else { throw Error.daemonShuttingDown(terminalID: terminalID) }
        switch attachAdoption(for: terminal, holderIsLive: holderIsLive) {
        case .notNeeded:
            return nil
        case .declined(let reason):
            return reason
        case .join(let task):
            // Someone else's adoption, already past every gate of its own.
            // Joining it opens no second hand-over.
            _ = try await joinInFlightAdoption(task, for: terminalID)
            return nil
        case .begin:
            guard mayBegin else {
                return "the adoption it set out to join had ended, and the row gate was not asked"
            }
            _ = try await beginAdoption(of: terminalID)
            return nil
        }
    }

    // MARK: - Adopting for a wake

    /// `adopt`, waited for no longer than `attachAdoptionBudget`: the result,
    /// or nil when the budget passed first and the adoption is still running.
    ///
    /// For the wake that finds a parked row's holder already running. That
    /// wake holds its claim and its caller's RPC for as long as it waits, and
    /// a holder busy past `busyRetryBudget` and then silent for an
    /// `adoptionReceiveTimeout` costs both several seconds. Bounded the way
    /// the attach is, for the same reason and with the same consequence: an
    /// adoption still running at the limit finishes in its own task and
    /// publishes as any adoption does.
    func adoptWithinAttachBudget(terminal: Terminal) async -> Result<HolderReader, Swift.Error>? {
        let attempt = Task { try await self.adopt(terminal: terminal, refusingLetGo: .teardown) }
        return await Self.settlement(of: attempt, within: attachAdoptionBudget, clock: clock)
    }

    /// Drops the let-go mark on a session something has deliberately brought
    /// back to life.
    ///
    /// The wake that un-parks a row over a live holder it did not adopt is the
    /// caller: it leaves the adoption to the next attach, and an attach
    /// refuses a session this registry told to let go — as a park that reached
    /// `abandon` did. Without this, the row would be awake and refused by
    /// every attach for the daemon's whole life.
    ///
    /// **Only a park's let-go, and only the mark the caller saw, is cleared.**
    /// `mark` is what `letGoMark(for:)` answered before the caller suspended,
    /// nil if the session was not let go then. A newer let-go — a delete or an
    /// archive whose `abandon` ran while the wake was adopting — carries a
    /// newer mark and is left standing, and a `.teardown` let-go is never
    /// cleared at all: either would let an attach or the startup pass adopt a
    /// holder that is being told to forget its session.
    func clearLetGo(terminalID: UUID, ifUnchangedSince mark: UInt64?) {
        guard let mark, let current = sessionsLetGo[terminalID],
              current.mark == mark, current.reason == .park else { return }
        sessionsLetGo[terminalID] = nil
    }

    /// Whether `terminal`'s recorded holder pid names this session's running
    /// holder: `holderIsLive` — a running `TBDHolder` by name, the attach
    /// handler's own check — and a holder that started within
    /// `AgentReaper.defaultHolderIdentityWindow` of the row's identity anchor
    /// (`HolderChildIdentity.anchor(of:)`: when its job started, or the row's
    /// creation for a row that never recorded that), the anchor every other
    /// holder identity check measures against. A holder forks its job as it
    /// starts, so the two instants sit together; a pid the kernel has handed
    /// to some other holder does not. An unreadable start time is uncertainty,
    /// and answers no.
    private func holderVerifiablyRunning(
        _ terminal: Terminal, holderIsLive: (Int32) -> Bool
    ) -> Bool {
        guard let holderPID = terminal.holderPID, holderPID > 1,
              holderIsLive(holderPID) else { return false }
        guard let holderStartedAt = signaller.startTime(holderPID) else { return false }
        return abs(holderStartedAt.timeIntervalSince(HolderChildIdentity.anchor(of: terminal)))
            <= AgentReaper.defaultHolderIdentityWindow
    }

    /// The result of `work`, or nil when `limit` passes on `clock` first.
    ///
    /// `work` is not cancelled when the limit wins. It runs to its own end in
    /// its own task, which is what an adoption needs: walking away from a
    /// hand-over mid-flight would strand the descriptor it is receiving. The
    /// timer is cancelled when the work wins, so no sleep outlives the race.
    ///
    /// A race of two unstructured tasks onto one continuation rather than a
    /// task group, because a group waits for every child before it returns,
    /// and that would make the limit wait for the work.
    static func settlement<Success: Sendable>(
        of work: Task<Success, Swift.Error>,
        within limit: Duration,
        clock: any Clock<Duration>
    ) async -> Result<Success, Swift.Error>? {
        typealias Outcome = Result<Success, Swift.Error>?
        return await withCheckedContinuation { (continuation: CheckedContinuation<Outcome, Never>) in
            let settled = ContinuationGuard()
            let timer = Task {
                do {
                    try await clock.sleep(for: limit)
                } catch {
                    // Cancelled: the work settled first.
                    return
                }
                if settled.claim() { continuation.resume(returning: nil) }
            }
            Task {
                let result = await work.result
                timer.cancel()
                if settled.claim() { continuation.resume(returning: result) }
            }
        }
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
    ///
    /// Refused first, and by name, once the daemon is shutting down: the
    /// reader is being released, and the app should hear that this daemon is
    /// going away rather than that the session has no reader.
    ///
    /// `attachSeq` is the app's number for the request this answers
    /// (`AttachRequestParams.attachSeq`). It is recorded on the pending attach
    /// and kept on the claim the attach becomes, and only an attach that
    /// carries one can be swept (`reconcileClaims`).
    func beginAttach(
        terminalID: UUID, attachSeq: UInt64? = nil,
        maxScrollbackLines: Int = HolderReader.scrollbackLines
    ) async throws -> HolderAttachVend {
        guard !isShuttingDown else { throw Error.daemonShuttingDown(terminalID: terminalID) }
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
        pendingAttaches[terminalID] = PendingAttach(
            generation: generation, attachSeq: attachSeq, reader: reader)

        let ptyFD: Int32
        do {
            ptyFD = try await reader.suspendDraining()
        } catch {
            clearPendingAttach(terminalID: terminalID, generation: generation)
            throw error
        }
        // The daemon is off this pty from here, and only from here: a
        // `suspendDraining` that returns has provably seen its drain thread
        // leave the descriptor, while one that throws leaves the daemon reading
        // — `.drainDidNotQuiesce` means the thread is still in there, and
        // `.cannotDuplicate` resumes before it throws. So the departure is
        // recorded on the success path alone, and the catch above deliberately
        // records nothing.
        //
        // Recorded before the vend below, so the vend's own assertion is
        // answered by the ledger rather than by this call's knowledge of its
        // own ordering — which is the entire point of having a ledger.
        readerCensus.stoppedReading(.daemon, session: terminalID)
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
        // The viewer's transition into reading, and the one the daemon cannot
        // observe from the outside: from the moment this descriptor leaves the
        // process the app may be reading it, and nothing on this side will ever
        // be told. If the daemon were still counted here — a vend that skipped
        // the quiesce, an arbitration step that resumed behind this call's back
        // — this is where it is seen.
        readerCensus.beganReading(
            .viewer(attach: generation), session: terminalID, at: "attach-vend")
        Self.logger.info(
            """
            vended the pty for session \(terminalID.uuidString, privacy: .public) to a viewer as \
            attach \(generation, privacy: .public); the daemon's reader is suspended and will not \
            resume without an answer about that viewer
            """)
        return HolderAttachVend(
            ptyFD: ptyFD, generation: generation, snapshotPreamble: preamble)
    }

    /// The viewer's acknowledgement: it is reading the descriptor, so this
    /// session is now the viewer's to read, and the daemon's reader stays
    /// suspended and retained.
    ///
    /// **Suspended, not stopped, and that is the whole of what an
    /// acknowledgement decides.** `beginAttach` already took the daemon off the
    /// pty; what is left to settle is whether the emulator it built goes with
    /// it. It does not. That emulator holds the session's screen as it stood at
    /// the attach, and it is the only store there is whenever the viewer cannot
    /// answer for itself — a machine read of an open session falls back to it
    /// (`source: .staleDaemon`), the input path asks it what modes the child is
    /// in, and a take-back resumes it instead of opening a second hand-over.
    /// Stopping it would make every one of those answers an empty screen or an
    /// error naming the wrong cause. The cost is one emulator per attached
    /// session, which is what the transport budgets for every session anyway.
    ///
    /// A suspended reader still holds its descriptor, so the daemon can still
    /// *write* to the pty — the one-reader invariant is about readers, and
    /// several writers on a pty master are fine. What it must never do is
    /// resume the drain without evidence the viewer is gone; `acceptHandback`
    /// and `seizeFromDeadApp` are the only two callers that carry it.
    ///
    /// The jiggle goes here rather than at the vend, and that ordering is the
    /// point of it: a program repaints on `SIGWINCH` into the tty, and the ack
    /// is the first moment anybody is certainly there to receive the repaint.
    /// The reader owns the descriptor the ioctl rides on, and keeps owning it.
    ///
    /// Generation-checked. A stale ack — a superseded viewer's, or a duplicate
    /// — is refused rather than allowed to hand away a pty a live attach is
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
    ///   and the ones that would install a different reader refuse outright
    ///   while a pending entry exists (`adopt`, `adoptForAttach`,
    ///   `beginAttach`). This method does not write `slots` at all — it
    ///   leaves the slot exactly as it found it — so it is not itself one of
    ///   the writers to enumerate.
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
        // deliberate 10 ms sleep. Two callers resume inside that window and
        // both must find the session already marked as the viewer's: an
        // `adopt` waiting on this actor, and a `beginAttach` parked between its
        // quiesce and its guard, which would otherwise hand out a second live
        // descriptor for a pty this acknowledgement has just given away.
        viewerAttachments[terminalID] = ViewerClaim(
            generation: generation, attachSeq: pending.attachSeq, owner: pending.recipient)

        await reader.jiggle()

        // The slot is left as it was found: `.adopted(reader)`, with the reader
        // suspended since `beginAttach` and nothing here resuming it. Nothing
        // decrements `liveDrainLoops` either, which is deliberate and matches
        // the `.unacknowledged` arm — see the counter's own comment.
        Self.logger.info(
            """
            attach \(generation, privacy: .public) for session \
            \(terminalID.uuidString, privacy: .public) was acknowledged; the daemon's reader is \
            suspended and retained, and the viewer owns the pty
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
            // The descriptor never left this process, which is the whole of
            // what this arm knows and the only evidence that takes a viewer off
            // the census without its cooperation. Recorded before the resume,
            // so the resume asserts against the ledger and a resume that had
            // somehow been licensed without this evidence would be caught.
            readerCensus.stoppedReading(.viewer(attach: generation), session: terminalID)
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
                readerCensus.beganReading(
                    .daemon, session: terminalID, at: "resume-after-failed-vend")
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
            settleAsUnacknowledged(terminalID: terminalID, pending: pending)
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

    /// Turns a pending attach into the claim an unacknowledged one leaves: the
    /// viewer may hold the pty, so the daemon neither reads it nor vends it
    /// again. The claim keeps the recipient the pending attach recorded, so an
    /// app's death can still find it.
    ///
    /// The claim is recorded before the pending entry is dropped, so the two
    /// hand off with nothing between them — not even a synchronous instant in
    /// which both maps are empty. Synchronous, and the caller must have read
    /// `pending` from the map with no `await` since.
    private func settleAsUnacknowledged(terminalID: UUID, pending: PendingAttach) {
        viewerAttachments[terminalID] = ViewerClaim(
            generation: pending.generation, attachSeq: pending.attachSeq,
            owner: pending.recipient)
        clearPendingAttach(terminalID: terminalID, generation: pending.generation)
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
        guard viewerAttachments[terminalID]?.generation == generation else { return }
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
        viewerAttachments[terminalID]?.generation
    }

    /// The app this session's viewer claim is recorded against, or nil when
    /// there is no claim or its owner is unknown. Test-facing, beside
    /// `viewerAttachment(for:)`: the generation says *that* the pty is held,
    /// and this says whose death would release it.
    func viewerAttachmentOwner(for terminalID: UUID) -> ProcessIdentity? {
        viewerAttachments[terminalID]?.owner
    }

    /// The generation of the attach vended for this session and not yet
    /// acknowledged, or nil when there is none. Test-facing, beside
    /// `viewerAttachment(for:)`: it tells an attach still pending from the
    /// claim it can become.
    func pendingAttachGeneration(for terminalID: UUID) -> UInt64? {
        pendingAttaches[terminalID]?.generation
    }

    /// Records a viewer claim with no attach behind it. Test-facing, and
    /// production never calls it: it lets a tier-1 test state "these sessions
    /// are held by these apps" without a holder, a pty or a reader, which every
    /// real claim needs. Only for a session with no pending attach — the
    /// invariant on `pendingAttaches` is the caller's to keep here.
    func recordViewerClaimForTesting(
        terminalID: UUID, generation: UInt64, owner: ProcessIdentity?,
        attachSeq: UInt64? = nil
    ) {
        viewerAttachments[terminalID] = ViewerClaim(
            generation: generation, attachSeq: attachSeq, owner: owner)
    }

    /// Records an attach as vended and not yet acknowledged, with no slot
    /// behind it. Test-facing, and production never calls it — `beginAttach`
    /// is the only real writer. It lets a tier-1 test state "this descriptor
    /// went out and its recipient is (or is not yet) recorded" without a
    /// holder or a pty; `reader` can be one that never started. Only for a
    /// session with no viewer claim — the invariant on `pendingAttaches` is
    /// the caller's to keep here.
    func recordPendingAttachForTesting(
        terminalID: UUID, generation: UInt64, reader: HolderReader,
        recipient: ProcessIdentity?, attachSeq: UInt64? = nil
    ) {
        pendingAttaches[terminalID] = PendingAttach(
            generation: generation, attachSeq: attachSeq, reader: reader,
            recipient: recipient)
    }

    /// Records which app a vended descriptor was delivered to, and answers
    /// with the take-back that recording started, if it started one.
    ///
    /// The attach handler calls this after the sidecar send, with the identity
    /// the send itself read for the connection it wrote on
    /// (`FDVendingServer.sendReportingRecipient`) — never one looked up before
    /// it, which a reconnect in between would make a stranger's. By the time
    /// it lands the attach may be still pending (the ordinary case: the ack
    /// needs the generation, and only the RPC response carries it), already a
    /// claim, or gone — released or superseded — in which case nothing names
    /// it any more and there is nothing to record.
    ///
    /// **A nil recipient records nothing**, and the attach stays ownerless: no
    /// app's death will take it back. `reclaimSessions(heldBy:)` lists what
    /// does clear it, and says why a death must not.
    ///
    /// A recipient this registry has already been told is gone is taken back
    /// — see `appsConfirmedGone` for the window that closes — and **only the
    /// one attach this call names is.** The death itself was acted on when it
    /// was confirmed: that pass took back everything then recorded against the
    /// app, and remembering it is what routes this late name here. Running the
    /// pass again would announce a second death that never happened, and would
    /// reach again for claims of that app whose take-back may still be in
    /// flight — each is held across its resume, by design — leaving
    /// `takeBacksInFlight` to turn each of those away.
    ///
    /// **Synchronous, so the record is all a caller waits for.** The attach
    /// RPC awaits this before it replies, and a take-back resumes a reader and
    /// jiggles its job — work no reply should stand behind. So the record
    /// lands here, in one stretch on the actor, and a late delivery's
    /// take-back runs in a task of this registry's own
    /// (`takeBackLateDelivery`), which re-checks the generation as every
    /// take-back does: a claim that moved on while it waited is refused, not
    /// seized. The returned task is that take-back, for a caller that must
    /// see it finish; nil when the record needed none.
    @discardableResult
    func recordAttachRecipient(
        _ recipient: ProcessIdentity?, terminalID: UUID, generation: UInt64
    ) -> Task<Void, Never>? {
        guard let recipient else { return nil }
        let recipientIsGone = appsConfirmedGone.contains(recipient)
        if var pending = pendingAttaches[terminalID], pending.generation == generation {
            pending.recipient = recipient
            if recipientIsGone {
                // Its acknowledgement cannot come now, so it is settled the
                // way the ready-timeout would settle it — the way the death's
                // own pass settles every unacknowledged attach it finds — and
                // the take-back below finds a claim to take.
                settleAsUnacknowledged(terminalID: terminalID, pending: pending)
            } else {
                pendingAttaches[terminalID] = pending
            }
        } else if viewerAttachments[terminalID]?.generation == generation {
            // Defensive: no production ordering reaches this arm. Nothing turns
            // this attach into a claim before this record lands: the ack needs
            // the generation only the attach RPC's reply carries, and the reply
            // waits for this record; the attach handler arms the ready-timeout
            // after it; and a death's pass settles only attaches whose
            // recipient is already recorded. Kept so that an ordering that does
            // reach it still records the owner a death needs, rather than
            // leaving the claim ownerless.
            viewerAttachments[terminalID]?.owner = recipient
        } else {
            return nil
        }
        guard recipientIsGone else { return nil }
        Self.logger.notice(
            """
            attach \(generation, privacy: .public) for session \
            \(terminalID.uuidString, privacy: .public) was delivered to app pid \
            \(recipient.pid, privacy: .public), whose death was already confirmed and acted on \
            before this delivery was recorded; taking back this one session, and only it
            """)
        return Task {
            await self.takeBackLateDelivery(
                terminalID: terminalID, generation: generation, recipient: recipient)
        }
    }

    /// The take-back `recordAttachRecipient` starts for an attach delivered to
    /// an app already confirmed gone: that one session, under the generation
    /// the record named. Generation-checked through `seizeFromDeadApp`, so an
    /// attach that moved on before this ran — released, or re-attached by a
    /// live app — is left alone.
    private func takeBackLateDelivery(
        terminalID: UUID, generation: UInt64, recipient: ProcessIdentity
    ) async {
        do {
            try await seizeFromDeadApp(terminalID: terminalID, generation: generation)
            Self.logger.notice(
                """
                took session \(terminalID.uuidString, privacy: .public) back from attach \
                \(generation, privacy: .public), delivered late to app pid \
                \(recipient.pid, privacy: .public)
                """)
        } catch {
            Self.logger.error(
                """
                could not take session \(terminalID.uuidString, privacy: .public) back from \
                attach \(generation, privacy: .public), delivered late to dead app pid \
                \(recipient.pid, privacy: .public): \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// How many sessions `app` holds a descriptor for, or may yet turn out
    /// to: claims recorded against it, attaches vended to it and not yet
    /// acknowledged, and **every attach whose recipient is not recorded yet.**
    ///
    /// The disconnect arbitration's stopping condition. An app holding nothing
    /// has nothing its death could license taking back, and it cannot come to
    /// hold anything new without a sidecar connection — whose own departure is
    /// reported and arbitrated in its turn.
    ///
    /// The last term is what keeps that condition honest. The recipient of a
    /// vend is recorded one actor hop after the descriptor left
    /// (`recordAttachRecipient` follows the sidecar send), and the departure
    /// that started an arbitration can be reported inside that hop: an app
    /// killed straight after a re-attach leaves exactly that. Read as nobody's,
    /// the attach would let the watch end on "holds nothing" while the app is
    /// still exiting; the record would then name an app no watch is looking
    /// at and that was never confirmed gone, and the attach would time out
    /// into a claim held for the daemon's whole life by a process that no
    /// longer exists. Counted for every app, it keeps each watch going until
    /// the record lands and says whose it is.
    ///
    /// The cost is bounded by the attach itself. It counts this way from
    /// `beginAttach` until the record that follows its send, a span the send's
    /// own retry budget bounds. One whose peer was never identified records
    /// nobody, and counts until it is acknowledged or its ready-timeout
    /// settles it into an ownerless claim, which counts for no app. Meanwhile
    /// a watch on some other app runs a check or two longer than it had to.
    func sessionsHeld(by app: ProcessIdentity) -> Int {
        viewerAttachments.values.filter { $0.owner == app }.count
            + pendingAttaches.values.filter { $0.recipient == nil || $0.recipient == app }.count
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
    /// **Every attach keeps its reader**, suspended, whether or not it was
    /// acknowledged — an acknowledgement decides who reads the pty, not who
    /// owns the emulator. So the ordinary take-back ingests the viewer's screen
    /// into that reader and resumes the drain it never restarted, rather than
    /// opening a second hand-over against a master this registry already holds.
    /// The reader kept its descriptor throughout, so the resume needs nothing
    /// from the holder — not even a reachable rendezvous socket.
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
    /// One implementation for every take-back, because they differ in exactly
    /// one respect and share every hazard: `acceptHandback` arrives with the
    /// viewer's screen, while `seizeFromDeadApp` and the claim sweep
    /// (`reconcileClaims`) arrive with nothing, and `preamble == nil` is that
    /// difference. Everything else — the generation check, the two arms, the
    /// claim held across the resume and dropped on the failure path, the
    /// jiggle after the resume — is identical, and a second copy of it would
    /// be a second place for the single-reader invariant to rot.
    ///
    /// With no preamble there is simply nothing to ingest: the suspended reader
    /// still holds the screen it had before the attach, and the jiggle is what
    /// gets a repainting program to redraw the rest.
    ///
    /// **One take-back per attach at a time.** Because the claim stands until
    /// the resume lands, a second take-back of the same attach — the viewer's
    /// handback and its app's seizure, arriving together — would pass the
    /// generation check while the first is suspended and resume the same
    /// reader again. So the first marks the attach in flight
    /// (`takeBacksInFlight`) and a second returns at once, without touching
    /// the census, the reader or the claim. It returns rather than throws:
    /// the take-back its caller asked for is under way, and the one in flight
    /// owns the outcome — including dropping the claim if it fails.
    ///
    /// **The `.adopted` arm serves every attach**, acknowledged or timed out,
    /// because both keep their reader suspended on a descriptor they never let
    /// go of. It is the ordinary path, and the strictly better one: no holder
    /// round trip, no second `dup`, no second drain loop, and the screen the
    /// daemon had at the attach is still underneath whatever the preamble puts
    /// on top of it.
    ///
    /// **The `nil` arm is defensive and expected to be dead.** A claim can only
    /// outlive its reader if something emptied the slot while the claim stood,
    /// and the one writer that empties a slot — `release` — clears the claim
    /// first. It is kept rather than turned into a `throw` because the
    /// alternative to a fresh adoption here is a session bricked for the
    /// daemon's whole life, and a hand-over from the holder is a legitimate
    /// recovery whenever that state is somehow reached.
    private func takeBackFromViewer(
        terminalID: UUID, generation: UInt64, preamble: Data?
    ) async throws {
        guard viewerAttachments[terminalID]?.generation == generation else {
            throw Error.handbackSuperseded(terminalID: terminalID, generation: generation)
        }
        // Marked before the first suspension below and cleared on every way
        // out; see "One take-back per attach at a time" in the header.
        let takeBack = TakeBack(terminalID: terminalID, generation: generation)
        guard takeBacksInFlight.insert(takeBack).inserted else {
            Self.logger.notice(
                """
                attach \(generation, privacy: .public) for session \
                \(terminalID.uuidString, privacy: .public) is already being taken back from its \
                viewer; leaving the outcome to the take-back in flight
                """)
            return
        }
        defer { takeBacksInFlight.remove(takeBack) }
        // The viewer leaves the census here, on its caller's evidence and
        // nothing weaker: `acceptHandback` arrives only after the viewer closed
        // its descriptor (the ordering the app owns and this process cannot
        // check), `seizeFromDeadApp` only after an app-liveness verdict that
        // the process holding it is gone, and the claim sweep only on the app's
        // own statement that it holds no descriptor for this session, made
        // after it closed any it received (`reconcileClaims`). All three mean
        // the same thing to the ledger — nothing outside this process is on
        // the pty — and recording it before the resume is what makes the
        // resume's assertion meaningful rather than self-certifying.
        readerCensus.stoppedReading(.viewer(attach: generation), session: terminalID)

        let reader: HolderReader
        do {
            switch slots[terminalID] {
            case .adopted(let suspended):
                // Every attach's arm. The reader never left the descriptor, so
                // the screen goes in before the drain restarts and the resume is
                // a restart of its thread. The barrier is where a test parks a
                // take-back with its claim still standing; see `takeBackBarrier`.
                await takeBackBarrier?()
                if let preamble { await suspended.ingest(preamble: preamble) }
                try await suspended.resumeDraining()
                readerCensus.beganReading(
                    .daemon, session: terminalID, at: "handback-resume")
                reader = suspended
            case nil:
                // Defensive; see the header. A claim with no reader under it
                // means something emptied the slot without clearing the claim.
                reader = try await beginAdoption(
                    of: terminalID, seedingScreenWith: preamble ?? Data())
            case .adopting, .releasing:
                // Unreachable while the claim above stands — the adoptions
                // (`adopt`, `adoptForAttach`) and `release` are the only
                // writers of those states, and the adoptions refuse on the
                // claim outright, while `release` clears it before it takes
                // the slot. Refused rather than assumed away:
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
        takeBacksCompleted += 1
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

    /// Reverts every session the confirmed-dead `app` was holding to
    /// daemon-read, and answers with the ones it took back. **Only that app's.**
    ///
    /// The death is evidence about one process: its descriptors closed with
    /// it. Every other claim in this registry — a newer app's above all, which
    /// is exactly what stands here when an old app's death is confirmed late —
    /// is on a pty somebody else may be reading, so the selection is by
    /// `ViewerClaim.owner` and a claim with no recorded owner is never
    /// selected. The death is also remembered (`appsConfirmedGone`), so an
    /// attach whose recipient is recorded only after this pass ran is taken
    /// back when it is.
    ///
    /// **An ownerless claim is cleared by its viewer, its session or the
    /// daemon — never by a death.** It arises when the sidecar could not
    /// identify the peer a descriptor went to (`FDVendingServer` retries that
    /// read back to back before giving up, so a `ps` spawn refused once does
    /// not leave one). Three things clear it: the viewer's own detach
    /// (`acceptHandback`), which proves the descriptor closed; the session's
    /// `release`; and a daemon restart, since claims live only in this
    /// registry's memory. A death cannot, because nothing here says whose
    /// death would close that descriptor: the claim may belong to an app that
    /// is alive and reading right now, and taking it back on some other app's
    /// death puts the daemon's drain beside that reader — the double reader
    /// this transport cannot recover from. Leaving it standing costs one
    /// session undrained until one of the three arrives, which is a stall, not
    /// corruption.
    ///
    /// Attaches vended to the dead app and never acknowledged go too. Their
    /// acknowledgement cannot come now, so each is settled exactly as the
    /// ready-timeout would settle it — into a claim — and taken back with the
    /// rest. Left pending, the timeout would turn each into a claim a moment
    /// later, after this pass had finished looking.
    ///
    /// The claims are snapshotted before the loop because each take-back
    /// suspends, and `viewerAttachments` is written across every one of those
    /// suspensions; iterating the live map would be iterating a collection that
    /// mutates under it. The generation snapshotted with each session is what
    /// makes a stale entry harmless — `takeBackFromViewer` refuses any claim
    /// that has moved on since, so a session re-attached by a *new* app while
    /// this loop ran is left to that app. A session whose take-back is already
    /// under way — the dead app's own handback, sent as it closed a tab just
    /// before it died — is left to that take-back and answered as taken back.
    ///
    /// A take-back that fails is logged and skipped rather than aborting the
    /// pass: the sessions are independent, and one unreachable holder must not
    /// strand every other session the dead app was holding. It drops its claim
    /// on the way out regardless, so nothing stays bricked either way.
    @discardableResult
    func reclaimSessions(heldBy app: ProcessIdentity) async -> [UUID] {
        appsConfirmedGone.insert(app)
        confirmedDeathPasses += 1
        let unacknowledged = pendingAttaches.filter { $0.value.recipient == app }
        for (terminalID, pending) in unacknowledged {
            settleAsUnacknowledged(terminalID: terminalID, pending: pending)
        }
        let claims = viewerAttachments
            .filter { $0.value.owner == app }
            .map { (terminalID: $0.key, generation: $0.value.generation) }
        let othersStanding = viewerAttachments.count - claims.count
        Self.logger.notice(
            """
            app pid \(app.pid, privacy: .public) is confirmed gone holding \
            \(claims.count, privacy: .public) session(s) \
            (\(unacknowledged.count, privacy: .public) never acknowledged); taking those back and \
            leaving the \(othersStanding, privacy: .public) other viewer claim(s) to their owners
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

    // MARK: - Taking back what a live app says it no longer holds

    /// One attach a claim sweep may take back: the session, the attach
    /// generation, and — when the attach is still pending — the entry to
    /// settle into a claim first.
    private struct SweepCandidate {
        let terminalID: UUID
        let generation: UInt64
        let pending: PendingAttach?
    }

    /// Takes back the claims `app` owns on sessions it says it no longer
    /// holds, and answers with them: the registry's half of
    /// `holder.reconcileClaims` while `holder_claim_reconcile_enabled` is on,
    /// and the reconciler for a viewer claim whose handback, or whose attach
    /// reply, was lost while its app lives
    /// (docs/specs/2026-10-25-holder-claim-reconcile-design.md). While the
    /// flag is off the handler asks `reportClaims` instead, which selects by
    /// pid and changes nothing.
    ///
    /// **Its authority is the one a handback carries: the app's own statement
    /// that it holds no descriptor for a session, made only after it closed
    /// any it received.** `held` is that statement — every session the app
    /// holds a descriptor for or has an attach in flight for — and
    /// `throughSeq` is the highest `attachSeq` it had sent when it built it.
    /// An attach is a candidate only when all four hold:
    ///
    /// 1. it is `app`'s: a claim whose `owner` is `app`, or a pending attach
    ///    whose recorded `recipient` is. A pending attach with no recipient —
    ///    its descriptor not yet sent, or sent to a peer the sidecar could not
    ///    name — is skipped, since nothing says whose table it is in;
    /// 2. it carries an `attachSeq` at or below `throughSeq`. One above it was
    ///    numbered after `held` was built, so `held` says nothing about it,
    ///    whichever of the two requests arrived first; one without a seq is an
    ///    older app's, and is never swept;
    /// 3. its session is not in `held`;
    /// 4. no take-back of that attach is already in flight
    ///    (`takeBacksInFlight`). The one under way owns the outcome, and a
    ///    handback's carries the screen this sweep cannot.
    ///
    /// **The candidates are selected in one synchronous stretch at entry**,
    /// before anything here suspends, so the set acted on is the set those
    /// conditions describe.
    ///
    /// Then:
    ///
    /// - **Only the candidate pending attaches are settled** into claims, the
    ///   way the ready-timeout would settle each, and before the first
    ///   suspension. Never every pending attach the app has, as a death's pass
    ///   does: an attach on a session in `held` is one the app is still
    ///   waiting on, and settling it would refuse its `attach.ready`.
    /// - Each candidate is then taken back through `takeBackFromViewer` with
    ///   no preamble, the path a dead app's seizure takes: the reader the
    ///   attach suspended goes back on the pty, and the job is jiggled so a
    ///   program that repaints on `SIGWINCH` redraws. Not through
    ///   `seizeFromDeadApp` itself, whose contract is a death verdict this
    ///   sweep does not have; the statement above stands in for it.
    /// - Before each take-back the claim is re-read, because every take-back
    ///   before it suspended: one that moved on to another attach, or away
    ///   from `app`, is left alone, and the take-back re-checks the generation
    ///   again itself.
    ///
    /// `takenBack` lists the take-backs that returned without throwing, as
    /// `reclaimSessions(heldBy:)` counts them — including one that found a
    /// take-back of the same attach begun since the selection, which owns it.
    /// A take-back that throws is logged and skipped, and drops its claim on
    /// the way out, as every failed take-back does. Either way the attach is
    /// no longer a candidate, so the next sweep's cheap gate
    /// (`hasCandidates`) does not pass it again. `wouldTakeBack` is always
    /// empty. Whatever is not a candidate is left exactly as it was.
    func reconcileClaims(
        heldBy app: ProcessIdentity, held: Set<UUID>, throughSeq: UInt64
    ) async -> HolderClaimSweep {
        let candidates = sweepCandidates(held: held, throughSeq: throughSeq, ownedBy: { $0 == app })
        let appPID = app.pid
        forgetEndedWouldTakeBacks()
        // Still the stretch the selection ran in, so every `pending` here is
        // the value just read from the map, as `settleAsUnacknowledged`
        // requires. Settled before the first take-back suspends, so the
        // ready-timeout cannot turn one into a claim behind this pass's back.
        for candidate in candidates {
            if let pending = candidate.pending {
                settleAsUnacknowledged(terminalID: candidate.terminalID, pending: pending)
            }
        }
        var takenBack: [UUID] = []
        for candidate in candidates {
            let terminalID = candidate.terminalID
            let generation = candidate.generation
            guard let claim = viewerAttachments[terminalID], claim.generation == generation,
                  claim.owner == app
            else {
                Self.logger.info(
                    """
                    attach \(generation, privacy: .public) of session \
                    \(terminalID.uuidString, privacy: .public) moved on while the claim sweep for \
                    app pid \(appPID, privacy: .public) ran; leaving it alone
                    """)
                continue
            }
            do {
                try await takeBackFromViewer(
                    terminalID: terminalID, generation: generation, preamble: nil)
                takenBack.append(terminalID)
                Self.logger.notice(
                    """
                    took back attach \(generation, privacy: .public) of session \
                    \(terminalID.uuidString, privacy: .public) from app pid \
                    \(appPID, privacy: .public), which says it no longer holds it
                    """)
            } catch {
                Self.logger.error(
                    """
                    could not take back attach \(generation, privacy: .public) of session \
                    \(terminalID.uuidString, privacy: .public) from app pid \
                    \(appPID, privacy: .public), which says it no longer holds it: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return HolderClaimSweep(takenBack: takenBack, wouldTakeBack: [])
    }

    /// Whether a sweep from the app with this pid could find anything to take
    /// back: some claim owned by a process with that pid, or some pending
    /// attach delivered to one, that also meets the other three conditions of
    /// `reconcileClaims` — whether `reportClaims` would name anything, without
    /// logging it.
    ///
    /// The cheap gate in front of a sweep. It reads only this registry, so a
    /// caller can ask it on every poll tick before it reads the flag or
    /// resolves the pid to an identity, which spawns `ps`. In the steady
    /// state every live panel's session is in `held` and this answers false.
    /// Matching by pid alone can only over-answer — a reused pid passes here
    /// and matches no owner in a sweep that acts — and never under-answers,
    /// because a sweep's owner always has the pid it resolved from.
    func hasCandidates(ownedByPID pid: Int32, held: Set<UUID>, throughSeq: UInt64) -> Bool {
        !sweepCandidates(held: held, throughSeq: throughSeq, ownedBy: { $0.pid == pid }).isEmpty
    }

    /// Names the claims a sweep from the app with this pid would take back,
    /// and changes nothing: the registry's half of `holder.reconcileClaims`
    /// while `holder_claim_reconcile_enabled` is off.
    ///
    /// **It matches the owner by pid alone**, as `hasCandidates` does, and
    /// applies the other three conditions of `reconcileClaims` unchanged.
    /// Matching by identity would need the pid resolved, which spawns `ps`
    /// twice and blocks, and with the flag off a candidate is never taken
    /// back: it stays a candidate on every 2 s tick until the app quits, so
    /// it would be resolved again on every one. The price is that a claim
    /// owned by an earlier process that held the same pid is named too. It is
    /// only named: a sweep that acts resolves the identity first, and leaves
    /// that claim alone.
    ///
    /// Each attach is logged at `.notice` as one the sweep would take back the
    /// first time a report names it, and not again for the daemon's life
    /// (`wouldTakeBacksLogged`), since a candidate the flag leaves standing is
    /// named on every tick. Every report still lists it in `wouldTakeBack`;
    /// `takenBack` is always empty.
    func reportClaims(
        ownedByPID pid: Int32, held: Set<UUID>, throughSeq: UInt64
    ) -> HolderClaimSweep {
        forgetEndedWouldTakeBacks()
        let candidates = sweepCandidates(
            held: held, throughSeq: throughSeq, ownedBy: { $0.pid == pid })
        for candidate in candidates {
            let terminalID = candidate.terminalID
            let generation = candidate.generation
            // Once per attach: the result names it on every report, the log
            // only on the first.
            guard wouldTakeBacksLogged.insert(
                TakeBack(terminalID: terminalID, generation: generation)).inserted
            else { continue }
            wouldTakeBackNotices += 1
            Self.logger.notice(
                """
                would take back attach \(generation, privacy: .public) of session \
                \(terminalID.uuidString, privacy: .public) from app pid \
                \(pid, privacy: .public), which says it no longer holds it; the claim sweep \
                is off, so the claim stands
                """)
        }
        return HolderClaimSweep(takenBack: [], wouldTakeBack: candidates.map(\.terminalID))
    }

    /// The attaches a sweep may take back, in session order: those `isOwner`
    /// accepts — by a claim's `owner`, or a pending attach's recorded
    /// `recipient` — with a covered seq, a session not in `held`, and no
    /// take-back of the same attach in flight. Synchronous, so it describes
    /// one instant; see `reconcileClaims` for each condition's reason.
    private func sweepCandidates(
        held: Set<UUID>, throughSeq: UInt64, ownedBy isOwner: (ProcessIdentity) -> Bool
    ) -> [SweepCandidate] {
        var candidates: [SweepCandidate] = []
        for (terminalID, pending) in pendingAttaches {
            guard let recipient = pending.recipient, isOwner(recipient),
                  isSweepable(
                    terminalID: terminalID, generation: pending.generation,
                    attachSeq: pending.attachSeq, held: held, throughSeq: throughSeq)
            else { continue }
            candidates.append(SweepCandidate(
                terminalID: terminalID, generation: pending.generation, pending: pending))
        }
        for (terminalID, claim) in viewerAttachments {
            guard let owner = claim.owner, isOwner(owner),
                  isSweepable(
                    terminalID: terminalID, generation: claim.generation,
                    attachSeq: claim.attachSeq, held: held, throughSeq: throughSeq)
            else { continue }
            candidates.append(SweepCandidate(
                terminalID: terminalID, generation: claim.generation, pending: nil))
        }
        // Ordered so a sweep's result and its log lines read the same way on
        // every run; dictionary order would not.
        return candidates.sorted { $0.terminalID.uuidString < $1.terminalID.uuidString }
    }

    /// Drops each attach `wouldTakeBacksLogged` remembers that is no longer
    /// recorded, as a pending attach or a claim: handed back, taken back,
    /// released or superseded. No sweep can select it again, so remembering
    /// it would only grow the set.
    private func forgetEndedWouldTakeBacks() {
        wouldTakeBacksLogged = wouldTakeBacksLogged.filter { logged in
            viewerAttachments[logged.terminalID]?.generation == logged.generation
                || pendingAttaches[logged.terminalID]?.generation == logged.generation
        }
    }

    /// The three conditions of a sweep that do not depend on whose an attach
    /// is: a seq at or below `throughSeq`, a session not in `held`, and no
    /// take-back of the same attach in flight.
    private func isSweepable(
        terminalID: UUID, generation: UInt64, attachSeq: UInt64?,
        held: Set<UUID>, throughSeq: UInt64
    ) -> Bool {
        guard let attachSeq, attachSeq <= throughSeq else { return false }
        guard !held.contains(terminalID) else { return false }
        return !takeBacksInFlight.contains(
            TakeBack(terminalID: terminalID, generation: generation))
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
    ///
    /// The default for the `exitConfirmationBudget` init parameter, which
    /// exists so a test whose negative window must outlast the budget can wait
    /// out a short one instead of this.
    static let defaultExitConfirmationBudget: Duration = .seconds(2)
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

    /// The Program Status Protocol (OSC 7501) tap for one session's reader, or
    /// nil when this registry has no store.
    ///
    /// `deliver` runs on the drain thread inside a parse, under the emulator's
    /// lock, so it only enqueues: `ProgramStatusStore.enqueue` yields to the
    /// store's inbox and returns, and the store's `run()` loop validates and
    /// applies in order. `.currentRow` because this reader reads the current
    /// holder process, so the row's current incarnation is the report's.
    /// `observedAt` is stamped here, on the parse thread, so the store's
    /// staleness check sees parse order.
    private func programStatusTap(for terminalID: UUID) -> HolderProgramStatusTap? {
        guard let store = programStatus else { return nil }
        return HolderProgramStatusTap(gate: store.gate, deliver: { payload in
            store.enqueue(ProgramStatusStore.Inbound(
                terminalID: terminalID,
                incarnation: .currentRow,
                payload: payload,
                observedAt: store.now()))
        })
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
                budget: exitConfirmationBudget,
                clock: clock)
        }

        // A child that is still running, a holder somebody else is attached to,
        // or one that answered for another installation: nothing here
        // establishes that this session is over, so its reader stays.
        guard let status else { return }
        guard case .adopted(let current) = slots[terminalID], current === reader else { return }

        recordStatus(status, for: terminalID)
        // A SIGKILLed Claude sends no `state=clear`, so the session's end is
        // the only signal its Program Status entries are over (spec
        // "Liveness"). Dropped here, where the child's exit is confirmed,
        // rather than after the release: a concurrent release that empties
        // the slot below must not leave the exited session's entries standing.
        if let programStatus {
            await programStatus.drop(terminalID: terminalID, reason: .childExited)
        }
        if let sessionEndedObserver {
            await sessionEndedObserver(terminalID, status, reader)
        }
        // Re-read after the drop's and the observer's suspensions: a
        // concurrent release may have emptied the slot, or a re-adoption
        // filled it with a reader this reclaim knows nothing about. Either way
        // this reader is no longer the one to release here.
        guard case .adopted(let after) = slots[terminalID], after === reader else { return }
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
        // A viewer holding this pty is a reader leaving it, because the session
        // itself is going away: the holder is told to forget its child, the job
        // is killed, and the viewer's `dup` refers to a terminal with nothing
        // on the other end. Recorded BEFORE the claim is dropped — once the
        // claim is gone there is nothing left to name the generation with.
        if let generation = viewerAttachments[terminalID]?.generation {
            readerCensus.stoppedReading(.viewer(attach: generation), session: terminalID)
        }
        // Whatever this release could not account for goes with the session. A
        // hygiene sweep, not an arbitration step: both readers above are
        // recorded as leaving by the steps that stop them, so this should find
        // nothing — it is here so a long-lived daemon's ledger cannot grow an
        // entry per session it has ever torn down.
        defer { readerCensus.forget(session: terminalID) }
        // A viewer's claim does not outlive the session it was made against.
        // Every caller here is tearing the session down or handing it back, and
        // a claim left behind would refuse every later adoption of a terminal
        // ID that no longer means anything.
        pendingAttaches[terminalID] = nil
        viewerAttachments[terminalID] = nil
        // The processes are named only for as long as this daemon is reading
        // them. A session it has let go of is one whose pids it has no
        // first-hand claim about any more.
        adoptedProcesses[terminalID] = nil
        switch slots[terminalID] {
        case nil:
            return
        case .releasing(let task):
            // Somebody is already stopping this reader; waiting for their stop
            // *is* this method's whole contract, so there is nothing to add.
            await task.value
            clearIfStillReleasing(task, for: terminalID)
        case .adopted(let reader):
            let task = Task<Void, Never> { await self.stopPublished(reader, for: terminalID) }
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

    /// Publishes an adopted reader into its slot, records the status that came
    /// with it, and counts the drain loop it carries.
    ///
    /// The one publish site for both callers — `spawn` and `beginAdoption` —
    /// because the counters only mean anything if *every* publish touches all
    /// three. They diverged once: `spawn` incremented `drainLoopsStarted`
    /// alone, so `stopPublished`'s unconditional decrement drove
    /// `liveDrainLoops` negative for a spawned session, and
    /// `peakLiveDrainLoops` could not see a second loop running beside a
    /// spawned one — the exact byte theft that counter exists to catch.
    ///
    /// `spawned` says whether the reader is a freshly spawned holder's. It
    /// decides what happens to a let-go mark, and the two answers differ on
    /// purpose:
    ///
    /// - **A spawn clears any mark.** It is a new holder process — a wake's,
    ///   or a transport move's for an existing row — so whatever let go of
    ///   the one before it no longer describes this session. A teardown mark
    ///   left on a live session would otherwise refuse every later attach and
    ///   keep every later wake parked, the day its reader went away.
    /// - **An adoption clears a park's mark only.** It is the same holder the
    ///   mark was about. Every adoption path refuses a teardown's mark on each
    ///   pass of its loop, so one that publishes over a teardown mark slipped
    ///   past those checks, and erasing the mark would hide the teardown from
    ///   the wake's own recheck (`refusalToUnpark`) and from every later
    ///   attach.
    private func publish(_ adoption: Adoption, for terminalID: UUID, spawned: Bool) {
        slots[terminalID] = .adopted(adoption.reader)
        recordStatus(adoption.description.status, for: terminalID)
        if spawned || sessionsLetGo[terminalID]?.reason == .park {
            sessionsLetGo[terminalID] = nil
        }
        // Recorded with the reader and cleared with it, so "the registry holds
        // a reader for this session" and "the registry can name that session's
        // processes" are the same fact rather than two that can disagree.
        adoptedProcesses[terminalID] = HolderAdoptedProcess(
            holderPID: adoption.holderPID, childPID: adoption.description.childPID)
        drainLoopsStarted += 1
        liveDrainLoops += 1
        peakLiveDrainLoops = max(peakLiveDrainLoops, liveDrainLoops)
        // The daemon's transition into reading. An adoption that was never
        // published is deliberately not counted here, for the same reason
        // `drainLoopsStarted` does not count one: its loop was stopped again
        // before the call that started it returned, and it never became a
        // reader this registry was on the hook for.
        readerCensus.beganReading(.daemon, session: terminalID, at: "publish")
    }

    /// Stops a reader this registry published, and drops it from the live count
    /// **before** anything awaiting the release resumes — which is what lets an
    /// adoption queued behind a release publish without ever overlapping the
    /// reader it waited for.
    private func stopPublished(_ reader: HolderReader, for terminalID: UUID) async {
        await releaseBarrier?()
        await reader.stop()
        liveDrainLoops -= 1
        // After the stop, never before: until it returns the drain thread may
        // still be inside a read, and the census says who is reading rather
        // than who intends to.
        readerCensus.stoppedReading(.daemon, session: terminalID)
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
    ///
    /// This is the daemon's shutdown, so it marks the registry shutting down
    /// first (`isShuttingDown`), before it reads which slots to release and
    /// with no suspension in between. Every adoption or attach that arrives
    /// after that refuses rather than building a reader this loop has already
    /// decided not to visit; one already in flight holds its slot, so the loop
    /// releases it and the adoption finds itself superseded. A `spawn` after
    /// this point still publishes a reader the loop never visits — by design,
    /// see `isShuttingDown`.
    func releaseAll() async {
        isShuttingDown = true
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

/// What one claim sweep did (`HolderRegistry.reconcileClaims`): the sessions
/// it took back or, when it was told not to act, the ones it would have. At
/// most one of the two is non-empty.
struct HolderClaimSweep: Sendable, Equatable {
    /// Sessions the daemon took back and reads again.
    var takenBack: [UUID]
    /// Sessions a sweep that acted would have taken back. Nothing was changed
    /// for them.
    var wouldTakeBack: [UUID]
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
