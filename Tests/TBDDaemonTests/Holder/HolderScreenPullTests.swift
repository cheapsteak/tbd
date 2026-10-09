import Clocks
import Foundation
import TBDShared
import Testing

@testable import TBDDaemonLib
import TestSupport

/// What `HolderScreenPull` promises: **one request, one answer, matched by id,
/// scoped to the connection it went out on, and bounded** — with every answer
/// that does not satisfy all four counted and dropped rather than applied.
///
/// Modelled on `HolderInjectionRoutingTests`, because the two types are
/// deliberate siblings. Every bound here runs on a `TestClock`, so nothing
/// sleeps in real time; the only real-time waits are `waitFor` polls for a
/// frame to have reached the harness, the scheduling handshake
/// `Tests/CLAUDE.md`'s clock-seam note sanctions, because
/// `Task { await pull.pull(…) }` only *schedules* the call.
///
/// `.clockDriven` at suite level: most of these await a value a broken puller
/// would never produce, so each needs its own hang bound.
@Suite("HolderScreenPull", .clockDriven, .serialized)
struct HolderScreenPullTests {

    // MARK: - Harness

    /// Stands in for the one thing the puller reaches out to: the sidecar it
    /// puts frames on, which answers with the epoch it sent on.
    private final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var sentFrames: [Data] = []

        /// The epoch `sendFrame` answers with — the connection the request
        /// went out on.
        var epoch: UInt64 = 1
        /// When set, `sendFrame` throws it: the sidecar being gone.
        var sendFrameError: Error?

        var frames: [Data] { lock.withLock { sentFrames } }

        /// Builds a puller on the **production** bound: the `bound` argument is
        /// *omitted*, not passed, so `HolderInputTiming.screenPullBound` is
        /// what the bound tests below actually exercise. A harness default of
        /// its own would make those tests prove nothing about the shipped
        /// value.
        func makePull(clock: any Clock<Duration>) -> HolderScreenPull {
            HolderScreenPull(sendFrame: sendFrame, clock: clock)
        }

        /// For tests about something other than the bound.
        func makePull(bound: Duration, clock: any Clock<Duration>) -> HolderScreenPull {
            HolderScreenPull(sendFrame: sendFrame, bound: bound, clock: clock)
        }

        private var sendFrame: @Sendable (Data) async throws -> UInt64 {
            { [self] frame in
                if let sendFrameError { throw sendFrameError }
                lock.withLock { sentFrames.append(frame) }
                return epoch
            }
        }

        /// The request the puller put on the wire, parsed back off it. Reading
        /// the real frame rather than a recorded tuple is what makes these
        /// tests cover the encoder as well as the correlation.
        func decodeRequest(at index: Int = 0) throws -> SidecarScreenRequest {
            let all = frames
            let wire: Data? = all.indices.contains(index) ? all[index] : nil
            let scanner = SidecarFrameScanner()
            let parsed = scanner.append(try #require(wire))
            let frame = try #require(parsed.first)
            #expect(SidecarFrameType(rawValue: frame.type) == .screenRequest)
            return try SidecarFrameCodec.decodeScreenRequest(payload: frame.payload)
        }
    }

    private struct SidecarGone: Error {}

    /// What the puller was supposed to answer, and what it answered.
    ///
    /// An `Error` rather than a string so `Issue.record` puts it on the primary
    /// failure line.
    private struct UnexpectedAnswer: Error, CustomStringConvertible {
        let expected: String
        let actual: HolderScreenPull.Answer

        var description: String { "the pull must answer \(expected), answered \(actual)" }
    }

    private static func payload(
        lines: [String] = ["live"], ageMilliseconds: Int = 3
    ) -> ViewerScreenPayload {
        ViewerScreenPayload(
            lines: lines, viewportStart: 0, cursorRow: 0, cursorColumn: 0,
            cursorVisible: true, cursorVisibleObserved: false,
            columns: 80, rows: 24,
            bracketedPaste: true, applicationCursor: false, alternateScreen: false,
            ageMilliseconds: ageMilliseconds)
    }

    // MARK: - The answer path

    @Test("A reply under the pending request id resolves the pull with its payload")
    func replyResolvesThePull() async throws {
        let harness = Harness()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }

