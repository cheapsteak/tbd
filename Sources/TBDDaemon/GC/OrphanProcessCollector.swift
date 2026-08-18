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
    /// When the owning row was archived. `nil` means no row survives at all,
    /// in which case grace is measured from process start instead — there is
    /// no archive instant to measure from.
    public var archivedAt: Date?

    public init(path: String, archivedAt: Date?) {
        self.path = path
        self.archivedAt = archivedAt
    }
}

/// The TBD-managed path universe one sweep classifies cwds against.
public struct TBDProcessRoots: Sendable {
    /// Canonical pool prefixes: each repo's worktree pool directory (canonical
    /// and legacy), the scratch-worktree pool, and the Claude scratchpad base.
    /// A cwd outside every one of these is never a candidate, whatever its
    /// parentage.
    public var pools: [String]
    /// Canonical paths of worktrees that are still alive. A cwd under one of
    /// these is never a candidate, even at `ppid == 1` — that narrowness is
    /// what keeps a deliberately detached dev server safe until the developer
    /// has archived the worktree it belonged to.
    public var live: [String]
    /// Canonical paths of worktrees that are dead, with the archive instant
    /// where the row survives to carry one.
    public var dead: [DeadWorktreeRoot]

    public init(pools: [String], live: [String], dead: [DeadWorktreeRoot]) {
        self.pools = pools
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
    /// Under a dead worktree, a `.deleting/` entry, or a scratchpad.
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
/// This type never reads the database and never spawns anything: the caller
/// supplies the `ps` snapshot, the pid-to-cwd map, and the root classification,
/// the same division of labor `ProfileDirCollector` and `DeletionQueueCollector`
/// keep with `OrphanGC`.
///
/// Every failure direction is toward KEEPING: an unreadable cwd, an unparseable
/// start time, a uid that is not ours, and any ambiguity between a live and a
/// dead owner all leave the process running.
public struct OrphanProcessCollector: Sendable {
    let signaller: any ProcessSignaller
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
        now: @escaping @Sendable () -> Date = Date.init,
        graceAttempts: Int = 30,
        pollInterval: Duration = .milliseconds(100),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.signaller = signaller
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
    /// - owned by `ourUID`.
    /// - `pid > 1`, and neither `ourPID` nor one of its ancestors.
    /// - not a `TBDDaemon` or `TBDApp` process. **Not hypothetical:** the
    ///   daemon runs at `ppid == 1` with its cwd inside a TBD tree — when
    ///   `scripts/restart.sh` is run from a worktree, that worktree — so
    ///   archiving it would otherwise have the sweep SIGKILL the live daemon
    ///   running the sweep.
    /// - its cwd is readable, and resolves under a dead TBD-managed root.
    /// - the grace window has passed: from `archivedAt` where the row survives
    ///   to carry one, and from process start time where it does not.
    public func candidates(
        processes: [ProcessSnapshotEntry],
        cwdByPID: [Int32: String],
        roots: TBDProcessRoots,
        ourUID: uid_t,
        ourPID: Int32,
        graceSeconds: Int
    ) -> [OrphanProcessCandidate] {
        let protected = protectedPIDs(processes: processes, ourPID: ourPID)
        var result: [OrphanProcessCandidate] = []
        for entry in processes.sorted(by: { $0.pid < $1.pid }) {
            guard entry.pid > 1, entry.ppid == 1 else { continue }
            guard entry.uid == ourUID else { continue }
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
    /// A cwd under a pool that matches no row at all is `dead` with no archive
    /// instant: that is the "absent from the database" arm, which covers
    /// `.deleting/` entries and directories whose row was hard-deleted. Its
    /// root is the pool's own child (two components for a `.deleting/<uuid>`
    /// entry) so the record names a worktree-shaped path rather than the pool.
    public func ownership(ofCWD cwd: String, roots: TBDProcessRoots) -> CWDOwnership {
        guard let pool = longestPrefix(of: cwd, among: roots.pools) else { return .outside }

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
        return .dead(DeadWorktreeRoot(path: Self.poolChild(of: cwd, pool: pool), archivedAt: nil))
    }

    /// `gcGraceSeconds` measured from `archivedAt` where a row survives, and
    /// from process start time where it does not. An unparseable start time
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

    /// `ourPID`, its ancestors, and every `TBDDaemon`/`TBDApp` process in the
    /// snapshot. Never signalled, and never descended into when computing a
    /// descendant closure.
    func protectedPIDs(processes: [ProcessSnapshotEntry], ourPID: Int32) -> Set<Int32> {
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
        return protected
    }

    /// True when argv[0]'s basename is `TBDDaemon` or `TBDApp`. Matched on the
    /// basename, so a path that merely *contains* the name (every TBD worktree
    /// does) is not mistaken for the binary.
    static func isTBDBinary(_ command: String) -> Bool {
        guard let arg0 = command.split(whereSeparator: { $0 == " " || $0 == "\t" }).first else {
            return false
        }
        let basename = arg0.split(separator: "/").last.map(String.init) ?? String(arg0)
        return basename == "TBDDaemon" || basename == "TBDApp"
    }

    // MARK: - Reclamation

    /// The orphan root plus every descendant of it in the snapshot, ordered
    /// **leaf-first** (deepest generation first).
    ///
    /// Computed here rather than by calling
    /// `ProcessSignaller.children(ofServerPID:)` in a loop, because that helper
    /// walks exactly one generation by construction. Leaf-first so a parent
    /// cannot fork a replacement child while its own subtree is being torn
    /// down. A protected pid is skipped and never descended into.
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
    /// Signalling goes through `ProcessSignaller` rather than raw `kill(2)` so
    /// tests never send a real signal, and so the `pid <= 1` refusal lives in
    /// exactly one place. That seam group-kills when the pid happens to be its
    /// own group leader; here that is a harmless superset, because every member
    /// of the closure is already being signalled individually. What it is not
    /// is *sufficient* — which is why the closure exists.
    ///
    /// Returns `nil` for an empty subtree (nothing was signalled, so there is
    /// nothing to record).
    public func reap(
        _ candidate: OrphanProcessCandidate, tree: [Int32], repoPath: String
    ) async -> ReapRecord? {
        guard !tree.isEmpty else { return nil }

        for pid in tree {
            signaller.terminate(pid)
        }
        for _ in 0..<graceAttempts {
            if !tree.contains(where: { signaller.isAlive($0) }) { break }
            try? await clock.sleep(for: pollInterval)
        }
        for pid in tree where signaller.isAlive(pid) {
            logger.warning("""
            gc: orphan-process pid \(pid, privacy: .public) survived SIGTERM — sending SIGKILL
            """)
            signaller.forceKill(pid)
        }

        logger.info("""
        gc: reclaimed orphan process pid \(candidate.pid, privacy: .public) \
        (subtree of \(tree.count, privacy: .public)) rooted in \
        \(candidate.rootPath, privacy: .public)
        """)
        return ReapRecord(
            kind: .orphanProcess,
            repoPath: repoPath,
            // Not a path this reap removed — nothing on disk was touched. It is
            // the dead worktree the process was rooted in, which is the only
            // place-shaped fact an orphan-process record has.
            worktreePath: candidate.rootPath,
            processDescription: Self.describe(candidate: candidate, tree: tree),
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

    /// The worktree-shaped child of `pool` that `cwd` sits under: one component
    /// normally, two for a `<pool>/.deleting/<uuid>` queue entry, since the
    /// queue directory itself owns nothing.
    static func poolChild(of cwd: String, pool: String) -> String {
        let base = pool.hasSuffix("/") ? String(pool.dropLast()) : pool
        guard cwd.count > base.count else { return base }
        let rest = cwd.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard let first = rest.first else { return base }
        if first == WorktreeDeletionQueue.dirName, rest.count > 1 {
            return base + "/" + first + "/" + rest[1]
        }
        return base + "/" + first
    }

    // MARK: - Real `ps` snapshot

    /// One `/bin/ps` snapshot of every process on the machine, or `nil` when it
    /// could not be taken — which the caller MUST treat as "skip this phase",
    /// never as "no orphans".
    ///
    /// `-ww` disables column-width truncation, without which macOS clips the
    /// command column even when stdout is a pipe.
    static func realProcessSnapshot() async -> [ProcessSnapshotEntry]? {
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
