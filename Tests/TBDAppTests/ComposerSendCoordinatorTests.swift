import Foundation
import TestSupport
import Testing
@testable import TBDApp
import TBDShared

/// How a composed message leaves the app.
///
/// The two paths are genuinely different mechanisms — a paste into a live
/// session, and an argv on a respawn — and the branch between them is a machine
/// fact, not a guess. The hold-until-SessionStart is what makes the wake path
/// honest: a wake whose session id no longer resolves makes Claude print one line
/// and exit 1 with the prompt lost, while tmux reports the respawn as a success.
@MainActor
@Suite("ComposerSendCoordinator")
struct ComposerSendCoordinatorTests {

    private static let mintedIncarnation = UUID()

    /// Main-actor isolated, and so `Sendable`: the coordinator's closure
    /// typealiases are `@Sendable`, which is what keeps a child of its task
    /// group from capturing state nobody has serialized.
    @MainActor
    private final class Recorder {
        var params: [TerminalSendParams] = []
        var wakePrompts: [String] = []
        /// The (terminal, incarnation) pairs the hold actually waited on.
        var waitedOn: [(UUID, UUID)] = []
    }

    private func makeCoordinator(
        recorder: Recorder,
        sendFails: Bool = false,
        wakeReply: ComposerSendCoordinator.WakeReply
            = .woken(incarnationID: ComposerSendCoordinatorTests.mintedIncarnation),
        /// Which incarnation the terminal's own SessionStart eventually carries.
        /// nil means none ever arrives.
        sessionStartCarries: UUID? = ComposerSendCoordinatorTests.mintedIncarnation,
        clock: any Clock<Duration> = ContinuousClock()
    ) -> ComposerSendCoordinator {
        ComposerSendCoordinator(
            send: { params in
                recorder.params.append(params)
                if sendFails { throw DaemonClientError.rpcError("nope", code: nil) }
            },
            wake: { _, _, prompt in
                recorder.wakePrompts.append(prompt)
                return wakeReply
            },
            awaitSessionStart: { terminalID, incarnationID in
                recorder.waitedOn.append((terminalID, incarnationID))
                // The production waiter resolves only on a matching id; the
                // double models exactly that rather than answering a bare Bool.
                return sessionStartCarries == incarnationID
            },
            clock: clock)
    }

    // MARK: - Running

