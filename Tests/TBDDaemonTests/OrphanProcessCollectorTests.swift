import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared
import TestSupport

/// Tier 1: pure classification and parsing. No database, no filesystem, no
/// subprocess and no real signal — the collector is handed its `ps` snapshot,
/// its pid-to-cwd map and its root classification, and answers.
///
/// The exception is the pair of `parseLiveCWDs` tests that name real paths:
/// canonicalizing a cwd is a `realpath(3)` call, so those are tier 2 and own a
/// scratch directory rather than naming a path on the developer's machine.
@Suite("OrphanProcessCollector")
struct OrphanProcessCollectorTests {

    private let pool = "/pool"
    private let dead = "/pool/gone"
    private let alive = "/pool/working"

    private let shared = "/shared"

    private func roots(archivedAt: Date? = Date(timeIntervalSince1970: 0)) -> TBDProcessRoots {
        TBDProcessRoots(
            pools: [pool],
            sharedRoots: [shared],
            live: [alive],
            dead: [DeadWorktreeRoot(path: dead, archivedAt: archivedAt)])
    }

    private func entry(
        pid: Int32, ppid: Int32 = 1, pgid: Int32? = nil, uid: uid_t? = nil,
        elapsed: TimeInterval? = 86_400, command: String = "/usr/bin/node server.js"
    ) -> ProcessSnapshotEntry {
        ProcessSnapshotEntry(
            pid: pid, ppid: ppid, pgid: pgid ?? pid, uid: uid ?? getuid(),
            elapsedSeconds: elapsed, command: command)
    }

    /// `environment` is each pid's markers as the reader would report them,
    /// hidden for any pid it does not name; `startTimes` is each pid's start
    /// time as the kernel would report it after that read, unreadable for any
    /// pid it does not name. Both are always injected, so no test here reads a
    /// real process.
    private func collector(
        signaller: ProcessSignaller = FakeProcessSignaller(),
        now: Date = Date(timeIntervalSince1970: 1_000_000),
        snapshots: ScriptedSnapshots = ScriptedSnapshots([]),
        environment: [Int32: ProcessEnvironmentMarkers] = [:],
        startTimes: [Int32: Date] = [:]
    ) -> OrphanProcessCollector {
        OrphanProcessCollector(
            signaller: signaller,
            snapshotProvider: { await snapshots.next() },
            now: { now },
            environmentReader: { environment[$0] ?? .hidden },
            startTimeReader: { startTimes[$0] },
            graceAttempts: 2, pollInterval: .milliseconds(1))
    }

    /// Hands out one `ps` reading per call and then repeats the last, so a test
    /// can make the process table change between the reading a tree was planned
    /// from and the volley that acts on it. `nil` stands for a reading that
    /// could not be taken at all.
    final class ScriptedSnapshots: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [[ProcessSnapshotEntry]?]
        private(set) var calls = 0

        init(_ readings: [[ProcessSnapshotEntry]?]) {
            self.readings = readings.isEmpty ? [[]] : readings
        }

