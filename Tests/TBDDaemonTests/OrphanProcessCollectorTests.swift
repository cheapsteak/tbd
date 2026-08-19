import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Tier 1: pure classification and parsing. No database, no filesystem, no
/// subprocess and no real signal — the collector is handed its `ps` snapshot,
/// its pid-to-cwd map and its root classification, and answers.
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

    private func collector(
        signaller: ProcessSignaller = FakeProcessSignaller(),
        now: Date = Date(timeIntervalSince1970: 1_000_000)
    ) -> OrphanProcessCollector {
        OrphanProcessCollector(
            signaller: signaller, now: { now },
            graceAttempts: 2, pollInterval: .milliseconds(1))
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

    /// A shared root nested inside a pool must win: its strays stay unowned.
    @Test("a shared root nested inside a pool keeps that pool's stray arm out")
    func nestedSharedRootWins() {
        let nested = TBDProcessRoots(
            pools: [pool], sharedRoots: [pool + "/shared"], live: [], dead: [])
        #expect(collector().ownership(ofCWD: pool + "/shared/stray", roots: nested) == .outside)
        #expect(collector().ownership(ofCWD: pool + "/stray", roots: nested)
            == .dead(DeadWorktreeRoot(path: pool + "/stray", archivedAt: nil)))
    }

    @Test("a pool path with no row at all is dead with no archive instant")
    func absentFromTheDatabase() {
        let subject = collector()
        let onlyPool = TBDProcessRoots(pools: [pool], live: [], dead: [])
        #expect(subject.ownership(ofCWD: "/pool/forgotten/sub", roots: onlyPool)
            == .dead(DeadWorktreeRoot(path: "/pool/forgotten", archivedAt: nil)))
        // A `.deleting/<uuid>` entry takes two components: the queue directory
        // itself owns nothing.
        #expect(subject.ownership(ofCWD: "/pool/.deleting/abc/sub", roots: onlyPool)
            == .dead(DeadWorktreeRoot(path: "/pool/.deleting/abc", archivedAt: nil)))
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

    @Test("grace runs from process start where no row survives, and an unknown age keeps")
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

    // MARK: - Reclamation

    @Test("reap SIGTERMs leaf-first and SIGKILLs only what survives the grace window")
    func reapEscalates() async throws {
        let signaller = FakeProcessSignaller()
        signaller.behaviors[701] = .init(aliveAfterTerminate: false)
        signaller.behaviors[700] = .init(aliveAfterTerminate: true, aliveAfterKill: false)
        let subject = collector(signaller: signaller)
        let candidate = OrphanProcessCandidate(
            pid: 700, cwd: dead, rootPath: dead, command: "/usr/bin/node server.js --port 3000")

        let record = await subject.reap(candidate, tree: [701, 700], repoPath: "/repo")

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
        #expect(unwrapped.processDescription == "pid=700 tree=2 /usr/bin/node server.js --port 3000")
        #expect(unwrapped.quarantinePath == nil)
    }

    @Test("an empty subtree records nothing")
    func emptySubtreeRecordsNothing() async {
        let record = await collector().reap(
            OrphanProcessCandidate(pid: 700, cwd: dead, rootPath: dead, command: "x"),
            tree: [], repoPath: "")
        #expect(record == nil)
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
    @Test("parseLiveCWDs yields both the deduped path list and the pid-to-cwd map")
    func parseLiveCWDsKeepsThePID() throws {
        let stdout = Data("p100\nn/tmp/a\np200\nn/tmp/b\np300\nn/tmp/a\n".utf8)
        let parsed = try #require(
            OrphanGC.parseLiveCWDs(.completed(status: 0, stdout: stdout, stderr: Data())))
        #expect(parsed.paths == ["/tmp/a", "/tmp/b"])
        #expect(parsed.cwdByPID == [100: "/tmp/a", 200: "/tmp/b", 300: "/tmp/a"])
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
