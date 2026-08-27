import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib

/// Tier 1 — the out-of-tmux evidence `serverPresence` uses to decide what a
/// `list-sessions` that did not answer means, with no tmux server anywhere and
/// no `ps` subprocess. Both halves are pure functions for exactly that reason:
/// the interesting condition (a machine with no tmux process running at all) is
/// not something a test on a shared box can arrange.
@Suite("Tmux server presence")
struct TmuxServerPresenceTests {

    // MARK: - The verdict

    /// The reboot case, and the regression this whole seam exists to fix. Every
    /// tmux server is genuinely gone, so nothing can be listening on any socket
    /// whatever `TMUX_TMPDIR` resolves to — and reconcile must reclaim, or the
    /// rows of every pre-reboot server accumulate forever.
    @Test("no tmux server process anywhere makes a failed list-sessions absent")
    func noTmuxProcessesIsAbsent() {
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: false) == .absent)
    }

    /// The field bug: something IS running and our `-L <name>` did not reach
    /// it, which says nothing about whether it is ours. Protect the rows.
    @Test("a running tmux server process keeps a failed list-sessions unreachable")
    func tmuxProcessesPresentIsUnreachable() {
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: true) == .unreachable)
    }

    /// The doctrine of this change in one assertion: a probe that could not be
    /// taken is not evidence of absence. Two failed reads still say nothing,
    /// and `.absent` is the only verdict that licenses parking or deleting.
    @Test("a probe that itself failed is unreachable, never absent")
    func failedProbeIsUnreachable() {
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: nil) == .unreachable)
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: nil) != .absent)
    }

    // MARK: - The matching rule

    @Test("a tmux invocation matches by argv[0] basename, absolute or bare")
    func matchesTmuxBasename() {
        #expect(TmuxManager.isTmuxProcessCommand("tmux -L tbd-acme new-session -d -s main"))
        #expect(TmuxManager.isTmuxProcessCommand("/opt/homebrew/bin/tmux -L tbd-acme attach"))
        #expect(TmuxManager.isTmuxProcessCommand("tmux"))
    }

    /// The rewritten process title, which is what a tmux server shows wherever
    /// `setproctitle` is available.
    @Test("the rewritten tmux: title matches for server and client alike")
    func matchesRewrittenTitle() {
        #expect(TmuxManager.isTmuxProcessCommand("tmux: server (/tmp/tmux-501/tbd-acme)"))
        #expect(TmuxManager.isTmuxProcessCommand("tmux: client (/tmp/tmux-501/tbd-acme)"))
    }

    /// Basename discipline, the same one `AgentReaper.isAgentBinary` keeps: a
    /// path that merely CONTAINS "tmux" is not a tmux process. Over-matching
    /// here would pin `.unreachable` forever on any box that happens to hold a
    /// tmux-ish path, and nothing would ever be reclaimed after a reboot.
    @Test("a path that merely contains tmux does not match")
    func doesNotMatchIncidentalPaths() {
        #expect(!TmuxManager.isTmuxProcessCommand("/Users/me/tmux-notes/bin/editor --flag"))
        #expect(!TmuxManager.isTmuxProcessCommand("tmuxinator start acme"))
        #expect(!TmuxManager.isTmuxProcessCommand("/bin/zsh -ic \"sleep 300\""))
        #expect(!TmuxManager.isTmuxProcessCommand(""))
        #expect(!TmuxManager.isTmuxProcessCommand("   "))
    }

    // MARK: - The snapshot gate

    private static func entry(
        pid: Int32, ppid: Int32, uid: uid_t, command: String
    ) -> ProcessSnapshotEntry {
        ProcessSnapshotEntry(
            pid: pid, ppid: ppid, pgid: pid, uid: uid,
            elapsedSeconds: 120, command: command)
    }

    /// A machine with no tmux anywhere. The reboot state, and the one that must
    /// answer "no".
    @Test("a snapshot with no tmux row reports no server processes")
    func emptyOfTmuxReportsFalse() {
        let snapshot = [
            Self.entry(pid: 10, ppid: 1, uid: 501, command: "/bin/zsh -l"),
            Self.entry(pid: 11, ppid: 1, uid: 501, command: "/usr/bin/ssh-agent -l"),
        ]
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: [], uid: 501, daemonPID: 99))
    }

    /// A tmux server daemonizes away from whoever started it, so its ppid is 1
    /// — never the daemon's. Name-agnostic on purpose: the socket name is what
    /// is under suspicion, so a server under ANY name counts.
    @Test("a daemonized tmux server under any name reports as present")
    func daemonizedServerReportsTrue() {
        let snapshot = [
            Self.entry(pid: 10, ppid: 1, uid: 501, command: "/bin/zsh -l"),
            Self.entry(
                pid: 42, ppid: 1, uid: 501,
                command: "tmux -L someone-elses-name new-session -d -s main"),
        ]
        #expect(TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
    }

    /// Another user's tmux server cannot be ours and is not reachable on our
    /// socket directory either, so it must not veto the reclaim.
    @Test("another uid's tmux server does not count")
    func foreignUIDDoesNotCount() {
        let snapshot = [
            Self.entry(pid: 42, ppid: 1, uid: 502, command: "tmux: server (/tmp/tmux-502/default)"),
        ]
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
    }

    /// The daemon's own in-flight `tmux …` CLI calls are clients, not servers.
    /// Counting them would let a concurrent reconcile probe veto its own
    /// reclaim, and the post-reboot sweep — which runs many tmux commands —
    /// would be exactly when that happens.
    @Test("this daemon's own tmux CLI children do not count")
    func ownCLIChildrenDoNotCount() {
        let snapshot = [
            Self.entry(pid: 43, ppid: 99, uid: 501, command: "tmux -L tbd-acme list-windows -a"),
        ]
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))

        // …but a real server that happens to sit next to one still counts.
        let withServer = snapshot + [
            Self.entry(pid: 44, ppid: 1, uid: 501, command: "tmux: server (/tmp/tmux-501/tbd-acme)"),
        ]
        #expect(TmuxManager.tmuxServerProcessesExist(
            in: withServer, uid: 501, daemonPID: 99))
    }

    /// A tmux client only exists while attached to a server, so it is evidence
    /// FOR one — and on platforms where tmux does not rewrite its title a
    /// server is indistinguishable from a client by argv anyway. Counting both
    /// errs toward `.unreachable`, the verdict that protects rows.
    @Test("a tmux client counts as evidence that a server is running")
    func clientCountsAsEvidence() {
        let snapshot = [
            Self.entry(pid: 45, ppid: 30, uid: 501, command: "tmux -L tbd-acme attach -t main"),
        ]
        #expect(TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
    }
}