        func next() -> [ProcessSnapshotEntry]? {
            lock.withLock {
                calls += 1
                return readings.count > 1 ? readings.removeFirst() : readings[0]
            }
        }
    }

    /// The start instants a plan would have recorded for `processes`, stamped
    /// at the collector's own `now` so an unchanged process table verifies
    /// exactly.
    private func plannedStarts(
        _ processes: [ProcessSnapshotEntry],
        at now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> [Int32: Date] {
        OrphanProcessCollector.startInstants(processes, capturedAt: now)
    }

    // MARK: - Exclusions

    @Test("a process that is not reparented to launchd is never a candidate")
    func onlyPPID1() {
        let found = collector().candidates(
            processes: [entry(pid: 50, ppid: 42)],
            cwdByPID: [50: dead], cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000),
            roots: roots(),
            ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600)
        #expect(found.isEmpty)
    }

    @Test("a process owned by another uid is never a candidate")
    func onlyOurUID() {
        let found = collector().candidates(
            processes: [entry(pid: 50, uid: getuid() &+ 1)],
            cwdByPID: [50: dead], cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000),
            roots: roots(),
            ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600)
        #expect(found.isEmpty)
    }

    @Test("pid 1 is never a candidate even if everything else matches")
    func neverPID1() {
        let found = collector().candidates(
            processes: [entry(pid: 1, ppid: 1)],
            cwdByPID: [1: dead], cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000),
            roots: roots(),
            ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600)
        #expect(found.isEmpty)
    }

    /// The sweep runs inside the daemon, so the daemon's own pid and its whole
    /// ancestry have to be unreachable by construction, not merely by the
    /// binary-name check.
    @Test("our own pid and its ancestors are protected")
    func selfAndAncestorsProtected() {
        let ours = getpid()
        let processes = [
            entry(pid: ours, ppid: 4000),
            entry(pid: 4000, ppid: 1),
            entry(pid: 4001, ppid: 1),
        ]
        let protected = collector().protectedPIDs(
            processes: processes, ourPID: ours, ourUID: getuid())
        #expect(protected.contains(ours))
        #expect(protected.contains(4000), "our parent")
        #expect(!protected.contains(4001), "an unrelated ppid==1 process is not protected")

        let found = collector().candidates(
            processes: processes,
            cwdByPID: [ours: dead, 4000: dead, 4001: dead],
            cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000),
            roots: roots(), ourUID: getuid(), ourPID: ours, graceSeconds: 3600)
        #expect(found.map(\.pid) == [4001])
    }

    @Test("TBDDaemon and TBDApp are recognized by a path component's basename, not by substring")
    func tbdBinaryMatching() {
        #expect(OrphanProcessCollector.isTBDBinary("/w/tbd/.build/debug/TBDDaemon --foo"))
        #expect(OrphanProcessCollector.isTBDBinary("/w/.build/debug/TBD.app/Contents/MacOS/TBDApp"))
        // A path that merely contains the name — every TBD worktree does.
        #expect(!OrphanProcessCollector.isTBDBinary("/Users/me/tbd/worktrees/TBDDaemon/node"))
        #expect(!OrphanProcessCollector.isTBDBinary("/usr/bin/node"))
    }

    /// `ps -o command=` prints argv space-joined and unquoted, so a home
    /// directory with a space in it splits argv[0] in two. Reading only the
    /// first token would leave `TBDApp` — whose only protection this is —
    /// unrecognized and reapable.
    @Test("a space in the executable's own path does not defeat the TBD-binary match")
    func tbdBinaryMatchingSurvivesSpacedPaths() {
        #expect(OrphanProcessCollector.isTBDBinary(
            "/Users/Jane Roe/tbd/.build/debug/TBDDaemon"))
        #expect(OrphanProcessCollector.isTBDBinary(
            "/Users/Jane Roe/tbd/.build/debug/TBD.app/Contents/MacOS/TBDApp --verbose"))
        // Still not a substring match, spaces or no spaces.
        #expect(!OrphanProcessCollector.isTBDBinary(
            "/Users/Jane Roe/tbd/worktrees/TBDApp/node server.js"))
    }

    /// The cwd map and the `ps` snapshot are two readings joined by pid alone,
    /// and macOS recycles pids. A process younger than the gap between them
    /// cannot be the one lsof saw.
    @Test("a process younger than the cwd reading is skipped as a possible pid reuse")
    func youngerThanTheCWDReadingIsSkipped() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let subject = collector(now: now)
        // lsof ran 10 minutes before this snapshot; the process is 5 old.
        let reused = subject.candidates(
            processes: [entry(pid: 50, elapsed: 300)],
            cwdByPID: [50: dead], cwdsCapturedAt: now.addingTimeInterval(-600),
            roots: roots(), ourUID: getuid(), ourPID: 12_345, graceSeconds: 0)
        #expect(reused.isEmpty)

        // The same process, old enough to have existed when lsof ran.
        let genuine = subject.candidates(
            processes: [entry(pid: 50, elapsed: 900)],
            cwdByPID: [50: dead], cwdsCapturedAt: now.addingTimeInterval(-600),
            roots: roots(), ourUID: getuid(), ourPID: 12_345, graceSeconds: 0)
        #expect(genuine.map(\.pid) == [50])
    }

    @Test("an unreadable process age keeps the process even when the row carries archivedAt")
    func unknownAgeKeepsOnTheArchivedAtArm() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let found = collector(now: now).candidates(
            processes: [entry(pid: 50, elapsed: nil)],
            cwdByPID: [50: dead], cwdsCapturedAt: now,
            roots: roots(archivedAt: now.addingTimeInterval(-86_400)),
            ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600)
        #expect(found.isEmpty)
    }

    @Test("an unreadable cwd is a skip, never a reclaim")
    func unreadableCWDSkips() {
        let found = collector().candidates(
            processes: [entry(pid: 50)], cwdByPID: [:],
            cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000), roots: roots(),
            ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600)
        #expect(found.isEmpty)
    }

    // MARK: - Ownership

    @Test("a cwd under a live worktree is live, under a dead one is dead, elsewhere is outside")
    func ownershipClassification() {
        let subject = collector()
        #expect(subject.ownership(ofCWD: alive + "/src", roots: roots()) == .live(path: alive))
        #expect(subject.ownership(ofCWD: "/elsewhere", roots: roots()) == .outside)
        #expect(subject.ownership(ofCWD: dead + "/a/b", roots: roots())
            == .dead(DeadWorktreeRoot(path: dead, archivedAt: Date(timeIntervalSince1970: 0))))
    }

    /// Component-wise, so a sibling pool that merely shares a string prefix is
    /// never read as living inside the other.
    @Test("prefix matching is component-wise")
    func componentWisePrefixes() {
        let subject = collector()
        let sibling = TBDProcessRoots(
            pools: ["/pool"], live: ["/pool/work"], dead: [])
        #expect(subject.ownership(ofCWD: "/pool/work-2", roots: sibling) != .live(path: "/pool/work"))
        #expect(subject.ownership(ofCWD: "/poolside/x", roots: sibling) == .outside)
    }

    /// The Claude scratchpad base holds one directory per project Claude Code
    /// has ever run in — most of them nothing to do with TBD. A stray there is
    /// NOT a dead worktree, and treating it as one would put a stranger's live
    /// session on the kill list.
    @Test("an unrecognized child of a shared root is never a candidate")
    func strayUnderASharedRootIsKept() {
        let subject = collector()
        #expect(subject.ownership(ofCWD: shared + "/-Users-me-projects-acme/x", roots: roots())
            == .outside)
        // Only what an explicit live/dead entry names is classified there.
        let known = TBDProcessRoots(
            pools: [pool], sharedRoots: [shared], live: [shared + "/-live"],
            dead: [DeadWorktreeRoot(path: shared + "/-dead", archivedAt: nil)])
        #expect(subject.ownership(ofCWD: shared + "/-live/x", roots: known)
            == .live(path: shared + "/-live"))
        #expect(subject.ownership(ofCWD: shared + "/-dead/x", roots: known)
            == .dead(DeadWorktreeRoot(path: shared + "/-dead", archivedAt: nil)))
    }

    /// A shared root nested inside a pool must win: the pool's `.deleting/`
    /// claim stops at its edge.
    @Test("a shared root nested inside a pool keeps that pool's deleting arm out")
    func nestedSharedRootWins() {
        let nested = TBDProcessRoots(
            pools: [pool], sharedRoots: [pool + "/shared"], live: [], dead: [])
        #expect(
            collector().ownership(ofCWD: pool + "/shared/.deleting/abc/x", roots: nested)
                == .outside)
        #expect(collector().ownership(ofCWD: pool + "/.deleting/abc/x", roots: nested)
            == .dead(DeadWorktreeRoot(path: pool + "/.deleting/abc", archivedAt: nil)))
    }

    /// The only stray a pool claims. TBD renamed the directory into
    /// `.deleting/` itself, so it is garbage by construction — the positive
    /// evidence the arm requires.
    @Test("a `.deleting/<uuid>` entry is dead with no archive instant")
    func deletionQueueEntryIsDead() {
        let subject = collector()
        let onlyPool = TBDProcessRoots(pools: [pool], live: [], dead: [])
        #expect(subject.ownership(ofCWD: "/pool/.deleting/abc/sub", roots: onlyPool)
            == .dead(DeadWorktreeRoot(path: "/pool/.deleting/abc", archivedAt: nil)))
        #expect(subject.ownership(ofCWD: "/pool/.deleting/abc", roots: onlyPool)
            == .dead(DeadWorktreeRoot(path: "/pool/.deleting/abc", archivedAt: nil)))
        // The queue directory itself names no entry, so nothing attests to it.
        #expect(subject.ownership(ofCWD: "/pool/.deleting", roots: onlyPool) == .outside)
    }

    /// The absence of a row is not evidence of death. `WorktreeLifecycle`
    /// backfills a row for a directory TBD did not create only from startup,
    /// `repo.add` and the cleanup RPC — no timer calls it — so on a daemon up
    /// for days a worktree someone made by hand under the pool, or a bare
    /// `mkdir`, names no row and never will. TBD cannot tell that from
    /// leftover garbage, and this file resolves ambiguity by keeping.
    @Test("a pool child with no row at all is outside, not dead")
    func unrecognizedPoolChildIsKept() {
        let subject = collector()
        let onlyPool = TBDProcessRoots(pools: [pool], live: [], dead: [])
        #expect(subject.ownership(ofCWD: "/pool/hand-made/sub", roots: onlyPool) == .outside)
        #expect(subject.ownership(ofCWD: "/pool/hand-made", roots: onlyPool) == .outside)
        // Not even the pool itself.
        #expect(subject.ownership(ofCWD: pool, roots: onlyPool) == .outside)
    }

    // MARK: - Grace

    @Test("grace runs from archivedAt where a row survives")
    func graceFromArchivedAt() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let subject = collector(now: now)
        let young = DeadWorktreeRoot(path: dead, archivedAt: now.addingTimeInterval(-60))
        let old = DeadWorktreeRoot(path: dead, archivedAt: now.addingTimeInterval(-7200))
        #expect(!subject.graceElapsed(root: young, entry: entry(pid: 5), graceSeconds: 3600))
        #expect(subject.graceElapsed(root: old, entry: entry(pid: 5), graceSeconds: 3600))
    }

    @Test("grace runs from process start for a queue entry, and an unknown age keeps")
    func graceFromProcessStart() {
        let subject = collector()
        let noRow = DeadWorktreeRoot(path: dead, archivedAt: nil)
        #expect(!subject.graceElapsed(
            root: noRow, entry: entry(pid: 5, elapsed: 60), graceSeconds: 3600))
        #expect(subject.graceElapsed(
            root: noRow, entry: entry(pid: 5, elapsed: 7200), graceSeconds: 3600))
        #expect(!subject.graceElapsed(
            root: noRow, entry: entry(pid: 5, elapsed: nil), graceSeconds: 3600),
            "an unparseable start time is too young to touch")
    }

    // MARK: - Descendant closure

    @Test("the closure is leaf-first and independent of process group")
    func closureIsLeafFirst() {
        let processes = [
            entry(pid: 700, ppid: 1, pgid: 698),
            entry(pid: 701, ppid: 700, pgid: 698),
            entry(pid: 702, ppid: 701, pgid: 702),
            entry(pid: 703, ppid: 700, pgid: 698),
            entry(pid: 900, ppid: 1),
        ]
        let order = collector().descendantClosure(
            of: 700, processes: processes, protected: [0, 1])
        #expect(order == [702, 701, 703, 700])
        #expect(!order.contains(900), "an unrelated root is not in the closure")
    }

    @Test("a protected pid is neither signalled nor descended into")
    func closureStopsAtProtected() {
        let processes = [
            entry(pid: 700, ppid: 1),
            entry(pid: 701, ppid: 700, command: "/w/.build/debug/TBDDaemon"),
            entry(pid: 702, ppid: 701),
        ]
        let protected = collector().protectedPIDs(
            processes: processes, ourPID: 99_999, ourUID: getuid())
        let order = collector().descendantClosure(
            of: 700, processes: processes, protected: protected)
        #expect(order == [700])
    }

    /// The uid exclusion is a claim about every process this sweep signals, not
    /// only about the root that entered the closure. A foreign-uid descendant is
    /// fully protected — not signalled, and not walked through — so a process of
    /// ours sitting under another user's stays running rather than being reached
    /// for across a privilege boundary.
    @Test("a descendant owned by another uid is neither signalled nor descended through")
    func closureStopsAtForeignUID() {
        let processes = [
            entry(pid: 700, ppid: 1),
            entry(pid: 701, ppid: 700, uid: getuid() &+ 1),
            entry(pid: 702, ppid: 701),
            entry(pid: 703, ppid: 700),
        ]
        let protected = collector().protectedPIDs(
            processes: processes, ourPID: 99_999, ourUID: getuid())

        #expect(protected.contains(701), "a foreign-uid process is protected")
        let order = collector().descendantClosure(
            of: 700, processes: processes, protected: protected)
        #expect(
            order == [703, 700],
            "the foreign-uid child and the grandchild below it are both left alone")
    }

    // MARK: - Environment markers

    private let liveWorktree = UUID(uuidString: "A1000000-0000-4000-8000-000000000001")!
    private let archivedWorktree = UUID(uuidString: "A2000000-0000-4000-8000-000000000002")!
    private let liveTerminal = UUID(uuidString: "A3000000-0000-4000-8000-000000000003")!
    /// Where the archived worktree a marker names lived. Deliberately not
    /// `dead`, so a test can tell which root a candidate was named for.
    private let leftBehind = "/pool/left"
    private let archivedAt = Date(timeIntervalSince1970: 0)

    private var leftBehindRoot: DeadWorktreeRoot {
        DeadWorktreeRoot(path: leftBehind, archivedAt: archivedAt)
    }

    private func markerRows() -> MarkerRows {
        MarkerRows(
            liveWorktreeIDs: [liveWorktree],
            terminalIDs: [liveTerminal],
            archivedWorktrees: [archivedWorktree: leftBehindRoot])
    }

    private func marked(_ worktree: String? = nil, terminal: String? = nil) -> ProcessEnvironmentMarkers {
        .markers(worktreeID: worktree, terminalID: terminal)
    }

    /// `candidates(…)` for one escaped root, pid 50, at `cwd` with
    /// `markers`, whose start time verifies.
    private func judgedRoot(
        cwd: String, markers: ProcessEnvironmentMarkers, elapsed: TimeInterval = 86_400,
        cwdsCapturedAt: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> [OrphanProcessCandidate] {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let processes = [entry(pid: 50, elapsed: elapsed)]
        let starts = plannedStarts(processes, at: now)
        return collector(now: now, environment: [50: markers], startTimes: starts).candidates(
            processes: processes, cwdByPID: [50: cwd], cwdsCapturedAt: cwdsCapturedAt,
            roots: roots(), ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600,
            markerRows: markerRows(), plannedStarts: starts)
    }

    // Inverted (hidden read as a veto), every Apple platform binary the cwd
    // route reclaims today would be kept.
    @Test("a hidden environment is neutral")
    func hiddenIsNeutral() {
        #expect(OrphanProcessCollector.judge(.hidden, rows: markerRows()) == .neutral)
    }

    // Inverted (no markers read as neutral), TBD's own tmux servers fall back
    // to the cwd rule that kills them.
    @Test("a readable environment with no marker keeps: no TBD terminal started it")
    func noMarkersKeeps() {
        #expect(OrphanProcessCollector.judge(.noMarkers, rows: markerRows()) == .keep)
    }

    // Inverted, a process started in live work would fall to its cwd.
    @Test("a worktree marker naming a worktree that is not archived keeps")
    func aLiveWorktreeMarkerKeeps() {
        #expect(OrphanProcessCollector.judge(marked(liveWorktree.uuidString), rows: markerRows()) == .keep)
    }

    // Inverted, a tab's process with a stale worktree view would fall to its cwd.
    @Test("a terminal marker naming an existing row keeps")
    func anExistingTerminalMarkerKeeps() {
        #expect(OrphanProcessCollector.judge(
            marked(terminal: liveTerminal.uuidString), rows: markerRows()) == .keep)
    }

    // Fails against any judge that does not hand back the named row's root.
    @Test("a worktree marker naming an archived worktree admits, with that row's root")
    func anArchivedWorktreeMarkerAdmits() {
        #expect(OrphanProcessCollector.judge(
            marked(archivedWorktree.uuidString), rows: markerRows()) == .admit(leftBehindRoot))
    }

    // Inverted (a missing row read as death), every process in a worktree TBD
    // forgot, or with a closed tab, becomes killable.
    @Test("a marker naming no row is neutral, a closed tab's included")
    func aMarkerNamingNoRowIsNeutral() {
        #expect(OrphanProcessCollector.judge(marked(UUID().uuidString), rows: markerRows()) == .neutral)
        #expect(
            OrphanProcessCollector.judge(marked(terminal: UUID().uuidString), rows: markerRows())
                == .neutral,
            "a tab closed in a worktree still in use is not a death certificate")
    }

    // Fails if the archived worktree's admit were checked before the live clauses.
    @Test("when markers disagree, live wins")
    func liveWinsWhenMarkersDisagree() {
        #expect(OrphanProcessCollector.judge(
            marked(archivedWorktree.uuidString, terminal: liveTerminal.uuidString),
            rows: markerRows()) == .keep)
        // A worktree archived between the live read and the archived read sits
        // in both; reading live first is what makes it keep.
        var raced = markerRows()
        raced.liveWorktreeIDs.insert(archivedWorktree)
        #expect(OrphanProcessCollector.judge(marked(archivedWorktree.uuidString), rows: raced) == .keep)
    }

    // Fails against a case-sensitive comparison of strings, which would make
    // each of these neutral.
    @Test("a lowercase ID names the same row as the uppercase one TBD writes")
    func aLowercaseIDNamesTheSameRow() {
        let rows = markerRows()
        #expect(OrphanProcessCollector.judge(
            marked(liveWorktree.uuidString.lowercased()), rows: rows) == .keep)
        #expect(OrphanProcessCollector.judge(
            marked(terminal: liveTerminal.uuidString.lowercased()), rows: rows) == .keep)
        #expect(OrphanProcessCollector.judge(
            marked(archivedWorktree.uuidString.lowercased()), rows: rows) == .admit(leftBehindRoot))
    }

    // Inverted either way — garbage as a keep or as an admit — one of these fails.
    @Test("a marker that is not a UUID is neutral: never a keep, never an admit")
    func garbageIsNeutral() {
        let rows = markerRows()
        #expect(OrphanProcessCollector.judge(marked("not-a-uuid"), rows: rows) == .neutral)
        #expect(OrphanProcessCollector.judge(marked(""), rows: rows) == .neutral)
        #expect(OrphanProcessCollector.judge(marked("x", terminal: "y"), rows: rows) == .neutral)
        // It contributes nothing either way, so it neither keeps on its own nor
        // blocks the other marker's admit.
        #expect(OrphanProcessCollector.judge(
            marked(archivedWorktree.uuidString, terminal: "garbage"), rows: rows) == .admit(leftBehindRoot))
    }

    // Fails if the tree guard counted a member TBD did not start: most daemons
    // spawn helpers with no marker, and those must not keep a dead tree.
    @Test("only a marker naming live work counts for the tree guard")
    func namesSomethingLiveIsOnlyTheTwoKeepClauses() {
        let rows = markerRows()
        #expect(OrphanProcessCollector.namesSomethingLive(marked(liveWorktree.uuidString), rows: rows))
        #expect(OrphanProcessCollector.namesSomethingLive(
            marked(terminal: liveTerminal.uuidString), rows: rows))
        #expect(!OrphanProcessCollector.namesSomethingLive(.noMarkers, rows: rows))
        #expect(!OrphanProcessCollector.namesSomethingLive(.hidden, rows: rows))
        #expect(!OrphanProcessCollector.namesSomethingLive(marked(archivedWorktree.uuidString), rows: rows))
    }

    // Fails against a reader that skips the start-time re-check; the 1 s
    // control fails against one that demands an exact match.
    @Test("an environment read whose pid's start moved reads as hidden")
    func readMarkersIsHiddenWhenTheStartMoved() {
        let planned = Date(timeIntervalSince1970: 900_000)
        let markers = marked(archivedWorktree.uuidString)
        let moved = collector(
            environment: [50: markers], startTimes: [50: planned.addingTimeInterval(3)])
        #expect(
            moved.readMarkers(pid: 50, plannedStart: planned) == .hidden,
            "3 s is past the 2 s tolerance, so the pid now names another process")
        let jittered = collector(
            environment: [50: markers], startTimes: [50: planned.addingTimeInterval(1)])
        #expect(
            jittered.readMarkers(pid: 50, plannedStart: planned) == markers,
            "etime truncation stays inside the tolerance")
    }

    // Fails against a reader that trusts a read it has nothing to verify against.
    @Test("an environment read for a pid the plan recorded no start for reads as hidden")
    func readMarkersIsHiddenWhenNoStartWasPlanned() {
        let start = Date(timeIntervalSince1970: 900_000)
        let markers = marked(archivedWorktree.uuidString)
        let subject = collector(environment: [50: markers], startTimes: [50: start])
        #expect(subject.readMarkers(pid: 50, plannedStart: nil) == .hidden)
        #expect(subject.readMarkers(pid: 50, plannedStart: start) == markers)
    }

    // Fails against a reader that treats an unreadable start as a match.
    @Test("an environment read whose pid's start cannot be read now reads as hidden")
    func readMarkersIsHiddenWhenTheStartCannotBeRead() {
        let subject = collector(environment: [50: marked(archivedWorktree.uuidString)])
        #expect(subject.readMarkers(pid: 50, plannedStart: Date(timeIntervalSince1970: 900_000)) == .hidden)
    }

    // The three tests above pin `readMarkers` alone; these two pin that both
    // sweep call sites go through it. Fails against a `candidates` that calls
    // `environmentReader` directly: the archived marker would then admit 50 by
    // env, exactly as the verified control does.
    @Test("a root whose start moved after the plan is judged by its cwd alone")
    func candidatesReadsARootsMarkersThroughTheStartTimeCheck() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let processes = [entry(pid: 50)]
        let starts = plannedStarts(processes, at: now)
        let moved = starts.mapValues { $0.addingTimeInterval(3) }
        let environment = [Int32(50): marked(archivedWorktree.uuidString)]

        func found(liveStarts: [Int32: Date]) -> [OrphanProcessCandidate] {
            collector(now: now, environment: environment, startTimes: liveStarts).candidates(
                processes: processes, cwdByPID: [50: "/"], cwdsCapturedAt: now,
                roots: roots(), ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600,
                markerRows: markerRows(), plannedStarts: starts)
        }

        let verified = found(liveStarts: starts).map(\.route)
        #expect(verified == [OrphanAdmissionRoute.env], "the control: an unmoved start admits by env")
        #expect(
            found(liveStarts: moved).isEmpty,
            "the read is hidden, so the cwd decides, and `/` admits nothing")
    }

    // Fails against a `treeNamesSomethingLive` that calls `environmentReader`
    // directly: 61's live marker would then keep the tree, exactly as the
    // verified control does.
    @Test("a tree member whose start moved after the plan does not keep the tree")
    func theTreeGuardReadsMarkersThroughTheStartTimeCheck() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let processes = [entry(pid: 60), entry(pid: 61, ppid: 60)]
        let starts = plannedStarts(processes, at: now)
        let moved = starts.mapValues { $0.addingTimeInterval(3) }
        let environment = [Int32(61): marked(liveWorktree.uuidString)]
        let tree = collector().descendantClosure(of: 60, processes: processes, protected: [])
        #expect(tree == [61, 60])

        let verified = collector(now: now, environment: environment, startTimes: starts)
        #expect(
            verified.treeNamesSomethingLive(tree, plannedStarts: starts, rows: markerRows()),
            "the control: an unmoved start lets 61's marker keep the tree")
        let reissued = collector(now: now, environment: environment, startTimes: moved)
        #expect(
            !reissued.treeNamesSomethingLive(tree, plannedStarts: starts, rows: markerRows()),
            "61's pid now names another process, whose marker speaks for nothing")
    }

    // The old code had no env route: a root at `/` was never a candidate.
    @Test("the env route admits a root whose cwd left the worktree, naming the archived worktree")
    func theEnvRouteAdmitsARootWhoseCwdLeft() {
        let found = judgedRoot(cwd: "/", markers: marked(archivedWorktree.uuidString))
        #expect(found == [OrphanProcessCandidate(
            pid: 50, cwd: "/", rootPath: leftBehind, command: "/usr/bin/node server.js", route: .env)])
    }

    // Inverted (the gate only on the cwd route), the 300 s root is admitted.
    @Test("the age gate binds the env route too: a root younger than the cwd reading is skipped")
    func theAgeGateBindsTheEnvRoute() {
        let readAt = Date(timeIntervalSince1970: 1_000_000 - 600)
        let markers = marked(archivedWorktree.uuidString)
        #expect(judgedRoot(cwd: "/", markers: markers, elapsed: 300, cwdsCapturedAt: readAt).isEmpty)
        let old = judgedRoot(cwd: "/", markers: markers, elapsed: 900, cwdsCapturedAt: readAt)
        #expect(old.count == 1, "old enough to have existed when lsof ran")
    }

    // Inverted (env checked before the live cwd), the root is admitted by env.
    @Test("a cwd in a live worktree keeps whatever the environment says")
    func aLiveCwdKeepsWhateverTheEnvSays() {
        #expect(judgedRoot(cwd: alive + "/src", markers: marked(archivedWorktree.uuidString)).isEmpty)
    }

    // The old code had no veto: both of these were cwd candidates.
    @Test("a veto beats the cwd route; a hidden environment leaves it to the cwd")
    func aVetoBeatsTheCwdRoute() {
        #expect(judgedRoot(cwd: dead, markers: .noMarkers).isEmpty)
        #expect(judgedRoot(cwd: dead, markers: marked(liveWorktree.uuidString)).isEmpty)
        let routes = judgedRoot(cwd: dead, markers: .hidden).map(\.route)
        #expect(routes == [OrphanAdmissionRoute.cwd])
    }

    // Fails against naming the marker's worktree when the cwd route admitted too.
    @Test("both routes admitting name the cwd's dead root")
    func bothRoutesNameTheCwdRoot() {
        let found = judgedRoot(cwd: dead + "/a", markers: marked(archivedWorktree.uuidString))
        #expect(found == [OrphanProcessCandidate(
            pid: 50, cwd: dead + "/a", rootPath: dead, command: "/usr/bin/node server.js",
            route: .cwdAndEnv)])
    }

    // The old code protected neither 700 nor 703, and walked into 704.
    @Test("a keep-list match joins the protected set and stops the walk beneath it")
    func aKeepListMatchJoinsTheProtectedSet() {
        let processes = [
            entry(pid: 700, command: "/opt/acme/bin/claude --bg-pty-host --session x"),
            entry(pid: 701, ppid: 700),
            entry(pid: 702, command: "/usr/bin/make dev"),
            entry(pid: 703, ppid: 702, command: "/opt/homebrew/bin/gpg-agent --daemon"),
            entry(pid: 704, ppid: 703),
        ]
        let subject = collector()
        let unlisted = subject.protectedPIDs(processes: processes, ourPID: 99_999, ourUID: getuid())
        let listed = subject.protectedPIDs(
            processes: processes, ourPID: 99_999, ourUID: getuid(), keepList: .shipped)

        #expect(!unlisted.contains(700))
        #expect(!unlisted.contains(703))
        #expect(listed.contains(700))
        #expect(listed.contains(703))
        #expect(!listed.contains(702))
        #expect(!listed.contains(701), "only the match itself; it is the walk that stops beneath it")
        #expect(subject.descendantClosure(of: 702, processes: processes, protected: unlisted) == [704, 703, 702])
        #expect(subject.descendantClosure(of: 702, processes: processes, protected: listed) == [702])

        let cwds: [Int32: String] = [700: dead, 702: dead]
        let found = subject.candidates(
            processes: processes, cwdByPID: cwds,
            cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000), roots: roots(),
            ourUID: getuid(), ourPID: 99_999, graceSeconds: 3600, keepList: .shipped)
        let pids = found.map(\.pid)
        #expect(pids == [702])
    }

    // Fails against the old format, which carried no route.
    @Test("the record names the route that admitted the root")
    func describeCarriesTheRoute() {
        let cases: [(OrphanAdmissionRoute, String)] = [
            (.cwd, "via=cwd"), (.env, "via=env"), (.cwdAndEnv, "via=cwd+env"),
        ]
        for (route, via) in cases {
            let candidate = OrphanProcessCandidate(
                pid: 700, cwd: "/", rootPath: dead, command: "/usr/bin/nix print-dev-env",
                route: route)
            let description = OrphanProcessCollector.describe(candidate: candidate, tree: [701, 700])
            #expect(description == "pid=700 tree=2 \(via) /usr/bin/nix print-dev-env")
        }
    }

    // MARK: - Live holder sessions

    private let session = UUID(uuidString: "0B7A0000-0000-4000-8000-000000000001")!
    private let anchor = Date(timeIntervalSince1970: 900_000)

    private func holderCommand(_ id: UUID) -> String {
        "/acme/.build/release/TBDHolder --session \(id.uuidString) --socket /h/x.sock --lock-fd 9"
    }

    /// A holder spawned from the worktree that launched the daemon keeps that
    /// cwd and sits at `ppid == 1`; archive that worktree and, without the
    /// exemption, the holder and its job are an "orphan" tree.
    private func holderTable() -> [ProcessSnapshotEntry] {
        [
            entry(pid: 800, command: holderCommand(session)),
            entry(pid: 801, ppid: 800, command: "/bin/zsh -l"),
            entry(pid: 900, command: "/usr/bin/node server.js"),
        ]
    }

    private func holderSignaller(childStartedAt: Date?) -> FakeProcessSignaller {
        let signaller = FakeProcessSignaller()
        signaller.cmdlines[800] = holderCommand(session)
        signaller.cmdlines[801] = "/bin/zsh -l"
        if let childStartedAt { signaller.startTimes[801] = childStartedAt }
        signaller.startTimes[800] = anchor
        return signaller
    }

    private func liveSession(holderPID: Int32? = 800, childPID: Int32? = 801) -> LiveHolderSession {
        LiveHolderSession(
            terminalID: session, holderPID: holderPID, childPID: childPID, childStartedAt: anchor)
    }

    private func sweep(
        _ subject: OrphanProcessCollector, processes: [ProcessSnapshotEntry], exempt: Set<Int32>
    ) -> [Int32] {
        subject.candidates(
            processes: processes,
            cwdByPID: [800: dead, 801: dead, 900: dead],
            cwdsCapturedAt: Date(timeIntervalSince1970: 1_000_000),
            roots: roots(), ourUID: getuid(), ourPID: 12_345, graceSeconds: 3600,
            exempt: exempt
        ).map(\.pid)
    }

    @Test("a live session's holder under a dead worktree's cwd is kept; a real orphan there is not")
    func liveHolderIsExemptWhileARealOrphanIsReaped() {
        let subject = collector(signaller: holderSignaller(childStartedAt: anchor))
        let processes = holderTable()
        // Discriminates: without the exemption the holder is a candidate.
        #expect(sweep(subject, processes: processes, exempt: []) == [800, 900])

        let exempt = subject.liveHolderSessionPIDs([liveSession()], processes: processes)
        #expect(exempt == [800, 801])
        #expect(sweep(subject, processes: processes, exempt: exempt) == [900])

        let protected = subject.protectedPIDs(
            processes: processes, ourPID: 12_345, ourUID: getuid(), exempt: exempt)
        #expect(protected.isSuperset(of: [800, 801]))
        #expect(!protected.contains(900))
    }

    @Test("a holder whose session row is absent (archived worktree) is not exempt")
    func holderOfAnUnlistedSessionIsNotExempt() {
        let subject = collector(signaller: holderSignaller(childStartedAt: anchor))
        let exempt = subject.liveHolderSessionPIDs([], processes: holderTable())
        #expect(exempt.isEmpty)
        #expect(sweep(subject, processes: holderTable(), exempt: exempt) == [800, 900])
    }

    @Test("a holder naming a live session is exempt even when the row has no holder pid")
    func holderIsRecognizedByItsCommandLine() {
        let subject = collector(signaller: holderSignaller(childStartedAt: anchor))
        let exempt = subject.liveHolderSessionPIDs(
            [liveSession(holderPID: nil, childPID: nil)], processes: holderTable())
        #expect(exempt == [800])
    }

    @Test("a recorded pid now naming a different process is not exempt")
    func reusedPIDsAreNotExempt() {
        let signaller = holderSignaller(childStartedAt: anchor.addingTimeInterval(86_400))
        signaller.cmdlines[800] = holderCommand(UUID())
        let subject = collector(signaller: signaller)
        let processes = [
            entry(pid: 800, command: holderCommand(UUID())),
            entry(pid: 801, ppid: 800, command: "/bin/zsh -l"),
        ]
        #expect(subject.liveHolderSessionPIDs([liveSession()], processes: processes).isEmpty)
    }

    @Test("a recorded holder with an unreadable command line stays exempt; an absent one does not")
    func recordedHolderWithUnreadableCommandStaysExempt() {
        let subject = collector(signaller: holderSignaller(childStartedAt: anchor))
        let unreadable = [entry(pid: 800, command: ""), entry(pid: 900)]
        #expect(subject.liveHolderSessionPIDs(
            [liveSession(childPID: nil)], processes: unreadable) == [800])
        #expect(subject.liveHolderSessionPIDs(
            [liveSession(childPID: nil)], processes: [entry(pid: 900)]).isEmpty)
    }

    @Test("a recorded job whose start time cannot be read stays exempt")
    func uncertainIdentityStaysExempt() {
        let subject = collector(signaller: holderSignaller(childStartedAt: nil))
        let exempt = subject.liveHolderSessionPIDs([liveSession()], processes: holderTable())
        #expect(exempt.contains(801))
    }

    @Test("a holder's session is read from any token, and only from a TBDHolder command")
    func holderSessionIDParsing() {
        #expect(OrphanProcessCollector.holderSessionID(holderCommand(session)) == session)
        #expect(OrphanProcessCollector.holderSessionID(
            "/opt/Jane Roe/.build/TBDHolder --session \(session.uuidString)") == session)
        #expect(OrphanProcessCollector.holderSessionID(
            "/usr/bin/node --session \(session.uuidString)") == nil)
        #expect(OrphanProcessCollector.holderSessionID("/x/TBDHolder --session") == nil)
    }

    // MARK: - Reclamation

    @Test("reap SIGTERMs leaf-first and SIGKILLs only what survives the grace window")
    func reapEscalates() async throws {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[701] = .init(aliveAfterTerminate: false)
        signaller.behaviors[700] = .init(aliveAfterTerminate: true, aliveAfterKill: false)
        let table = [entry(pid: 700), entry(pid: 701, ppid: 700)]
        let subject = collector(signaller: signaller, snapshots: ScriptedSnapshots([table]))
        let candidate = OrphanProcessCandidate(
            pid: 700, cwd: dead, rootPath: dead, command: "/usr/bin/node server.js --port 3000")

        let record = await subject.reap(
            candidate, tree: [701, 700], plannedStarts: plannedStarts(table), repoPath: "/repo")

        #expect(signaller.terminated == [701, 700])
        #expect(signaller.killed == [700])
        // Through the pid-exact door, never the one that escalates to a group
        // kill: a process group is a superset of the group, not of this
        // closure, and could hold a pid the sweep protected.
        #expect(signaller.terminatedProcessOnly == [701, 700])
        #expect(signaller.killedProcessOnly == [700])
        let unwrapped = try #require(record)
        #expect(unwrapped.kind == .orphanProcess)
        #expect(unwrapped.worktreePath == dead)
        #expect(unwrapped.repoPath == "/repo")
        #expect(unwrapped.processDescription == "pid=700 tree=2 via=cwd /usr/bin/node server.js --port 3000")
        #expect(unwrapped.quarantinePath == nil)
    }

    @Test("an empty subtree records nothing")
    func emptySubtreeRecordsNothing() async {
        let record = await collector().reap(
            OrphanProcessCandidate(pid: 700, cwd: dead, rootPath: dead, command: "x"),
            tree: [], plannedStarts: [:], repoPath: "")
        #expect(record == nil)
    }

    // MARK: - Identity at signal time

    /// The root's `age >= cwdAge` gate in `candidates(…)` never sees a
    /// descendant: descendants enter a tree purely through the snapshot's ppid
    /// chain. So the pid the kernel reissued into a descendant slot is caught
    /// here or nowhere.
    @Test("a descendant whose start time moved between the plan and the volley is not signalled")
    func descendantSubstitutionIsSkipped() async throws {
        let signaller = FakeProcessSignaller()
        for pid: Int32 in [700, 702] { signaller.behaviors[pid] = .init(aliveAfterTerminate: false) }
        let planned = [entry(pid: 700), entry(pid: 701, ppid: 700), entry(pid: 702, ppid: 700)]
        // 701 exited and its pid was reissued to a stranger: same pid, same
        // uid, same parent slot, but a start time of seconds ago rather than a
        // day ago.
        let atVolley = [entry(pid: 700), entry(pid: 701, ppid: 700, elapsed: 3), entry(pid: 702, ppid: 700)]
        // `reap` is called directly here, so its first reading IS the volley's.
        let subject = collector(signaller: signaller, snapshots: ScriptedSnapshots([atVolley]))

        let record = await subject.reap(
            OrphanProcessCandidate(pid: 700, cwd: dead, rootPath: dead, command: "process-compose up"),
            tree: [701, 702, 700], plannedStarts: plannedStarts(planned), repoPath: "/repo")

        #expect(
            !signaller.terminated.contains(701),
            "a reissued pid names an unrelated live process and must never be signalled")
        #expect(signaller.terminated == [702, 700], "the rest of the tree is still reclaimed")
        #expect(signaller.killed.isEmpty)
        #expect(try #require(record).processDescription == "pid=700 tree=2 via=cwd process-compose up")
    }

    /// The escalation is a second volley, separated from the first by
    /// `graceAttempts × pollInterval` of wall time, and SIGKILL is the signal
    /// nothing survives. It gets its own check rather than the SIGTERM
    /// volley's now-stale conclusion.
    @Test("the SIGKILL escalation re-checks identity rather than reusing the SIGTERM volley's")
    func escalationRechecksIdentity() async throws {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[700] = .init(aliveAfterTerminate: true, aliveAfterKill: false)
        let planned = [entry(pid: 700)]
        let reissued = [entry(pid: 700, elapsed: 1)]
        let subject = collector(
            signaller: signaller, snapshots: ScriptedSnapshots([planned, reissued]))

        _ = await subject.reap(
            OrphanProcessCandidate(pid: 700, cwd: dead, rootPath: dead, command: "x"),
            tree: [700], plannedStarts: plannedStarts(planned), repoPath: "/repo")

        #expect(signaller.terminated == [700], "identity still matched when SIGTERM was sent")
        #expect(
            signaller.killed.isEmpty,
            "the pid was reissued during the grace window, so SIGKILL must not follow")
    }

    @Test("an identity that cannot be re-read is a skip, never a kill")
    func unreadableIdentityKeeps() async throws {
        let signaller = FakeProcessSignaller()
        let planned = [entry(pid: 700), entry(pid: 701, ppid: 700)]
        let subject = collector(
            signaller: signaller, snapshots: ScriptedSnapshots([nil]))

        let record = await subject.reap(
            OrphanProcessCandidate(pid: 700, cwd: dead, rootPath: dead, command: "x"),
            tree: [701, 700], plannedStarts: plannedStarts(planned), repoPath: "/repo")

        #expect(signaller.terminated.isEmpty, "a ps that did not answer signals nothing")
        #expect(signaller.killed.isEmpty)
        #expect(record == nil, "nothing was signalled, so nothing is recorded")
    }

    @Test("a pid whose etime did not parse can never be verified, so it is never signalled")
    func unparseableAgeIsNeverSignalled() async throws {
        let signaller = FakeProcessSignaller()
        let planned = [entry(pid: 700), entry(pid: 701, ppid: 700, elapsed: nil)]
        let subject = collector(signaller: signaller, snapshots: ScriptedSnapshots([planned]))

        _ = await subject.reap(
            OrphanProcessCandidate(pid: 700, cwd: dead, rootPath: dead, command: "x"),
            tree: [701, 700], plannedStarts: plannedStarts(planned), repoPath: "/repo")

        #expect(signaller.terminated == [700])
    }

    @Test("start instants are the snapshot's capture time minus etime, and skip unparseable rows")
    func startInstantsDeriveFromETime() {
        let at = Date(timeIntervalSince1970: 1_000_000)
        let map = OrphanProcessCollector.startInstants(
            [entry(pid: 5, elapsed: 60), entry(pid: 6, elapsed: nil)], capturedAt: at)
        #expect(map[5] == at.addingTimeInterval(-60))
        #expect(map[6] == nil, "an unparseable etime yields no identity, so the pid never verifies")
    }

    // MARK: - Parsing

    @Test("the ps snapshot parses five fixed fields plus a command that may contain spaces")
    func parsesPSLines() {
        let rows = OrphanProcessCollector.parseProcessLines("""
            1     0     1     0 11-23:23:11 /sbin/launchd
          228 98372 42549   501 01-09:07:58 /Applications/Some App/Helper --node-ipc
          244     1 81603   501       50:44 /usr/bin/node
        """)
        #expect(rows.count == 3)
        #expect(rows[1].pid == 228)
        #expect(rows[1].ppid == 98_372)
        #expect(rows[1].pgid == 42_549)
        #expect(rows[1].uid == 501)
        #expect(rows[1].command == "/Applications/Some App/Helper --node-ipc")
        #expect(rows[2].elapsedSeconds == TimeInterval(50 * 60 + 44))
    }

    @Test("etime parses every shape ps emits and refuses anything else")
    func parsesETime() {
        #expect(OrphanProcessCollector.parseETime("50:44") == 3044)
        #expect(OrphanProcessCollector.parseETime("01:02:03") == 3723)
        #expect(OrphanProcessCollector.parseETime("11-23:23:11") == TimeInterval(11 * 86_400 + 84_191))
        #expect(OrphanProcessCollector.parseETime("garbage") == nil)
        #expect(OrphanProcessCollector.parseETime("") == nil)
    }

    /// The pid header lsof always printed and `parseLiveCWDs` used to discard.
    /// Both shapes come from one pass, and the path list is unchanged.
    ///
    /// The fixture cwds sit under a scratch directory this test owns, whose own
    /// path is `realpath`-resolved, so the parser's canonicalization is the
    /// identity on them — and the test runs with them absent from disk and with
    /// them present to prove it. Bare `/tmp/a` and `/tmp/b` literals made this
    /// test's outcome depend on whether an unrelated process had left those
    /// paths lying around: existing, they canonicalize to `/private/tmp/...`.
    @Test(
        "parseLiveCWDs yields both the deduped path list and the pid-to-cwd map",
        arguments: [false, true]
    )
    func parseLiveCWDsKeepsThePID(fixtureCWDsExistOnDisk: Bool) throws {
        let scratch = try makeCanonicalScratchDirectory(prefix: "tbd-live-cwds")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let pathA = scratch + "/a"
        let pathB = scratch + "/b"
        if fixtureCWDsExistOnDisk {
            for path in [pathA, pathB] {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
            }
        }

        let stdout = Data("p100\nn\(pathA)\np200\nn\(pathB)\np300\nn\(pathA)\n".utf8)
        let parsed = try #require(
            OrphanGC.parseLiveCWDs(.completed(status: 0, stdout: stdout, stderr: Data())))
        #expect(parsed.paths == [pathA, pathB])
        #expect(parsed.cwdByPID == [100: pathA, 200: pathB, 300: pathA])
    }

    /// Canonicalization is load-bearing, not cosmetic: these cwds are compared
    /// against git's own worktree paths, which git records already resolved. A
    /// cwd lsof reports through a symlink has to arrive as the same string, or
    /// a live worktree reads as idle and gets reaped out from under its agent.
    /// It also has to happen before the dedup, so two spellings of one
    /// directory collapse to a single entry.
    @Test("parseLiveCWDs resolves each cwd to the path git would report")
    func parseLiveCWDsCanonicalizes() throws {
        let scratch = try makeCanonicalScratchDirectory(prefix: "tbd-live-cwds-canon")
        defer { try? FileManager.default.removeItem(atPath: scratch) }
        let worktree = scratch + "/worktree"
        try FileManager.default.createDirectory(atPath: worktree, withIntermediateDirectories: true)
        let viaSymlink = scratch + "/link-to-worktree"
        try FileManager.default.createSymbolicLink(atPath: viaSymlink, withDestinationPath: worktree)

        let stdout = Data("p100\nn\(viaSymlink)\np200\nn\(worktree)\n".utf8)
        let parsed = try #require(
            OrphanGC.parseLiveCWDs(.completed(status: 0, stdout: stdout, stderr: Data())))
        #expect(parsed.paths == [worktree],
                "a cwd reported through a symlink resolves to its target, and dedupes against it")
        #expect(parsed.cwdByPID == [100: worktree, 200: worktree])
    }

    @Test("an unavailable lsof invalidates both halves together")
    func parseLiveCWDsFailsWhole() {
        #expect(OrphanGC.parseLiveCWDs(.timedOut) == nil)
        #expect(OrphanGC.parseLiveCWDs(
            .completed(status: 1, stdout: Data("p1\nn/tmp/a\n".utf8), stderr: Data())) == nil)
    }

    @Test("an unavailable ps snapshot is nil, never an empty list")
    func parseProcessSnapshotFailsWhole() {
        #expect(OrphanProcessCollector.parseProcessSnapshot(.timedOut) == nil)
        #expect(OrphanProcessCollector.parseProcessSnapshot(
            .completed(status: 1, stdout: Data(), stderr: Data())) == nil)
        #expect(OrphanProcessCollector.parseProcessSnapshot(
            .completed(status: 0, stdout: Data(), stderr: Data()))?.isEmpty == true)
    }
}
