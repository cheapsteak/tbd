import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Tier 3: spawns a real child process and kills/restarts it. Bounded
// polling against explicit deadlines per Tests/CLAUDE.md — no bare
// Task.sleep as a synchronization primitive, and timeout failures report
// the observed state, not just what was expected.
@Suite("ProviderEventsSupervisor (live)")
struct ProviderEventsSupervisorTests {
    /// Stub emits hello+snapshot then hangs; killing its process tree must
    /// trigger a restart whose snapshot is REAPPLIED (resync-by-reconnect —
    /// the contract has no cursors, so a fresh connection is the whole
    /// recovery story). Each invocation announces a run-specific session id,
    /// so the post-restart assertion can only pass if run 2's snapshot
    /// actually reached the mirror.
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
            config: config, manager: manager,
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
        let leakDeadline = Date().addingTimeInterval(5)
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
            silenceLimit: 90, backoffCap: 1, healthyResetUptime: 1)
        await supervisor.start()

        // Bounded wait for the child to exist before stopping it.
        var pid: Int32 = 0
        let spawnDeadline = Date().addingTimeInterval(15)
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
        #expect(elapsed < 10, "stop() took \(elapsed)s — it must not wait on a TERM-immune child")
        var alive = true
        let leakDeadline = Date().addingTimeInterval(5)
        while Date() < leakDeadline {
            alive = pid > 0 && kill(-pid, 0) == 0
            if !alive { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(!alive, "TERM-ignoring stub group \(pid) survived stop(); SIGKILL escalation missing")
        try? FileManager.default.removeItem(at: dir)
    }

    private func runAssertions(db: TBDDatabase, countFile: URL, pidFile: URL) async throws {
        // Bounded wait (15s deadline, tier-3 discipline): run 1's snapshot lands.
        var rows: [RemoteSessionRow] = []
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            rows = (try? await db.remoteSessions.list()) ?? []
            if Set(rows.map(\.sessionID)) == ["live-a", "run-1"] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(Set(rows.map(\.sessionID)) == ["live-a", "run-1"],
                "run 1's snapshot not applied within 15s; observed rows=\(rows.map(\.sessionID))")

        // Kill the whole stub process group (SIGKILL can't be trapped, so the
        // backgrounded sleep has to be taken out with it) and require a
        // respawn: only a real second exec can bump the counter file.
        let pid = try #require(Int32(
            String(contentsOf: pidFile, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(-pid, SIGKILL)
        var count = 0
        let restartDeadline = Date().addingTimeInterval(15)
        while Date() < restartDeadline {
            count = Int((try? String(contentsOf: countFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
            if count >= 2 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(count >= 2,
                "supervisor did not restart the events process within 15s; observed invocation count=\(count)")

        // Reconnect-and-resnapshot IS the resync mechanism, so run 2's
        // snapshot must reach the mirror. `run-2` exists nowhere else — if the
        // second connection's hello+snapshot were dropped, this fails.
        let resyncDeadline = Date().addingTimeInterval(15)
        while Date() < resyncDeadline {
            rows = (try? await db.remoteSessions.list()) ?? []
            if rows.contains(where: { $0.sessionID == "run-2" }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(rows.contains { $0.sessionID == "run-2" },
                "reconnect snapshot did not resync the mirror; observed rows=\(rows.map(\.sessionID))")
    }
}
