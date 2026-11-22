import Foundation
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel
import TestSupport

/// The holder spawn double: lets a unit test put a session on the holder
/// transport without launching `TBDHolder`, through every path that spawns
/// via `WorktreeLifecycle.spawnTerminal` — `terminal.create`, worktree
/// creation's primary and hook tabs, and the rest.
///
/// It is a `HolderSpawnFabricator`, so it plugs into a **real**
/// `HolderRegistry` (`makeHolderRegistryDouble(launch:)`) rather than standing
/// beside one. Wire that registry exactly where production wires its own —
/// `router.holderRegistry`, `lifecycle.holderRegistry` — and
/// `TerminalSpawnTransport.decide` grants it, because the registry reports
/// `canSpawn`. With no registry wired, every spawn is refused.
///
/// **What it supports**
///
///   - Every spawn is recorded (`launches`): the terminal id and the
///     `HolderLaunchRequest` a real holder would have been asked to run — argv,
///     working directory, process environment and size — plus the handle given
///     back.
///   - Each spawn gets two fresh pids, distinct across the double's life and
///     all above macOS's `PID_MAX` (99,999), so none can name a real process
///     and nothing that signals a row's pids can reach one.
///   - The handle's socket path is the session's real rendezvous path, derived
///     from the registry's environment as a real spawn derives it — so a path
///     too long for `sun_path` is refused here as it would be there — and
///     nothing is ever bound at it.
///   - `failNextSpawn(with:)` makes the next spawn throw, before anything
///     else it could fail on; it records the terminal id in `failedSpawns` and
///     returns no handle, so no row is written.
///   - A second spawn for a terminal id that is still live is refused with
///     `HolderRegistry.Error.sessionAlreadyRegistered` and never reaches the
///     double, as a real registry refuses it; a teardown frees the id again.
///   - Every registry teardown of the session — `abandon` in each spelling
///     (create-time cleanup, `terminal.delete`, archive, a park) and the hook
///     tab's `abandonVerifiedJob` — is recorded in `abandonments` instead of
///     signalling anything. `abandonVerifiedJob` still returns the report a
///     real teardown gives a row that recorded no child pid or start time.
///
/// **What it does not support**
///
///   - **No reader.** Nothing is handed over, so the registry publishes no
///     `HolderReader`: `reader(for:)` and `adoptedProcess(for:)` answer nil and
///     no status is recorded (a spawn clears any remembered one). Anything
///     served from the daemon's emulator — `terminal.output`, `terminal.send`
///     and other input, attach, closed-terminal screen capture, resize — has
///     nothing to serve such a row, and an on-demand adoption fails at the
///     empty rendezvous.
///   - **The pids are not alive.** The kernel answers "no such process" for
///     them, so every liveness probe (`holderProcessIsLive`,
///     `ProcessSignaller.isAlive`) reads the session as ended — reconcile's
///     holder inventory, which probes the empty rendezvous and then the child
///     pid, among them: it reads a double's row as a holder that is gone. Tests
///     that need otherwise inject those probes, as holder tests do today.
///   - **No process, no socket, no lock, no log file.** Nothing is created
///     under the registry's `TBD_HOME`, so there is nothing to clean up.
final class FakeHolderLaunch: HolderSpawnFabricator, @unchecked Sendable {
    /// One spawn this double answered.
    struct Launch: Sendable, Equatable {
        let terminalID: UUID
        /// What a real holder would have been asked to run.
        let request: HolderLaunchRequest
        /// The handle given back, whose pids the row records.
        let handle: HolderHandle

        /// The job's full argv: the shell, its flags, and the command line.
        var argv: [String] { [request.executable] + request.arguments }

        /// The command line the shell is asked to run — the last argument of
        /// `<shell> <flags> <command>` — with the `export K='v';` prefix that
        /// carries the spawn's `env`.
        var commandLine: String? { request.arguments.last }
    }

    /// One teardown the registry handed to this double.
    struct Abandonment: Sendable, Equatable {
        let terminalID: UUID
        let handle: HolderHandle
    }

    /// The error a scripted failure throws when the test names none.
    struct SpawnFailure: Error, Equatable, CustomStringConvertible {
        let terminalID: UUID
        var description: String { "scripted holder spawn failure for terminal \(terminalID)" }
    }

    /// Every pid the double hands out is above this floor. macOS issues pids
    /// up to `PID_MAX` (99,999), so none of them can name a real process.
    static let pidFloor: Int32 = 1_000_000

