import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "gc")

/// One row of a `/bin/ps` snapshot — the process graph `lsof` does not carry.
///
/// `sid` is deliberately absent: it is not a valid `ps` keyword on macOS, so
/// session membership cannot be read this way at all. Parentage plus the
/// descendant closure computed from it is what stands in for it.
public struct ProcessSnapshotEntry: Sendable, Equatable {
    public var pid: Int32
    public var ppid: Int32
    /// Process group. Recorded because it is the field that explains why a
    /// group kill is not dependable here: a real orphan is often not its own
    /// group leader (measured: `pid=1450, pgid=1448`, its leader already dead),
    /// so `killpg` on it would strand its children.
    public var pgid: Int32
    public var uid: uid_t
    /// Seconds since the process started (`ps etime`), or `nil` when the field
    /// could not be parsed — which the grace gate reads as "too young to
    /// touch", the keep-favoring direction.
    public var elapsedSeconds: TimeInterval?
    /// Full argv (`ps -ww -o command=`).
    public var command: String

    public init(
        pid: Int32, ppid: Int32, pgid: Int32, uid: uid_t,
        elapsedSeconds: TimeInterval?, command: String
    ) {
        self.pid = pid
        self.ppid = ppid
        self.pgid = pgid
        self.uid = uid
        self.elapsedSeconds = elapsedSeconds
        self.command = command
    }
}

/// A TBD-managed directory tree whose owning worktree is dead, so processes
/// rooted inside it are reclaimable.
public struct DeadWorktreeRoot: Sendable, Equatable {
    /// Canonical directory path.
    public var path: String
    /// When the owning row was archived, where an archived row is what
    /// established the death. `nil` means the evidence was of the other kind —
    /// a `<pool>/.deleting/<uuid>` queue entry, which TBD renamed there itself
    /// and which carries no archive instant to measure from, so grace runs
    /// from process start instead.
    public var archivedAt: Date?

    public init(path: String, archivedAt: Date?) {
        self.path = path
        self.archivedAt = archivedAt
    }
}

/// The TBD-managed path universe one sweep classifies cwds against.
public struct TBDProcessRoots: Sendable {
    /// Canonical prefixes of directories TBD owns **outright**: each repo's
    /// worktree pool (canonical and legacy) and the scratch-worktree pool.
    ///
    /// A pool is where TBD's own `.deleting/<uuid>` queue entries live, and an
    /// entry there is positive evidence of death — TBD renamed it there. Being
    /// under a pool is NOT itself such evidence: a directory a person created
    /// under one by hand, with `git worktree add` or a bare `mkdir`, gets no
    /// row until something calls `WorktreeLifecycle.reconcile`, and no timer
    /// ever does. So an unrecognized child of a pool is ambiguous, and
    /// ambiguity keeps.
    public var pools: [String]
    /// Canonical prefixes of directories TBD **shares** with other software —
    /// today the Claude scratchpad base, which Claude Code fills with one
    /// directory per project it has ever been run in, most of which TBD has
    /// never managed. A cwd here is classified only by an explicit `live` or
    /// `dead` entry, and a shared root holds no `.deleting/` queue TBD drains,
    /// so an unrecognized child is never a candidate.
    ///
    /// `ScratchpadCollector.reconcile` already takes the same whitelist side
    /// ("Unrelated directories in the base are untouched") for a merely
    /// destructive operation. This one kills processes.
    public var sharedRoots: [String]
    /// Canonical paths of worktrees that are still alive, and of their Claude
    /// scratchpads. A cwd under one of these is never a candidate, even at
    /// `ppid == 1` — that narrowness is what keeps a deliberately detached dev
    /// server safe until the developer has archived the worktree it belonged
    /// to.
    public var live: [String]
    /// Canonical paths of worktrees whose rows say they are dead — archived —
    /// and of their Claude scratchpads, each carrying that row's archive
    /// instant.
    public var dead: [DeadWorktreeRoot]

    public init(
        pools: [String], sharedRoots: [String] = [], live: [String],
        dead: [DeadWorktreeRoot]
    ) {
        self.pools = pools
        self.sharedRoots = sharedRoots
        self.live = live
        self.dead = dead
    }
}

