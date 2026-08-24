import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The app mirrors the daemon's awaiting-input columns from a push, rather than
/// deriving them or waiting for the next `terminal.list` refresh. This is what
/// lets the sidebar show "a prompt is on screen" on the worktree the user is
/// looking at: the `.attentionNeeded` notification that reports the same thing
/// is auto-marked-read for every visible worktree.
@Suite("AppState — terminalAwaitingInputChanged")
@MainActor
struct TerminalAwaitingInputDeltaTests {
    /// `UserDefaults.standard` on this unbundled executable is the developer's
    /// real `TBDApp.plist`, so each `AppState` gets its own suite and the
    /// caller tears it down.
    private func state() -> (
        state: AppState, worktreeID: UUID, terminalID: UUID, suiteName: String
    ) {
        let suiteName = "TerminalAwaitingInputDeltaTests-\(UUID().uuidString)"
        let state = AppState(userDefaults: UserDefaults(suiteName: suiteName)!)
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals = [
            worktreeID: [
                Terminal(
                    id: terminalID,
                    worktreeID: worktreeID,
                    tmuxWindowID: "@1",
                    tmuxPaneID: "%1",
                    label: "claude",
                    kind: .claude,
                    activityState: .working,
                    activityStateSource: .hookEvent("PreToolUse"),
                    activityStateObservedAt: Date(timeIntervalSince1970: 10)
                )
            ]
        ]
        return (state, worktreeID, terminalID, suiteName)
    }

    private static let prompt = AwaitingInputReason(
        message: "Claude needs your permission to use Bash",
        hookEventName: "Notification",
        notificationType: "permission_prompt")

    @Test func recordsTheReasonOnTheCachedTerminal() throws {
        let (app, worktreeID, terminalID, suiteName) = state()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let observedAt = Date(timeIntervalSince1970: 20)

        app.handleDelta(.terminalAwaitingInputChanged(TerminalAwaitingInputDelta(
            terminalID: terminalID,
            worktreeID: worktreeID,
            reason: Self.prompt,
            observedAt: observedAt)))

        let terminal = try #require(app.terminals[worktreeID]?.first)
        #expect(terminal.awaitingInputReason == Self.prompt)
        #expect(terminal.awaitingInputObservedAt == observedAt)
        #expect(terminal.hasPromptOnScreen)
    }

    /// The delta says nothing about what the session is doing, and the daemon
    /// deliberately does not move `activityState` from the `Notification` hook
    /// either — it gates hibernation.
    @Test func leavesTheActivityFactAlone() throws {
        let (app, worktreeID, terminalID, suiteName) = state()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let before = app.terminals[worktreeID]!.first!

        app.handleDelta(.terminalAwaitingInputChanged(TerminalAwaitingInputDelta(
            terminalID: terminalID,
            worktreeID: worktreeID,
            reason: Self.prompt,
            observedAt: Date(timeIntervalSince1970: 20))))

        let after = try #require(app.terminals[worktreeID]?.first)
        #expect(after.activityState == before.activityState)
        #expect(after.activityStateSource == before.activityStateSource)
        #expect(after.activityStateObservedAt == before.activityStateObservedAt)
    }

    @Test func retractionClearsBothColumns() throws {
        let (app, worktreeID, terminalID, suiteName) = state()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        app.handleDelta(.terminalAwaitingInputChanged(TerminalAwaitingInputDelta(
            terminalID: terminalID,
            worktreeID: worktreeID,
            reason: Self.prompt,
            observedAt: Date(timeIntervalSince1970: 20))))

        app.handleDelta(.terminalAwaitingInputChanged(TerminalAwaitingInputDelta(
            terminalID: terminalID,
            worktreeID: worktreeID,
            reason: nil,
            observedAt: nil)))

        let terminal = try #require(app.terminals[worktreeID]?.first)
        #expect(terminal.awaitingInputReason == nil)
        #expect(terminal.awaitingInputObservedAt == nil)
        #expect(!terminal.hasPromptOnScreen)
    }

    @Test func aDeltaForAnUnknownTerminalIsANoOp() {
        let (app, worktreeID, _, suiteName) = state()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        app.handleDelta(.terminalAwaitingInputChanged(TerminalAwaitingInputDelta(
            terminalID: UUID(),
            worktreeID: worktreeID,
            reason: Self.prompt,
            observedAt: Date(timeIntervalSince1970: 20))))

        #expect(app.terminals[worktreeID]?.first?.awaitingInputReason == nil)
    }
}