    private let lock = NSLock()
    private var recordedLaunches: [Launch] = []
    private var recordedAbandonments: [Abandonment] = []
    private var recordedFailures: [UUID] = []
    /// `nil` entries throw `SpawnFailure`.
    private var scriptedFailures: [(any Error)?] = []
    private var lastPID: Int32 = FakeHolderLaunch.pidFloor

    init() {}

    /// Every spawn answered, in order.
    var launches: [Launch] { lock.withLock { recordedLaunches } }

    /// Every teardown handed over, in order.
    var abandonments: [Abandonment] { lock.withLock { recordedAbandonments } }

    /// The terminal ids whose spawn was failed on purpose, in order.
    var failedSpawns: [UUID] { lock.withLock { recordedFailures } }

    /// The spawn answered for `terminalID`, if there was one.
    func launch(for terminalID: UUID) -> Launch? {
        lock.withLock { recordedLaunches.last(where: { $0.terminalID == terminalID }) }
    }

    /// Makes the next spawn throw `error`, or `SpawnFailure` when nil. Calls
    /// queue up: each one fails one spawn, in order.
    func failNextSpawn(with error: (any Error)? = nil) {
        lock.withLock { scriptedFailures.append(error) }
    }

    // MARK: - HolderSpawnFabricator

    func spawn(
        terminalID: UUID, launch: HolderLaunchRequest, environment: [String: String]
    ) async throws -> HolderHandle {
        // A queued failure is consumed first, so it is always the one that
        // fires, whatever else this spawn would have failed on.
        if let failure = takeScriptedFailure(for: terminalID) { throw failure }
        let socketPath = try HolderRendezvous.socketPath(
            sessionID: terminalID, environment: environment)
        return lock.withLock {
            let handle = HolderHandle(
                holderPID: lastPID + 1, childPID: lastPID + 2, socketPath: socketPath)
            lastPID += 2
            recordedLaunches.append(
                Launch(terminalID: terminalID, request: launch, handle: handle))
            return handle
        }
    }

    /// Dequeues the next scripted failure, recording `terminalID` against it,
    /// or answers nil when none is queued.
    private func takeScriptedFailure(for terminalID: UUID) -> (any Error)? {
        lock.withLock { () -> (any Error)? in
            guard !scriptedFailures.isEmpty else { return nil }
            let scripted = scriptedFailures.removeFirst()
            recordedFailures.append(terminalID)
            if let scripted { return scripted }
            return SpawnFailure(terminalID: terminalID)
        }
    }

    func abandon(terminalID: UUID, handle: HolderHandle) async {
        lock.withLock {
            recordedAbandonments.append(Abandonment(terminalID: terminalID, handle: handle))
        }
    }

    // MARK: - Environment

    /// A registry environment for the double: a `TBD_HOME` under the run's
    /// fenced scratch root, short enough for every rendezvous path to fit
    /// `sun_path`, and a fixed `PATH` and `SHELL` so the launch's argv does not
    /// depend on the developer's login shell. Nothing is created there.
    static func scratchEnvironment() -> [String: String] {
        [
            "TBD_HOME": fencedScratchRoot(prefix: "tbdfhl"),
            "PATH": "/usr/bin:/bin",
            "SHELL": "/bin/sh",
        ]
    }
}

/// A real `HolderRegistry` whose spawns and teardowns go through `launch`.
///
/// It has no `HolderSpawner`, so nothing it does can start a holder, and it
/// reports `canSpawn`, so the transport gate grants it. Everything else is the
/// production registry: let-go marks, releases, attach bookkeeping and the rest
/// behave as they do in the daemon, over sessions that have no reader.
///
/// `signaller` and `emulatorKind` are the registry's own seams, defaulted as
/// the registry defaults them. `HolderTouchRecorder.registryDouble(launch:)`
/// passes recording ones.
func makeHolderRegistryDouble(
    launch: FakeHolderLaunch,
    environment: [String: String] = FakeHolderLaunch.scratchEnvironment(),
    listTerminals: @escaping @Sendable () async throws -> [TBDShared.Terminal] = { [] },
    signaller: any ProcessSignaller = ProductionProcessSignaller(),
    emulatorKind: @escaping @Sendable () async -> HolderEmulatorKind = { .swiftTerm }
) -> HolderRegistry {
    HolderRegistry(
        owner: HolderOwnerToken(rawValue: "acme-installation"),
        environment: environment,
        listTerminals: listTerminals,
        spawner: nil,
        signaller: signaller,
        spawnFabricator: launch,
        emulatorKind: emulatorKind)
}

