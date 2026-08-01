import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("Watch Desk judge lease store")
struct WatchDeskLeaseStoreTests {
    private func fixture() async throws -> (TBDDatabase, Worktree, Terminal, Terminal) {
        let db = try TBDDatabase(inMemory: true)
        let desk = try await db.worktrees.createScratch(
            name: "watch-desk", displayName: "Watch Desk",
            path: "/tmp/watch-desk-\(UUID())", tmuxServer: "test")
        let claude = try await db.terminals.create(
            worktreeID: desk.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.claudeCode, kind: .claude)
        let codex = try await db.terminals.create(
            worktreeID: desk.id, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: TerminalLabel.codex, kind: .codex)
        return (db, desk, claude, codex)
    }

    @Test("two candidates race and only one acquires")
    func contention() async throws {
        let (db, desk, claude, codex) = try await fixture()
        let now = Date(timeIntervalSince1970: 1_000)
        let claudeAttempt = Task {
            try? await db.watchDeskLeases.acquire(
                worktreeID: desk.id, terminalID: claude.id, now: now)
        }
        let codexAttempt = Task {
            try? await db.watchDeskLeases.acquire(
                worktreeID: desk.id, terminalID: codex.id, now: now)
        }
        let winners = await [claudeAttempt.value, codexAttempt.value].compactMap { $0 }
        #expect(winners.count == 1)
        #expect(try await db.watchDeskLeases.status(worktreeID: desk.id) == winners.first)
    }

    @Test("renewal preserves credentials and extends expiry")
    func renewal() async throws {
        let (db, desk, claude, _) = try await fixture()
        let start = Date(timeIntervalSince1970: 2_000)
        let first = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id, now: start)
        let renewed = try await db.watchDeskLeases.renew(
            worktreeID: desk.id, terminalID: claude.id,
            token: first.token, generation: first.generation,
            now: start.addingTimeInterval(30))
        #expect(renewed.token == first.token)
        #expect(renewed.generation == first.generation)
        #expect(renewed.expiresAt > first.expiresAt)
    }

    @Test("acquire cannot recover or disclose an unexpired holder capability")
    func acquireDoesNotRenewCurrentHolder() async throws {
        let (db, desk, claude, _) = try await fixture()
        let start = Date(timeIntervalSince1970: 2_500)
        _ = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id, now: start)
        await #expect(throws: WatchDeskLeaseError.self) {
            try await db.watchDeskLeases.acquire(
                worktreeID: desk.id, terminalID: claude.id,
                now: start.addingTimeInterval(1))
        }
    }

    @Test("expired owner is replaced at a higher generation")
    func expiryTakeover() async throws {
        let (db, desk, claude, codex) = try await fixture()
        let start = Date(timeIntervalSince1970: 3_000)
        let first = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id, now: start, lifetime: 10)
        let successor = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: codex.id,
            now: start.addingTimeInterval(11))
        #expect(successor.generation == first.generation + 1)
        #expect(successor.token != first.token)
        await #expect(throws: WatchDeskLeaseError.self) {
            try await db.watchDeskLeases.validate(
                worktreeID: desk.id, terminalID: claude.id,
                token: first.token, generation: first.generation,
                now: start.addingTimeInterval(11))
        }
    }

    @Test("atomic transfer fences predecessor and assigns explicit roles")
    func transfer() async throws {
        let (db, desk, claude, codex) = try await fixture()
        let start = Date(timeIntervalSince1970: 4_000)
        let first = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id, now: start)
        let next = try await db.watchDeskLeases.transfer(
            worktreeID: desk.id, fromTerminalID: claude.id, toTerminalID: codex.id,
            token: first.token, generation: first.generation,
            now: start.addingTimeInterval(1))
        #expect(next.generation == first.generation + 1)
        await #expect(throws: WatchDeskLeaseError.self) {
            try await db.watchDeskLeases.validate(
                worktreeID: desk.id, terminalID: claude.id,
                token: first.token, generation: first.generation,
                now: start.addingTimeInterval(2))
        }
        let terminals = try await db.terminals.list(worktreeID: desk.id)
        #expect(terminals.first(where: { $0.id == codex.id })?.watchDeskRole == .judge)
        #expect(terminals.first(where: { $0.id == claude.id })?.watchDeskRole == .readOnlyCoordinator)
    }

    @Test("reverse transfer supports Codex to Claude and fences Codex")
    func reverseTransfer() async throws {
        let (db, desk, claude, codex) = try await fixture()
        let start = Date(timeIntervalSince1970: 4_500)
        let first = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: codex.id, now: start)
        let next = try await db.watchDeskLeases.transfer(
            worktreeID: desk.id, fromTerminalID: codex.id, toTerminalID: claude.id,
            token: first.token, generation: first.generation,
            now: start.addingTimeInterval(1))
        #expect(next.terminalID == claude.id)
        #expect(next.generation == first.generation + 1)
        await #expect(throws: WatchDeskLeaseError.self) {
            try await db.watchDeskLeases.validate(
                worktreeID: desk.id, terminalID: codex.id,
                token: first.token, generation: first.generation,
                now: start.addingTimeInterval(2))
        }
    }

    @Test("renewal marks terminals created after acquisition read-only")
    func renewalLabelsLateObserver() async throws {
        let (db, desk, claude, _) = try await fixture()
        let first = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id)
        let late = try await db.terminals.create(
            worktreeID: desk.id, tmuxWindowID: "@late", tmuxPaneID: "%late",
            label: TerminalLabel.codex, kind: .codex)
        _ = try await db.watchDeskLeases.renew(
            worktreeID: desk.id, terminalID: claude.id,
            token: first.token, generation: first.generation)
        #expect(try await db.terminals.get(id: late.id)?.watchDeskRole == .readOnlyCoordinator)
    }

    @Test("release removes authority without deleting terminals")
    func release() async throws {
        let (db, desk, claude, _) = try await fixture()
        let lease = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id)
        try await db.watchDeskLeases.release(
            worktreeID: desk.id, terminalID: claude.id,
            token: lease.token, generation: lease.generation)
        #expect(try await db.watchDeskLeases.status(worktreeID: desk.id)?.isValid(at: Date()) == false)
        #expect(try await db.terminals.get(id: claude.id)?.watchDeskRole == nil)
    }

    @Test("owner loss revocation preserves generation tombstone for recovery")
    func ownerLoss() async throws {
        let (db, desk, claude, codex) = try await fixture()
        let first = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id)
        try await db.watchDeskLeases.revoke(worktreeID: desk.id)
        let recovered = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: codex.id)
        #expect(recovered.generation == first.generation + 1)
    }

    @Test("read-only observer cannot validate mutable authority")
    func observerDenied() async throws {
        let (db, desk, claude, codex) = try await fixture()
        let lease = try await db.watchDeskLeases.acquire(
            worktreeID: desk.id, terminalID: claude.id)
        await #expect(throws: WatchDeskLeaseError.self) {
            try await db.watchDeskLeases.validate(
                worktreeID: desk.id, terminalID: codex.id,
                token: lease.token, generation: lease.generation)
        }
    }
}
