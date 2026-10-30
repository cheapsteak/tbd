import Testing
import Foundation
import TBDShared
@testable import TBDDaemonLib

/// The pure half of the column writer: which column value a rolled-up state
/// maps to, what the stored wait reason carries, and the banner's fixed text.
@Suite struct ProgramStatusColumnTests {
    private let t0 = Date(timeIntervalSince1970: 4_000_000)

    @Test func everyRollupValueMapsToItsColumn() {
        let question = ProgramStatusBlock(kind: .question, taskID: nil)
        #expect(ProgramStatusColumnValue.mapping(.working) == ProgramStatusColumnValue.working)
        #expect(ProgramStatusColumnValue.mapping(.awaitingInput(reason: AwaitingInputReason(
            message: "m", programStatusBlock: question)))
            == ProgramStatusColumnValue.waitingForUser(question))
        #expect(ProgramStatusColumnValue.mapping(.awaitingInput(reason: nil))
            == ProgramStatusColumnValue.waitingForUser(ProgramStatusBlock(kind: nil, taskID: nil)))
        #expect(ProgramStatusColumnValue.mapping(.idle) == ProgramStatusColumnValue.idle)
        #expect(ProgramStatusColumnValue.mapping(.done) == ProgramStatusColumnValue.idle)
        #expect(ProgramStatusColumnValue.mapping(.error) == ProgramStatusColumnValue.idle)
        #expect(ProgramStatusColumnValue.mapping(.needsAuth) == ProgramStatusColumnValue.idle)
        #expect(ProgramStatusColumnValue.mapping(.parked(reason: "auto")) == nil)
        #expect(ProgramStatusColumnValue.mapping(.gone) == nil)
        #expect(ProgramStatusColumnValue.mapping(.unknown(why: "nothing")) == nil)
        #expect(ProgramStatusColumnValue.mapping(.rateLimited(until: nil)) == nil)
    }

    @Test func onlyAWaitCarriesAReason() {
        #expect(ProgramStatusColumnValue.working.awaitingInputReason == nil)
        #expect(ProgramStatusColumnValue.idle.awaitingInputReason == nil)
        #expect(ProgramStatusColumnValue.unknown.awaitingInputReason == nil)
        #expect(ProgramStatusColumnValue.unknown.activityState == .unknown)
        #expect(ProgramStatusColumnValue.unknown.block == nil)
    }

    @Test func theStoredReasonCarriesTheBlockAndNoText() throws {
        let snapshot = ProgramStatusSnapshot(
            terminalID: UUID(), incarnationID: nil,
            main: ProgramStatusEntry(
                state: .blocked, kind: .permission, title: "acme title", msg: "acme secret",
                observedAt: t0),
            tasks: [], revision: 1)
        let resolved = try #require(ProgramStatusRollup.resolve(snapshot))
        let value = try #require(ProgramStatusColumnValue.mapping(resolved.value))
        #expect(value.activityState == .waitingForUser)
        let reason = try #require(value.awaitingInputReason)
        #expect(reason.message == "")
        #expect(reason.programStatusBlock?.kind == .permission)
        #expect(reason.programStatusBlock?.taskID == nil)
        #expect(reason.classification == .promptOnScreen)
        let encoded = try #require(FactColumnJSON.encode(reason))
        #expect(!encoded.contains("acme secret"))
        #expect(!encoded.contains("acme title"))
    }

    @Test func blockedTaskMapsWithItsTaskID() throws {
        let snapshot = ProgramStatusSnapshot(
            terminalID: UUID(), incarnationID: nil,
            main: ProgramStatusEntry(state: .idle, observedAt: t0),
            tasks: [ProgramStatusTaskEntry(
                id: "t1",
                entry: ProgramStatusEntry(
                    state: .blocked, kind: .question, title: "acme task",
                    observedAt: t0.addingTimeInterval(1)))],
            revision: 1)
        let resolved = try #require(ProgramStatusRollup.resolve(snapshot))
        let value = try #require(ProgramStatusColumnValue.mapping(resolved.value))
        #expect(value.activityState == .waitingForUser)
        #expect(value.block?.taskID == "t1")
        #expect(value.awaitingInputReason?.message == "")
    }

    @Test func bannerTextPerAgentAndKind() {
        let claude = ProgramStatusProtocol.claudeCodeApp
        let codex = ProgramStatusProtocol.codexApp
        let permission = ProgramStatusBlock(kind: .permission, taskID: nil)
        let question = ProgramStatusBlock(kind: .question, taskID: nil)
        let unnamed = ProgramStatusBlock(kind: nil, taskID: nil)

        #expect(ProgramStatusAttention.message(app: claude, block: permission)
            == "Claude needs your permission")
        #expect(ProgramStatusAttention.message(app: codex, block: permission)
            == "Codex needs your permission")
        #expect(ProgramStatusAttention.message(app: claude, block: question)
            == "Claude has a question")
        #expect(ProgramStatusAttention.message(app: codex, block: question)
            == "Codex has a question")
        #expect(ProgramStatusAttention.message(app: claude, block: unnamed)
            == "Claude needs your input")
        #expect(ProgramStatusAttention.message(app: codex, block: unnamed)
            == "Codex needs your input")

        // A blocked task entry is labelled by its task, whatever its kind.
        #expect(ProgramStatusAttention.message(
            app: claude, block: ProgramStatusBlock(kind: .permission, taskID: "t1"))
            == "Claude needs your input")
        #expect(ProgramStatusAttention.message(
            app: claude, block: ProgramStatusBlock(kind: .auth, taskID: nil))
            == "Claude needs your input")
        #expect(ProgramStatusAttention.message(
            app: codex, block: ProgramStatusBlock(kind: .unrecognized("acme"), taskID: nil))
            == "Codex needs your input")
        #expect(ProgramStatusAttention.message(app: nil, block: question)
            == "Claude has a question")
    }
}