/// Records every call through the seams listed here — the router's ways to
/// reach a holder session's process or screen, and its reads of process
/// facts — for a test that asserts a path makes none. Each seam records into
/// `events` instead of acting.
///
/// **What it covers**
///
///   - **Screen reads** – the router's `holderScreenResolver`: its reader
///     census (`ptyReader`) and its daemon-store lookup, the first thing every
///     screen read through the resolver asks. Wired by `install(on:)`.
///   - **Input** – the router's `holderInjectionCourier`, through which the
///     daemon types into a session: the viewer lookup, the sidecar frame and
///     the direct write. Wired by `install(on:)`.
///   - **Holder probes** – the router's `holderChildSignaller` and
///     `holderProcessIsLive`, and its `appIdentityResolver`, which runs `ps`
///     for the app's identity in production. Wired by `install(on:)`.
///   - **Process facts** – `signaller` and `processTableReader`. These are
///     initializer parameters, so the fixture passes them itself: as the
///     router's `processSignaller:` and `processTableReader:`, and as the
///     lifecycle's `processSignaller:`. The signaller's identity reads
///     (`commandLine`, `stat`, `startTime`) are `ps` subprocesses in
///     production.
///   - **The registry** – `registryDouble(launch:)`, a holder registry double
///     whose own `signaller` and `emulatorKind` record here. Such a registry
///     holds a reader only once an adoption has built one, and every adoption
///     asks `emulatorKind` before it connects to the session's rendezvous, so
///     each attempt to obtain a reader is recorded although it then fails at
///     the empty rendezvous. Spawns and teardowns are the spawn double's to
///     record (`FakeHolderLaunch.launches` and `.abandonments`).
///
/// `unwiredSeams(of:)` reaches each covered seam once and names those that
/// recorded nothing, so a test can show its fixture wired every seam before
/// it reads an empty `events` as evidence.
///
/// **What it cannot see.** Anything that reaches a process or a session
/// without going through one of those seams: a direct
/// `ProcessTableSnapshot.read()`, a `Process` launched in place, a
/// `ProductionProcessSignaller()` built at the call site, a `HolderClient`
/// opened on a rendezvous directly, any router seam not listed above (the
/// dev-server runner and probes among them), and the router's hibernation
/// coordinator, which builds its own signaller. None of those has a seam a
/// test can route here, so an empty `events` says nothing about them.
final class HolderTouchRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []

    /// Every touch, in order.
    var events: [String] { lock.withLock { recorded } }

    func note(_ event: String) { lock.withLock { recorded.append(event) } }

    var processTableReader: @Sendable () -> ProcessTableSnapshot? {
        { [self] in
            note("process-table read")
            return nil
        }
    }

    var signaller: any ProcessSignaller { RecordingSignaller(recorder: self) }

    /// The registry's reader-build seam. A registry asks it at every adoption,
    /// before connecting, and at a spawn through a real `HolderSpawner`, which
    /// a registry double never has.
    var emulatorKind: @Sendable () async -> HolderEmulatorKind {
        { [self] in
            note("registry: reader build")
            return .swiftTerm
        }
    }

    /// A holder registry double over `launch` whose own process probes and
    /// reader builds record here. Wire it wherever the fixture wires a
    /// registry: `router.holderRegistry`, `lifecycle.holderRegistry`.
    func registryDouble(launch: FakeHolderLaunch) -> HolderRegistry {
        makeHolderRegistryDouble(launch: launch, signaller: signaller, emulatorKind: emulatorKind)
    }

    func install(on router: RPCRouter) {
        // Each seam is typed as its initializer or property declares it, so no
        // call below infers a closure type.
        let ptyReader: @Sendable (UUID) async -> PtyReaderRole? = { [self] id in
            note("screen read: reader census for \(id)")
            return nil
        }
        let daemonStore: @Sendable (UUID) async -> HolderDaemonStore? = { [self] id in
            note("screen read: daemon store for \(id)")
            return nil
        }
        router.holderScreenResolver = HolderScreenResolver(
            ptyReader: ptyReader, daemonStore: daemonStore, pull: nil)

        let sendFrame: @Sendable (Data) async throws -> Void = { [self] _ in
            note("input: sidecar frame")
        }
        let viewerAttachment: @Sendable (UUID) async -> UInt64? = { [self] id in
            note("input: viewer lookup for \(id)")
            return nil
        }
        let writeDirectly: @Sendable (UUID, Data) async throws -> Void = { [self] id, _ in
            note("input: direct write to \(id)")
        }
        router.holderInjectionCourier = HolderInjectionCourier(
            sendFrame: sendFrame, viewerAttachment: viewerAttachment,
            writeDirectly: writeDirectly)

        let childSignaller: any ProcessSignaller = signaller
        router.holderChildSignaller = childSignaller
        let holderProcessIsLive: @Sendable (Int32) -> Bool = { [self] pid in
            note("holder liveness probe of \(pid)")
            return false
        }
        router.holderProcessIsLive = holderProcessIsLive
        let appIdentityResolver: @Sendable (Int32) -> ProcessIdentity? = { [self] pid in
            note("app identity read of \(pid)")
            return nil
        }
        router.appIdentityResolver = appIdentityResolver
    }

    /// Reaches every seam this recorder covers on `router` once, and answers
    /// the ones that recorded nothing: seams the fixture left on their
    /// production defaults, or never wired. Empty means an empty `events`
    /// read earlier on the same fixture spoke for every one of them.
    ///
    /// It records as it goes and leaves state on the router's registry, so a
    /// test calls it once, after its own assertions on `events`.
    func unwiredSeams(of router: RPCRouter) async -> [String] {
        // Above macOS's PID_MAX (99,999) and below the spawn double's floor,
        // so even a seam left on its production default asks the kernel about
        // no real process and no double's session.
        let pid = FakeHolderLaunch.pidFloor - 1
        let sessionID = UUID()
        var unwired: [String] = []
        var mark = events.count

        _ = router.processTableReader()
        settle("router processTableReader", since: &mark, into: &unwired)
        _ = router.processSignaller.commandLine(pid)
        settle("router processSignaller", since: &mark, into: &unwired)
        _ = router.lifecycle.processSignaller.stat(pid - 1)
        settle("lifecycle processSignaller", since: &mark, into: &unwired)
        _ = router.holderChildSignaller.startTime(pid - 2)
        settle("router holderChildSignaller", since: &mark, into: &unwired)
        _ = router.holderProcessIsLive(pid - 3)
        settle("router holderProcessIsLive", since: &mark, into: &unwired)
        _ = router.appIdentityResolver(pid - 4)
        settle("router appIdentityResolver", since: &mark, into: &unwired)

        if let resolver = router.holderScreenResolver {
            _ = await resolver.ptyReader(sessionID)
        }
        settle("router holderScreenResolver reader census", since: &mark, into: &unwired)
        if let resolver = router.holderScreenResolver {
            _ = try? await resolver.screen(terminalID: sessionID, maxLines: 1)
        }
        settle("router holderScreenResolver daemon store", since: &mark, into: &unwired)
        if let courier = router.holderInjectionCourier {
            _ = await courier.deliver(terminalID: sessionID, bytes: Data("x".utf8))
        }
        settle("router holderInjectionCourier", since: &mark, into: &unwired)

        guard let registry = router.holderRegistry else {
            return unwired + ["router holderRegistry"]
        }
        // An adoption. Nothing is bound at the double's rendezvous, so it
        // fails at the connect, after asking `emulatorKind`.
        let adoptee = TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder)
        _ = try? await registry.adopt(terminal: adoptee)
        settle("registry emulatorKind", since: &mark, into: &unwired)
        // An attach to a session whose ended status came from an absent
        // rendezvous asks the registry's signaller when the holder started. A
        // nil answer declines the adoption, so nothing connects.
        let probed = TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder,
            holderPID: pid - 5)
        await registry.recordStatusForTesting(
            .exitedStatusUnknown, for: probed.id, fromAbsentRendezvous: true)
        try? await registry.adoptForAttach(terminal: probed, holderIsLive: { _ in true })
        settle("registry signaller", since: &mark, into: &unwired)
        return unwired
    }

    /// Adds `seam` to `unwired` when nothing has been recorded since `mark`,
    /// then moves `mark` to the present.
    private func settle(_ seam: String, since mark: inout Int, into unwired: inout [String]) {
        let now = events.count
        if now == mark { unwired.append(seam) }
        mark = now
    }

    private struct RecordingSignaller: ProcessSignaller {
        let recorder: HolderTouchRecorder

        func isAlive(_ pid: Int32) -> Bool {
            recorder.note("isAlive \(pid)")
            return false
        }
        func terminate(_ pid: Int32) { recorder.note("terminate \(pid)") }
        func forceKill(_ pid: Int32) { recorder.note("forceKill \(pid)") }
        func terminateProcessOnly(_ pid: Int32) { recorder.note("terminateProcessOnly \(pid)") }
        func forceKillProcessOnly(_ pid: Int32) { recorder.note("forceKillProcessOnly \(pid)") }
        func commandLine(_ pid: Int32) -> String? {
            recorder.note("commandLine \(pid)")
            return nil
        }
        func stat(_ pid: Int32) -> String? {
            recorder.note("stat \(pid)")
            return nil
        }
        func startTime(_ pid: Int32) -> Date? {
            recorder.note("startTime \(pid)")
            return nil
        }
    }
}
