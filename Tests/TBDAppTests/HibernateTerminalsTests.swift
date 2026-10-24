import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// A manual park sends one request per terminal and asks nothing first: the
/// daemon parks a session whose session mod cannot vouch for its draft
/// without a confirmation. A refusal shows the plain alert, and the rest of
/// the batch still goes.
@MainActor
@Suite("hibernate sends each terminal once")
struct HibernateTerminalsTests {

    private actor Calls {
        var all: [UUID] = []
        func record(_ id: UUID) { all.append(id) }
    }

    private func makeState() -> (AppState, String) {
        let suite = "HibernateTerminalsTests-\(UUID().uuidString)"
        return (AppState(userDefaults: UserDefaults(suiteName: suite)!), suite)
    }

    @Test func eachTerminalIsSentOnce() async {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let first = UUID(), second = UUID()
        let calls = Calls()
        state.terminalHibernateSender = { tid in await calls.record(tid) }

        await state.hibernateTerminals([first, second], worktreeID: UUID())

        #expect(await calls.all == [first, second])
        #expect(state.alertMessage == nil)
    }

    @Test func aRefusalAlertsAndTheBatchGoesOn() async {
        let (state, suite) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let refused = UUID(), fine = UUID()
        let calls = Calls()
        state.terminalHibernateSender = { tid in
            await calls.record(tid)
            if tid == refused {
                throw DaemonClientError.rpcError("session is running", code: nil)
            }
        }

        await state.hibernateTerminals([refused, fine], worktreeID: UUID())

        #expect(await calls.all == [refused, fine])
        #expect(state.alertMessage?.contains("Couldn't hibernate") == true)
    }
}
