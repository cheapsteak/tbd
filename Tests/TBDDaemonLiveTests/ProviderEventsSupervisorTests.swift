import Testing
import Foundation
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 3: spawns a real child process and kills/restarts it. Bounded
// polling against explicit deadlines per Tests/CLAUDE.md — no bare
// Task.sleep as a synchronization primitive, and timeout failures report
// the observed state, not just what was expected.
//
// The deadlines below (`saturatedWaitDeadline`, `reapDeadline`) are hang
// guards sized against the *process population*, not against how long the
// supervisor ought to take: in CI this target runs in the quiet serial pass
// where healthy waits are milliseconds, but a full local `scripts/test.sh`
// puts all 5417 tests in one process, and per-test scheduling latency scales
// with that total (Tests/CLAUDE.md, "Population is the scheduler"). See each
// constant for its derivation.
//
// The suite time limit is a hang catcher, pinned per the tier-3 convention
// (Tests/CLAUDE.md: tier-3 suites pin their own limit rather than inheriting
// `.clockDriven`, whose value is sized for the fast parallel pass). It is NOT
// a regression detector here — unlike `SubprocessTimeoutTests`, nothing in
// this suite proves anything by outliving it. Its job is to stop a regressed
// `stop()` that never returns from wedging a whole local run, since nothing
// else bounds that. Sized so the first named diagnostic (a 90s bounded wait's
// thrown failure) always lands well inside it, and above the worst-case
// failing chain (~90x3 + 30 + stop ~= 310s).
@Suite("ProviderEventsSupervisor (live)", .timeLimit(.minutes(6)))
struct ProviderEventsSupervisorTests {
    /// Hang guard for the bounded waits on supervisor progress (spawn, snapshot
    /// application, respawn, resync).
    ///
    /// Positive waits, all of them: each breaks on its first satisfying probe,
    /// so raising the guard costs a passing run nothing and only a genuinely
    /// failing one pays it. 15s was the previous value and produced reds on a
    /// loaded multi-agent dev box that went green on a targeted rerun — the
    /// signature of scheduling latency, not of a supervisor defect (mined p50
    /// per-test duration is ~1/3 of total wall time). 90s matches the
    /// `ciSafeDeadline` re-derivation for this same contention class; that
    /// constant lives in `Tests/TBDDaemonTests` and is not importable from this
    /// target, so both take the same value from `TestSupport` rather than
    /// repeating the literal.
    private static let saturatedWaitDeadline: TimeInterval =
        TestDeadlines.saturatedPassSeconds

    /// Hang guard for the "no leaked children" waits, which are cheaper than
    /// the ones above but not free: SIGKILL delivery is kernel-immediate, yet
    /// `kill(pid, 0)` keeps succeeding on a **zombie** until Foundation's
    /// termination machinery (or launchd, for an orphan) reaps it — and that
    /// reaping needs queue turns, which starve under the same contention.
    private static let reapDeadline: TimeInterval = 30

