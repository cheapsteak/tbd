import Foundation
import DaemonTestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1. The daemon's in-memory record of why recent creations failed, and
/// `worktree.createFailure`, which hands a reason to a CLI that saw its
/// worktree's row disappear.
@Suite("worktree.createFailure")
struct WorktreeCreateFailureLogTests {

    // MARK: - The record

    @Test func aRecordedReasonIsReturned() async {
        let log = WorktreeCreateFailureLog()
        let id = UUID()
        await log.record(worktreeID: id, reason: "the disk is full")

        #expect(await log.reason(for: id) == "the disk is full")
    }

    @Test func anUnknownIDHasNoReason() async {
        let log = WorktreeCreateFailureLog()
        await log.record(worktreeID: UUID(), reason: "x")

        #expect(await log.reason(for: UUID()) == nil)
    }

    @Test func theOldestIsDroppedPastTheCapacity() async {
        let log = WorktreeCreateFailureLog(capacity: 3)
        let ids = (0..<4).map { _ in UUID() }
        for (index, id) in ids.enumerated() {
            await log.record(worktreeID: id, reason: "reason \(index)")
        }

        #expect(await log.reason(for: ids[0]) == nil)
        #expect(await log.reason(for: ids[1]) == "reason 1")
        #expect(await log.reason(for: ids[3]) == "reason 3")
    }

    /// Recording an id again replaces its reason and makes it the newest, so
    /// it is not the one dropped next.
    @Test func recordingAgainMakesItTheNewest() async {
        let log = WorktreeCreateFailureLog(capacity: 2)
        let first = UUID()
        let second = UUID()
        await log.record(worktreeID: first, reason: "old")
        await log.record(worktreeID: second, reason: "b")
        await log.record(worktreeID: first, reason: "new")
        await log.record(worktreeID: UUID(), reason: "c")

        #expect(await log.reason(for: first) == "new")
        #expect(await log.reason(for: second) == nil)
    }

    @Test func theDefaultCapacityIsSixtyFour() async {
        let log = WorktreeCreateFailureLog()
        let ids = (0..<65).map { _ in UUID() }
        for id in ids {
            await log.record(worktreeID: id, reason: "r")
        }

        #expect(await log.reason(for: ids[0]) == nil)
        #expect(await log.reason(for: ids[1]) == "r")
    }

    // MARK: - The RPC

    private func makeRouter() throws -> RPCRouter {
        let db = try TBDDatabase(inMemory: true)
        return RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db,
                git: GitManager(),
                tmux: TmuxManager(dryRun: true),
                hooks: HookResolver()
            ),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: makeTestActuationLog()
        )
    }

    private func askForFailure(_ router: RPCRouter, _ id: UUID) async throws -> WorktreeCreateFailureResult {
        let response = await router.handle(try RPCRequest(
            method: RPCMethod.worktreeCreateFailure,
            params: WorktreeCreateFailureParams(worktreeID: id)))
        #expect(response.success, "\(response.error ?? "")")
        return try response.decodeResult(WorktreeCreateFailureResult.self)
    }

    @Test func theHandlerReturnsTheRecordedReason() async throws {
        let router = try makeRouter()
        let id = UUID()
        await router.worktreeCreateFailures.record(
            worktreeID: id, reason: "git worktree add failed — the disk is full; free space and try again")

        let result = try await askForFailure(router, id)

        #expect(result.reason == "git worktree add failed — the disk is full; free space and try again")
    }

    @Test func theHandlerAnswersNilForAnIDWithNoFailure() async throws {
        let router = try makeRouter()

        let result = try await askForFailure(router, UUID())

        #expect(result.reason == nil)
    }
}
