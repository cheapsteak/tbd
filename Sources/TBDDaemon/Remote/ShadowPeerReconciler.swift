import Darwin
import Foundation
import os
import TBDShared

private let reconcilerLogger = Logger(subsystem: "com.tbd.daemon", category: "shadowPeer")

// MARK: - What the live bridge says it is publishing

/// One provider's live shadow peers, as its `ShadowPeerManager` currently holds
/// them.
///
/// A provider that reports **nothing at all** is different from a provider that
/// reports an empty inventory, and the difference is load-bearing: the first is
/// "no link is answering for this provider, so TBD cannot tell a live shadow
/// from an orphan", and the second is "this link is up and publishing no
/// shadows". Only the second licenses reclaiming a current-generation row.
public struct ShadowPeerBridgeInventory: Sendable, Equatable {
    public let provider: String
    /// The pid behind each handle this link is publishing right now — the same
    /// pairs `ShadowPeerManager.artifacts()` exposes.
    public let pidsByHandle: [String: pid_t]

    public init(provider: String, pidsByHandle: [String: pid_t]) {
        self.provider = provider
        self.pidsByHandle = pidsByHandle
    }
}

/// Who can answer "is this shadow still live?".
public protocol ShadowPeerBridgeInspecting: Sendable {
    /// One entry per provider whose peer link is answering. A provider absent
    /// from the result is one nothing can vouch for, and the sweep leaves its
    /// current-generation rows alone.
    func bridgedShadows() async -> [ShadowPeerBridgeInventory]
}

/// The registry a live `ShadowPeerManager` registers itself with, and the
/// reconciler reads.
///
/// Indirection rather than a direct reference because the two have opposite
/// lifetimes: the reconciler is started once at boot and runs for the daemon's
/// life, while a manager comes and goes with its provider's peer link. Whoever
/// wires a manager registers it here; the reconciler needs to know nothing
/// about how many there are.
public actor ShadowPeerBridgeRegistry: ShadowPeerBridgeInspecting {
    private var inventories: [String: @Sendable () async -> [String: pid_t]] = [:]

    public init() {}

    /// Answer for `provider` from now on. Registering the same provider twice
    /// replaces the answerer: one link per provider, and the newest one owns
    /// the shadows.
    public func register(
        provider: String, inventory: @escaping @Sendable () async -> [String: pid_t]
    ) {
        inventories[provider] = inventory
    }

    /// Stop answering for `provider`.
    ///
    /// **This is what makes its shadows reclaimable**, so it is called when a
    /// manager is torn down for good — never merely because a link went down,
    /// where the manager itself unpublishes every shadow and forgets its rows.
    public func deregister(provider: String) {
        inventories.removeValue(forKey: provider)
    }

    public func bridgedShadows() async -> [ShadowPeerBridgeInventory] {
        var result: [ShadowPeerBridgeInventory] = []
        for (provider, inventory) in inventories {
            result.append(
                ShadowPeerBridgeInventory(provider: provider, pidsByHandle: await inventory()))
        }
        return result.sorted { $0.provider < $1.provider }
    }
}

// MARK: - Is anything listening?

/// What a connect to a socket path found.
public enum ShadowPeerListenerState: Sendable, Equatable {
    /// Something accepted, or its backlog is full. Either way a listener
    /// exists, so the file is not TBD's to unlink.
    case listening
    /// `ECONNREFUSED` — the file is there and nothing is behind it. This is the
    /// designed signal that a peer is gone.
    case refused
    /// No such file. Already reclaimed, by the helper's own exit or by an
    /// earlier sweep.
    case absent
    /// The probe could not decide. Never treated as "not listening": an
    /// undecided probe leaves the file and the row alone for the next pass.
    case inconclusive(String)
}

public protocol ShadowPeerSocketProbing: Sendable {
    func listenerState(atPath path: String) -> ShadowPeerListenerState
}

