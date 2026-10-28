import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — in-memory database, dry-run tmux, a scripted fake provider, and a
/// real actuation log in a temp directory. No `TBD_HOME`, no subprocesses.
///
/// The auto-archive-on-merge rail reaches remote lanes
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Auto-archive on
/// merge"). It performs the same act on the same code as a manual archive,
/// under the opt-in it already has — there is no second flag, because a
/// second switch would gate a switch. It declines by itself when the provider
/// declares no `archive`, when a guard refuses, and when the inventory is
/// stale, and it records each decline as a request row under its own daemon
/// actor confirmed `refused` with the reason `not-eligible`. The merged edge
/// is not seen again, so that row is how a lane left active after its PR
/// merged is traced to the refusal that kept it. The skips that come before
/// any archive decision — a lane the rail is not armed for, and remote
/// backends off — write no row.
@Suite("Auto-archive on merge: remote lanes")
struct AutoArchiveRemoteLaneTests {

    /// The record a decline leaves: a dispose request naming the lane under
    /// the rail's daemon actor, with no RPC method, confirmed `refused` with a
    /// refusal sentence containing `fragment`.
    private func expectDeclineRecorded(
        _ fixture: RemoteLaneFixture, lane: Worktree, mentioning fragment: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let (request, outcome) = try fixture.refusalRecord(sourceLocation: sourceLocation)
        let actor = request["actor"] as? [String: Any]
        #expect(actor?["kind"] as? String == "daemon", sourceLocation: sourceLocation)
        #expect(actor?["rail"] as? String == "auto-archive-on-merge", sourceLocation: sourceLocation)
        #expect(request["kind"] as? String == "dispose", sourceLocation: sourceLocation)
        #expect(request["method"] == nil, "a daemon rail's row carries no RPC method",
                sourceLocation: sourceLocation)
        #expect((request["target"] as? [String: Any])?["worktree"] as? String == lane.id.uuidString,
                sourceLocation: sourceLocation)
        let error = outcome["error"] as? String
        #expect(error?.contains(fragment) == true,
                "the outcome does not carry the refusal: \(error ?? "no error")",
                sourceLocation: sourceLocation)
    }

    @Test("an armed remote lane whose provider declares archive is retired on merge")
    func armedRemoteLaneWithCapabilityIsArchived() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "rail-armed")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: true)

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: lane.id, prNumber: 7)

        #expect(archived)
        #expect(fixture.invoker.calls == [["describe"], ["archive", "sess-1"]])
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(await fixture.manager.filingDecision(for: lane.id) != nil)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.first?["method"] == nil, "a daemon rail's row carries no RPC method")
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    /// The same notification the local path creates. A worktree that leaves
    /// the active list without the user asking at that moment has to say why.
    @Test("a rail-driven remote archive records a notification naming the PR")
    func railRecordsANotification() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "rail-notification")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: true)

        _ = await fixture.coordinator().handleMergedTransition(worktreeID: lane.id, prNumber: 42)

        let notifications = try await fixture.db.notifications.unread(worktreeID: lane.id)
        let messages = notifications.compactMap(\.message)
        #expect(messages.contains { $0.contains("PR #42") },
                "no notification named the merge: \(messages)")
    }

    @Test("an armed remote lane whose provider declares no archive is not retired")
    func armedRemoteLaneWithoutCapabilityIsDeclined() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["stop"], tag: "rail-nocap")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: true)

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: lane.id, prNumber: 7)

        #expect(!archived)
        // `stop` is never substituted for a missing `archive`, on any path.
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try await fixture.status(of: lane) == .active)
        try expectDeclineRecorded(fixture, lane: lane, mentioning: "does not declare the \"archive\" capability")
    }

    /// The opt-in is the only gate. A remote lane that was never armed is
    /// left alone even where the provider could archive it — otherwise the
    /// remote path would be auto-archiving lanes the user never opted in.
    @Test("an unarmed remote lane is left alone even when the provider can archive")
    func unarmedRemoteLaneIsLeftAlone() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "rail-unarmed")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: false)

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: lane.id, prNumber: 7)

        #expect(!archived)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    /// A lane that inherits its arming from the repo-wide default rather than
    /// from a per-worktree override still retires — the rail reads the same
    /// effective value it always did.
    @Test("a remote lane armed only by the global default is retired")
    func remoteLaneArmedByTheDefaultIsArchived() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "rail-default-on")
        defer { fixture.cleanup() }
        try await fixture.db.config.setAutoArchiveOnMergeDefault(true)
        let lane = try await fixture.seedLane()

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: lane.id, prNumber: 7)

        #expect(archived)
        #expect(try await fixture.status(of: lane) == .archived)
    }

    /// The rail carries the guards too: it is the same archive on the same
    /// path, and retiring a lane whose agent is mid-task by accident is
    /// exactly what the guard exists to stop. The rail has no `--force`.
    @Test("a remote lane whose agent is still working is not retired on merge")
    func workingRemoteLaneIsNotRetired() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "rail-working")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(agentState: .working)
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: true)

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: lane.id, prNumber: 7)

        #expect(!archived)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try await fixture.status(of: lane) == .active)
        try expectDeclineRecorded(fixture, lane: lane, mentioning: "working")
    }

    /// With no remote manager — the shape every install has while
    /// `remote_backends_enabled` is off — the rail declines exactly as it did
    /// before it had a remote path at all. It makes no archive decision there,
    /// so it records nothing.
    @Test("with remote backends off the rail declines a remote lane silently")
    func remoteLaneDeclinedWithoutAManager() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: ["archive"], tag: "rail-nomanager")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: true)
        let coordinator = AutoArchiveOnMergeCoordinator(
            db: fixture.db,
            lifecycle: WorktreeLifecycle(
                db: fixture.db, git: GitManager(), tmux: TmuxManager(dryRun: true),
                hooks: HookResolver(), subscriptions: fixture.subscriptions),
            subscriptions: fixture.subscriptions,
            actuationLog: ActuationLog(path: fixture.logPath))

        let archived = await coordinator.handleMergedTransition(worktreeID: lane.id, prNumber: 7)

        #expect(!archived)
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    /// The rail reads the same guards out of the same mirror, so it inherits
    /// the same refusal: a stale inventory is no basis for retiring a lane,
    /// and the rail has no `--force` to reach for. It declines and records
    /// the decline, exactly as it does for a missing capability.
    @Test("an armed remote lane is left alone while the provider's inventory is stale")
    func staleInventoryDeclinesTheRail() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [
                RemoteLaneFixture.failingList,
                // A spare, so a regressed gate fails by assertion rather than
                // by exhausting the invoker's script (a `precondition`).
                providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#),
            ],
            tag: "rail-stale")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: lane.id, value: true)
        try await fixture.markSnapshotStale()

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: lane.id, prNumber: 7)

        #expect(!archived)
        #expect(!fixture.invoker.calls.contains { $0.first == "archive" })
        #expect(try await fixture.status(of: lane) == .active)
        try expectDeclineRecorded(fixture, lane: lane, mentioning: "stale")
    }

    // MARK: - The local path, unchanged

    @Test("a local worktree armed the same way still auto-archives and records its act")
    func localLaneStillArchives() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "rail-local")
        defer { fixture.cleanup() }
        let worktree = try await fixture.db.worktrees.create(
            repoID: fixture.repo.id, name: "acme-local", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")
        try await fixture.db.worktrees.setAutoArchiveOnMerge(id: worktree.id, value: true)

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: worktree.id, prNumber: 7)

        #expect(archived)
        #expect(try await fixture.status(of: worktree) == .archived)
        #expect(fixture.invoker.calls == [["describe"]], "a local archive must call no provider")
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    @Test("an unarmed local worktree is still left alone")
    func unarmedLocalLaneIsLeftAlone() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "rail-local-unarmed")
        defer { fixture.cleanup() }
        let worktree = try await fixture.db.worktrees.create(
            repoID: fixture.repo.id, name: "acme-local", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")

        let archived = await fixture.coordinator().handleMergedTransition(
            worktreeID: worktree.id, prNumber: 7)

        #expect(!archived)
        #expect(try await fixture.status(of: worktree) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }
}