/// A one-shot async gate. `wait()` suspends until `open()` is called and
/// returns immediately after that.
///
/// Deliberately not a `DispatchSemaphore`: nothing here needs to hold a thread,
/// and parking cooperative threads on a 3-core runner is the hazard
/// `Tests/CLAUDE.md` documents under "Thread-blocking gates run off the
/// cooperative pool".
private actor AsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    func open() {
        guard !isOpen else { return }
        isOpen = true
        let pending = waiters
        waiters = []
        for continuation in pending { continuation.resume() }
    }
}

/// How many times the memo actually took a reading.
private actor ReadingCounter {
    private(set) var count = 0
    func bump() { count += 1 }
}

/// Tier 1 — the memo in front of the machine-global process probe, driven
/// entirely through injected closures: no `ps`, no subprocess, no wall-clock
/// wait. The behaviour under test is "how many readings were taken", and the
/// window is compared against an injected date source rather than measured.
@Suite("Tmux server process probe memo")
struct TmuxServerProcessProbeCacheTests {

    /// The point of the whole type. `serverPresence` asks this question once per
    /// server that did not answer, and the answer does not depend on the server
    /// — so a post-reboot sweep over N dead servers must cost one `ps`, not N.
    @Test("a reading inside the freshness window is reused rather than retaken")
    func readingInsideTheWindowIsReused() async {
        let date = TestDateSource()
        let counter = ReadingCounter()
        let cache = TmuxServerProcessProbeCache(now: date.provider)
        let take: @Sendable () async -> Bool? = { await counter.bump(); return false }

        #expect(await cache.reading(taking: take) == false)
        date.advance(by: TmuxServerProcessProbeCache.freshness - 1)
        #expect(await cache.reading(taking: take) == false)

        #expect(await counter.count == 1,
                "a reading still inside its window must not be retaken")
    }

    /// The other half, and the one that keeps the memo honest: `.absent` is the
    /// verdict that licenses parking and deleting rows, so a reading may not
    /// outlive its window. The boundary is pinned exactly — at `freshness` the
    /// reading is already stale — so shortening or lengthening the window is a
    /// deliberate edit rather than a silent drift.
    @Test("a reading older than the freshness window is retaken")
    func staleReadingIsRetaken() async {
        let date = TestDateSource()
        let counter = ReadingCounter()
        let cache = TmuxServerProcessProbeCache(now: date.provider)
        let take: @Sendable () async -> Bool? = { await counter.bump(); return false }

        #expect(await cache.reading(taking: take) == false)
        date.advance(by: TmuxServerProcessProbeCache.freshness)
        #expect(await cache.reading(taking: take) == false)

        #expect(await counter.count == 2,
                "a reading at or past its window must be taken again")
    }

    /// A reading that could not be taken is memoized like any other — rerunning
    /// a `ps` that just failed is no more likely to answer — and it still means
    /// `.unreachable`, never absence. Memoizing must not turn "I don't know"
    /// into a licence to reclaim.
    @Test("a reading that could not be taken is memoized and still never means absence")
    func failedReadingIsMemoizedAndNeverAbsent() async {
        let date = TestDateSource()
        let counter = ReadingCounter()
        let cache = TmuxServerProcessProbeCache(now: date.provider)
        let take: @Sendable () async -> Bool? = { await counter.bump(); return nil }

        #expect(await cache.reading(taking: take) == nil)
        #expect(await cache.reading(taking: take) == nil)
        #expect(await counter.count == 1, "a failed reading is memoized like any other")
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: nil) == .unreachable)
    }

    /// The arm that matters under a sweep, where the askers arrive together
    /// rather than one after another: a second asker that arrives while a
    /// reading is in the air joins it instead of spawning a second `ps`
    /// alongside. `runBoundedProcess` has no concurrency limit of its own, so
    /// without this the machine takes N simultaneous full process-table scans.
    ///
    /// No wall-clock wait anywhere: the first reading is held open on a gate
    /// until the second asker has been launched.
    @Test("concurrent askers join one reading instead of each taking their own")
    func concurrentAskersJoinOneReading() async {
        let entered = AsyncGate()
        let release = AsyncGate()
        let counter = ReadingCounter()
        let cache = TmuxServerProcessProbeCache()
        let take: @Sendable () async -> Bool? = {
            await counter.bump()
            await entered.open()
            await release.wait()
            return false
        }

        let first = Task { await cache.reading(taking: take) }
        // The reading is now in the air, and `reading` claims the in-flight slot
        // with no suspension after starting it, so the actor cannot hand a
        // second asker an empty slot.
        await entered.wait()
        let second = Task { await cache.reading(taking: take) }
        await release.open()

        #expect(await first.value == false)
        #expect(await second.value == false)
        #expect(await counter.count == 1,
                "the second asker must join the reading in flight, not take one")
    }
}