/// The production probe: a **non-blocking** `connect(2)` on an `AF_UNIX`
/// `SOCK_STREAM`, which is the same connect-and-drop `ListAgents` uses to
/// delist a peer whose socket no longer answers.
///
/// Non-blocking deliberately. A `connect` to a Unix socket whose listener has a
/// full backlog blocks, and blocking the reconciler's actor executor is the
/// starvation class the rest of this subsystem avoids everywhere. `EAGAIN` /
/// `EINPROGRESS` from a non-blocking connect means a listener exists and is
/// merely busy, which is exactly the answer the sweep needs.
public struct UnixSocketShadowPeerProbe: ShadowPeerSocketProbing {
    public init() {}

    public func listenerState(atPath path: String) -> ShadowPeerListenerState {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < sunPathSize else {
            return .inconclusive("path is longer than sun_path (\(sunPathSize - 1) bytes)")
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            return .inconclusive("socket(2): \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, length)
            }
        }
        guard connected != 0 else { return .listening }
        switch errno {
        case ECONNREFUSED: return .refused
        case ENOENT: return .absent
        case EAGAIN, EINPROGRESS: return .listening
        default: return .inconclusive("connect(2): \(String(cString: strerror(errno)))")
        }
    }
}

// MARK: - What one sweep did

/// The count that makes a leak visible.
///
/// Every unbounded leak in this repo's history went unnoticed because nothing
/// counted it — 2,804 git branches, ~7,100 tmux sockets. This is the counting,
/// and the sweep logs it as an `os.Logger` info line, which is durable where a
/// signpost is a ring buffer that is never persisted.
public struct ShadowPeerSweepResult: Sendable, Equatable {
    /// Helper processes signalled and confirmed gone.
    public var helpersKilled = 0
    public var recordsUnlinked = 0
    public var socketsUnlinked = 0
    /// Write-temps stranded beside a recorded record path — the fourth durable
    /// artifact, created by `ShadowPeerRecordStore.write` on every status
    /// rewrite and cleaned up only on its throwing paths, so a daemon or helper
    /// death mid-write leaves one behind forever.
    public var recordTemporariesUnlinked = 0
    /// Whitelist rows retired, once everything they named was settled.
    public var rowsForgotten = 0
    /// Rows a live link vouched for, left completely untouched.
    public var liveShadowsKept = 0
    /// Rows still inside their publication grace, left alone.
    public var withinGrace = 0
    /// Current-generation rows whose provider nothing answered for. Not
    /// reclaimed, and counted so a wiring gap shows up as a number rather than
    /// as a silence.
    public var unvouchedFor = 0
    /// Artifacts at a recorded path that proved to belong to somebody else —
    /// the recycled-pid case, where a real session now owns `<pid>.json` or
    /// `<pid>.sock`. Left on disk, always.
    public var foreignArtifactsLeftAlone = 0
    /// Rows kept for a later pass because something was undecided: a probe that
    /// could not answer, or a process that outlived `SIGKILL`.
    public var deferred = 0

    public init() {}

    /// The headline number: artifacts this pass took back.
    public var reclaimedArtifacts: Int {
        helpersKilled + recordsUnlinked + socketsUnlinked + recordTemporariesUnlinked
    }
}

// MARK: - The reconciler

