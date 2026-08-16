import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 2 — in-memory database, dry-run tmux, a scripted fake provider, and a
/// real actuation log in a temp directory. No `TBD_HOME`, no subprocesses.
///
/// `worktree.revive` on a remote lane
/// (`docs/specs/2026-08-16-remote-lane-archive-design.md` §"Revive"). The
/// discriminator is what the provider reports **right now**, not how the row
/// came to be archived — so a lane filed under the `gone` exemption is
/// reversible by the same gesture that filed it, while one the provider still
/// asserts is archived is refused rather than flipped into a row the next
/// snapshot would re-file.
@Suite("worktree.revive: remote lanes")
struct WorktreeReviveRemoteLaneTests {

    private func revive(_ router: RPCRouter, _ worktree: Worktree) async throws -> RPCResponse {
        await router.handle(try RPCRequest(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: worktree.id),
            actor: .app))
    }

    // MARK: - The verb path

    @Test("a provider declaring unarchive is invoked, and the row returns to active")
    func declaredUnarchiveInvokesTheVerb() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive", "unarchive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": false}"#)],
            tag: "revive-verb")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)

        let response = try await revive(fixture.router(), lane)

        #expect(response.success, "the revive was refused: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"], ["unarchive", "sess-1"]])
        #expect(try await fixture.status(of: lane) == .active)
        let returned = try response.decodeResult(Worktree.self)
        #expect(returned.id == lane.id)
        #expect(returned.status == .active, "the handler returned the pre-flip snapshot")
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["method"] as? String == RPCMethod.worktreeRevive)
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    /// The session's condition comes back through the mirror rather than
    /// through a second call: an exited session flips just as cleanly, and
    /// the lane returns to the list already carrying the provider's current
    /// word on it.
    @Test("an exited session flips cleanly and its condition reaches the mirror")
    func exitedSessionFlipsCleanly() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["unarchive"],
            verbs: [providerOK(
                #"{"id": "sess-1", "state": "exited", "exit_code": 3, "archived": false}"#)],
            tag: "revive-exited")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)

        let response = try await revive(fixture.router(), lane)

        #expect(response.success, "the revive was refused: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .active)
        let mirrored = try await fixture.db.remoteSessions.row(provider: "fake", sessionID: "sess-1")
        #expect(mirrored?.decodedPayload?.state == .exited)
        #expect(mirrored?.decodedPayload?.exitCode == 3)
    }

    /// A `gone` session may be listed again, and an exited one may still be a
    /// record the provider can unarchive — so the verb is worth attempting.
    /// What comes back when it is not there is `not_found`, and that degrades
    /// to a plain row flip rather than an error: the user asked for the lane
    /// back, and TBD's own filing decision is TBD's to reverse.
    @Test("a not_found response degrades to a row flip rather than an error")
    func notFoundDegradesToARowFlip() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["unarchive"],
            verbs: [ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "not_found", "message": "no such session"}}"#.utf8),
                stderr: "")],
            tag: "revive-notfound")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true, gone: true)

        let response = try await revive(fixture.router(), lane)

        #expect(response.success, "not_found should not surface as an error: \(response.error ?? "")")
        #expect(try await fixture.status(of: lane) == .active)
        #expect(try fixture.actuationRows().last?["result"] as? String == "dispatched")
    }

    @Test("a failing unarchive verb leaves the row archived and records transport-failed")
    func failingVerbLeavesTheRowArchived() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["unarchive"],
            verbs: [ProviderResult(
                exitCode: 1,
                stdout: Data(#"{"error": {"code": "unreachable", "message": "host is down"}}"#.utf8),
                stderr: "")],
            tag: "revive-failure")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)

        let response = try await revive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error == "host is down")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(await fixture.manager.filingDecision(for: lane.id) == nil)
        #expect(try fixture.actuationRows().last?["result"] as? String == "transport-failed")
    }

    /// Same watermark as archive, in the other direction — the one a
    /// timestamp on the row itself could not cover, since revive clears
    /// `archivedAt` and leaves nothing to appeal to.
    @Test("reviving a remote lane records the local filing decision")
    func reviveRecordsTheFilingDecision() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["unarchive"],
            verbs: [providerOK(#"{"id": "sess-1", "state": "running", "archived": false}"#)],
            tag: "revive-watermark")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)
        #expect(await fixture.manager.filingDecision(for: lane.id) == nil, "sanity: nothing recorded yet")

        let before = Date()
        let response = try await revive(fixture.router(), lane)
        let after = Date()

        #expect(response.success)
        let recorded = try #require(await fixture.manager.filingDecision(for: lane.id))
        #expect(recorded >= before && recorded <= after)
    }

    // MARK: - The row-only path

    /// The lane filed under the `gone` exemption: TBD's own decision, which a
    /// TBD gesture reverses. Nothing will arrive to undo it, because the
    /// filing sync reads `archived` only from a provider declaring `archive`.
    @Test("a lane no provider reports archived flips with no provider call")
    func rowOnlyFlipCallsNothing() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: [], tag: "revive-rowonly")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: nil, gone: true)

        let response = try await revive(fixture.router(), lane)

        #expect(response.success, "the revive was refused: \(response.error ?? "no error")")
        #expect(fixture.invoker.calls == [["describe"]], "the row-only path must call no verb")
        #expect(try await fixture.status(of: lane) == .active)
        #expect(await fixture.manager.filingDecision(for: lane.id) != nil)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.last?["result"] as? String == "dispatched")
    }

    // MARK: - The refusal

    /// With no verb to call and the provider still asserting `archived:
    /// true`, a row-only flip would be re-filed by the sync on the next
    /// snapshot, and again on every snapshot after. Refusing is what keeps
    /// the two records from fighting.
    @Test("a lane the provider still reports archived, with no unarchive, is refused")
    func refusedWhenProviderStillReportsArchived() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["archive"], tag: "revive-refused")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)

        let response = try await revive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error?.contains("unarchive") == true,
                "the refusal did not name the capability: \(response.error ?? "no error")")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(fixture.invoker.calls == [["describe"]])
        #expect(try fixture.actuationRows().isEmpty, "a refusal must write no actuation row")
    }

    @Test("reviving a remote lane is refused when remote backends are off")
    func refusedWhenSubsystemDisabled() async throws {
        let fixture = try await RemoteLaneFixture.make(
            capabilities: ["unarchive"], tag: "revive-flag-off")
        defer { fixture.cleanup() }
        let lane = try await fixture.seedLane(status: .archived, archived: true)
        try await fixture.db.config.setRemoteBackendsEnabled(false)

        let response = try await revive(fixture.router(), lane)

        #expect(!response.success)
        #expect(response.error == "remote backends disabled")
        #expect(try await fixture.status(of: lane) == .archived)
        #expect(try fixture.actuationRows().isEmpty)
    }

    // MARK: - The local path, unchanged

    /// A local worktree still resolves through the lifecycle, which rejects
    /// an active row — and it does so **beneath** an already-written request
    /// row. That two-row shape is what discriminates: had the new branch
    /// captured a local worktree, the remote path would have refused above
    /// the row and written none.
    @Test("a local worktree still reaches the lifecycle and records its request row")
    func localWorktreeStillReachesTheLifecycle() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "revive-local")
        defer { fixture.cleanup() }
        let worktree = try await fixture.db.worktrees.create(
            repoID: fixture.repo.id, name: "acme-local", branch: "acme-branch",
            path: "/tmp/acme-wt-\(UUID().uuidString)", tmuxServer: "tbd-acme")

        let response = try await revive(fixture.router(), worktree)

        #expect(!response.success, "an active local worktree is not revivable")
        #expect(fixture.invoker.calls == [["describe"]], "a local revive must call no provider")
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.first?["method"] as? String == RPCMethod.worktreeRevive)
        #expect(rows.last?["result"] as? String == "transport-failed")
    }

    @Test("an unknown worktree id still throws and records transport-failed")
    func unknownWorktreeStillRecordsTransportFailure() async throws {
        let fixture = try await RemoteLaneFixture.make(capabilities: [], tag: "revive-unknown")
        defer { fixture.cleanup() }

        let response = await fixture.router().handle(try RPCRequest(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: UUID()),
            actor: .app))

        #expect(!response.success)
        let rows = try fixture.actuationRows()
        #expect(rows.count == 2)
        #expect(rows.last?["result"] as? String == "transport-failed")
    }
}