        let request = try harness.decodeRequest()
        #expect(request.terminalID == terminalID,
                "the frame must carry its own target, so the app can verify it")
        #expect(request.lines == 50)
        #expect(!request.wantStyledCapture)

        let sent = Self.payload(lines: ["from the viewer"])
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: harness.epoch)

        #expect(await answer.value == .answered(sent, styledCapture: nil))
        #expect(await pull.answeredPullsObserved == 1)
        #expect(await pull.timedOutPullsObserved == 0)
    }

    @Test("A styled capture asked for and answered rides the same reply")
    func styledCaptureRidesTheReply() async throws {
        let harness = Harness()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 0, retainedScrollbackLines: 5_000,
                wantStyledCapture: true)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }

        let request = try harness.decodeRequest()
        #expect(request.wantStyledCapture)
        #expect(request.lines == 0, "a modes-only reading asks for no lines")
        #expect(request.styledScrollbackLines == 5_000)

        let sent = Self.payload()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent,
                styledCapture: "red\u{1b}[0m\n"),
            epoch: harness.epoch)

        #expect(await answer.value == .answered(sent, styledCapture: "red\u{1b}[0m\n"))
    }

    /// A named refusal must end the wait *immediately*, not on the bound. The
    /// clock never advances in this test, so a puller that merely logged the
    /// refusal would hang out to the suite's bound rather than pass.
    @Test("A named refusal resolves the pull at once, without consuming the bound")
    func refusalResolvesImmediately() async throws {
        for reason in SidecarScreenReply.Unavailable.allCases {
            let harness = Harness()
            let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
            let terminalID = UUID()

            let answer = Task {
                await pull.pull(
                    terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                    wantStyledCapture: false)
            }
            try await waitFor("the screen request to reach the sidecar") {
                harness.frames.count == 1
            }
            let request = try harness.decodeRequest()

            pull.record(
                SidecarScreenReply(
                    requestID: request.requestID, terminalID: terminalID, unavailable: reason),
                epoch: harness.epoch)

            #expect(await answer.value == .refused(reason))
            #expect(await pull.answeredPullsObserved == 0,
                    "a refusal is not an answered pull; the soak counters must not conflate them")
        }
    }

    // MARK: - The bound, from both sides

    /// The upper half of the pin on the production bound: the puller is
    /// default-constructed and the clock advanced by exactly
    /// `HolderInputTiming.screenPullBound`, so a shipped bound *longer* than
    /// that constant leaves the pull unresolved and this test hangs out to the
    /// suite's `.clockDriven` bound instead of passing.
    @Test("A silent viewer times the pull out at the production bound")
    func silentViewerTimesOut() async throws {
        let harness = Harness()
        let clock = TestClock<Duration>()
        let pull = harness.makePull(clock: clock)

        let answer = Task {
            await pull.pull(
                terminalID: UUID(), lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }

        await clock.advanceWhenSuspended(by: HolderInputTiming.screenPullBound)

        #expect(await answer.value == .timedOut)
        #expect(await pull.timedOutPullsObserved == 1)
    }

    /// The other half, and the direction that is actually harmful: a bound
    /// **shorter** than the constant would put the stale-modes branch back in
    /// front of every send to an open tab, which is the branch the measured
    /// Enter loss came through.
    ///
    /// An absence, asserted positively: virtual time stops one instant short
    /// and the viewer answers there. A puller that had already given up would
    /// answer `.timedOut` and count the reply as late, so both readings
    /// discriminate.
    @Test("The pull's bound is not reached early")
    func boundIsNotReachedEarly() async throws {
        let harness = Harness()
        let clock = TestClock<Duration>()
        let pull = harness.makePull(clock: clock)
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        await clock.advanceWhenSuspended(
            by: HolderInputTiming.screenPullBound - .milliseconds(1))
        let sent = Self.payload()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: harness.epoch)

        #expect(await answer.value == .answered(sent, styledCapture: nil))
        #expect(await pull.lateRepliesObserved == 0,
                "the puller gave up before its bound, so the viewer's answer arrived late")
        #expect(await pull.timedOutPullsObserved == 0)
    }

    @Test("A reply arriving after the bound is late, and is not applied")
    func replyAfterTheBoundIsLate() async throws {
        let harness = Harness()
        let clock = TestClock<Duration>()
        let pull = harness.makePull(clock: clock)
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        await clock.advanceWhenSuspended(by: HolderInputTiming.screenPullBound)
        #expect(await answer.value == .timedOut)

        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: Self.payload()),
            epoch: harness.epoch)
        try await waitFor("the late reply to be accounted for") {
            await pull.lateRepliesObserved == 1
        }
        #expect(await pull.answeredPullsObserved == 0,
                "a late answer must never be counted as one the caller received")
    }

    // MARK: - Replies that must not be matched

    /// The property that keeps a stray answer from stealing a pull: a reply for
    /// an id nobody is waiting on resolves nothing, and leaves a concurrently
    /// pending request alone.
    @Test("A reply for an unknown request id is counted late and disturbs nothing")
    func unknownRequestIDDisturbsNothing() async throws {
        let harness = Harness()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        pull.record(
            SidecarScreenReply(
                requestID: UUID(), terminalID: terminalID, screen: Self.payload(lines: ["stray"])),
            epoch: harness.epoch)
        try await waitFor("the stray reply to be accounted for") {
            await pull.lateRepliesObserved == 1
        }

        // The real answer still lands, which is the half that proves the stray
        // did not consume the pending entry.
        let sent = Self.payload(lines: ["mine"])
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: harness.epoch)
        #expect(await answer.value == .answered(sent, styledCapture: nil))
    }

    /// A reply whose session disagrees with its request's is misaddressed, and
    /// **the pending entry stays pending** — otherwise a stray frame could take
    /// another session's pull with it.
    @Test("A misaddressed reply is dropped and leaves the request pending")
    func misaddressedReplyLeavesTheRequestPending() async throws {
        let harness = Harness()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: UUID(),
                screen: Self.payload(lines: ["someone else's screen"])),
            epoch: harness.epoch)
        try await waitFor("the misaddressed reply to be accounted for") {
            await pull.misaddressedRepliesObserved == 1
        }

        let sent = Self.payload(lines: ["mine"])
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: harness.epoch)
        #expect(await answer.value == .answered(sent, styledCapture: nil),
                "the misaddressed reply must not have consumed the pending entry")
        #expect(await pull.lateRepliesObserved == 0,
                "a misaddressed reply is its own fault, not a late one")
    }

    /// Correlating by id alone would let a reply that crossed a reconnect
    /// resolve a request sent on the connection before it. The epoch is what
    /// closes that, and it travels with the reply from the receive thread.
    @Test("A reply on a different connection epoch is dropped")
    func replyOnAStaleEpochIsDropped() async throws {
        let harness = Harness()
        harness.epoch = 4
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID,
                screen: Self.payload(lines: ["from the old connection"])),
            epoch: 5)
        try await waitFor("the stale-epoch reply to be accounted for") {
            await pull.lateRepliesObserved == 1
        }

        let sent = Self.payload(lines: ["same connection"])
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: 4)
        #expect(await answer.value == .answered(sent, styledCapture: nil))
    }

    // MARK: - The connection going away

    @Test("A lost connection fails every request outstanding on it")
    func lostConnectionFailsItsRequests() async throws {
        let harness = Harness()
        harness.epoch = 2
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())

        let answer = Task {
            await pull.pull(
                terminalID: UUID(), lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }

        pull.connectionLost(epoch: 2)

        guard case .undeliverable = await answer.value else {
            throw UnexpectedAnswer(expected: ".undeliverable", actual: await answer.value)
        }
    }

    /// The discriminating other half: a *later* epoch's loss must leave this
    /// request alone, or every reconnect would cancel the pulls made after it.
    @Test("A lost connection leaves another epoch's requests alone")
    func lostConnectionLeavesOtherEpochsAlone() async throws {
        let harness = Harness()
        harness.epoch = 2
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        pull.connectionLost(epoch: 1)

        let sent = Self.payload()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: 2)
        #expect(await answer.value == .answered(sent, styledCapture: nil))
    }

    /// The window `failEveryRequest` cannot see: a connection that ended
    /// before the send returned its epoch leaves a pending entry with no stamp
    /// for the sweep to match, so it would otherwise sit out the whole bound
    /// before answering `.timedOut` — a correct answer arrived at slowly.
    /// `lastEndedEpoch` closes it, and epochs being monotonic is what makes one
    /// `UInt64` enough.
    ///
    /// Driven deterministically rather than by racing the stamp: the loss is
    /// recorded first, and the send then answers with that same ended epoch.
    /// The clock never advances, so a puller without the guard hangs out to the
    /// suite's bound instead of passing.
    @Test("a request sent on an already-ended connection answers at once")
    func sendOnAnEndedEpochAnswersAtOnce() async throws {
        let harness = Harness()
        harness.epoch = 5
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())

        pull.connectionLost(epoch: 5)
        // A real gate, not a scheduling guess: `connectionLost` is
        // fire-and-forget, so the ended-epoch mark lands on its own turn and a
        // pull issued before it would see nothing.
        try await waitFor("the connection loss to be recorded") {
            await pull.connectionsLostObserved == 1
        }

        let answer = await pull.pull(
            terminalID: UUID(), lines: 50, retainedScrollbackLines: 5_000,
            wantStyledCapture: false)

        guard case .undeliverable = answer else {
            throw UnexpectedAnswer(expected: ".undeliverable", actual: answer)
        }
        #expect(await pull.timedOutPullsObserved == 0,
                "a request on a dead connection must not spend the bound")
    }

    /// The discriminating other half: a loss on an *earlier* epoch must not
    /// refuse a request sent on a later one, or every reconnect would poison
    /// the pulls made after it.
    @Test("a request sent on a newer connection survives an older epoch's loss")
    func sendOnANewerEpochSurvivesAnOlderLoss() async throws {
        let harness = Harness()
        harness.epoch = 6
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        pull.connectionLost(epoch: 5)
        try await waitFor("the older connection's loss to be recorded") {
            await pull.connectionsLostObserved == 1
        }

        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 50, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }
        let request = try harness.decodeRequest()

        let sent = Self.payload()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: 6)
        #expect(await answer.value == .answered(sent, styledCapture: nil))
    }

    /// No sidecar at all is an immediate answer, not a wait. The clock never
    /// advances, so a puller that fell through to the bound would hang.
    @Test("A sidecar that cannot carry the frame answers at once")
    func undeliverableFrameAnswersAtOnce() async throws {
        let harness = Harness()
        harness.sendFrameError = SidecarGone()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())

        let answer = await pull.pull(
            terminalID: UUID(), lines: 50, retainedScrollbackLines: 5_000,
            wantStyledCapture: false)

        guard case .undeliverable = answer else {
            throw UnexpectedAnswer(expected: ".undeliverable", actual: answer)
        }
        #expect(await pull.timedOutPullsObserved == 0,
                "an undeliverable request must not spend the bound")
    }

    // MARK: - Overlap

    /// Two pulls for one session are independent by ruling: each is answered
    /// from the app's live terminal at the moment it is handled, because
    /// joining them would hand the second caller an age measured for the
    /// first's observation.
    @Test("Two overlapping pulls for one session are both answered, each with its own payload")
    func overlappingPullsAreIndependent() async throws {
        let harness = Harness()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())
        let terminalID = UUID()

        let first = Task {
            await pull.pull(
                terminalID: terminalID, lines: 10, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the first request to reach the sidecar") { harness.frames.count == 1 }
        let second = Task {
            await pull.pull(
                terminalID: terminalID, lines: 20, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the second request to reach the sidecar") { harness.frames.count == 2 }

        let firstRequest = try harness.decodeRequest(at: 0)
        let secondRequest = try harness.decodeRequest(at: 1)
        #expect(firstRequest.requestID != secondRequest.requestID,
                "each pull must mint its own correlation id")

        let secondPayload = Self.payload(lines: ["second"], ageMilliseconds: 2)
        let firstPayload = Self.payload(lines: ["first"], ageMilliseconds: 99)
        // Answered out of order on purpose: correlation is by id, not arrival.
        pull.record(
            SidecarScreenReply(
                requestID: secondRequest.requestID, terminalID: terminalID,
                screen: secondPayload),
            epoch: harness.epoch)
        pull.record(
            SidecarScreenReply(
                requestID: firstRequest.requestID, terminalID: terminalID, screen: firstPayload),
            epoch: harness.epoch)

        #expect(await first.value == .answered(firstPayload, styledCapture: nil))
        #expect(await second.value == .answered(secondPayload, styledCapture: nil))
        #expect(await pull.answeredPullsObserved == 2)
        #expect(await pull.lateRepliesObserved == 0)
    }

    // MARK: - The depth cap, through the puller

    /// The cap is `SidecarScreenRequest`'s invariant, and this is the puller
    /// honouring it rather than re-deriving it: a reader asking for more than
    /// the daemon retains gets the daemon's depth, so the contract does not
    /// vary by who is looking.
    @Test("A requested depth past the daemon's retained depth goes out clamped")
    func requestedDepthIsClampedOnTheWire() async throws {
        let harness = Harness()
        let pull = harness.makePull(bound: .seconds(30), clock: TestClock())

        let terminalID = UUID()
        let answer = Task {
            await pull.pull(
                terminalID: terminalID, lines: 100_000, retainedScrollbackLines: 5_000,
                wantStyledCapture: false)
        }
        try await waitFor("the screen request to reach the sidecar") { harness.frames.count == 1 }

        let request = try harness.decodeRequest()
        #expect(request.lines == 5_000)

        // Answered rather than abandoned: a pull left pending at the end of a
        // test leaks its continuation, and a leaked continuation is a warning
        // in somebody else's test output.
        let sent = Self.payload()
        pull.record(
            SidecarScreenReply(
                requestID: request.requestID, terminalID: terminalID, screen: sent),
            epoch: harness.epoch)
        #expect(await answer.value == .answered(sent, styledCapture: nil))
    }
}