/// The named reconciler for a shadow peer's durable artifacts — the helper
/// process, its socket, its record, and the write-temps that record's saves
/// stage through.
///
/// Per the doctrine in the root `CLAUDE.md`, creation against the process table
/// and the filesystem cannot be transactional, so the standing guarantee is a
/// sweep that compares ground truth against intent. This is that sweep for
/// `docs/specs/2026-08-29-remote-peer-messaging-design.md`, and it deliberately
/// does **not** fold into `OrphanGC`: an hour is far too slow for registry
/// hygiene, where a stale record is a peer that other sessions can address and
/// send into a void.
///
/// **It reclaims only against the durable whitelist**
/// (`ShadowPeerArtifactStore`), never by inference. "Any socket in
/// `/tmp/cc-socks` with nothing listening" is the tempting rule and it is
/// forbidden: it races a real session between `bind()` and `listen()`, and that
/// directory is shared with every Claude Code session on the machine. Four
/// classes are in scope, and each of them is a row:
///
/// - a helper process with no bridged session behind it,
/// - a record with no live helper — including the **recycled-pid ghost**, which
///   Claude Code's own reaper provably will not collect, because it checks pid
///   liveness and nothing else (measured),
/// - a socket TBD created with nothing listening,
/// - anything TBD published under a previous daemon generation.
///
/// A fourth artifact rides along with the record: `ShadowPeerRecordStore.write`
/// stages every rewrite through a hidden `.<pid>.json.<uuid>.tmp` sibling in the
/// registry directory and removes it only on its throwing paths, so a death
/// between the write and the `rename(2)` strands one permanently. It is
/// reclaimed here — see `unlinkStrandedRecordTemporaries` for why that is still
/// ledger-derived rather than the forbidden inference.
///
/// **Ownership is proved before every unlink.** A pid outlives the process TBD
/// filed under it: `<pid>.json` and `<pid>.sock` can be re-created by a real
/// Claude Code session that inherited the number. So a record is unlinked only
/// when the `sessionId` inside it is the one TBD published, and a socket only
/// when a connect gets `ECONNREFUSED`. Anything else is somebody's live peer
/// and is left exactly where it is.
public actor ShadowPeerReconciler {
    private let artifacts: ShadowPeerArtifactStore
    private let bridges: any ShadowPeerBridgeInspecting
    private let generation: String
    private let signaller: any ProcessSignaller
    private let probe: any ShadowPeerSocketProbing
    private let procStart: @Sendable (pid_t) -> String?
    private let now: @Sendable () -> Date
    /// How long a freshly published row is immune.
    ///
    /// A row is written the moment its helper exists, which is *before* the
    /// manager finishes installing the shadow into the table this sweep reads
    /// its inventory from. Without a grace, a sweep landing inside that window
    /// would read a row nothing vouches for yet and kill a shadow that is
    /// seconds old. Wall-clock rather than a `Duration` because it compares two
    /// persisted `Date`s — data, not behavior.
    private let publicationGrace: TimeInterval
    private let interval: Duration
    private let graceAttempts: Int
    private let pollInterval: Duration
    private let clock: any Clock<Duration>
    /// The last pass, kept so `tbd peer list` can answer "what did the sweep
    /// find?" in one command rather than sending an operator to `log show`.
    ///
    /// In memory, and deliberately: it describes this daemon's own sweeping,
    /// and a persisted copy would outlive the process whose behavior it
    /// reports. Nil until the first pass completes, which is the honest answer
    /// for a daemon that has not swept yet — never a zeroed result, which would
    /// read as "swept, found nothing".
    private var lastResult: (result: ShadowPeerSweepResult, at: Date)?

    public init(
        artifacts: ShadowPeerArtifactStore,
        bridges: any ShadowPeerBridgeInspecting,
        generation: String = ShadowPeerDaemonGeneration.current,
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        probe: any ShadowPeerSocketProbing = UnixSocketShadowPeerProbe(),
        procStart: @escaping @Sendable (pid_t) -> String? = { ProcessStartTime.procStart(pid: $0) },
        now: @escaping @Sendable () -> Date = Date.init,
        publicationGrace: TimeInterval = 30,
        interval: Duration = .seconds(60),
        graceAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.artifacts = artifacts
        self.bridges = bridges
        self.generation = generation
        self.signaller = signaller
        self.probe = probe
        self.procStart = procStart
        self.now = now
        self.publicationGrace = publicationGrace
        self.interval = interval
        self.graceAttempts = graceAttempts
        self.pollInterval = pollInterval
        self.clock = clock
    }

    /// The most recent pass and when it finished, or nil before the first one.
    public func lastSweep() -> (result: ShadowPeerSweepResult, at: Date)? {
        lastResult
    }

    /// Sweep once at startup — the pass that reclaims a dead daemon's leavings
    /// — then on its own tick until cancelled.
    public func run() async {
        await sweep()
        while !Task.isCancelled {
            do {
                try await clock.sleep(for: interval)
            } catch {
                return  // cancelled mid-sleep
            }
            guard !Task.isCancelled else { return }
            await sweep()
        }
    }

    /// One pass over the whitelist.
    ///
    /// Every pass is recorded, including the two that give up early: a sweep
    /// that could not load the whitelist is a fact an operator needs, and one
    /// that reported nothing would be indistinguishable from a sweep that never
    /// ran.
    @discardableResult
    public func sweep() async -> ShadowPeerSweepResult {
        let result = await performSweep()
        lastResult = (result, now())
        return result
    }

    private func performSweep() async -> ShadowPeerSweepResult {
        var result = ShadowPeerSweepResult()

        // **The whitelist is read first, and the live inventory second.** The
        // publishing side writes a row before its shadow becomes visible in an
        // inventory, so reading the inventory first would let a shadow born in
        // between look like a row nothing vouches for. Reading rows first plus
        // the publication grace below closes that window from both ends.
        let rows: [ShadowPeerArtifact]
        do {
            rows = try await artifacts.all()
        } catch {
            reconcilerLogger.error("""
                shadow peer sweep skipped: the whitelist would not load: \
                \(error.localizedDescription, privacy: .public)
                """)
            return result
        }
        guard !rows.isEmpty else {
            // Nothing was ever published, which is every install with the
            // feature off. Counted at debug rather than info: an info line
            // every tick forever would bury the counts that matter.
            reconcilerLogger.debug("shadow peer sweep: the whitelist is empty")
            return result
        }

        let inventories = await bridges.bridgedShadows()
        let vouchingProviders = Set(inventories.map(\.provider))
        var livePIDsByProvider: [String: [String: pid_t]] = [:]
        var livePIDs: Set<pid_t> = []
        for inventory in inventories {
            livePIDsByProvider[inventory.provider] = inventory.pidsByHandle
            livePIDs.formUnion(inventory.pidsByHandle.values)
        }

        let deadline = now().addingTimeInterval(-publicationGrace)
        for row in rows {
            let fromThisGeneration = row.daemonGeneration == generation

            // A row a live link vouches for is untouched, whatever the process
            // table says about it. A reaper that eats live state is worse than
            // one that leaks, and the link — not this sweep — is what withdraws
            // a shadow it no longer wants. The pid is checked as well as the
            // handle: a pid some link is using is never signalled, whichever
            // row happens to name it.
            if livePIDsByProvider[row.provider]?[row.handle] == row.pid
                || livePIDs.contains(row.pid) {
                result.liveShadowsKept += 1
                continue
            }

            // Everything below only applies to a row this daemon published. A
            // previous generation's row describes a helper this daemon never
            // spawned and no link here is carrying, so it needs no vouching and
            // gets none.
            if fromThisGeneration {
                guard row.publishedAt <= deadline else {
                    result.withinGrace += 1
                    continue
                }
                guard vouchingProviders.contains(row.provider) else {
                    result.unvouchedFor += 1
                    reconcilerLogger.debug("""
                        shadow \(row.handle, privacy: .public) (pid \(row.pid, privacy: .public)) \
                        left alone: nothing is answering for provider \
                        \(row.provider, privacy: .public), so a live shadow and an orphan are \
                        indistinguishable
                        """)
                    continue
                }
            }

            await reclaim(row, staleGeneration: !fromThisGeneration, into: &result)
        }

        reconcilerLogger.info("""
            shadow peer sweep reclaimed \(result.reclaimedArtifacts, privacy: .public) artifact(s) \
            over \(rows.count, privacy: .public) recorded shadow(s): \
            helpers=\(result.helpersKilled, privacy: .public) \
            records=\(result.recordsUnlinked, privacy: .public) \
            sockets=\(result.socketsUnlinked, privacy: .public) \
            write-temps=\(result.recordTemporariesUnlinked, privacy: .public) \
            rows=\(result.rowsForgotten, privacy: .public); kept \
            \(result.liveShadowsKept, privacy: .public) live, \
            \(result.withinGrace, privacy: .public) within grace, \
            \(result.unvouchedFor, privacy: .public) unvouched-for, left \
            \(result.foreignArtifactsLeftAlone, privacy: .public) foreign artifact(s) alone, \
            deferred \(result.deferred, privacy: .public)
            """)
        return result
    }

    // MARK: - Reclaiming one shadow

    /// Take back one row's artifacts, in the only safe order: the process
    /// first, so nothing can rewrite the record behind us; then the record;
    /// then the socket; then the row itself, last, so a crash anywhere in the
    /// middle leaves the row for the next pass rather than losing the whitelist
    /// entry that names what is left.
    private func reclaim(
        _ row: ShadowPeerArtifact, staleGeneration: Bool, into result: inout ShadowPeerSweepResult
    ) async {
        var settled = true

        let alive = signaller.isAlive(row.pid)
        let currentStart = alive ? procStart(row.pid) : nil

        switch occupancy(of: row, alive: alive, currentStart: currentStart) {
        case .gone:
            break  // nothing to signal; the artifacts below are all that is left

        case .ourHelper:
            reconcilerLogger.info("""
                reclaiming shadow \(row.name, privacy: .public) (\(row.handle, privacy: .public)): \
                helper pid \(row.pid, privacy: .public) is running with \
                \(staleGeneration ? "no daemon behind it" : "no bridged session behind it", privacy: .public)
                """)
            if await terminate(pid: row.pid) {
                result.helpersKilled += 1
            } else {
                settled = false
                result.deferred += 1
                reconcilerLogger.error("""
                    shadow peer helper pid \(row.pid, privacy: .public) outlived SIGKILL; leaving \
                    its row for the next sweep
                    """)
            }

        case .stranger:
            // The measured ghost: Claude Code's reaper checks pid liveness and
            // nothing else, so this record would survive it forever. Its pid
            // now belongs to an unrelated process, which must never be
            // signalled — that is somebody's editor, or a session of their own.
            reconcilerLogger.info("""
                recycled-pid ghost for shadow \(row.name, privacy: .public) \
                (\(row.handle, privacy: .public)): pid \(row.pid, privacy: .public) is alive but \
                is not the helper TBD recorded, so it is left running and only the artifacts are \
                reclaimed
                """)

        case .undecided:
            // **Undecided touches nothing at all** — not the process, not the
            // record, not the socket, not the row. Falling through to the
            // artifact paths here is how a live helper gets eaten: its own
            // record decodes, carries the session id this row published, and
            // gets unlinked out from under a running shadow, which then
            // vanishes from every `ListAgents` while its socket keeps accepting
            // and discarding. The socket probe would then read `.listening`,
            // count as settled, and retire the row — live state destroyed and
            // an unreclaimable orphan created in one pass.
            result.deferred += 1
            let missingSide = row.procStart == nil ? "the recorded" : "the kernel's"
            reconcilerLogger.info("""
                shadow \(row.handle, privacy: .public) (pid \(row.pid, privacy: .public)) left \
                entirely alone: the pid is alive but no start time is available on \
                \(missingSide, privacy: .public) side, so TBD can prove neither that this is its \
                own helper nor that it is a stranger's process. Deferred to the next sweep
                """)
            return
        }

        if settled {
            switch unlinkRecordIfOurs(row) {
            case .unlinked:
                result.recordsUnlinked += 1
            case .absent:
                break
            case .foreign:
                result.foreignArtifactsLeftAlone += 1
            case .undecided:
                settled = false
                result.deferred += 1
            }
        }

        // The record's write-temps, and **only when the pid is provably gone**.
        // A dead pid cannot be halfway through a `rename(2)`, which is the one
        // thing that would make a temp at this name somebody's live business
        // rather than an orphan.
        //
        // Liveness is re-read rather than reused from the top of this call: a
        // helper this pass has just killed leaves exactly the stranded temp
        // this reclaims, and reusing the earlier `alive` would skip its own
        // kill's leavings and then retire the row that named them.
        if !signaller.isAlive(row.pid) {
            result.recordTemporariesUnlinked += unlinkStrandedRecordTemporaries(row)
        }

        if settled {
            switch unlinkSocketIfUnclaimed(row) {
            case .unlinked:
                result.socketsUnlinked += 1
            case .absent:
                break
            case .foreign:
                result.foreignArtifactsLeftAlone += 1
            case .undecided:
                settled = false
                result.deferred += 1
            }
        }

        guard settled else { return }
        do {
            try await artifacts.forget(pid: row.pid)
            result.rowsForgotten += 1
        } catch {
            reconcilerLogger.error("""
                reclaimed shadow \(row.handle, privacy: .public) but could not retire its row: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
    }

    /// Who holds the pid a row names.
    ///
    /// **Four answers, not two.** The pid alone is never the question — every
    /// artifact this sweep touches is named after a number the kernel recycles
    /// — so the discriminator is the kernel's start time for that pid against
    /// the one recorded at publication. Both have to be present for a
    /// comparison to mean anything, and a comparison that cannot be made is its
    /// own answer rather than a default into either of the others.
    private enum PIDOccupancy {
        /// Nothing holds it.
        case gone
        /// The helper TBD spawned, still running.
        case ourHelper
        /// Alive, and demonstrably started at a different moment — the measured
        /// recycled-pid ghost.
        case stranger
        /// Alive, and unprovable either way: the store records NULL when the
        /// kernel refuses the start-time read at publication, and the read can
        /// refuse again now.
        case undecided
    }

    private func occupancy(
        of row: ShadowPeerArtifact, alive: Bool, currentStart: String?
    ) -> PIDOccupancy {
        guard alive else { return .gone }
        guard let recorded = row.procStart, let current = currentStart else { return .undecided }
        return current == recorded ? .ourHelper : .stranger
    }

    private enum ArtifactOutcome {
        case unlinked
        case absent
        /// At the recorded path, but demonstrably not TBD's any more.
        case foreign
        case undecided
    }

    /// Unlink the record only when the file at the recorded path still carries
    /// the session id TBD published.
    ///
    /// The check is not ceremony. A record's filename is its pid, so a session
    /// that inherited a recycled pid writes its own record at exactly this
    /// path; unlinking on the strength of the path alone would delist a live
    /// teammate.
    ///
    /// **"Somebody else's" and "unreadable" are different answers, and only the
    /// first is settled.** A read that failed or a file that did not decode
    /// proves nothing about who wrote it — a transient `EINTR`, a partial read,
    /// an `EACCES` — and answering `.foreign` there retires the row while
    /// leaving the record on disk, which is the whitelist entry gone and the
    /// artifact left with nothing able to recognise it afterwards. Only a
    /// record that decodes and carries a *different* session id is proof of a
    /// stranger. A file that stays undecodable forever therefore holds its row
    /// forever too, visible as a `deferred` count every pass — which is the
    /// counting this design exists for, and strictly better than discarding the
    /// only recognition TBD has.
    private func unlinkRecordIfOurs(_ row: ShadowPeerArtifact) -> ArtifactOutcome {
        let url = URL(fileURLWithPath: row.recordPath)
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            reconcilerLogger.error("""
                could not read the shadow record at \(row.recordPath, privacy: .public) \
                (\(error.localizedDescription, privacy: .public)); leaving it and its row for the \
                next sweep rather than assuming it is somebody else's
                """)
            return .undecided
        }
        guard let record = try? JSONDecoder().decode(ShadowPeerRecord.self, from: data) else {
            reconcilerLogger.error("""
                the file at \(row.recordPath, privacy: .public) did not decode as a shadow peer \
                record; leaving it and its row for the next sweep, because a record TBD cannot \
                read is one it cannot prove belongs to somebody else
                """)
            return .undecided
        }
        guard record.sessionID == row.sessionID else {
            reconcilerLogger.info("""
                left the record at \(row.recordPath, privacy: .public) alone: it is not the one TBD \
                published for shadow \(row.handle, privacy: .public), so its pid has been recycled \
                and it belongs to somebody else
                """)
            return .foreign
        }
        do {
            try FileManager.default.removeItem(at: url)
            return .unlinked
        } catch {
            reconcilerLogger.error("""
                could not unlink the shadow record at \(row.recordPath, privacy: .public): \
                \(error.localizedDescription, privacy: .public)
                """)
            return .undecided
        }
    }

    /// Unlink the write-temps stranded beside this row's record path. Returns
    /// how many were taken back.
    ///
    /// **The record has a hidden fourth artifact.** `ShadowPeerRecordStore`
    /// stages every write through `.<pid>.json.<uuid>.tmp` in the registry
    /// directory and unlinks it only on its own throwing paths, so a helper or
    /// daemon that dies between the write and the `rename(2)` strands one — and
    /// records are rewritten on every status change, so the opportunity recurs
    /// for the life of every shadow. Nothing else would ever collect it: the
    /// name starts with a dot so it is out of every glob, the ledger records
    /// only `socket_path` and `record_path`, and Claude Code's own reaper reads
    /// `<int>.json` and nothing else. That is the same shape as the ~7,100
    /// orphaned tmux sockets this repo accumulated — a resource with no
    /// collector — so it gets one here.
    ///
    /// **This is still ledger-derived, not the forbidden inference.** The
    /// candidate names are generated from this row's own recorded
    /// `record_path` through the single naming rule that created them
    /// (`ShadowPeerRecordStore.isTemporaryFileName`), never by scanning the
    /// directory for a shape; and the pid the row names is checked dead first,
    /// so no live process can be midway through the `rename(2)` that would make
    /// one of these files somebody's business rather than an orphan.
    ///
    /// One residual leak is accepted rather than solved: a temp beside a pid a
    /// stranger now holds is left where it is, because that process may be
    /// writing it. If it was TBD's, it stays forever. There is no way to tell
    /// the two apart from outside, and tearing a live session's record write in
    /// half is much the worse error.
    private func unlinkStrandedRecordTemporaries(_ row: ShadowPeerArtifact) -> Int {
        var unlinked = 0
        for url in ShadowPeerRecordStore.temporaryFiles(forRecordAt: row.recordPath) {
            do {
                try FileManager.default.removeItem(at: url)
                unlinked += 1
                reconcilerLogger.info("""
                    unlinked a stranded shadow record write-temp at \(url.path, privacy: .public); \
                    the daemon or helper that was writing it never finished the rename
                    """)
            } catch {
                reconcilerLogger.error("""
                    could not unlink the stranded shadow record write-temp at \
                    \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)
                    """)
            }
        }
        return unlinked
    }

    /// Unlink the socket only when a connect proves nothing is behind it.
    ///
    /// This is the narrow version of the rule the design forbids in general:
    /// not "any socket with nothing listening", which races a real session
    /// between `bind()` and `listen()`, but "this socket, which TBD's own
    /// bookkeeping says TBD created, and which now refuses a connect".
    private func unlinkSocketIfUnclaimed(_ row: ShadowPeerArtifact) -> ArtifactOutcome {
        switch probe.listenerState(atPath: row.socketPath) {
        case .absent:
            return .absent
        case .listening:
            reconcilerLogger.info("""
                left the socket at \(row.socketPath, privacy: .public) alone: something is \
                listening on it, so it is no longer the one TBD's helper for shadow \
                \(row.handle, privacy: .public) bound
                """)
            return .foreign
        case .inconclusive(let detail):
            reconcilerLogger.error("""
                could not tell whether anything is listening on \
                \(row.socketPath, privacy: .public) (\(detail, privacy: .public)); leaving it and \
                its row for the next sweep
                """)
            return .undecided
        case .refused:
            do {
                try FileManager.default.removeItem(atPath: row.socketPath)
                return .unlinked
            } catch {
                reconcilerLogger.error("""
                    could not unlink the shadow socket at \(row.socketPath, privacy: .public): \
                    \(error.localizedDescription, privacy: .public)
                    """)
                return .undecided
            }
        }
    }

    /// SIGTERM, poll, SIGKILL — **pid-exact in both cases**.
    ///
    /// Never the process group. A helper is one process TBD spawned and
    /// recorded; its group can hold processes this sweep deliberately excluded,
    /// and on a pid whose occupant has changed `getpgid` resolves to a
    /// stranger's group entirely. Returns whether the pid is gone.
    private func terminate(pid: pid_t) async -> Bool {
        signaller.terminateProcessOnly(pid)
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return true }
            try? await clock.sleep(for: pollInterval)
        }
        guard signaller.isAlive(pid) else { return true }
        signaller.forceKillProcessOnly(pid)
        for _ in 0..<graceAttempts {
            if !signaller.isAlive(pid) { return true }
            try? await clock.sleep(for: pollInterval)
        }
        return !signaller.isAlive(pid)
    }
}