/// How one process's cwd relates to the TBD-managed path universe.
public enum CWDOwnership: Sendable, Equatable {
    /// Not under any TBD-managed pool. Never a candidate.
    case outside
    /// Under a worktree that is still alive. Never a candidate.
    case live(path: String)
    /// Under something positively known to be dead: an archived worktree, an
    /// archived worktree's scratchpad, or a `<pool>/.deleting/<uuid>` entry.
    case dead(DeadWorktreeRoot)
}

/// One process that outlived the worktree it was rooted in.
public struct OrphanProcessCandidate: Sendable, Equatable {
    public var pid: Int32
    /// Resolved cwd, from the sweep's single `lsof -d cwd -Fn` pass.
    public var cwd: String
    /// The dead TBD-managed root the cwd fell under — what the reap record's
    /// `worktreePath` carries.
    public var rootPath: String
    /// Full argv, truncated into the reap record's `processDescription`.
    public var command: String

    public init(pid: Int32, cwd: String, rootPath: String, command: String) {
        self.pid = pid
        self.cwd = cwd
        self.rootPath = rootPath
        self.command = command
    }
}

/// Reclaims processes that outlived the worktree they were rooted in — the
/// named reconciler for that resource class
/// (`docs/specs/2026-08-18-orphan-process-gc-design.md`).
///
/// Under an interactive shell every job runs in its own process group, so
/// `killpg(pane_pid, …)` reaches the shell and nothing else; what normally
/// kills a foreground job is the kernel hanging up the pty. A `disown`ed or
/// `nohup`ed job escapes both, reparents to launchd, and no TBD structure can
/// find it again. `AgentReaper` cannot see one: it walks a single generation
/// from the tmux server, its per-teardown escalation runs after the pane pid is
/// already dead, and its `isTBDOwned` gate excludes non-agent binaries by
/// design.
///
/// Classification and reclamation never read the database and never spawn
/// anything: the caller supplies the `ps` snapshot, the pid-to-cwd map and the
/// root classification, the same division of labor `ProfileDirCollector` and
/// `DeletionQueueCollector` keep with `OrphanGC`. The one exception is
/// `realProcessSnapshot()`, the production `/bin/ps` reader — a static factory
/// for that injected input, deliberately outside the classifying surface so
/// every gate below stays a pure function of its arguments.
///
/// Every failure direction is toward KEEPING: an unreadable cwd, an unparseable
/// start time, a uid that is not ours, an identity that cannot be re-read at
/// signal time, and any ambiguity about whether the owning directory is dead
/// all leave the process running. Reclamation runs on positive evidence of
/// death — an archived row, or a `.deleting/<uuid>` entry TBD renamed there
/// itself — never on the mere absence of one.
public struct OrphanProcessCollector: Sendable {
    let signaller: any ProcessSignaller
    /// One fresh `/bin/ps` reading, taken immediately before each volley so a
    /// pid the kernel reissued since the sweep planned its tree is recognized
    /// and left alone. Injected so tests never spawn a subprocess.
    let snapshotProvider: @Sendable () async -> [ProcessSnapshotEntry]?
    let now: @Sendable () -> Date
    /// Number of liveness polls between SIGTERM and SIGKILL.
    let graceAttempts: Int
    /// Delay between liveness polls.
    let pollInterval: Duration
    /// Injected so the SIGTERM-to-SIGKILL escalation is testable without real
    /// waiting (`Duration` is behavior; the grace comparison uses `now`
    /// instead, because `Date` is data).
    let clock: any Clock<Duration>

    public init(
        signaller: any ProcessSignaller = ProductionProcessSignaller(),
        snapshotProvider: @escaping @Sendable () async -> [ProcessSnapshotEntry]? = {
            await OrphanProcessCollector.realProcessSnapshot()
        },
        now: @escaping @Sendable () -> Date = Date.init,
        graceAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.signaller = signaller
        self.snapshotProvider = snapshotProvider
        self.now = now
        self.graceAttempts = graceAttempts
        self.pollInterval = pollInterval
        self.clock = clock
    }

    // MARK: - Identification

