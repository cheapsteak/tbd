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
func makeHolderRegistryDouble(
    launch: FakeHolderLaunch,
    environment: [String: String] = FakeHolderLaunch.scratchEnvironment(),
    listTerminals: @escaping @Sendable () async throws -> [TBDShared.Terminal] = { [] }
) -> HolderRegistry {
    HolderRegistry(
        owner: HolderOwnerToken(rawValue: "acme-installation"),
        environment: environment,
        listTerminals: listTerminals,
        spawner: nil,
        spawnFabricator: launch)
}
