import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 1 — no tmux, no subprocesses, one temp file.
///
/// The wired handlers call tmux and the DB with plain `try await` after their
/// request row. Without `actuating`, such a throw falls through to the router's
/// blanket catch, which writes no outcome — and the record then cannot tell
/// "the act failed" from "the outcome was lost". This is that seam's own test:
/// the outcome is recorded, and the error still propagates untouched so the RPC
/// error surface stays byte-identical.
@Suite("Actuation throw classification")
struct ActuationThrowClassificationTests {

    private struct TmuxWentAway: Error, CustomStringConvertible {
        var description: String { "tmux server 'tbd-acme' is not running" }
    }

    private func makeFixture() throws -> (router: RPCRouter, logPath: String) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-actuation-throw-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("actuations.jsonl").path

        let db = try TBDDatabase(inMemory: true)
        let router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(), tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            actuationLog: ActuationLog(path: path))
        return (router, path)
    }

    private func rows(at path: String) throws -> [[String: Any]] {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
        return try contents
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line in
                try #require(
                    try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            }
    }

    @Test("a throw in the acting section is recorded as transport-failed and rethrown unchanged")
    func throwIsRecordedAndRethrown() async throws {
        let fixture = try makeFixture()
        let requestID = try await fixture.router.beginActuation(
            .terminalCreate, actor: .app,
            target: .local(worktree: UUID(), terminal: UUID()))

        await #expect(throws: TmuxWentAway.self) {
            try await fixture.router.actuating(requestID) { throw TmuxWentAway() }
        }

        let written = try rows(at: fixture.logPath)
        #expect(written.count == 2)
        let outcome = try #require(written.last)
        #expect(outcome["confirms"] as? String == requestID)
        #expect(outcome["result"] as? String == "transport-failed")
        // The error text the caller would have seen, verbatim.
        #expect(outcome["error"] as? String == "\(TmuxWentAway())")
    }

    @Test("an acting section that returns writes no outcome of its own")
    func successfulStepLeavesTheOutcomeToTheHandler() async throws {
        let fixture = try makeFixture()
        let requestID = try await fixture.router.beginActuation(
            .terminalCreate, actor: .app,
            target: .local(worktree: UUID(), terminal: UUID()))

        let value = try await fixture.router.actuating(requestID) { 42 }
        #expect(value == 42)
        // Only the request row: the handler decides what a success is called,
        // and one act must never confirm twice.
        #expect(try rows(at: fixture.logPath).count == 1)
    }
}