    /// Every process the sweep may reclaim, in pid order.
    ///
    /// A process qualifies only when ALL of these hold, and each of them fails
    /// toward keeping:
    /// - `ppid == 1` — reparented to launchd, i.e. actually escaped.
    /// - owned by `ourUID`. Enforced through the protected set, so the same
    ///   exclusion holds for every process the reap volley reaches and not only
    ///   for the root that entered it.
    /// - `pid > 1`, and neither `ourPID` nor one of its ancestors.
    /// - not a `TBDDaemon` or `TBDApp` process. **Not hypothetical:** the
    ///   daemon runs at `ppid == 1` with its cwd inside a TBD tree — when
    ///   `scripts/restart.sh` is run from a worktree, that worktree — so
    ///   archiving it would otherwise have the sweep SIGKILL the live daemon
    ///   running the sweep.
    /// - its cwd is readable, and resolves under a TBD-managed root positively
    ///   known to be dead — an archived worktree (or its scratchpad), or a
    ///   `.deleting/<uuid>` queue entry. A directory nobody can attest is dead,
    ///   including an unrecognized child of a worktree pool, keeps.
    /// - it is at least as old as the cwd reading it was joined to, so a pid
    ///   the kernel reissued between the two readings cannot inherit a dead
    ///   process's cwd. An unreadable age fails this, i.e. keeps.
    /// - the grace window has passed: from `archivedAt` where an archived row
    ///   established the death, and from process start time for a `.deleting/`
    ///   entry, which carries no such instant.
    public func candidates(
        processes: [ProcessSnapshotEntry],
        cwdByPID: [Int32: String],
        cwdsCapturedAt: Date,
        roots: TBDProcessRoots,
        ourUID: uid_t,
        ourPID: Int32,
        graceSeconds: Int
    ) -> [OrphanProcessCandidate] {
        let protected = protectedPIDs(processes: processes, ourPID: ourPID, ourUID: ourUID)
        // How stale the cwd map is by the time this snapshot was read. Never
        // negative, so a clock that went backwards cannot weaken the gate.
        let cwdAge = max(0, now().timeIntervalSince(cwdsCapturedAt))
        var result: [OrphanProcessCandidate] = []
        for entry in processes.sorted(by: { $0.pid < $1.pid }) {
            guard entry.pid > 1, entry.ppid == 1 else { continue }
            // Covers the uid exclusion too: `protectedPIDs` holds every process
            // owned by someone else, so there is one enforcement point rather
            // than a root-only gate here and nothing at all on descendants.
            guard !protected.contains(entry.pid) else { continue }
            // Absence of evidence is not evidence of an orphan. A process whose
            // cwd could not be read is skipped, never reclaimed — the direction
            // that matters most here, because the whole rule is keyed on cwd.
            guard let cwd = cwdByPID[entry.pid] else {
                logger.debug("""
                gc: orphan-process skip pid \(entry.pid, privacy: .public) — cwd unreadable
                """)
                continue
            }
            // The cwd map and this snapshot are two readings taken at different
            // moments and joined by **pid alone**, and macOS recycles pids. A
            // process younger than the gap cannot be the one lsof saw: its pid
            // was reissued in between, and the cwd it matched is a dead
            // process's. Skip it — evidence of the wrong process is worse than
            // no evidence. An unreadable age is skipped for the same reason,
            // which also makes "an unparseable etime keeps the process" true
            // for BOTH grace arms rather than only the no-row one.
            guard let age = entry.elapsedSeconds, age >= cwdAge else {
                logger.debug("""
                gc: orphan-process skip pid \(entry.pid, privacy: .public) — \
                younger than the cwd reading, so the pid may have been reused
                """)
                continue
            }
            guard case .dead(let root) = ownership(ofCWD: cwd, roots: roots) else { continue }
            guard graceElapsed(root: root, entry: entry, graceSeconds: graceSeconds) else { continue }
            result.append(OrphanProcessCandidate(
                pid: entry.pid, cwd: cwd, rootPath: root.path, command: entry.command))
        }
        return result
    }