    @Test func aRunningSendCarriesPartsSuppressionAndTheGate() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "look at \(ComposerTokens.text(for: 1)) please",
            paths: [1: "/tmp/a.png"],
            state: .running, terminalID: UUID(), worktreeID: UUID())

        #expect(outcome == .sent)
        let params = try #require(recorder.params.first)
        #expect(params.parts == [
            .text("look at "), .imagePath("/tmp/a.png"), .text(" please"),
        ])
        #expect(params.envelope == .suppressed)
        #expect(params.gateOnAwaitingInput == true)
        #expect(params.submit == true)
        // The composer never uses the keys path and never asks for verification.
        #expect(params.keys == nil)
        #expect(params.verify == nil)
        #expect(params.text == nil)
    }

    @Test func aFailedSendReportsItAndDoesNotClaimDelivery() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder, sendFails: true).send(
            text: "hi", paths: [:], state: .running,
            terminalID: UUID(), worktreeID: UUID())
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
    }

    // MARK: - Not running

    /// An argument prompt cannot carry attachments, so each token is replaced
    /// inline with its quoted path and Claude reads the files with its Read tool.
    @Test func aNotRunningSendWakesWithTheFlattenedText() async throws {
        let recorder = Recorder()
        let terminalID = UUID()
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "look at \(ComposerTokens.text(for: 1)) please",
            paths: [1: "/tmp/a.png"],
            state: .notRunning(exited: true), terminalID: terminalID, worktreeID: UUID())

        #expect(outcome == .woke)
        #expect(recorder.wakePrompts == ["look at '/tmp/a.png' please"])
        #expect(recorder.params.isEmpty, "a not-running send must never call terminal.send")
        // The hold waited on THIS wake's own spawn, not on the terminal at large.
        #expect(recorder.waitedOn.count == 1)
        #expect(recorder.waitedOn.first?.0 == terminalID)
        #expect(recorder.waitedOn.first?.1 == Self.mintedIncarnation)
    }

    /// **The hold.** The composer's own session never reports in, so the text
    /// comes back editable with an error line rather than vanishing into a
    /// session that exited 1 while tmux called the respawn a success.
    @Test func aWakeWhoseSessionNeverStartsFails() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(
            recorder: recorder, sessionStartCarries: nil).send(
            text: "hi", paths: [:], state: .notRunning(exited: true),
            terminalID: UUID(), worktreeID: UUID())

        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("did not report"))
    }

    /// **The load-bearing negative for the whole incarnation scoping.** A
    /// SessionStart arrives on this terminal, and it belongs to somebody else's
    /// spawn — a competing wake, a post-`--fork-session` recapture, a person
    /// typing `claude --resume` in the pane. It must NOT release the hold.
    @Test func aSessionStartFromAnotherIncarnationDoesNotRelease() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(
            recorder: recorder, sessionStartCarries: UUID()).send(
            text: "hi", paths: [:], state: .notRunning(exited: true),
            terminalID: UUID(), worktreeID: UUID())

        guard case .failed = outcome else {
            Issue.record("another spawn's SessionStart must not release the hold")
            return
        }
    }

    /// `woken: false` is an idempotent no-op: the prompt was never delivered
    /// anywhere, there is no spawn to wait on, and the hold is never entered.
    @Test func aNoOpWakeSurfacesWithoutEnteringTheHold() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder, wakeReply: .noOp).send(
            text: "hi", paths: [:], state: .notRunning(exited: false),
            terminalID: UUID(), worktreeID: UUID())

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(recorder.waitedOn.isEmpty, "a no-op names no spawn to wait on")
    }

    /// The session-gone error surfaces too, and also without entering the hold.
    /// The wake RPC distinguishes the two and the app must swallow neither.
    @Test func aRefusedWakeSurfacesItsMessage() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(
            recorder: recorder, wakeReply: .failed(message: "session gone")).send(
            text: "hi", paths: [:], state: .notRunning(exited: false),
            terminalID: UUID(), worktreeID: UUID())

        guard case .failed(let message) = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(message.contains("session gone"))
        #expect(recorder.waitedOn.isEmpty)
    }

    /// A daemon too old to report an incarnation woke the session and delivered
    /// the prompt — it just cannot name the spawn. Holding until the timeout
    /// would show an error for a message that landed, so this reports success
    /// and does not wait.
    @Test func aWokenWakeWithNoIncarnationDoesNotHold() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(
            recorder: recorder, wakeReply: .woken(incarnationID: nil),
            sessionStartCarries: nil).send(
            text: "hi", paths: [:], state: .notRunning(exited: true),
            terminalID: UUID(), worktreeID: UUID())

        #expect(outcome == .woke)
        #expect(recorder.waitedOn.isEmpty)
    }

    /// The hold's deadline is the **injected** clock's, never wall time. A
    /// waiter that simply never answers is released by advancing virtual time
    /// past the timeout — which is the only way a 45-second bound is testable
    /// at all, and the reason the coordinator takes a clock.
    @Test(.clockDriven) func theHoldTimesOutOnTheInjectedClock() async throws {
        let recorder = Recorder()
        let clock = EventDrivenTestClock()
        let coordinator = ComposerSendCoordinator(
            send: { recorder.params.append($0) },
            wake: { _, _, prompt in
                recorder.wakePrompts.append(prompt)
                return .woken(incarnationID: Self.mintedIncarnation)
            },
            awaitSessionStart: { terminalID, incarnationID in
                recorder.waitedOn.append((terminalID, incarnationID))
                // Never answers on its own. Only the clock can end this send —
                // and this parks until it does rather than spinning: a
                // `Task.yield()` loop burns a core for the whole hold and, on a
                // cooperative pool of one, can starve the very timer it is
                // waiting for.
                let (parked, release) = AsyncStream<Void>.makeStream()
                await withTaskCancellationHandler {
                    // Nothing is ever yielded into it; the loop ends when the
                    // race cancels the loser and `finish()` closes the stream.
                    for await _ in parked {}
                } onCancel: {
                    release.finish()
                }
                return false
            },
            clock: clock)

        async let outcome = coordinator.send(
            text: "hi", paths: [:], state: .notRunning(exited: true),
            terminalID: UUID(), worktreeID: UUID())

        // **Wait for the sleeper, then advance — on the fast pass's budget, not
        // on the handshake's.** Three things have to happen before the timeout
        // child registers anything: the `async let` child has to get a thread,
        // `send` has to run its `wake` double and reach the task group *on the
        // main actor* — a process-wide serialization point every other
        // `@MainActor` test in the pass queues on — and the group's timeout child
        // has to get a thread of its own. None of that is the coordinator being
        // slow, so the bound belongs to `TestDeadlines.saturatedPass` (90 s): the
        // clock's 45 s default sits *below* fast pass 2's measured p90 per-test
        // latency (51.4 s, max 55.3 s), which is how this test came back red on
        // CI while passing on an idle machine. Nothing in the doubles can hold
        // the group back — the waiter double releases the main actor at its first
        // suspension and the timeout child never touches it — so the wait only
        // ever pays for scheduling.
        try await clock.requireSleeperArmed(timeout: TestDeadlines.saturatedPass)
        await clock.advance(by: ComposerSendCoordinator.wakeHoldTimeout)

        guard case .failed(let message) = await outcome else {
            Issue.record("the hold must expire on the injected clock")
            return
        }
        #expect(message.contains("did not report"))
        // **The sentence a person reads.** The bound is spelled in whole
        // seconds — interpolating the `Duration` renders "45.0 seconds", which
        // reads as a measurement — and the copy claims only what the app can
        // know. The prompt left on the respawn's own argv, so a session that
        // never reported in is one TBD heard nothing FROM, which is not the same
        // as one that received nothing.
        #expect(message.contains("45 seconds"))
        #expect(!message.contains("45.0"))
        #expect(message.contains("could not be confirmed"))
        #expect(!message.lowercased().contains("was not delivered"))
        #expect(recorder.waitedOn.count == 1)
    }

    // MARK: - What the banner says

    /// A refusal reaches the person in the daemon's own words. The error's
    /// `localizedDescription` would prefix them with "RPC error: ", which names
    /// a transport nobody typing into the composer has heard of.
    @Test func aRefusalsMessageReachesTheBannerVerbatim() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder, sendFails: true).send(
            text: "hi", paths: [:], state: .running,
            terminalID: UUID(), worktreeID: UUID())

        #expect(outcome == .failed(message: "nope"))
    }

    private struct BoomError: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    /// The other branch: anything that is not an RPC refusal keeps its own
    /// description. The unwrapping drops the daemon's framing, not the error.
    @Test func aNonRPCFailureKeepsItsOwnDescription() async throws {
        let coordinator = ComposerSendCoordinator(
            send: { _ in throw BoomError() },
            wake: { _, _, _ in .noOp },
            awaitSessionStart: { _, _ in false })

        let outcome = await coordinator.send(
            text: "hi", paths: [:], state: .running,
            terminalID: UUID(), worktreeID: UUID())

        #expect(outcome == .failed(message: "boom"))
    }

    // MARK: - Refusals

    @Test func aBlockedComposerSendsNothing() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "hi", paths: [:], state: .blocked(message: "Allow?"),
            terminalID: UUID(), worktreeID: UUID())

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(recorder.params.isEmpty)
        #expect(recorder.wakePrompts.isEmpty)
    }

    /// A composer that is not on screen at all cannot have been asked to send —
    /// but the coordinator answers for the state anyway rather than assuming.
    @Test func aHiddenComposerSendsNothing() async throws {
        let recorder = Recorder()
        let outcome = await makeCoordinator(recorder: recorder).send(
            text: "hi", paths: [:], state: .hidden,
            terminalID: UUID(), worktreeID: UUID())

        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(recorder.params.isEmpty)
        #expect(recorder.wakePrompts.isEmpty)
    }

    @Test func blankTextSendsNothing() async throws {
        let recorder = Recorder()
        _ = await makeCoordinator(recorder: recorder).send(
            text: "   \n ", paths: [:], state: .running,
            terminalID: UUID(), worktreeID: UUID())
        #expect(recorder.params.isEmpty)
    }

    /// A message that is nothing but an image token is still a message.
    @Test func aTokenOnlyMessageIsNotBlank() async throws {
        let recorder = Recorder()
        _ = await makeCoordinator(recorder: recorder).send(
            text: ComposerTokens.text(for: 1), paths: [1: "/tmp/a.png"],
            state: .running, terminalID: UUID(), worktreeID: UUID())
        #expect(recorder.params.first?.parts == [.imagePath("/tmp/a.png")])
    }
}
