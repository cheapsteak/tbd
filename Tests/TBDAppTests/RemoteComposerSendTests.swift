import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The composer's remote branch: one `remote.sendMessage` per submit, the
/// text kept until the daemon accepts it, the daemon's own sentence on a
/// refusal, an immediate transcript sync on success, and never the local
/// paste or wake paths.
@MainActor
@Suite("Remote composer send")
struct RemoteComposerSendTests {
    private static let selection = RemoteSessionSelection(provider: "acme", sessionID: "s1")

    @MainActor
    private final class Recorder {
        var remoteSends: [(RemoteSessionSelection, String)] = []
        var syncRequests: [RemoteSessionSelection] = []
        var localSends = 0
        var wakes = 0
    }

    private func makeCoordinator(
        recorder: Recorder, remoteFails: Error? = nil, wireRemote: Bool = true
    ) -> ComposerSendCoordinator {
        // Typed up front: a closure literal inside the ternary below loses its
        // `@Sendable` inference.
        let remote: ComposerSendCoordinator.RemoteSender = { selection, text in
            recorder.remoteSends.append((selection, text))
            if let remoteFails { throw remoteFails }
        }
        return ComposerSendCoordinator(
            send: { _ in recorder.localSends += 1 },
            wake: { _, _, _ in
                recorder.wakes += 1
                return .noOp
            },
            awaitSessionStart: { _, _ in false },
            sendRemote: wireRemote ? remote : nil,
            onRemoteSent: { recorder.syncRequests.append($0) })
    }

    @Test("a running remote target sends the text as typed and asks for a sync")
    func runningSendsAndSyncs() async throws {
        let recorder = Recorder()
        let text = "please look at /command and\nthe second line"
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: text, paths: [:], state: .running, target: .remote(Self.selection))

        #expect(outcome == .sent)
        let sent = try #require(recorder.remoteSends.first)
        #expect(recorder.remoteSends.count == 1)
        #expect(sent.0 == Self.selection)
        #expect(sent.1 == text, "a typed /command and embedded newlines travel verbatim")
        #expect(recorder.syncRequests == [Self.selection])
        #expect(recorder.localSends == 0)
        #expect(recorder.wakes == 0)
    }

    @Test("a refused remote send reports the daemon's sentence and asks for no sync")
    func refusalBannersAndDoesNotSync() async {
        let recorder = Recorder()
        let outcome = await makeCoordinator(
            recorder: recorder,
            remoteFails: DaemonClientError.rpcError("session is waiting on a prompt", code: nil)
        ).send(text: "hi", paths: [:], state: .running, target: .remote(Self.selection))

        #expect(outcome == .failed(message: "session is waiting on a prompt"))
        #expect(recorder.syncRequests.isEmpty)
    }

    @Test("a blocked or exited remote target sends nothing")
    func disabledStatesSendNothing() async {
        let recorder = Recorder()
        let coordinator = makeCoordinator(recorder: recorder)
        let blocked = await coordinator.send(
            text: "hi", paths: [:], state: RemoteComposerState.blocked.composerState,
            target: .remote(Self.selection))
        let exited = await coordinator.send(
            text: "hi", paths: [:], state: RemoteComposerState.exited.composerState,
            target: .remote(Self.selection))
        let hidden = await coordinator.send(
            text: "hi", paths: [:], state: .hidden, target: .remote(Self.selection))

        #expect(blocked == .failed(message: "Waiting on a prompt — answer it in the terminal"))
        #expect(exited == .failed(message: "Session has exited"))
        #expect(hidden == .failed(message: "This session has no composer."))
        #expect(recorder.remoteSends.isEmpty)
        #expect(recorder.wakes == 0, "a remote target has no wake path")
    }

    @Test("a notRunning state never wakes a remote target")
    func notRunningNeverWakes() async {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "hi", paths: [:], state: .notRunning(exited: true),
            target: .remote(Self.selection))
        #expect(outcome == .failed(message: "This session is not running."))
        #expect(recorder.wakes == 0)
        #expect(recorder.remoteSends.isEmpty)
    }

    @Test("whitespace sends nothing")
    func whitespaceSendsNothing() async {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "  \n ", paths: [:], state: .running, target: .remote(Self.selection))
        #expect(outcome == .failed(message: "Nothing to send."))
        #expect(recorder.remoteSends.isEmpty)
    }

    @Test("a coordinator with no remote sender refuses rather than dropping the text")
    func unwiredRemoteSenderRefuses() async {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder, wireRemote: false).send(
            text: "hi", paths: [:], state: .running, target: .remote(Self.selection))
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(recorder.syncRequests.isEmpty)
    }

    @Test("a terminal target still takes the local paste path")
    func terminalTargetUsesLocalPath() async {
        let recorder = Recorder()
        let worktree = ComposerHarness.worktree()
        let terminal = ComposerHarness.runningTerminal(worktreeID: worktree.id)
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "hi", paths: [:], state: .running,
            target: .terminal(terminal, worktree))
        #expect(outcome == .sent)
        #expect(recorder.localSends == 1)
        #expect(recorder.remoteSends.isEmpty)
        #expect(recorder.syncRequests.isEmpty)
    }

    // MARK: - Composer state mapping

    @Test("remote composer states map onto the shared composer vocabulary")
    func stateMapping() {
        #expect(RemoteComposerState.hidden.composerState == .hidden)
        #expect(RemoteComposerState.running.composerState == .running)
        #expect(RemoteComposerState.blocked.composerState
                == .blocked(message: "Waiting on a prompt — answer it in the terminal"))
        #expect(RemoteComposerState.exited.composerState
                == .unavailable(message: "Session has exited"))
        #expect(!ComposerState.unavailable(message: "x").isEnabled)
    }
}