    /// Stub emits hello+snapshot then hangs; killing its process tree must
    /// trigger a restart whose snapshot is REAPPLIED (resync-by-reconnect —
    /// the contract has no cursors, so a fresh connection is the whole
    /// recovery story). Each invocation announces a run-specific session id,
    /// so the post-restart assertion can only pass if a snapshot from a
    /// connection established *after* the kill reached the mirror.
    ///
    /// The stub goes silent after its snapshot and `silenceLimit` is 5, so the
    /// supervisor's own watchdog legitimately kills and respawns it every few
    /// seconds of test time. Respawns are therefore expected background
    /// behaviour, especially on a starved run, and the assertions below are
    /// written against the contract ("a dead or silent events process is
    /// replaced, and the replacement resyncs by reconnecting") rather than
    /// against particular run indices, which are a transient a starved observer
    /// can miss entirely.
    @Test func snapshotAppliedAndRestartResyncs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("events-supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let countFile = dir.appendingPathComponent("count")
        let pidFile = dir.appendingPathComponent("pid")
        let script = dir.appendingPathComponent("events-stub.sh")
        // Backgrounded sleep + a TERM trap that kills it: SIGTERM to this shell
        // takes its child down with it. Without that, bash parked in a
        // FOREGROUND `sleep 600` defers SIGTERM until the sleep finishes, and
        // the sleep outlives the test by ten minutes.
        try """
        #!/bin/bash
        if [ "$1" != "events" ]; then echo '{"sessions": []}'; exit 0; fi
        echo $$ > "\(pidFile.path)"
        n=$(cat "\(countFile.path)" 2>/dev/null || echo 0)
        n=$((n + 1))
        echo $n > "\(countFile.path)"
        echo '{"event": "hello", "contract_version": 1}'
        echo "{\\"event\\": \\"snapshot\\", \\"sessions\\": [{\\"id\\": \\"live-a\\", \\"state\\": \\"running\\"}, {\\"id\\": \\"run-$n\\", \\"state\\": \\"running\\"}]}"
        sleep 600 &
        child=$!
        trap 'kill "$child" 2>/dev/null; exit 143' TERM INT
        wait "$child"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let db = try TBDDatabase(inMemory: true)
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(), runner: ProviderRunner(),
            registryURL: dir.appendingPathComponent("unused.json"))
        let config = RemoteProviderConfig(name: "stub", exec: script.path)
        let supervisor = ProviderEventsSupervisor(
            config: config, manager: manager, contractVersion: 1,
            silenceLimit: 5, backoffCap: 1, healthyResetUptime: 1)
        await supervisor.start()

        // Body runs inside a Result so teardown ALWAYS happens before the temp
        // directory is removed: a still-looping supervisor whose script has
        // vanished spawn-fails every ~1s for the rest of the test process, and
        // `stop()` is async so `defer` can't await it.
        let outcome: Result<Void, any Error>
        do {
            try await runAssertions(db: db, countFile: countFile, pidFile: pidFile)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await supervisor.stop()

        // stop() is deterministic: the child tree is dead and the supervision
        // task is finished, so nothing can outlive the test. Bounded poll
        // because an orphaned grandchild is reaped by launchd, not by us.
        let pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        var alive = true
        let leakDeadline = Date().addingTimeInterval(Self.reapDeadline)
        while Date() < leakDeadline {
            alive = pid > 0 && kill(-pid, 0) == 0
            if !alive { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!alive, "stub process group \(pid) survived stop(); leaked children")

        try? FileManager.default.removeItem(at: dir)
        try outcome.get()
    }

    /// Only the parser and `RemoteProviderManager.apply(...)` have unit
    /// coverage of `complete`; the pass-through at
    /// `ProviderEventsSupervisor.handle(_:)` — private, and not itself
    /// exercised by any other live test — has none. `snapshotAppliedAndRestartResyncs`
    /// above never asserts on it: its stub's snapshot line never sets
    /// `"complete"` at all, so it only ever walks the default-true branch. A
    /// hardcoded `complete: true` at the pass-through would leave every test
    /// in this file green while quietly resuming exactly the tombstoning the
    /// events half of this feature exists to prevent.
    ///
    /// The stub emits one COMPLETE baseline snapshot (`keep-a`, `drop-b`),
    /// then one INCOMPLETE snapshot that omits `drop-b` and introduces
    /// `new-c`. `new-c` exists nowhere else in the script, so its arrival in
    /// the mirror is the positive signal that the second, incomplete event
    /// was actually applied — not just sent — which is what makes the
    /// absence assertion that follows trustworthy rather than a race. Once
    /// that signal fires, `drop-b`'s absence bookkeeping (`missingCount`/
    /// `gone`, the two-absence rule in `RemoteSessionStore.applySnapshot`)
    /// must be untouched: an incomplete snapshot is authoritative about
    /// presence only, never about absence.
    @Test func incompleteEventsSnapshotDoesNotAdvanceAbsenceBookkeeping() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("events-supervisor-incomplete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid")
        let script = dir.appendingPathComponent("events-incomplete-stub.sh")
        try """
        #!/bin/bash
        if [ "$1" != "events" ]; then echo '{"sessions": []}'; exit 0; fi
        echo $$ > "\(pidFile.path)"
        echo '{"event": "hello", "contract_version": 1}'
        echo '{"event": "snapshot", "complete": true, "sessions": [{"id": "keep-a", "state": "running"}, {"id": "drop-b", "state": "running"}]}'
        echo '{"event": "snapshot", "complete": false, "sessions": [{"id": "keep-a", "state": "running"}, {"id": "new-c", "state": "running"}]}'
        sleep 600 &
        child=$!
        trap 'kill "$child" 2>/dev/null; exit 143' TERM INT
        wait "$child"
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let db = try TBDDatabase(inMemory: true)
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(), runner: ProviderRunner(),
            registryURL: dir.appendingPathComponent("unused.json"))
        let config = RemoteProviderConfig(name: "stub-incomplete", exec: script.path)
        // Well above anything this test's bounded polling could take: unlike
        // `snapshotAppliedAndRestartResyncs`, nothing here exercises restart,
        // so a watchdog-triggered respawn mid-assertion would only be noise
        // to keep out, not behavior under test.
        let supervisor = ProviderEventsSupervisor(
            config: config, manager: manager, contractVersion: 1,
            silenceLimit: 90, backoffCap: 1, healthyResetUptime: 1)
        await supervisor.start()

