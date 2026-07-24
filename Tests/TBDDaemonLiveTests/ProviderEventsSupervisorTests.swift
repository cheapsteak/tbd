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
    /// Stub emits hello+snapshot then hangs; killing it must trigger a
    /// restart which re-emits the snapshot (resync-by-reconnect — the
    /// contract has no cursors, so a fresh connection is the whole recovery
    /// story).
    @Test func snapshotAppliedAndRestartResyncs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("events-supervisor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let countFile = dir.appendingPathComponent("count")
        let script = dir.appendingPathComponent("events-stub.sh")
        try """
        #!/bin/bash
        if [ "$1" != "events" ]; then echo '{"sessions": []}'; exit 0; fi
        echo $$ > "\(dir.path)/pid"
        n=$(cat "\(countFile.path)" 2>/dev/null || echo 0)
        echo $((n + 1)) > "\(countFile.path)"
        echo '{"event": "hello", "contract_version": 1}'
        echo '{"event": "snapshot", "sessions": [{"id": "live-a", "state": "running"}]}'
        sleep 600
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
        defer { Task { await supervisor.stop() } }

        // Bounded wait (15s deadline, tier-3 discipline): snapshot lands in mirror.
        let deadline = Date().addingTimeInterval(15)
        var rows: [RemoteSessionRow] = []
        while Date() < deadline {
            rows = (try? await db.remoteSessions.list()) ?? []
            if rows.map(\.sessionID) == ["live-a"] { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(rows.map(\.sessionID) == ["live-a"], "snapshot not applied within 15s; observed rows=\(rows)")

        // Kill the stream; supervisor must respawn (invocation count reaches 2).
        let pid = try #require(Int32(
            String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)))
        kill(pid, SIGKILL)
        let restartDeadline = Date().addingTimeInterval(15)
        var count = 0
        while Date() < restartDeadline {
            count = Int((try? String(contentsOf: countFile, encoding: .utf8))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
            if count >= 2 { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(count >= 2, "supervisor did not restart the events process within 15s; observed invocation count=\(count)")
        rows = (try? await db.remoteSessions.list()) ?? []
        #expect(rows.map(\.sessionID) == ["live-a"],
                "reconnect snapshot did not resync the mirror; observed rows=\(rows)")
    }
}
