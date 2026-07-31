import Foundation
import TBDShared
import Testing
@testable import TBDApp

/// Tier 1 state-action tests. The injected performer replaces the external
/// daemon boundary; terminal/tab integration, dedupe, and alert behavior are
/// real AppState behavior.
@MainActor
@Suite("Continue in Codex AppState action")
struct ContinueInCodexAppStateTests {
    private struct TestError: LocalizedError {
        var errorDescription: String? { "Claude transcript is unavailable" }
    }

    private actor TakeoverGate {
        private var started = false
        private var released = false
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

        func blockUntilReleased() async {
            started = true
            let waiters = startedWaiters
            startedWaiters.removeAll()
            waiters.forEach { $0.resume() }
            guard !released else { return }
            await withCheckedContinuation { releaseWaiters.append($0) }
        }

        func waitUntilStarted() async {
            guard !started else { return }
            await withCheckedContinuation { startedWaiters.append($0) }
        }

        func release() {
            released = true
            let waiters = releaseWaiters
            releaseWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }

    private func withAppState(
        _ body: @MainActor (AppState, UserDefaults) async throws -> Void
    ) async rethrows {
        let suiteName = "TBDAppTests.ContinueInCodex.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(false, forKey: AppState.terminalAutoResizeKey)
        try await body(AppState(userDefaults: defaults), defaults)
    }

    private func result(
        terminal: Terminal,
        created: Bool = true
    ) -> TerminalContinueInCodexResult {
        TerminalContinueInCodexResult(
            terminal: terminal,
            handoffPath: "/private/tmp/CODEX_HANDOFF.md",
            created: created,
            warnings: [],
            capture: TerminalContinueInCodexCaptureMetadata(
                transcriptBytesRead: 1_024,
                transcriptBytesRendered: 768,
                handoffBytesOutput: 2_048,
                transcriptTailTruncated: false
            )
        )
    }

    @Test("integrates and selects the returned Codex terminal")
    func successIntegratesReturnedTerminal() async {
        await withAppState { state, _ in
            let sourceID = UUID()
            let worktreeID = UUID()
            let target = Terminal(
                worktreeID: worktreeID,
                tmuxWindowID: "@2",
                tmuxPaneID: "%2",
                label: TerminalLabel.codex,
                kind: .codex
            )
            var received: (UUID, Int?, Int?, String?)?
            state.continueInCodexPerformer = { source, cols, rows, colorFgBg in
                received = (source, cols, rows, colorFgBg)
                return result(terminal: target)
            }

            await state.continueInCodex(sourceTerminalID: sourceID)

            #expect(received?.0 == sourceID)
            #expect(received?.1 == nil)
            #expect(received?.2 == nil)
            #expect(received?.3 == nil)
            #expect(state.terminals[worktreeID]?.map(\.id) == [target.id])
            #expect(state.tabs[worktreeID]?.map(\.id) == [target.id])
            #expect(state.activeTabIndices[worktreeID] == 0)
            #expect(state.continueInCodexInFlight.isEmpty)
        }
    }

    @Test("suppresses an overlapping click and integrates only one terminal")
    func overlappingRequestsAreDeduplicated() async {
        await withAppState { state, _ in
            let sourceID = UUID()
            let worktreeID = UUID()
            let target = Terminal(
                worktreeID: worktreeID,
                tmuxWindowID: "@2",
                tmuxPaneID: "%2",
                label: TerminalLabel.codex,
                kind: .codex
            )
            let gate = TakeoverGate()
            var callCount = 0
            state.continueInCodexPerformer = { _, _, _, _ in
                callCount += 1
                await gate.blockUntilReleased()
                return result(terminal: target)
            }

            let first = Task {
                await state.continueInCodex(sourceTerminalID: sourceID)
            }
            await gate.waitUntilStarted()

            await state.continueInCodex(sourceTerminalID: sourceID)

            #expect(callCount == 1)
            #expect(state.continueInCodexInFlight == [sourceID])

            await gate.release()
            await first.value

            #expect(callCount == 1)
            #expect(state.terminals[worktreeID]?.map(\.id) == [target.id])
            #expect(state.tabs[worktreeID]?.map(\.id) == [target.id])
            #expect(state.continueInCodexInFlight.isEmpty)
        }
    }

    @Test("shows the daemon error and clears the in-flight guard")
    func failureShowsUsefulErrorAndAllowsRetry() async {
        await withAppState { state, _ in
            let sourceID = UUID()
            var callCount = 0
            state.continueInCodexPerformer = { _, _, _, _ in
                callCount += 1
                throw TestError()
            }

            await state.continueInCodex(sourceTerminalID: sourceID)
            await state.continueInCodex(sourceTerminalID: sourceID)

            #expect(callCount == 2)
            #expect(state.alertMessage == "Couldn't continue in Codex: Claude transcript is unavailable")
            #expect(state.alertIsError)
            #expect(state.continueInCodexInFlight.isEmpty)
            #expect(state.terminals.values.flatMap { $0 }.isEmpty)
        }
    }
}
