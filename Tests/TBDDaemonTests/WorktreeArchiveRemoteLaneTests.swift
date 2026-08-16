import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — in-memory database, dry-run tmux, a scripted fake provider, and a
/// real actuation log in a temp directory. No `TBD_HOME`, no subprocesses.
///
/// `worktree.archive` on a remote lane
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Archive"). Three
/// routes out of the same handler — the verb, the `gone` exemption, and a
/// refusal — plus the two guards on the verb path, and the record shape that
/// separates them: **a refusal writes no actuation row at all**, because
/// nothing was attempted and the record may claim solely acts that were
/// attempted.
///
/// The local arms are here for the same reason they always were: this is a
/// shared handler, and a run that showed the remote path working while
/// quietly breaking the local one must not pass.
@Suite("worktree.archive: remote lanes")
struct WorktreeArchiveRemoteLaneTests {

    private func archive(
        _ router: RPCRouter, _ worktree: Worktree, force: Bool = false
    ) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: worktree.id, force: force),
            actor: .app))
    }

    // MARK: - The verb path

    @Test("a provider declaring archive is invoked, and the row is filed")
    func declaredArchiveInvokesTheVerb() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "stop"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "archive-verb")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane)

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"], ["archive", "sess-1"]])
        #expect(try await fixture.status(of: lane) == .archived)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.first?["method"] as? String == RPCMethod.worktreeArchive)
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    /// The contract mandates that `archive` return the updated Session, so
    /// every conforming provider hands back `archived: true`. Mirroring that
    /// response before the row is written would hand the filing sync a row
    /// still `.active` alongside a fresh `archived: true` — and the sync would
    /// file the row a second time, on the daemon's own rail, with a
    /// notification claiming the *provider* retired a session the *user* just
    /// retired.
    ///
    /// So the shape is asserted, not just the outcome: exactly the two rows
    /// this one gesture is entitled to, none of them on the sync's rail, and
    /// no notification at all.
    @Test("the verb's own response does not re-enter the filing sync")
    func verbResponseDoesNotReenterTheFilingSync() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "archive-no-resync")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane)

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .archived)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2, "one gesture must write one request and one outcome, got \(rows.count)")
        #expect(
            rows.allSatisfy { ($0["actor"] as? [String: Any])?["rail"] as? String != "remote-filing-sync" },
            "the filing sync wrote a row for a gesture the user made")
        #expect(
            try await fixture.notifications(for: lane).isEmpty,
            "the user archived this lane themselves; nothing may claim the provider did")
    }

    /// The watermark that stops a `list` response composed before this
    /// gesture from undoing it on arrival. Discriminating by construction:
    /// the manager records nothing on its own, so this reads `nil` the moment
    /// the `noteFilingDecision` call is deleted.
    @Test("archiving a remote lane records the local filing decision")
    func archiveRecordsTheFilingDecision() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "archive-watermark")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        #expect(await fixture.manager.filingDecision(for: lane.id) == nil, "sanity: nothing recorded yet")

        let before = Date()
        let response = try await archive(fixture.router(), lane)
        let after = Date()

        #expect(response.success)
        let recorded = try #require(await fixture.manager.filingDecision(for: lane.id))
        #expect(recorded >= before && recorded <= after)
    }

    /// The provider no longer knows this session. That is the case the `gone`
    /// exemption exists for, so it files the row rather than failing — a lane
    /// on a capable provider must not be harder to retire than one on a
    /// provider that declares nothing.
    @Test("a not_found from the archive verb degrades to a row-only filing")
    func notFoundDegradesToARowFlip() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "not_found", "message": "gone"}}"#.utf8),
                stderr: "")],
            tag: "archive-notfound")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane)

        #expect(response.success, "not_found should not surface as an error: \(response.error ?? "")")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(try fixture.actuationRows().last?["result"] as? String == "dispatched")
    }

    @Test("a failing archive verb leaves the row alone and records transport-failed")
    func failingVerbLeavesTheRowAlone() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "unreachable", "message": "host is down"}}"#.utf8),
                stderr: "")],
            tag: "archive-failure")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error == "host is down")
        // A retirement TBD did not perform is not one it may claim.
        #expect(try await fixture.status(of: lane) == .active)
        #expect(await fixture.manager.filingDecision(for: lane.id) == nil)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.last?["result"] as? String == "transport-failed")
    }

    // MARK: - The gone exemption

    @Test("a gone lane is filed with no provider call, and still records its act")
    func goneLaneIsFiledWithoutTheProvider() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: [], tag: "archive-gone")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(gone: true)

        let response = try await archive(fixture.router(), lane)

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"]], "the gone path must call no verb")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(await fixture.manager.filingDecision(for: lane.id) != nil)
        // A row genuinely changed status, so the record names that act —
        // unlike a refusal, which writes nothing.
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    /// The guards defend the verb path. The `gone` path touches nothing on
    /// the provider and has nothing to defend, so a working agent and a dirty
    /// checkout both file cleanly there.
    @Test("the guards do not apply to the gone path")
    func guardsDoNotApplyToTheGonePath() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: [], tag: "archive-gone-guards")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(
            agentState: .working, meta: ["workspace_dirty": "true"], gone: true)

        let response = try await archive(fixture.router(), lane)

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(fixture.invoker.calls == [["describe"]])
    }

    // MARK: - Refusals

    @Test("a provider declaring neither archive nor a gone session is refused")
    func undeclaredCapabilityIsRefused() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: [], tag: "archive-refused")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error?.contains("archive") == true,
                "the refusal did not name the capability: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .active)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try fixture.actuationRows().isEmpty, "a refusal must write no actuation row")
    }

    /// `stop` is never substituted for a missing `archive`. Ending compute
    /// and retiring a record are different acts, and the assertion is on the
    /// invoker rather than on the response: a refusal that had quietly killed
    /// the session first would still look like a refusal from the outside.
    @Test("a provider declaring only stop is refused, and stop is never invoked")
    func stopIsNeverSubstituted() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["stop"], tag: "archive-stop-only")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(!fixture.invoker.calls.contains { $0.first == "stop" })
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    /// Even forced. `--force` overrides the guards, which are about the
    /// session's condition; it cannot conjure a capability the provider does
    /// not have.
    @Test("force does not override a missing archive capability")
    func forceDoesNotOverrideAMissingCapability() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["stop"], tag: "archive-force-nocap")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = try await archive(fixture.router(), lane, force: true)

        #expect(!response.success)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    @Test("archiving a remote lane is refused when remote backends are off")
    func refusedWhenSubsystemDisabled() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "archive-flag-off")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.db.config.setRemoteBackendsEnabled(false)

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error == "remote backends disabled")
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    // MARK: - The stale-snapshot gate

    /// The same gate every `remote.*` mutation passes, for the same reason and
    /// with sharper stakes here. Both of archive's guards are read out of the
    /// mirror — `agentState` and `meta.workspace_dirty` — so on a stale mirror
    /// a session that was idle at the last good poll and is working now reads
    /// as safe, the guards pass, and a mid-task session is retired.
    @Test("a stale provider inventory refuses the archive above the record")
    func staleInventoryRefusesTheArchive() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [
                RemoteLaneFixture.failingList,
                // A spare, so a regressed gate fails this test by assertion
                // rather than by exhausting the invoker's script — which is a
                // `precondition` and would abort the whole test process.
                providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#),
            ],
            tag: "archive-stale")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.markSnapshotStale()

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error?.contains("stale") == true,
                "the refusal did not say why: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .active)
        #expect(!fixture.invoker.calls.contains { $0.first == "archive" })
        #expect(try fixture.actuationRows().isEmpty, "a refusal must write no actuation row")
    }

    /// `--force` overrides it, exactly as it overrides the two guards: the user
    /// has been told the inventory is stale and is asking anyway.
    @Test("force overrides the stale-snapshot gate")
    func forceOverridesTheStaleGate() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [
                RemoteLaneFixture.failingList,
                providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#),
            ],
            tag: "archive-stale-force")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.markSnapshotStale()

        let response = try await archive(fixture.router(), lane, force: true)

        #expect(response.success, "force did not override the gate: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(fixture.invoker.calls.last == ["archive", "sess-1"])
    }

    /// A fresh inventory is the ordinary case, so the gate must not fire when
    /// nothing is wrong — otherwise a run that refused everything would pass
    /// the arm above by doing nothing.
    @Test("a healthy provider inventory does not trip the stale gate")
    func healthyInventoryArchivesNormally() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "archive-fresh")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()
        try await fixture.manager.apply(snapshot: [], provider: "fake")

        let response = try await archive(fixture.router(), lane)

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .archived)
    }

    // MARK: - Guards on the verb path

    @Test("a lane whose agent is working is refused, and the verb never runs")
    func workingAgentIsRefused() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "archive-working")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(agentState: .working)

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error?.contains("working") == true,
                "the refusal did not say why: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    @Test("a provider-reported dirty checkout is refused, and the verb never runs")
    func dirtyCheckoutIsRefused() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "archive-dirty")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(
            agentState: .idle, meta: [RemoteLaneLifecycle.dirtyWorkspaceMetaKey: "true"])

        let response = try await archive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error?.contains(RemoteLaneLifecycle.dirtyWorkspaceMetaKey) == true,
                "the refusal did not name the key: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().isEmpty)
    }

    /// The guard is inert until a provider adopts the key. A session that
    /// says nothing about its checkout — the overwhelmingly common case —
    /// must archive exactly as it would have before the guard existed, and a
    /// value that is not a claim must not be read as one.
    @Test("a provider that reports nothing about its checkout is not guarded")
    func absentDirtyKeyLeavesTheGuardInert() async throws {
        for meta in [nil, [:], ["workspace_dirty": ""], ["workspace_dirty": "unknown"],
                     ["repo": "acme/api"]] as [[String: String]?] {
            let fixture = try await RemoteLaneFixture.make(
                capabilities: ["archive"],
                verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
                tag: "archive-dirty-inert")
            defer { fixture.cleanup() }
            let lane = try await fixture.seedLane(meta: meta)

            let response = try await archive(fixture.router(), lane)

            #expect(response.success, "meta \(String(describing: meta)) was guarded: \(response.error ?? "")")
            #expect(try await fixture.status(of: lane) == .archived)
        }
    }

    @Test("force overrides the working guard")
    func forceOverridesTheWorkingGuard() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "archive-force-working")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(agentState: .working)

        let response = try await archive(fixture.router(), lane, force: true)

        #expect(response.success, "force did not override the guard: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"], ["archive", "sess-1"]])
        #expect(try await fixture.status(of: lane) == .archived)
    }

    @Test("force overrides the dirty-checkout guard")
    func forceOverridesTheDirtyGuard() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": true}"#)],
            tag: "archive-force-dirty")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(
            meta: [RemoteLaneLifecycle.dirtyWorkspaceMetaKey: "true"])

        let response = try await archive(fixture.router(), lane, force: true)

        #expect(response.success, "force did not override the guard: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"], ["archive", "sess-1"]])
        #expect(try await fixture.status(of: lane) == .archived)
    }

    // MARK: - The local path, unchanged

    @Test("a local worktree still archives and records its act")
    func localWorktreeStillArchives() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "archive-local")
        defer { fixture.cleanup() }
        let worktree = try await fixture.db.worktrees.create(
            repoID: fixture.repo.id, name: "acme-local", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")

        let response = try await archive(fixture.router(), worktree)

        #expect(response.success, "the archive was refused: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: worktree) == .archived)
        #expect(fixture.invoker.calls == [["describe"]], "a local archive must call no provider")
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.first?["method"] as? String == RPCMethod.worktreeArchive)
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    /// The pre-row read must not swallow the not-found case: an unknown id
    /// still reaches `beginArchiveWorktree` and still records a
    /// transport-failed outcome, exactly as it did before the branch.
    @Test("an unknown worktree id still throws and records transport-failed")
    func unknownWorktreeStillRecordsTransportFailure() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "archive-unknown")
        defer { fixture.cleanup() }

        let response = await fixture.router().handle(try RPCRequest(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: UUID()),
            actor: .app))

        #expect(!response.success)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.last?["result"] as? String == "transport-failed")
    }

    // MARK: - worktree.forget, the sibling surface

    /// Forget keeps refusing a remote lane, and that is a scope decision:
    /// forget means "leave the files alone", a remote lane has no files here,
    /// and retiring a lane is archive's job. The gate is still mechanically
    /// necessary — `forgetWorktree` resolves through `getLocal` and would
    /// throw beneath an already-written row.
    @Test("forgetting a remote lane is refused, and writes no actuation row for it")
    func forgetOnARemoteLaneIsRefusedAndRecordsNothing() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"], tag: "forget-remote")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane()

        let response = await fixture.router().handle(try RPCRequest(
            method: RPCMethod.worktreeForget,
            params: WorktreeForgetParams(worktreeID: lane.id),
            actor: .app))

        #expect(!response.success)
        #expect(response.error?.contains("remote lane") == true,
                "the refusal did not say why: \(response.error ?? "no error")")
        #expect(response.error?.contains("Archive") == true,
                "the refusal did not name the alternative: \(response.error ?? "no error")")
        // The row survives: a refused forget must not half-delete the lane.
        #expect(try await fixture.db.worktrees.get(id: lane.id) != nil)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try fixture.actuationRows().isEmpty)
    }

    /// The gate reads locality, not "the row exists": an unknown id must keep
    /// its old behavior, reaching `forgetWorktree` and recording the
    /// transport-failed outcome.
    @Test("an unknown id still reaches forget and records transport-failed")
    func forgetOnAnUnknownWorktreeStillRecordsTransportFailure() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "forget-unknown")
        defer { fixture.cleanup() }

        let response = await fixture.router().handle(try RPCRequest(
            method: RPCMethod.worktreeForget,
            params: WorktreeForgetParams(worktreeID: UUID()),
            actor: .app))

        #expect(!response.success)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["kind"] as? String == "dispose")
        #expect(rows.last?["result"] as? String == "transport-failed")
    }
}
