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

        var errorDescription: String? {
            switch self {
            case .notAHolderSession(let terminalID):
                return "terminal \(terminalID.uuidString) is not a holder-backed session"
            case .foreignOwner(let terminalID, let holderOwner):
                return "the holder for terminal \(terminalID.uuidString) belongs to installation "
                    + "\(holderOwner); leaving it alone"
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
    /// `adopting` is the idempotence guard. It holds the *task*, not a flag, so
    /// a second caller has something to await rather than a state to poll —
    /// which is what makes "two concurrent adoptions produce one reader" a
    /// property of the type instead of a timing accident.
    private enum Slot {
        case adopting(Task<Adoption, Swift.Error>)
        case adopted(HolderReader)
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
    /// The environment the rendezvous paths are derived from. Explicit rather
    /// than ambient so tests never reach the developer's real `~/tbd`.
    private let environment: [String: String]
    private let listTerminals: @Sendable () async throws -> [Terminal]

    private var slots: [UUID: Slot] = [:]
    /// The last status a holder reported for a session, and the only home it
    /// has: no `terminal` column records an exit status, and the row's fate
    /// belongs to the holder reconciler Milestone B adds. Recorded here so a
    /// job that ended during an outage is *reported* rather than lost, and so
    /// an unreachable holder is recorded as `exitedStatusUnknown` — never as a
    /// fabricated code, which downstream could not tell from a real one.
    private var statuses: [UUID: HolderChildStatus] = [:]
    /// How many drain loops this registry has ever started.
    ///
    /// Test-facing, and the honest instrument for the invariant above: object
    /// identity alone cannot tell a registry that reused a reader from one that
    /// built a second and threw it away, and only the count sees the second
    /// drain loop that would have been stealing bytes.
    private(set) var drainLoopsStarted = 0

    private let busyRetryBudget: Duration
    private let clock: any Clock<Duration>

    init(
        owner: HolderOwnerToken,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        listTerminals: @escaping @Sendable () async throws -> [Terminal],
        busyRetryBudget: Duration = HolderRegistry.defaultBusyRetryBudget,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.owner = owner
        self.environment = environment
        self.listTerminals = listTerminals
        self.busyRetryBudget = busyRetryBudget
        self.clock = clock
    }

    // MARK: - Reading

    /// The live reader for a session, or nil if none has been adopted.
    /// A session still being adopted answers nil: there is no drain loop yet.
    func reader(for terminalID: UUID) -> HolderReader? {
        guard case .adopted(let reader) = slots[terminalID] else { return nil }
        return reader
    }

    /// The last status a holder reported for a session, if one ever has.
    func lastKnownStatus(for terminalID: UUID) -> HolderChildStatus? {
        statuses[terminalID]
    }

    // MARK: - Adoption

    /// Connects to the session's holder, takes a `dup` of its pty master, and
    /// starts draining it.
    ///
    /// Idempotent, and that is load-bearing rather than tidy — see the type's
    /// note on byte theft. A call for a session already adopted returns the same
    /// reader; a call for one mid-adoption awaits that adoption's own task.
    @discardableResult
    func adopt(terminal: Terminal) async throws -> HolderReader {
        guard terminal.transport == .holder else {
            throw Error.notAHolderSession(terminalID: terminal.id)
        }
        switch slots[terminal.id] {
        case .adopted(let reader):
            return reader
        case .adopting(let task):
            return try await task.value.reader
        case nil:
            break
        }

        let terminalID = terminal.id
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
        slots[terminalID] = .adopting(task)

        let adoption: Adoption
        do {
            adoption = try await task.value
        } catch {
            // Nothing was started, so nothing is owed a `stop()`. Clearing the
            // slot is what lets a later pass retry a holder that was merely
            // slow to answer.
            slots[terminalID] = nil
            throw error
        }
        slots[terminalID] = .adopted(adoption.reader)
        statuses[terminalID] = adoption.description.status
        drainLoopsStarted += 1
        Self.logger.info(
            """
            adopted the holder for session \(terminalID.uuidString, privacy: .public): child \
            \(adoption.description.childPID, privacy: .public) is \
            \(String(describing: adoption.description.status), privacy: .public)
            """)
        return adoption.reader
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

    /// One connect-and-take. Every exit path closes the connection: the holder
    /// serves one client at a time, so a connection kept past the hand-over
    /// would refuse every later verb — a `forget` on the deletion path above all.
    private static func attemptAttach(
        terminalID: UUID,
        socketPath: String,
        expecting owner: HolderOwnerToken
    ) async throws -> Adoption {
        let client = HolderClient(socketPath: socketPath)
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
    func release(terminalID: UUID) async {
        guard let slot = slots.removeValue(forKey: terminalID) else { return }
        switch slot {
        case .adopted(let reader):
            await reader.stop()
        case .adopting(let task):
            // The attach performs no cancellation checks, so this waits for it
            // to finish rather than interrupting it — which is what we want: a
            // reader that was started while we were releasing would otherwise
            // be exactly the leak this method exists to prevent.
            task.cancel()
            if let adoption = try? await task.value {
                await adoption.reader.stop()
            }
        }
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
    /// would never adopt anything. So it is persisted beside the other
    /// installation-scoped files under `TBD_HOME` (`tbdd.pid`, `port`), and like
    /// them it is a fixed name that is rewritten rather than accumulated: no
    /// sweep is owed one.
    ///
    /// Minting is `O_EXCL`, so two daemons racing on a fresh `TBD_HOME` agree on
    /// whichever won rather than each keeping its own.
    static func installationOwner(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> HolderOwnerToken {
        let path = TBDConstants.holderOwnerTokenPath(environment: environment)
        if let existing = readOwnerToken(at: path) { return existing }

        let minted = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(
            at: TBDConstants.configDir(environment: environment),
            withIntermediateDirectories: true)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        if fd >= 0 {
            var bytes = Array(minted.utf8)
            _ = Darwin.write(fd, &bytes, bytes.count)
            Darwin.close(fd)
            return HolderOwnerToken(rawValue: minted)
        }
        // Lost the race, or could not write at all. A token read back is the
        // right answer; a store we cannot write to gets a value derived from the
        // store's own path, which is at least stable across restarts — an
        // ephemeral one would quietly disown every holder on the next boot.
        if let existing = readOwnerToken(at: path) { return existing }
        Self.logger.error(
            """
            could not persist the holder owner token at \(path, privacy: .public) \
            (errno \(errno, privacy: .public)); falling back to a path-derived token
            """)
        return HolderOwnerToken(
            rawValue: "tbd-home:\(TBDConstants.configDir(environment: environment).path)")
    }

    private static func readOwnerToken(at path: String) -> HolderOwnerToken? {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : HolderOwnerToken(rawValue: trimmed)
    }
}