    /// Classifies one resolved cwd against the TBD-managed path universe.
    ///
    /// The longest matching prefix wins, so a worktree nested inside a pool is
    /// classified by the worktree rather than the pool. A tie between a live
    /// and a dead owner resolves to `live` — keep-biased, like every other gate
    /// in this sweep.
    ///
    /// Reclamation needs **positive evidence of death**, and there are exactly
    /// two kinds. An archived row is one, and arrives as a `dead` entry. A
    /// `<pool>/.deleting/<uuid>` queue entry is the other: TBD renamed the
    /// directory there itself, so it is garbage by construction, and it is
    /// reported with no archive instant because there is no row left to carry
    /// one. Its root is the two-component entry path rather than the pool, so
    /// the reap record names a worktree-shaped path.
    ///
    /// Every other unrecognized cwd is `outside`, under a pool as much as
    /// under a shared root. The absence of a row is not evidence of death: a
    /// directory a person made under a pool by hand acquires a row only when
    /// something calls `WorktreeLifecycle.reconcile`, which has no periodic
    /// caller at all, so on a daemon up for days a live hand-made worktree and
    /// a leftover are indistinguishable — and this file resolves every
    /// ambiguity by keeping.
    public func ownership(ofCWD cwd: String, roots: TBDProcessRoots) -> CWDOwnership {
        let poolMatch = longestPrefix(of: cwd, among: roots.pools)
        let sharedMatch = longestPrefix(of: cwd, among: roots.sharedRoots)
        guard poolMatch != nil || sharedMatch != nil else { return .outside }

        let liveMatch = longestPrefix(of: cwd, among: roots.live)
        let deadMatch = roots.dead
            .filter { isUnder(cwd, prefix: $0.path) }
            .max(by: { $0.path.count < $1.path.count })

        if let liveMatch, liveMatch.count >= (deadMatch?.path.count ?? 0) {
            return .live(path: liveMatch)
        }
        if let deadMatch {
            return .dead(deadMatch)
        }
        // Unrecognized by any row. The one stray that is still positive
        // evidence of death is a `.deleting/<uuid>` entry TBD renamed there
        // itself; everything else under a pool is ambiguous and keeps. Claimed
        // only when no shared root sits deeper — a nested shared root wins.
        guard let poolMatch, poolMatch.count > (sharedMatch?.count ?? -1),
              let queued = Self.deletionQueueEntry(of: cwd, pool: poolMatch)
        else { return .outside }
        return .dead(DeadWorktreeRoot(path: queued, archivedAt: nil))
    }

    /// `gcGraceSeconds` measured from `archivedAt` where an archived row
    /// established the death, and from process start time for a `.deleting/`
    /// queue entry, which carries no such instant. An unparseable start time
    /// keeps the process.
    func graceElapsed(
        root: DeadWorktreeRoot, entry: ProcessSnapshotEntry, graceSeconds: Int
    ) -> Bool {
        if let archivedAt = root.archivedAt {
            return now().timeIntervalSince(archivedAt) >= Double(graceSeconds)
        }
        guard let elapsed = entry.elapsedSeconds else { return false }
        return elapsed >= Double(graceSeconds)
    }

    /// `ourPID`, its ancestors, every `TBDDaemon`/`TBDApp` process in the
    /// snapshot, and every process owned by a uid other than `ourUID`. Never
    /// signalled, and never descended into when computing a descendant closure.
    ///
    /// The uid exclusion lives here rather than only at the orphan root because
    /// a root-only gate is not the exclusion the sweep claims: once a root
    /// passed it, every descendant entered the kill volley whatever its own uid
    /// was, and only `kill(2)` returning `EPERM` across uids kept the promise.
    /// That is the kernel's guarantee, not this collector's, and it evaporates
    /// wherever the daemon is not the unprivileged per-user process it is today.
    ///
    /// A foreign uid protects the process **entirely** — the walk stops there,
    /// so an `ourUID` grandchild underneath one keeps running. Reclaiming it
    /// would mean reaching across a privilege boundary on the strength of a
    /// parent link, and every degraded-input path in this file is keep-favoring
    /// instead. The grandchild is not lost to the reconciler either: when its
    /// foreign parent exits, it reparents to launchd and the next sweep sees it
    /// as an orphan root of its own.
    func protectedPIDs(
        processes: [ProcessSnapshotEntry], ourPID: Int32, ourUID: uid_t
    ) -> Set<Int32> {
        var byPID: [Int32: ProcessSnapshotEntry] = [:]
        for entry in processes { byPID[entry.pid] = entry }

        var protected: Set<Int32> = [0, 1, ourPID]
        // Walk our own ancestry. Bounded by `protected` growing on every step,
        // so a cyclic (corrupt) snapshot terminates instead of hanging a sweep.
        var cursor = ourPID
        while let entry = byPID[cursor], !protected.contains(entry.ppid) {
            protected.insert(entry.ppid)
            cursor = entry.ppid
        }
        for entry in processes where Self.isTBDBinary(entry.command) {
            protected.insert(entry.pid)
        }
        for entry in processes where entry.uid != ourUID {
            protected.insert(entry.pid)
        }
        return protected
    }

