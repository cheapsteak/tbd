import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TBDKernel

/// The session-ended step dev servers save their last output through
/// (plan decision D2): called once per finished session, with the
/// established status, while the reader is still published and holds the
/// final screen — and the release still follows.
@Suite(.serialized)
struct HolderSessionEndedObserverTests {
    private struct Call: Sendable {
        let terminalID: UUID
        let status: HolderChildStatus
        let screen: String
        let readerStillPublished: Bool
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var calls: [Call] = []
        func append(_ call: Call) { lock.lock(); calls.append(call); lock.unlock() }
        var all: [Call] { lock.lock(); defer { lock.unlock() }; return calls }
    }

    @Test func theObserverSeesTheStatusAndTheScreenBeforeTheRelease() async throws {
        let fixture = try await HolderProcessFixture.start(command: "printf 'BOOM\\n'; exit 3")
        defer { fixture.tearDown() }
        await fixture.client.close()

        let registry = HolderRegistry(
            owner: fixture.owner,
            environment: HolderProcessFixture.environment(home: fixture.home),
            listTerminals: { [] })
        defer { Task.detached { await registry.releaseAll() } }
        let calls = Calls()
        await registry.setSessionEndedObserver { terminalID, status, reader in
            let screen = await reader.renderScreen()
            let published = await registry.reader(for: terminalID) === reader
            calls.append(Call(terminalID: terminalID, status: status, screen: screen,
                              readerStillPublished: published))
        }

        _ = try await registry.adopt(terminal: Terminal(
            id: fixture.sessionID, worktreeID: UUID(), tmuxWindowID: "", tmuxPaneID: "", transport: .holder))
        let released = await pollUntil("the registry to release the finished session's reader") {
            await registry.reader(for: fixture.sessionID) == nil
        }
        #expect(released, "the observer must not prevent the release")

        let seen = calls.all
        #expect(seen.count == 1)
        let call = try #require(seen.first)
        #expect(call.terminalID == fixture.sessionID)
        #expect(call.status == .exited(code: 3))
        #expect(call.screen.contains("BOOM"), "the observer ran after the screen was lost: \(call.screen.debugDescription)")
        #expect(call.readerStillPublished, "the observer ran after the release")
    }
}