        // Same teardown-before-cleanup shape as `snapshotAppliedAndRestartResyncs`
        // above, for the same reason: `stop()` is async so `defer` can't await
        // it, and it must run before the temp dir goes away regardless of
        // outcome.
        let outcome: Result<Void, any Error>
        do {
            try await runIncompleteSnapshotAssertions(db: db)
            outcome = .success(())
        } catch {
            outcome = .failure(error)
        }
        await supervisor.stop()

        let pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        var alive = true
        let leakDeadline = Date().addingTimeInterval(Self.reapDeadline)
        while Date() < leakDeadline {
            alive = pid > 0 && kill(-pid, 0) == 0
            if !alive { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!alive, "stub process group \(pid) survived stop(); leaked children")

        try? FileManager.default.removeItem(at: dir)
        try outcome.get()
    }

    /// A provider that IGNORES SIGTERM must still die: `stop()` escalates to
    /// SIGKILL against the process group and only returns once the child is
    /// gone and the supervision task has finished. Without the escalation this
    /// hangs (or returns leaving an immortal child respawning on backoff).
    @Test func stopEscalatesToSIGKILLForATermIgnoringProvider() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("events-supervisor-kill-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appendingPathComponent("pid")
        let script = dir.appendingPathComponent("stubborn-stub.sh")
        // `trap '' TERM` around a loop of short foreground sleeps: SIGTERM to
        // the group kills the current `sleep`, the shell ignores it and loops,
        // so only SIGKILL ends this process.
        try """
        #!/bin/bash
        echo $$ > "\(pidFile.path)"
        echo '{"event": "hello", "contract_version": 1}'
        trap '' TERM
        while :; do sleep 1; done
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let db = try TBDDatabase(inMemory: true)
        let manager = RemoteProviderManager(
            db: db, subscriptions: StateSubscriptionManager(), runner: ProviderRunner(),
            registryURL: dir.appendingPathComponent("unused.json"))
        let supervisor = ProviderEventsSupervisor(
            config: RemoteProviderConfig(name: "stubborn", exec: script.path), manager: manager,
            contractVersion: 1, silenceLimit: 90, backoffCap: 1, healthyResetUptime: 1)
        await supervisor.start()

        // Bounded wait for the child to exist before stopping it.
        var pid: Int32 = 0
        let spawnDeadline = Date().addingTimeInterval(Self.saturatedWaitDeadline)
        while Date() < spawnDeadline {
            pid = Int32((try? String(contentsOf: pidFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
            if pid > 0 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(pid > 0, "stubborn stub never recorded its pid; nothing to escalate against")

        let started = Date()
        await supervisor.stop()
        let elapsed = Date().timeIntervalSince(started)
        // The bound discriminates "stop() returned promptly after one ~0.5s kill
        // grace" from "stop() waited on the TERM-immune child" — and that second
        // case is UNBOUNDED, because the child ignores TERM forever. So the
        // number only has to sit far above the worst-case scheduling latency of
        // stop()'s several actor/task hops under saturation, and far below
        // "never". 10s failed the first half: it is inside observed per-test
        // scheduling noise (p90 ~= 26s for trivial tests at population 4536).
        #expect(elapsed < 60, "stop() took \(elapsed)s — it must not wait on a TERM-immune child")
        var alive = true
        let leakDeadline = Date().addingTimeInterval(Self.reapDeadline)
        while Date() < leakDeadline {
            alive = pid > 0 && kill(-pid, 0) == 0
            if !alive { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!alive, "TERM-ignoring stub group \(pid) survived stop(); SIGKILL escalation missing")
        try? FileManager.default.removeItem(at: dir)
    }

    /// Three bounded waits, written against the contract rather than against a
    /// particular run index.
    ///
    /// Why that distinction matters: the stub goes silent after its snapshot
    /// and `silenceLimit` is 5, so the supervisor's watchdog kills and respawns
    /// it every few seconds *on its own*. Each respawn bumps the counter file
    /// and replaces the mirror rows with `{live-a, run-N}` for the new N, so
    /// `{live-a, run-1}` is a **transient** state — an observer starved past it
    /// would never see it again while N marched upward, and demanding that
    /// exact set turned a slow run into a red one reporting
    /// `rows=["live-a", "run-2"]`. Each wait below therefore asserts the
    /// property it cares about: that *a* snapshot was applied, that the process
    /// was replaced, and that a snapshot from a connection established after
    /// the kill reached the mirror.
    private func runAssertions(db: TBDDatabase, countFile: URL, pidFile: URL) async throws {
        // Wait 1: a snapshot has been applied — `live-a` plus whichever `run-N`
        // is current. Records the highest N seen, which is the baseline the
        // resync wait below is measured against.
        var rows: [RemoteSessionRow] = []
        var maxRunAtKill: Int?
        let deadline = Date().addingTimeInterval(Self.saturatedWaitDeadline)
        while Date() < deadline {
            rows = (try? await db.remoteSessions.list()) ?? []
            let ids = rows.map(\.sessionID)
            if ids.contains("live-a"), let highest = Self.highestRunIndex(ids) {
                maxRunAtKill = highest
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let maxRunAtKill else {
            throw Failure("""
                no snapshot was applied within \(Self.saturatedWaitDeadline)s — the mirror needs \
                "live-a" and some "run-<n>"; observed rows=\(rows.map(\.sessionID))
                """)
        }

        // Read the invocation count immediately before the kill, so the respawn
        // wait below is relative to what had already happened rather than to a
        // fixed `>= 2`.
        let countAtKill = Self.invocationCount(countFile)

        // Kill the whole stub process group (SIGKILL can't be trapped, so the
        // backgrounded sleep has to be taken out with it).
        //
        // The pid may already be stale — the watchdog may have cycled the
        // process first, in which case this no-ops on ESRCH and the watchdog's
        // own respawn satisfies the waits below. That is fine: the contract
        // under test is "the supervisor replaces a dead or silent events process
        // and resyncs by reconnecting", not "our kill specifically caused it".
        let pid = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(-pid, SIGKILL)

        // Wait 2: a replacement process really ran. Only a fresh exec bumps the
        // counter file.
        var count = countAtKill
        let restartDeadline = Date().addingTimeInterval(Self.saturatedWaitDeadline)
        while Date() < restartDeadline {
            count = Self.invocationCount(countFile)
            if count > countAtKill { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        guard count > countAtKill else {
            throw Failure("""
                supervisor did not restart the events process within \
                \(Self.saturatedWaitDeadline)s; observed invocation count=\(count), \
                was \(countAtKill) at the kill
                """)
        }

        // Wait 3: reconnect-and-resnapshot IS the resync mechanism, so a
        // snapshot from a connection established AFTER the kill must reach the
        // mirror. `run-M` for M > maxRunAtKill exists nowhere else — no earlier
        // connection could have produced it — which preserves the original
        // test's "only a real second connection can pass this" property without
        // pinning a specific index.
        var highest: Int?
        let resyncDeadline = Date().addingTimeInterval(Self.saturatedWaitDeadline)
        while Date() < resyncDeadline {
            rows = (try? await db.remoteSessions.list()) ?? []
            highest = Self.highestRunIndex(rows.map(\.sessionID))
            if let highest, highest > maxRunAtKill { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let highest, highest > maxRunAtKill else {
            throw Failure("""
                reconnect snapshot did not resync the mirror within \
                \(Self.saturatedWaitDeadline)s — no run index above \(maxRunAtKill) reached it; \
                observed rows=\(rows.map(\.sessionID))
                """)
        }
    }

    /// Bounded wait for the positive signal (`new-c`'s arrival) that the
    /// INCOMPLETE snapshot reached the mirror, then a direct check of
    /// `drop-b`'s absence bookkeeping. See
    /// `incompleteEventsSnapshotDoesNotAdvanceAbsenceBookkeeping`'s doc
    /// comment for why the positive signal is what makes this trustworthy.
    private func runIncompleteSnapshotAssertions(db: TBDDatabase) async throws {
        var rows: [RemoteSessionRow] = []
        let deadline = Date().addingTimeInterval(Self.saturatedWaitDeadline)
        while Date() < deadline {
            rows = (try? await db.remoteSessions.list()) ?? []
            if rows.contains(where: { $0.sessionID == "new-c" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard rows.contains(where: { $0.sessionID == "new-c" }) else {
            throw Failure("""
                the incomplete snapshot never reached the mirror within \
                \(Self.saturatedWaitDeadline)s — "new-c" only exists in that event; \
                observed rows=\(rows.map(\.sessionID))
                """)
        }

        let dropB = try #require(
            rows.first { $0.sessionID == "drop-b" },
            "the baseline COMPLETE snapshot's \"drop-b\" row must still exist")
        #expect(
            dropB.missingCount == 0,
            """
            an incomplete snapshot omitting "drop-b" must not advance its absence \
            count; got missingCount=\(dropB.missingCount)
            """)
        #expect(!dropB.gone, "\"drop-b\" must not be tombstoned by an incomplete snapshot")

        let keepA = try #require(
            rows.first { $0.sessionID == "keep-a" },
            "\"keep-a\", present in both snapshots, must still exist")
        #expect(keepA.missingCount == 0)
        #expect(!keepA.gone)
    }

    /// Highest `n` across ids shaped `run-<n>`, or `nil` if the mirror carries
    /// none. The stub announces one per invocation, so this is "which
    /// connection's snapshot is currently applied".
    private static func highestRunIndex(_ ids: some Sequence<String>) -> Int? {
        ids.compactMap { id -> Int? in
            guard id.hasPrefix("run-") else { return nil }
            return Int(id.dropFirst("run-".count))
        }.max()
    }

    /// The stub's invocation counter, or 0 if the file is missing or unparsable
    /// (which is indistinguishable from "not yet written" and treated the same).
    private static func invocationCount(_ countFile: URL) -> Int {
        Int((try? String(contentsOf: countFile, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
    }
}

/// Timeout diagnostics travel as a thrown `Error` so they land on the primary
/// failure line and survive into the CI summary (Tests/CLAUDE.md, rule 4).
private struct Failure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}
