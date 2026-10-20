import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// A manual park the daemon refuses as `composerDraftUnconfirmed` becomes one
/// question; a yes reissues the refused terminals with the override.
@MainActor
@Suite("hibernate asks when the draft is unconfirmed")
struct HibernateUnconfirmedDraftTests {

    private actor Calls {
        var all: [(UUID, Bool)] = []
        func record(_ id: UUID, _ override: Bool) { all.append((id, override)) }
    }

    private func makeState() -> (AppState, String) {
        let suite = "HibernateUnconfirmedDraftTests-\(UUID().uuidString)"
        return (AppState(userDefaults: UserDefaults(suiteName: suite)!), suite)
    }

    private static let unconfirmed = DaemonClientError.rpcError(
        "draft unconfirmed", code: RPCErrorCode.composerDraftUnconfirmed.rawValue)

    @Test func promptCopyForOneSession() {
        let p = AppState.unconfirmedDraftPrompt(count: 1)
        #expect(p.message == "TBD can't confirm this session's draft is saved. Hibernate anyway?")
        #expect(p.informative == "Text typed but not sent may be lost.")
        #expect(p.confirm == "Hibernate Anyway")
    }

    @Test func promptCopyForSeveral() {
        let p = AppState.unconfirmedDraftPrompt(count: 3)
        #expect(p.message == "TBD can't confirm 3 sessions' drafts are saved. Hibernate anyway?")
        #expect(p.informative == "Text typed but not sent may be lost.")
        #expect(p.confirm == "Hibernate Anyway")
    }

    @Test func unconfirmedRefusalAsksAndReissuesWithOverride() async {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let id = UUID()
        let calls = Calls()
        state.terminalHibernateSender = { tid, override in
            await calls.record(tid, override)
            if !override { throw Self.unconfirmed }
        }
        var asked: [Int] = []
        state.unconfirmedDraftConfirmer = { count in asked.append(count); return true }

        await state.hibernateTerminal(terminalID: id, worktreeID: UUID())

        let all = await calls.all
        #expect(asked == [1])
        #expect(all.count == 2)
        #expect(all[0].0 == id && all[0].1 == false)
        #expect(all[1].0 == id && all[1].1 == true)
    }

    @Test func decliningDoesNothing() async {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let calls = Calls()
        state.terminalHibernateSender = { tid, override in
            await calls.record(tid, override)
            throw Self.unconfirmed
        }
        state.unconfirmedDraftConfirmer = { _ in false }

        await state.hibernateTerminal(terminalID: UUID(), worktreeID: UUID())

        #expect(await calls.all.count == 1)
        #expect(state.alertMessage == nil)
    }

    @Test func otherErrorsStillAlert() async {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        state.terminalHibernateSender = { _, _ in
            throw DaemonClientError.rpcError("session is running", code: nil)
        }
        var asked = 0
        state.unconfirmedDraftConfirmer = { _ in asked += 1; return true }

        await state.hibernateTerminal(terminalID: UUID(), worktreeID: UUID())

        #expect(asked == 0)
        #expect(state.alertMessage?.contains("Couldn't hibernate") == true)
    }

    @Test func batchAsksOnce() async {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let refusedA = UUID(), refusedB = UUID(), fine = UUID()
        let calls = Calls()
        state.terminalHibernateSender = { tid, override in
            await calls.record(tid, override)
            if tid != fine && !override { throw Self.unconfirmed }
        }
        var asked: [Int] = []
        state.unconfirmedDraftConfirmer = { count in asked.append(count); return true }

        await state.hibernateTerminals([refusedA, fine, refusedB], worktreeID: UUID())

        let all = await calls.all
        #expect(asked == [2])
        let overridden = all.filter { $0.1 }.map { $0.0 }
        #expect(Set(overridden) == [refusedA, refusedB])
        #expect(all.count == 5)
    }
}
