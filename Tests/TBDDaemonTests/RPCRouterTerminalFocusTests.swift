import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

/// Thread-safe capture box. `SendableBox` is declared `private` in other test
/// files, so this suite needs its own copy.
private final class CaptureBox<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [T] = []
    func append(_ value: T) { lock.lock(); defer { lock.unlock() }; _values.append(value) }
    var values: [T] { lock.lock(); defer { lock.unlock() }; return _values }
    var count: Int { values.count }
}

// Uses the shared RPCRouterTests fixture (db + router, in-memory, dryRun tmux).
extension RPCRouterTests {

    private func seedTerminal() async throws -> (worktreeID: UUID, terminalID: UUID) {
        let repo = try await db.repos.create(
            path: "/tmp/focus-repo-\(UUID().uuidString)",
            displayName: "focus-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "focus-wt",
            branch: "tbd/focus-wt",
            path: "/tmp/focus-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-focus"
        )
        let term = try await db.terminals.create(
            worktreeID: wt.id,
            tmuxWindowID: "@focus-0",
            tmuxPaneID: "%focus-0"
        )
        return (wt.id, term.id)
    }

    @Test("terminal.focus broadcasts a focusRequest delta resolving worktree from terminal")
    func focusBroadcastsDelta() async throws {
        let (worktreeID, terminalID) = try await seedTerminal()

        let captured = CaptureBox<Data>()
        router.subscriptions.addSubscriber { data in
            captured.append(data)
            return true
        }

        let params = TerminalFocusParams(terminalID: terminalID, message: "look", activate: true)
        let request = try RPCRequest(method: RPCMethod.terminalFocus, params: params)
        let response = await router.handle(request)
        #expect(response.success)

        #expect(captured.count == 1)
        let delta = try JSONDecoder().decode(StateDelta.self, from: captured.values[0])
        guard case let .notificationReceived(n) = delta else {
            Issue.record("expected .notificationReceived, got \(delta)")
            return
        }
        #expect(n.worktreeID == worktreeID)
        #expect(n.terminalID == terminalID)
        #expect(n.type == .focusRequest)
        #expect(n.activate == true)
        #expect(n.message == "look")
    }

    @Test("terminal.focus soft push defaults activate to false")
    func focusSoftDefaultsActivateFalse() async throws {
        let (_, terminalID) = try await seedTerminal()

        let captured = CaptureBox<Data>()
        router.subscriptions.addSubscriber { data in
            captured.append(data)
            return true
        }

        let params = TerminalFocusParams(terminalID: terminalID)
        let request = try RPCRequest(method: RPCMethod.terminalFocus, params: params)
        _ = await router.handle(request)

        let delta = try JSONDecoder().decode(StateDelta.self, from: captured.values[0])
        guard case let .notificationReceived(n) = delta else {
            Issue.record("expected .notificationReceived")
            return
        }
        #expect(n.activate == false)
    }

    @Test("terminal.focus errors for an unknown terminal")
    func focusUnknownTerminalErrors() async throws {
        let params = TerminalFocusParams(terminalID: UUID())
        let request = try RPCRequest(method: RPCMethod.terminalFocus, params: params)
        let response = await router.handle(request)
        #expect(!response.success)
    }
}
