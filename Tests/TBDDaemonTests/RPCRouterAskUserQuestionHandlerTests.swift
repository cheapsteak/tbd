import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

// Tests for the AskUserQuestion RPC handlers — verifies that PreToolUse
// flips the worktree to unread (attentionNeeded notification) and that
// PostToolUse marks notifications read as a belt-and-suspenders cleanup.
extension RPCRouterTests {

    // MARK: - Helpers

    private func makeRepoAndWorktree() async throws -> (repoID: UUID, worktreeID: UUID) {
        let repo = try await db.repos.create(
            path: "/tmp/test-repo-\(UUID().uuidString)",
            displayName: "test-repo",
            defaultBranch: "main"
        )
        let wt = try await db.worktrees.create(
            repoID: repo.id,
            name: "test-wt",
            branch: "tbd/test-wt",
            path: "/tmp/test-wt-\(UUID().uuidString)",
            tmuxServer: "tbd-test"
        )
        return (repo.id, wt.id)
    }

    private func sendPending(
        terminalID: UUID,
        toolUseID: String = "toolu_test",
        inputJSON: String
    ) async -> RPCResponse {
        let params = TerminalAskUserQuestionPendingParams(
            terminalID: terminalID,
            toolUseID: toolUseID,
            inputJSON: inputJSON,
            timestampMillis: Int64(Date().timeIntervalSince1970 * 1000)
        )
        let request = try! RPCRequest(method: RPCMethod.terminalAskUserQuestionPending, params: params)
        return await router.handle(request)
    }

    private func sendCleared(
        terminalID: UUID,
        toolUseID: String = "toolu_test"
    ) async -> RPCResponse {
        let params = TerminalAskUserQuestionClearedParams(
            terminalID: terminalID,
            toolUseID: toolUseID
        )
        let request = try! RPCRequest(method: RPCMethod.terminalAskUserQuestionCleared, params: params)
        return await router.handle(request)
    }

    // MARK: - Pending: happy path

    @Test("askUserQuestion.pending creates attentionNeeded notification for owning worktree")
    func askUserQuestionPendingCreatesNotification() async throws {
        let (_, worktreeID) = try await makeRepoAndWorktree()
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: "@mock-0",
            tmuxPaneID: "%mock-0"
        )

        let inputJSON = #"{"questions":[{"question":"Pick a fruit","header":"Fruit","options":[{"label":"apple","description":""}],"multiSelect":false}]}"#
        let response = await sendPending(terminalID: terminal.id, inputJSON: inputJSON)
        #expect(response.success)

        // Notification row was inserted with the expected fields.
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        let notif = try #require(unread.first)
        #expect(notif.type == .attentionNeeded)
        #expect(notif.worktreeID == worktreeID)
        let message = try #require(notif.message)
        #expect(message.contains("Pick a fruit"))

        // pendingQuestions is still populated for the transcript merger.
        let entries = await router.pendingQuestions.entries(forTerminal: terminal.id)
        #expect(entries.count == 1)
        #expect(entries.first?.toolUseID == "toolu_test")
    }

    // MARK: - Pending: terminal missing

    @Test("askUserQuestion.pending without DB terminal still stores pending entry, no notification")
    func askUserQuestionPendingWithMissingTerminal() async throws {
        let phantomTerminalID = UUID()
        let inputJSON = #"{"questions":[{"question":"Anything?","header":"Q","options":[],"multiSelect":false}]}"#
        let response = await sendPending(terminalID: phantomTerminalID, inputJSON: inputJSON)
        #expect(response.success)

        // No worktree to attach to → no notifications anywhere in the DB.
        let allRecords = try await db.notifications.unreadSummaryByWorktree()
        #expect(allRecords.isEmpty)

        // pendingQuestions still records the entry so any later transcript
        // request for this terminal can use it (preserves prior behavior).
        let entries = await router.pendingQuestions.entries(forTerminal: phantomTerminalID)
        #expect(entries.count == 1)
    }

    // MARK: - Pending: message extraction

    @Test("askUserQuestion.pending uses first question and truncates long text")
    func askUserQuestionPendingMessageExtraction() async throws {
        let (_, worktreeID) = try await makeRepoAndWorktree()
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: "@mock-1",
            tmuxPaneID: "%mock-1"
        )

        // 200-char question to force truncation, plus a second question we
        // must ignore.
        let longText = String(repeating: "A", count: 200)
        let inputJSON = """
        {"questions":[{"question":"\(longText)","header":"long","options":[],"multiSelect":false},{"question":"second question text","header":"second","options":[],"multiSelect":false}]}
        """

        let response = await sendPending(terminalID: terminal.id, inputJSON: inputJSON)
        #expect(response.success)

        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        let message = try #require(unread.first?.message)
        // First question wins.
        #expect(message.hasPrefix("A"))
        #expect(!message.contains("second question text"))
        // Truncated to <= 120 chars including the ellipsis.
        #expect(message.count <= 120)
        #expect(message.hasSuffix("…"))
    }

    // MARK: - Pending: malformed JSON

    @Test("askUserQuestion.pending with malformed inputJSON falls back to generic message")
    func askUserQuestionPendingMalformedJSON() async throws {
        let (_, worktreeID) = try await makeRepoAndWorktree()
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: "@mock-2",
            tmuxPaneID: "%mock-2"
        )

        let response = await sendPending(terminalID: terminal.id, inputJSON: "not-json-at-all{")
        #expect(response.success)

        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(unread.count == 1)
        let notif = try #require(unread.first)
        #expect(notif.type == .attentionNeeded)
        #expect(notif.message == "Claude is waiting for your answer")
    }

    // MARK: - Cleared: happy path

    @Test("askUserQuestion.cleared marks worktree notifications read")
    func askUserQuestionClearedMarksRead() async throws {
        let (_, worktreeID) = try await makeRepoAndWorktree()
        let terminal = try await db.terminals.create(
            worktreeID: worktreeID,
            tmuxWindowID: "@mock-3",
            tmuxPaneID: "%mock-3"
        )

        // Seed an unread notification (as if a prior PreToolUse already
        // marked attention needed).
        _ = try await db.notifications.create(
            worktreeID: worktreeID,
            type: .attentionNeeded,
            message: "Pick one"
        )
        let beforeUnread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(beforeUnread.count == 1)

        let response = await sendCleared(terminalID: terminal.id)
        #expect(response.success)

        let afterUnread = try await db.notifications.unread(worktreeID: worktreeID)
        #expect(afterUnread.isEmpty)
    }

    // MARK: - Cleared: terminal missing

    @Test("askUserQuestion.cleared returns ok when terminal is missing")
    func askUserQuestionClearedWithMissingTerminal() async throws {
        let response = await sendCleared(terminalID: UUID())
        #expect(response.success)
    }
}