    /// True when the executable this process is running is `TBDDaemon` or
    /// `TBDApp`.
    ///
    /// `ps -o command=` prints argv space-joined and unquoted, so where argv[0]
    /// ends is genuinely ambiguous: a home directory named `Jane Roe` yields
    /// `~/tbd/.build/debug/TBDApp` as two tokens, `.../Jane` and
    /// `Roe/tbd/.build/debug/TBDApp`. Taking only the first would read that
    /// basename as `Jane` and leave the app unprotected — and `isTBDBinary` is
    /// the ONLY thing protecting
    /// `TBDApp` and any sibling worktree's daemon, neither of which is in this
    /// process's ancestry.
    ///
    /// So every whitespace-delimited token is checked, and any one of them
    /// having basename `TBDDaemon`/`TBDApp` protects the process.
    /// That over-matches — a stray argument spelled `.../TBDApp` protects its
    /// process too — and over-matching is the keep-favoring direction, which is
    /// the one this whole sweep takes. Matching stays on the **basename**, so a
    /// path that merely contains the name (every TBD worktree does) is still
    /// not mistaken for the binary.
    static func isTBDBinary(_ command: String) -> Bool {
        for token in command.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let basename = token.split(separator: "/").last.map(String.init) ?? String(token)
            if basename == "TBDDaemon" || basename == "TBDApp" { return true }
        }
        return false
    }

    // MARK: - Identity across time

    /// How far a re-read start instant may sit from the one the plan recorded
    /// and still be the same process.
    ///
    /// `ps etime` is whole seconds truncated, so two readings of one process
    /// can disagree by just under a second, and the instant a snapshot is
    /// stamped is not the instant the kernel filled it in. Two seconds absorbs
    /// both. It does not weaken the substitution test it guards: a reissued
    /// pid necessarily started AFTER the reading that recorded the pid it
    /// replaced, so its start instant moves by the whole age of that reading's
    /// subject — days, in every orphan measured here — and never by a second.
    public static let identityDriftTolerance: TimeInterval = 2

    /// Start instant per pid: the snapshot's capture time minus the row's
    /// `etime`. This is the cheap identity of a process across time — the pid
    /// alone is not one, because macOS reissues pids, and a reissued pid
    /// necessarily carries a later start instant than the one a snapshot
    /// recorded for it.
    ///
    /// A row whose `etime` did not parse is deliberately ABSENT from the map,
    /// so it can never be verified and is therefore never signalled: the same
    /// keep-favoring direction an unreadable cwd and an unparseable age take
    /// on the identification side.
    public static func startInstants(
        _ processes: [ProcessSnapshotEntry], capturedAt: Date
    ) -> [Int32: Date] {
        var result: [Int32: Date] = [:]
        for entry in processes {
            guard let elapsed = entry.elapsedSeconds else { continue }
            result[entry.pid] = capturedAt.addingTimeInterval(-elapsed)
        }
        return result
    }

    /// The members of `tree`, in the plan's leaf-first order, whose identity in
    /// a FRESH `ps` reading still matches what the plan recorded for them.
    ///
    /// Called immediately before every volley — the SIGTERM one and the SIGKILL
    /// escalation alike — and for descendants exactly as for the root. The
    /// sweep's own snapshot is not enough on its own: `reclaimOrphanProcesses`
    /// reaps candidates one after another and each reap blocks for up to
    /// `graceAttempts × pollInterval`, so with the half-dozen simultaneous
    /// orphans a field census found, the last candidate's tree would otherwise
    /// be signalled many seconds after the reading that named its pids. The
    /// root's `age >= cwdAge` gate in `candidates(…)` covers neither that
    /// drift nor descendants, which enter a tree purely by the snapshot's ppid
    /// chain.
    ///
    /// `nil` means the re-reading itself failed, and the caller must signal
    /// nothing at all: an identity that cannot be re-read is a skip, never a
    /// kill.
    func verifiedTargets(
        _ tree: [Int32], plannedStarts: [Int32: Date]
    ) async -> [Int32]? {
        // Stamped BEFORE the reading rather than after it, so any delay in
        // taking the snapshot widens the apparent drift rather than hiding it.
        let capturedAt = now()
        guard let fresh = await snapshotProvider() else {
            logger.warning("""
            gc: orphan-process identity re-read failed — signalling nothing this volley
            """)
            return nil
        }
        let current = Self.startInstants(fresh, capturedAt: capturedAt)
        return tree.filter { pid in
            guard let planned = plannedStarts[pid] else {
                logger.debug("""
                gc: orphan-process skip pid \(pid, privacy: .public) — \
                the plan recorded no start instant for it
                """)
                return false
            }
            guard let live = current[pid] else {
                logger.debug("""
                gc: orphan-process skip pid \(pid, privacy: .public) — \
                gone or unreadable at signal time
                """)
                return false
            }
            let drift = abs(live.timeIntervalSince(planned))
            guard drift <= Self.identityDriftTolerance else {
                logger.warning("""
                gc: orphan-process skip pid \(pid, privacy: .public) — start time moved \
                \(Int(drift), privacy: .public)s since the sweep planned this tree, \
                so the pid now names a different process
                """)
                return false
            }
            return true
        }
    }

    // MARK: - Reclamation

    /// The orphan root plus every descendant of it in the snapshot, ordered
    /// **leaf-first** (deepest generation first).
    ///
    /// Computed here rather than by calling
    /// `ProcessSignaller.children(ofServerPID:)` in a loop, because that helper
    /// walks exactly one generation by construction. A protected pid is skipped
    /// and never descended into.
    ///
    /// Leaf-first so that no descendant is still unsignalled at the moment its
    /// ancestor gets SIGTERM — an ancestor signalled first could spend its own
    /// shutdown respawning children that are not in this list. It is an
    /// ordering, not a barrier: `reap` sends the whole ordered volley without
    /// waiting between generations, so a process that forks during its own
    /// SIGTERM handling can still leave a child behind. That residue is
    /// keep-biased — the next hourly sweep sees it as an orphan of its own.
    ///
    /// Membership here is decided purely by the snapshot's ppid chain, which
    /// says nothing about whether a pid still names the same process by the
    /// time the volley reaches it. That is `verifiedTargets`' job, and it runs
    /// on this list — root and descendants alike — immediately before each
    /// signal.
    public func descendantClosure(
        of pid: Int32, processes: [ProcessSnapshotEntry], protected: Set<Int32>
    ) -> [Int32] {
        var childrenByPPID: [Int32: [Int32]] = [:]
        for entry in processes where entry.pid != entry.ppid {
            childrenByPPID[entry.ppid, default: []].append(entry.pid)
        }
        var byDepth: [[Int32]] = []
        var frontier: [Int32] = protected.contains(pid) ? [] : [pid]
        var seen: Set<Int32> = Set(frontier)
        while !frontier.isEmpty {
            byDepth.append(frontier)
            var next: [Int32] = []
            for parent in frontier {
                for child in childrenByPPID[parent, default: []].sorted() {
                    guard !protected.contains(child), seen.insert(child).inserted else { continue }
                    next.append(child)
                }
            }
            frontier = next
        }
        return byDepth.reversed().flatMap { $0 }
    }

    /// SIGTERM the whole subtree leaf-first, poll for
    /// `graceAttempts × pollInterval`, then SIGKILL whatever is still alive —
    /// again leaf-first.
    ///
    /// Every volley is filtered through `verifiedTargets` first, so a pid whose
    /// start instant has moved since `plannedStarts` was taken is dropped
    /// rather than signalled, and a re-reading that fails drops the whole
    /// volley. This is what makes the pid-reuse protection hold for the LAST
    /// candidate of a multi-orphan sweep and for descendants, neither of which
    /// the root-only `age >= cwdAge` gate in `candidates(…)` reaches.
    ///
    /// Signalling goes through `ProcessSignaller` rather than raw `kill(2)` so
    /// tests never send a real signal, and so the `pid <= 1` refusal lives in
    /// exactly one place. It uses the seam's **process-only** methods: the
    /// ordinary `terminate`/`forceKill` escalate to a group kill whenever the
    /// pid is its own group leader, and a process group is a superset of the
    /// *group*, not of this closure. That superset can hold a pid this sweep
    /// deliberately protected, and on a reused pid it resolves to a stranger's
    /// group outright — so the promise that a protected process is never
    /// signalled would not survive it. Group semantics are also not
    /// *sufficient* here, which is why the closure exists at all.
    ///
    /// Returns `nil` for an empty subtree (nothing was signalled, so there is
    /// nothing to record).
    public func reap(
        _ candidate: OrphanProcessCandidate, tree: [Int32],
        plannedStarts: [Int32: Date], repoPath: String
    ) async -> ReapRecord? {
        guard !tree.isEmpty else { return nil }

        guard let targets = await verifiedTargets(tree, plannedStarts: plannedStarts),
              !targets.isEmpty else {
            logger.info("""
            gc: orphan-process pid \(candidate.pid, privacy: .public) — nothing left to \
            signal once identities were re-read; keeping the whole tree
            """)
            return nil
        }

        for pid in targets {
            signaller.terminateProcessOnly(pid)
        }
        for _ in 0..<graceAttempts {
            if !targets.contains(where: { signaller.isAlive($0) }) { break }
            try? await clock.sleep(for: pollInterval)
        }
        let survivors = targets.filter { signaller.isAlive($0) }
        if !survivors.isEmpty {
            // Re-verified separately, because the grace window is itself wall
            // time — `graceAttempts × pollInterval`, ≈3s by default — during
            // which a member that honored SIGTERM can exit and have its pid
            // reissued to a stranger. SIGKILL is the signal nothing survives,
            // so it gets the same check the SIGTERM volley got, not the
            // SIGTERM volley's now-stale conclusion.
            let killable = await verifiedTargets(survivors, plannedStarts: plannedStarts) ?? []
            for pid in killable {
                logger.warning("""
                gc: orphan-process pid \(pid, privacy: .public) survived SIGTERM — sending SIGKILL
                """)
                signaller.forceKillProcessOnly(pid)
            }
        }

        logger.info("""
        gc: reclaimed orphan process pid \(candidate.pid, privacy: .public) \
        (subtree of \(targets.count, privacy: .public)) rooted in \
        \(candidate.rootPath, privacy: .public)
        """)
        return ReapRecord(
            kind: .orphanProcess,
            repoPath: repoPath,
            // Not a path this reap removed — nothing on disk was touched. It is
            // the dead worktree the process was rooted in, which is the only
            // place-shaped fact an orphan-process record has.
            worktreePath: candidate.rootPath,
            // The set actually signalled, not the set planned: a member dropped
            // by the identity check was never touched, and the record is an
            // audit trail of what this sweep did.
            processDescription: Self.describe(candidate: candidate, tree: targets),
            reapedAt: now()
        )
    }

    /// `pid=<pid> tree=<n> <argv truncated>` — what was killed, not merely
    /// where it lived.
    static func describe(candidate: OrphanProcessCandidate, tree: [Int32]) -> String {
        let argv = candidate.command.prefix(200)
        return "pid=\(candidate.pid) tree=\(tree.count) \(argv)"
    }

    // MARK: - Path helpers

    private func longestPrefix(of path: String, among prefixes: [String]) -> String? {
        prefixes.filter { isUnder(path, prefix: $0) }.max(by: { $0.count < $1.count })
    }

    /// `path` is `prefix` itself or strictly below it. Component-wise, so
    /// `/a/pool-2` is never read as living under `/a/pool`.
    private func isUnder(_ path: String, prefix: String) -> Bool {
        guard !prefix.isEmpty else { return false }
        return path == prefix || path.hasPrefix(prefix.hasSuffix("/") ? prefix : prefix + "/")
    }

    /// The `<pool>/.deleting/<uuid>` queue entry `cwd` sits inside, or `nil`
    /// when it sits under no such entry — which includes every ordinary child
    /// of the pool, and the queue directory itself, since that directory owns
    /// nothing and its own death is not attested by anything.
    static func deletionQueueEntry(of cwd: String, pool: String) -> String? {
        let base = pool.hasSuffix("/") ? String(pool.dropLast()) : pool
        guard cwd.count > base.count else { return nil }
        let rest = cwd.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard rest.count > 1, rest[0] == WorktreeDeletionQueue.dirName else { return nil }
        return base + "/" + rest[0] + "/" + rest[1]
    }

    // MARK: - Real `ps` snapshot

    /// One `/bin/ps` snapshot of every process on the machine, or `nil` when it
    /// could not be taken — which the caller MUST treat as "skip this phase",
    /// never as "no orphans".
    ///
    /// `-ww` disables column-width truncation, without which macOS clips the
    /// command column even when stdout is a pipe.
    public static func realProcessSnapshot() async -> [ProcessSnapshotEntry]? {
        let outcome: BoundedProcessOutcome
        do {
            outcome = try await runBoundedProcess(
                executable: "/bin/ps",
                arguments: ["-axww", "-o", "pid=,ppid=,pgid=,uid=,etime=,command="],
                currentDirectory: nil,
                timeout: .seconds(60)
            )
        } catch {
            logger.error("gc: ps spawn failed: \(String(describing: error), privacy: .public)")
            return nil
        }
        return parseProcessSnapshot(outcome)
    }

    /// Pure parser, extracted so the "unavailable ⇒ skip the phase" direction
    /// is directly unit-testable. Same failure vocabulary as
    /// `OrphanGC.parseLiveCWDs`: a timeout, a non-zero exit and non-UTF-8
    /// output all yield `nil` rather than a partial picture.
    static func parseProcessSnapshot(_ outcome: BoundedProcessOutcome) -> [ProcessSnapshotEntry]? {
        switch outcome {
        case .timedOut:
            logger.error("gc: ps timed out after 60s")
            return nil
        case .completed(let status, let stdout, _):
            guard status == 0 else {
                logger.error("""
                gc: ps exited \(status, privacy: .public) — treating the process snapshot as unavailable
                """)
                return nil
            }
            guard let text = String(data: stdout, encoding: .utf8) else {
                logger.error("gc: ps output was not valid UTF-8")
                return nil
            }
            return parseProcessLines(text)
        }
    }

    /// `pid ppid pgid uid etime command...` — five fixed fields, then the
    /// command, which may contain spaces and is therefore taken whole.
    static func parseProcessLines(_ text: String) -> [ProcessSnapshotEntry] {
        var result: [ProcessSnapshotEntry] = []
        for line in text.split(separator: "\n") {
            // Hand-scanned rather than `split(maxSplits:)`: `ps` right-aligns
            // its numeric columns, so the runs of padding between them would
            // eat an unpredictable share of any split budget. Take exactly five
            // whitespace-delimited tokens, then keep the rest verbatim — the
            // command legitimately contains spaces.
            var rest = line[...]
            var fields: [Substring] = []
            for _ in 0..<5 {
                rest = rest.drop(while: { $0 == " " || $0 == "\t" })
                guard let end = rest.firstIndex(where: { $0 == " " || $0 == "\t" }) else {
                    if !rest.isEmpty { fields.append(rest) }
                    rest = rest[rest.endIndex...]
                    break
                }
                fields.append(rest[..<end])
                rest = rest[end...]
            }
            guard fields.count == 5,
                  let pid = Int32(fields[0]), let ppid = Int32(fields[1]),
                  let pgid = Int32(fields[2]), let uid = UInt32(fields[3])
            else { continue }
            result.append(ProcessSnapshotEntry(
                pid: pid, ppid: ppid, pgid: pgid, uid: uid_t(uid),
                elapsedSeconds: parseETime(String(fields[4])),
                command: String(rest.drop(while: { $0 == " " || $0 == "\t" }))
            ))
        }
        return result
    }

    /// `ps etime`: `[[dd-]hh:]mm:ss`. Returns `nil` for anything that does not
    /// parse, which the grace gate reads as "too young to touch".
    static func parseETime(_ raw: String) -> TimeInterval? {
        var days = 0.0
        var rest = raw
        if let dash = rest.firstIndex(of: "-") {
            guard let parsed = Double(rest[rest.startIndex..<dash]) else { return nil }
            days = parsed
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map(String.init)
        guard (2...3).contains(parts.count) else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            seconds = seconds * 60 + value
        }
        return days * 86_400 + seconds
    }
}
