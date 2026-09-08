import Clocks
import Foundation
import Testing
@testable import TBDApp
@testable import TBDShared
import TestSupport

/// `ProvisionalRowComposer` — the step that decides whether the model-proxy
/// stream's in-flight message is on screen, and where in the list it sits.
///
/// Pure, so every test here is a plain value assertion: the composer has no
/// files, no clock and no `AppState`. The wiring that feeds it is exercised
/// separately in `ProvisionalRowPublishTests` below.
@Suite("ProvisionalRowComposer")
struct ProvisionalRowComposerTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    /// Two settled JSONL rows, so "appended last" is a real claim about order
    /// rather than a statement about a one-element array.
    private static let settled: [TranscriptItem] = [
        .userPrompt(id: "u1", text: "explain the fold", timestamp: t0),
        .assistantText(id: "msg_old", text: "an older answer", timestamp: t0),
    ]

    private static func streaming(
        _ text: String, id: String = "msg_a", lastLineAt: Date = t0
    ) -> ProvisionalMessage {
        ProvisionalMessage(messageID: id, text: text, phase: .streaming, lastLineAt: lastLineAt)
    }

    /// Nothing is confirmed. The default for tests that are about some other
    /// retire rule, so a stray confirmation cannot make them pass vacuously.
    private static let nothingConfirmed: @Sendable (String) -> Bool = { _ in false }

    /// The text of an `.assistantText` row, read straight off the case so this
    /// suite stays free of the `@MainActor` rendering helpers.
    private static func assistantText(_ item: TranscriptItem?) -> String? {
        guard let item, case .assistantText(_, let text, _, _) = item else { return nil }
        return text
    }

    private static func compose(
        items: [TranscriptItem] = settled,
        provisional: ProvisionalMessage?,
        confirmed: @escaping (String) -> Bool = nothingConfirmed,
        now: Date = t0,
        streamingEnabled: Bool = true
    ) -> [TranscriptItem] {
        ProvisionalRowComposer.compose(
            items: items, provisional: provisional, confirmed: confirmed,
            now: now, streamingEnabled: streamingEnabled)
    }

    // MARK: - Appearing and growing

    @Test("a streaming message appears as the last row, with the stream id prefix")
    func streamingMessageAppears() {
        let items = Self.compose(provisional: Self.streaming("Hello"))

        #expect(items.count == Self.settled.count + 1)
        #expect(Array(items.dropLast()) == Self.settled,
                "the settled transcript must be passed through untouched")
        guard let last = items.last,
              case .assistantText(let id, let text, let timestamp, let usage) = last else {
            Issue.record("expected a trailing assistantText row, got \(String(describing: items.last))")
            return
        }
        #expect(id == "stream:msg_a")
        #expect(id.hasPrefix(ProvisionalRowComposer.idPrefix))
        #expect(text == "Hello")
        #expect(timestamp == nil, "the row carries no timestamp — the JSONL has not stamped it yet")
        #expect(usage == nil)
    }

    /// The identity has to hold still while the text grows, or the table
    /// rebuilds instead of re-rendering its last row.
    @Test("a growing message keeps one row identity and updates its text")
    func growingMessageKeepsItsIdentity() {
        let first = Self.compose(provisional: Self.streaming("Hel"))
        let second = Self.compose(provisional: Self.streaming("Hello, world"))

        #expect(first.count == second.count)
        #expect(first.last?.id == second.last?.id)
        #expect(Self.assistantText(second.last) == "Hello, world")
    }

    /// The empty-text case is deliberate, not an oversight: `StreamFileReader`
    /// reports a message that has started and said nothing so a reader can see
    /// that a turn has begun. The row is a bare cursor until the first delta.
    @Test("a started message with no text yet still gets a row")
    func startedButSilentStillGetsARow() {
        let items = Self.compose(provisional: Self.streaming(""))

        #expect(items.last?.id == "stream:msg_a")
        #expect(Self.assistantText(items.last) == "")
    }

    // MARK: - Retiring

    /// The ordinary end of a turn: the JSONL catches up, the real row lands,
    /// and the provisional one must be gone in the same publish — not one row
    /// later, or the answer renders twice.
    @Test("a confirmed message is replaced by its JSONL row, not shown twice")
    func confirmedMessageIsReplaced() {
        let landed = Self.settled + [
            .assistantText(id: "msg_a", text: "Hello, world", timestamp: Self.t0),
        ]

        let items = Self.compose(
            items: landed,
            provisional: Self.streaming("Hello, world"),
            confirmed: { $0 == "msg_a" })

        #expect(items == landed, "the composer must add nothing once the id is confirmed")
        #expect(!items.contains { ProvisionalRowComposer.isProvisional(itemID: $0.id) },
                "no provisional row survives confirmation")
        #expect(items.contains { $0.id == "msg_a" },
                "and the settled row it was standing in for is present")
    }

    @Test("an aborted message is retired")
    func abortedMessageIsRetired() {
        let items = Self.compose(provisional: ProvisionalMessage(
            messageID: "msg_a", text: "half an ans",
            phase: .aborted(reason: "upstream closed"), lastLineAt: Self.t0))

        #expect(items == Self.settled)
    }

    @Test("a completed but unconfirmed message is retired after the deadline")
    func completedMessageRetiresAfterTheDeadline() {
        let completed = ProvisionalMessage(
            messageID: "msg_a", text: "Hello, world", phase: .complete(at: Self.t0),
            lastLineAt: Self.t0)

        let atFiftyNine = Self.compose(
            provisional: completed, now: Self.t0.addingTimeInterval(59))
        #expect(atFiftyNine.last?.id == "stream:msg_a",
                "59 s after the stop the row is still the best thing to show")

        let atSixtyOne = Self.compose(
            provisional: completed, now: Self.t0.addingTimeInterval(61))
        #expect(atSixtyOne == Self.settled,
                "61 s after the stop nothing is ever going to confirm it")

        // The boundary belongs to the retired side. A row kept at exactly the
        // deadline would come with a zero-length alarm that fires the instant
        // it is armed, re-publishes, composes the same row and arms zero
        // again — a spin whenever `now` is frozen or steps backwards.
        let atExactlySixty = Self.compose(
            provisional: completed, now: Self.t0.addingTimeInterval(60))
        #expect(atExactlySixty == Self.settled,
                "the boundary tick retires the row rather than composing a zero-delay one")
        #expect(ProvisionalRowComposer.retireDelay(
            for: completed, now: Self.t0.addingTimeInterval(60)) == nil,
                "and asks for no alarm, so the two rules agree at the boundary")
    }

    /// The deadline measures from the completion instant, so a row that
    /// completed long before this publish is already gone on its first render.
    @Test("the deadline is measured from the completion instant, not from first sight")
    func deadlineIsMeasuredFromCompletion() {
        let longDone = ProvisionalMessage(
            messageID: "msg_a", text: "Hello",
            phase: .complete(at: Self.t0.addingTimeInterval(-3600)),
            lastLineAt: Self.t0.addingTimeInterval(-3600))

        #expect(Self.compose(provisional: longDone) == Self.settled)
    }

    @Test("nothing tailed yet means nothing appended")
    func noProvisionalMeansNoRow() {
        #expect(Self.compose(provisional: nil) == Self.settled)
    }

    // MARK: - The flag

    /// The off branch of the feature's gate. Everything else about the input is
    /// exactly the appearing case, so this can only pass because the flag was
    /// read.
    @Test("streaming off never produces a row")
    func streamingOffProducesNoRow() {
        #expect(Self.compose(provisional: Self.streaming("Hello"), streamingEnabled: false)
                == Self.settled)
        #expect(Self.compose(provisional: Self.streaming("Hello"), streamingEnabled: true).count
                == Self.settled.count + 1,
                "and the same input with the flag on does produce one")
    }

    // MARK: - Order

    /// The pane composes in three layers — JSONL, then the daemon's pending
    /// `AskUserQuestion` captures, then this. A question captured by the
    /// `PreToolUse` hook was captured *before* the answer now streaming, so the
    /// provisional row belongs after it.
    @Test("the row sorts after a pending AskUserQuestion synthetic item")
    func rowSortsAfterAPendingQuestion() {
        let merged = AskUserQuestionMerger.merge(
            jsonlItems: Self.settled,
            pending: [PendingAskUserQuestion(
                toolUseID: "toolu_1",
                inputJSON: #"{"questions":[]}"#,
                timestamp: Self.t0)])
        #expect(merged.items.last?.id == "toolu_1", "fixture check: the merger appends the capture")

        let items = Self.compose(items: merged.items, provisional: Self.streaming("Hello"))

        #expect(items.count == merged.items.count + 1)
        #expect(items.last?.id == "stream:msg_a")
        #expect(items[items.count - 2].id == "toolu_1",
                "the synthetic question keeps its place directly above the provisional row")
    }

    // MARK: - Session History

    /// Session History reads the same `AppState.sessionTranscripts` store the
    /// live pane publishes into, and the session it is showing can be the one a
    /// live pane is streaming. `settledOnly` is what keeps the unconfirmed row
    /// out of a record of what the session was.
    @Test("settledOnly drops the provisional row and keeps everything else in order")
    func settledOnlyDropsTheProvisionalRow() {
        let withRow = Self.compose(provisional: Self.streaming("Hello"))
        #expect(withRow.count == Self.settled.count + 1, "fixture check: a row is present")

        #expect(ProvisionalRowComposer.settledOnly(withRow) == Self.settled)
        #expect(ProvisionalRowComposer.settledOnly(Self.settled) == Self.settled,
                "a transcript with no provisional row passes through unchanged")
    }

    // MARK: - The declared constants

    @Test("the retire window is 60 seconds and the prefix is stream:")
    func constantsAreWhatTheDesignDeclares() {
        #expect(ProvisionalRowComposer.unconfirmedRetireAfter == .seconds(60))
        #expect(ProvisionalRowComposer.silentStreamRetireAfter == .seconds(600),
                "the silent-stream window is the proxy's own drain cap")
        #expect(ProvisionalRowComposer.idPrefix == "stream:")
        #expect(ProvisionalRowComposer.isProvisional(itemID: "stream:msg_a"))
        #expect(!ProvisionalRowComposer.isProvisional(itemID: "msg_a"))
    }

    // MARK: - The alarm's delay

    @Test("every phase but aborted asks for a retire alarm, each on its own rule")
    func eachPhaseSchedulesItsOwnAlarm() {
        let completed = ProvisionalMessage(
            messageID: "msg_a", text: "done", phase: .complete(at: Self.t0),
            lastLineAt: Self.t0)

        #expect(ProvisionalRowComposer.retireDelay(
            for: ProvisionalMessage(
                messageID: "msg_a", text: "half",
                phase: .aborted(reason: "x"), lastLineAt: Self.t0),
            now: Self.t0) == nil,
                "an aborted row was never composed, so there is nothing to wake up for")

        #expect(ProvisionalRowComposer.retireDelay(for: completed, now: Self.t0) == .seconds(60))
        #expect(ProvisionalRowComposer.retireDelay(
            for: completed, now: Self.t0.addingTimeInterval(45)) == .seconds(15))
        #expect(ProvisionalRowComposer.retireDelay(
            for: completed, now: Self.t0.addingTimeInterval(600)) == nil,
                "a deadline already past asks for no alarm at all, never a zero-length one")

        // The silent-stream rule. Measured from the last line, ten minutes
        // wide, and restarted by a line rather than by the poll that noticed
        // it: the second reading below is the same message a minute later
        // whose line arrived a minute later too.
        #expect(ProvisionalRowComposer.retireDelay(
            for: Self.streaming("Hel"), now: Self.t0) == .seconds(600))
        #expect(ProvisionalRowComposer.retireDelay(
            for: Self.streaming("Hel"), now: Self.t0.addingTimeInterval(540)) == .seconds(60))
        #expect(ProvisionalRowComposer.retireDelay(
            for: Self.streaming("Hello", lastLineAt: Self.t0.addingTimeInterval(60)),
            now: Self.t0.addingTimeInterval(60)) == .seconds(600),
                "a new line restarts the window rather than shortening it")
        #expect(ProvisionalRowComposer.retireDelay(
            for: Self.streaming("Hel"), now: Self.t0.addingTimeInterval(600)) == nil)
    }

    // MARK: - The silent-stream rule

    /// The case the 60-second rule cannot reach: a proxy killed mid-turn writes
    /// neither `stop` nor `aborted`, so the fold reports `.streaming` forever
    /// and the JSONL — which never saw that request finish either — will not
    /// confirm it. Without a deadline of its own the row is on screen for good.
    ///
    /// What discriminates: with a deadline only for `.complete`, every
    /// assertion below that expects the row *gone* fails, because a streaming
    /// row was composed unconditionally.
    @Test("a streaming message with no terminal line is retired at the drain cap")
    func silentStreamingMessageRetiresAtTheDrainCap() {
        let quiet = Self.streaming("half an answer")

        #expect(Self.compose(provisional: quiet, now: Self.t0.addingTimeInterval(599)).last?.id
                == "stream:msg_a",
                "a stream can be quiet for minutes while a tool-input block streams")
        #expect(Self.compose(provisional: quiet, now: Self.t0.addingTimeInterval(600))
                == Self.settled,
                "the boundary tick retires, the same way the completion rule does")
        #expect(Self.compose(provisional: quiet, now: Self.t0.addingTimeInterval(601))
                == Self.settled)
        #expect(ProvisionalRowComposer.retireDelay(
            for: quiet, now: Self.t0.addingTimeInterval(600)) == nil,
                "and asks for no alarm, so the two rules agree at the boundary")
    }

    /// The window is restarted by each line, not by the message: the same
    /// message nine minutes in, having just produced a delta, is owed a fresh
    /// ten minutes rather than the minute that was left.
    @Test("a new line restarts the silent-stream window")
    func aNewLineRestartsTheSilentStreamWindow() {
        let nineMinutesIn = Self.t0.addingTimeInterval(540)
        let stale = Self.streaming("half an answer")
        let refreshed = Self.streaming("half an answer, and more", lastLineAt: nineMinutesIn)

        #expect(Self.compose(provisional: stale, now: nineMinutesIn.addingTimeInterval(61))
                == Self.settled,
                "without a new line the original window runs out")
        #expect(Self.compose(provisional: refreshed, now: nineMinutesIn.addingTimeInterval(61))
                .last?.id == "stream:msg_a",
                "with one, the row is still the best thing to show")
        #expect(ProvisionalRowComposer.retireDeadline(for: refreshed)
                == nineMinutesIn.addingTimeInterval(600))
    }
}

/// The trailing cursor: how a reader tells the provisional row from a settled
/// one. Two hops — the presentation marks the node, the bubble draws the mark —
/// and both are asserted, because either alone renders nothing.
@MainActor
@Suite("ProvisionalRowPresentation")
struct ProvisionalRowPresentationTests {

    @Test("a stream: item builds a node marked provisional and a plain one does not")
    func streamPrefixMarksTheNode() {
        let presentation = TranscriptPresentation.build(
            items: [
                .assistantText(id: "msg_old", text: "settled", timestamp: nil),
                .assistantText(id: "stream:msg_a", text: "arriving", timestamp: nil),
            ],
            memo: TranscriptPresentationMemo())

        #expect(presentation.nodes.count == 2)
        #expect(presentation.nodes[0].isProvisional == false)
        #expect(presentation.nodes[1].isProvisional)
    }

    /// Two rows with identical text but different provisional-ness must not
    /// collide in the composed-blocks cache, which is keyed on
    /// `(id, contentVersion)`.
    @Test("the provisional mark is part of a node's content version")
    func provisionalMarkIsPartOfTheContentVersion() {
        let kind = TranscriptRenderNode.Kind.chatBubble(
            .assistantText(id: "x", text: "same text", timestamp: nil))
        let plain = TranscriptRenderNode(id: "x", kind: kind, badgeUsage: nil)
        let marked = TranscriptRenderNode(id: "x", kind: kind, badgeUsage: nil, isProvisional: true)

        #expect(plain.contentVersion != marked.contentVersion)
        #expect(plain != marked)
    }

    @Test("the bubble draws a trailing cursor only for a provisional node")
    func bubbleDrawsTheCursorOnlyWhenProvisional() {
        let item = TranscriptItem.assistantText(id: "stream:msg_a", text: "Hello", timestamp: nil)

        let plain = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil)
        let marked = TranscriptBubbleGeometry.composedBlocks(
            for: item, badgeUsage: nil, linkResolver: nil, isProvisional: true)

        #expect(Self.prose(plain) == "Hello")
        #expect(Self.prose(marked) == "Hello" + TranscriptBubbleGeometry.provisionalCursor)
    }

    private static func prose(_ blocks: [MessageBlock]) -> String {
        blocks.compactMap { block -> String? in
            guard case .prose(let string) = block else { return nil }
            return string.string
        }.joined()
    }
}

/// A `Date` a test can move, for the `now` seam `TableTranscriptPaneView.publish`
/// takes. `TestClock` moves virtual *durations*; this moves the wall clock the
/// retire comparison is made against, and the two have to be moved together —
/// the alarm decides *when* to re-publish, the composer decides what the
/// re-publish shows.
///
/// File scope, and `@unchecked Sendable` over a lock, because the `now` closure
/// crosses into the alarm's detached task.
private final class MovableDate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date {
        lock.lock(); defer { lock.unlock() }
        return value
    }
    func advance(by seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        value = value.addingTimeInterval(seconds)
    }
}

/// The publish step in `TableTranscriptPaneView` — the seam where the composer,
/// the source and the retire alarm meet.
///
/// Driven directly rather than through a SwiftUI view tree, the same shape as
/// `TaskKey.resolve`: `publish` is where the four inputs are actually gathered,
/// and a view host would add nothing but flakiness.
///
/// The suite is deliberately NOT `@MainActor`. `publish` is `nonisolated` — the
/// isolation it actually runs under in the app, since the scheduler's on-change
/// closure is `@Sendable` — and every read of `AppState` here goes through an
/// explicit `MainActor.run` helper, which is also what keeps the bounded-poll
/// conditions free of main-actor captures.
@Suite("ProvisionalRowPublish", .clockDriven, .serialized)
struct ProvisionalRowPublishTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    @MainActor
    private static func makeState(streaming: Bool, suite: String) -> AppState {
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, transcriptStreamingEnabled: streaming)
        return state
    }

    private static func removeSuite(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private static func publishedIDs(
        _ state: AppState, session: String = "s1"
    ) async -> [String] {
        await MainActor.run { (state.sessionTranscripts[session] ?? []).map(\.id) }
    }

    /// A second session with an ordinary transcript and no stream file at all —
    /// the "plain transcript news" case whose publish composes no provisional
    /// row and therefore takes `publish`'s disarm branch.
    private static let userLine = #"{"type":"user","uuid":"b1","timestamp":"2026-08-26T10:00:00.000Z","message":{"role":"user","content":"unrelated"}}"#

    private static func addPlainTranscript(
        to source: TranscriptSource, sessionID: String
    ) async throws {
        let dir = fencedScratchRoot(prefix: "tbdprov")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/transcript.jsonl"
        try (Self.userLine + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await source.refresh(sessionID: sessionID, path: path)?.appended.count == 1)
    }

    /// Writes one complete-and-unconfirmed message into a real stream file and
    /// has the source tail it. No transcript file at all, so
    /// `hasAssistantMessage` is false — which is exactly the unconfirmed case.
    private static func sourceWithCompletedMessage(now: Date) async throws -> TranscriptSource {
        let dir = fencedScratchRoot(prefix: "tbdprov")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/stream.jsonl"
        let lines = try [
            ModelProxyStreamLine.start(message: "msg_a", at: now),
            .text(message: "msg_a", index: 0, text: "Hello, world"),
            .stop(message: "msg_a"),
        ].map { try $0.encodedLine() + "\n" }.joined()
        try lines.write(toFile: path, atomically: true, encoding: .utf8)

        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: now))
        return source
    }

    /// The finding the alarm exists for: once a message stops, the stream file
    /// goes quiet, so no poll will ever report news for it again and nothing
    /// else would ever take the row down.
    @Test("a completed row is withdrawn by the alarm, 60 s later and not before")
    func theAlarmWithdrawsACompletedRow() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let date = MovableDate(Self.t0)
        let source = try await Self.sourceWithCompletedMessage(now: Self.t0)
        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)

        let published = await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { date.now })
        #expect(published.last?.id == "stream:msg_a")
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"])
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a", "the completed row armed the alarm")

        // 59 s of virtual time. The alarm is armed for 60, so nothing fires and
        // the row is still on screen.
        date.advance(by: 59)
        await clock.advanceWhenSuspended(by: .seconds(59))
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"],
                "the row must survive right up to the deadline")

        // Past it. The alarm's re-publish re-composes, and the composer's own
        // 60-second rule is what drops the row.
        date.advance(by: 2)
        await clock.advance(by: .seconds(2))
        let withdrawn = await pollUntilTrue(timeout: .seconds(10)) {
            await Self.publishedIDs(state).isEmpty
        }
        #expect(withdrawn == .satisfied, "the alarm's re-publish must withdraw the row")
        #expect(await timer.armedMessage(sessionID: "s1") == nil, "and it does not re-arm itself")
    }

    /// The scheduler holds **one** on-change closure for the whole app, so every
    /// registered session's publish runs through whichever pane's timer was
    /// installed last — and TBD keeps up to eight panes alive at once. Session
    /// A's completed row arms a 60-second alarm; session B then gets ordinary
    /// transcript news inside that window, which composes no provisional row
    /// and so takes `publish`'s disarm branch. With one alarm slot for the
    /// whole app, B's publish cancelled A's alarm and A's row never retired.
    @Test("a publish for another session leaves this session's retire alarm alone")
    func anotherSessionsPublishDoesNotDisarmThisOne() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let date = MovableDate(Self.t0)
        let source = try await Self.sourceWithCompletedMessage(now: Self.t0)
        try await Self.addPlainTranscript(to: source, sessionID: "s2")
        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)

        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { date.now })
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a")

        // Half-way through A's window, B publishes. Same `publish`, same timer
        // instance, no provisional of its own.
        date.advance(by: 30)
        await clock.advanceWhenSuspended(by: .seconds(30))
        await TableTranscriptPaneView.publish(
            sessionID: "s2", state: state, source: source,
            retireTimer: timer, now: { date.now })

        let bIDs = await Self.publishedIDs(state, session: "s2")
        #expect(bIDs.isEmpty == false, "B's publish really did run and write B's transcript")
        #expect(bIDs.allSatisfy { !$0.hasPrefix(ProvisionalRowComposer.idPrefix) },
                "and it composed no provisional row of its own")
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a",
                "B's publish must not disarm A's alarm")
        #expect(await timer.armedMessage(sessionID: "s2") == nil,
                "nor arm one of its own")
        #expect(await timer.armedSessionCount == 1, "exactly A's alarm, and nothing else")
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"])

        // A's alarm still fires on A's original schedule, 60 s from when it was
        // armed: 29 s more is inside the window, 2 s past it is not.
        date.advance(by: 29)
        await clock.advanceWhenSuspended(by: .seconds(29))
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"],
                "still inside A's window")

        date.advance(by: 2)
        await clock.advance(by: .seconds(2))
        let withdrawn = await pollUntilTrue(timeout: .seconds(10)) {
            await Self.publishedIDs(state).isEmpty
        }
        #expect(withdrawn == .satisfied, "A's row must retire on A's own deadline")
        #expect(await Self.publishedIDs(state, session: "s2").isEmpty == false,
                "and B's transcript is untouched by it")
    }

    /// A stream file with one text line and no terminal line — a turn in
    /// flight, or a proxy that died before writing its `stop`. The two look
    /// identical from here, which is the whole reason the silent-stream rule
    /// exists.
    ///
    /// What discriminates: before the rule, a streaming row armed nothing, so
    /// the alarm assertion below read nil and the row stayed on screen for
    /// good.
    @Test("a streaming row arms the silent-stream alarm and is withdrawn by it")
    func aStreamingRowIsWithdrawnByTheSilentStreamAlarm() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let path = try Self.streamFileWithOneTextLine()
        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let date = MovableDate(Self.t0)

        let published = await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { date.now })
        #expect(published.last?.id == "stream:msg_a")
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a",
                "a stream that may never end must still be on a deadline")

        // Nine minutes of silence is not enough: a healthy turn streaming a
        // large tool-input block emits no text deltas for exactly this long.
        date.advance(by: 540)
        await clock.advanceWhenSuspended(by: .seconds(540))
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"],
                "the row must survive right up to the drain cap")

        date.advance(by: 61)
        await clock.advance(by: .seconds(61))
        let withdrawn = await pollUntilTrue(timeout: .seconds(10)) {
            await Self.publishedIDs(state).isEmpty
        }
        #expect(withdrawn == .satisfied, "the alarm's re-publish must withdraw the row")
        #expect(await timer.armedMessage(sessionID: "s1") == nil, "and it does not re-arm itself")
    }

    /// The window belongs to the last line, so a delta arriving inside it buys
    /// the row another full ten minutes — and the pending alarm has to be
    /// replaced, not left alone, even though the message id has not changed.
    ///
    /// What discriminates: with the alarm keyed by message id alone, the
    /// re-publish after the append is a no-op, the original alarm fires at its
    /// original deadline, and the row is withdrawn while its stream is still
    /// producing.
    @Test("a line arriving inside the window re-arms the silent-stream alarm")
    func aNewLineReArmsTheSilentStreamAlarm() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let path = try Self.streamFileWithOneTextLine()
        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))

        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let date = MovableDate(Self.t0)

        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { date.now })
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a")

        // Nine minutes in, one more delta lands and the source re-reads it.
        date.advance(by: 540)
        await clock.advanceWhenSuspended(by: .seconds(540))
        let more = try ModelProxyStreamLine
            .text(message: "msg_a", index: 0, text: "lo").encodedLine()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((more + "\n").utf8))
        try handle.close()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: date.now))
        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { date.now })

        // Past the *original* deadline. The row is still there, because the
        // append moved it.
        date.advance(by: 61)
        await clock.advanceWhenSuspended(by: .seconds(61))
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"],
                "the original window expired, but the line that arrived replaced it")
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a",
                "and the replacement alarm is still pending")
    }

    /// What a mounting pane does to get a retire timer, in one place: it takes
    /// the scheduler's. `appSideLoop` has exactly this line, and the tests
    /// below drive it once per pane so "a second pane mounted" is the gesture
    /// production makes rather than a claim about it.
    private static func timerForMountingPane(
        _ scheduler: TranscriptPollScheduler
    ) -> ProvisionalRetireTimer {
        scheduler.provisionalRetire
    }

    /// The handoff production actually performs. Panes mount, remount and are
    /// restarted wholesale by a Settings flip, and every one of them publishes
    /// through the scheduler's single `onChange` slot.
    ///
    /// What discriminates: while a pane built its own `ProvisionalRetireTimer`
    /// per mount, the two handles below were different objects, the row's
    /// re-arm landed in the one the *second* pane installed, and the first
    /// pane's teardown reached only its own. The orphan then outlived
    /// `TranscriptSource.forget` and republished an empty transcript for a
    /// session nothing was watching — which `AppState+History.selectSession`
    /// caches as an answer, so Session History for it read empty for good.
    @Test("a pane that tore down leaves no orphan alarm for a later mount to fire")
    func aTornDownPaneLeavesNoOrphanAlarm() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let path = try Self.streamFileWithOneTextLine()
        let source = TranscriptSource()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: Self.t0))
        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let date = MovableDate(Self.t0)
        let scheduler = TranscriptPollScheduler(source: source, clock: clock)

        // Pane A mounts on the streaming session and publishes: a row with a
        // ten-minute silent-stream deadline, and an alarm to match.
        let paneA = TranscriptPaneToken()
        let timerA = Self.timerForMountingPane(scheduler)
        await scheduler.register(
            sessionID: "s1", path: path, streamPath: path,
            tier: .background, token: paneA)
        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timerA, now: { date.now })
        #expect(await timerA.armedMessage(sessionID: "s1") == "msg_a")

        // Pane B mounts — a second pane, or the same pane restarted by a
        // Settings flip. It takes a timer the way every pane does.
        let timerB = Self.timerForMountingPane(scheduler)
        #expect(timerA === timerB, "a pane mounting must not mint a second timer")

        // Nine minutes in, a line arrives for A's row and it re-arms — through
        // the handle the pane that mounted last is holding.
        date.advance(by: 540)
        let more = try ModelProxyStreamLine
            .text(message: "msg_a", index: 0, text: "lo").encodedLine()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((more + "\n").utf8))
        try handle.close()
        #expect(await source.refreshStream(sessionID: "s1", path: path, now: date.now))
        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timerB, now: { date.now })
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"])

        // A tears down: the hold goes, the alarm goes with it, and the source
        // forgets the session — the real teardown sequence, in its real order.
        await scheduler.deregister(sessionID: "s1", token: paneA)
        await scheduler.disarmProvisional(sessionID: "s1")
        #expect(await timerB.armedSessionCount == 0,
                "the re-armed alarm was reachable from the departing pane's teardown")

        // Past every deadline either arm could have set.
        await clock.advance(by: .seconds(1_200))
        let published = await pollUntilTrue(timeout: .seconds(1)) {
            await Self.publishedIDs(state) != ["stream:msg_a"]
        }
        #expect(published == .timedOut,
                "nothing may publish for a session that has been forgotten")
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"])
    }

    /// Two panes, two sessions, one timer — the arrangement the app is in
    /// whenever more than one transcript is open. Each session's row must
    /// retire on its own rule and its own instant, and neither may take the
    /// other down on the way.
    ///
    /// The rules are deliberately different: A completed and unconfirmed (60 s
    /// from its stop), B streaming and quiet (600 s from its last line). A
    /// timer that kept one alarm for the whole app, or one deadline for the
    /// whole table, fails between the two advances below.
    @Test("two sessions arm and retire independently through the one timer")
    func twoSessionsRetireIndependently() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let source = try await Self.sourceWithCompletedMessage(now: Self.t0)
        let streamingPath = try Self.streamFileWithOneTextLine()
        #expect(await source.refreshStream(sessionID: "s2", path: streamingPath, now: Self.t0))
        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let date = MovableDate(Self.t0)
        let scheduler = TranscriptPollScheduler(source: source, clock: clock)
        let timer = Self.timerForMountingPane(scheduler)

        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { date.now })
        // A's alarm is the only sleeper on this clock, so waiting for one
        // proves *it* is armed before any virtual time moves. B's may register
        // a moment later, which is why the advance that fires it is generous
        // rather than exact; A's is not, because "A retires on its own minute"
        // is the claim being made.
        await clock.waitForSuspension()
        await TableTranscriptPaneView.publish(
            sessionID: "s2", state: state, source: source,
            retireTimer: timer, now: { date.now })
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"])
        #expect(await Self.publishedIDs(state, session: "s2") == ["stream:msg_a"])
        #expect(await timer.armedSessionCount == 2, "one timer, two live alarms")

        // A's minute is up; B's ten are not.
        date.advance(by: 61)
        await clock.advance(by: .seconds(61))
        let aWithdrawn = await pollUntilTrue(timeout: .seconds(10)) {
            await Self.publishedIDs(state).isEmpty
        }
        #expect(aWithdrawn == .satisfied, "A retires on the unconfirmed rule")
        #expect(await Self.publishedIDs(state, session: "s2") == ["stream:msg_a"],
                "and B's row is untouched by it")
        #expect(await timer.armedMessage(sessionID: "s2") == "msg_a",
                "B's alarm is still pending on its own, longer window")

        // And B's, on its own deadline rather than A's.
        date.advance(by: 540)
        await clock.advance(by: .seconds(700))
        let bWithdrawn = await pollUntilTrue(timeout: .seconds(10)) {
            await Self.publishedIDs(state, session: "s2").isEmpty
        }
        #expect(bWithdrawn == .satisfied, "B retires on the silent-stream rule")
        let cleared = await pollUntilTrue(timeout: .seconds(10)) {
            await timer.armedSessionCount == 0
        }
        #expect(cleared == .satisfied, "and neither alarm re-arms after firing")
    }

    /// A remount, which used to be the moment a second timer appeared. Now it
    /// is the moment a pane finds the alarm the previous one armed, and the
    /// property to pin is that the row retires exactly once, on the deadline it
    /// was given before the remount.
    @Test("a remounted pane finds the same timer and retires the row it inherited")
    func aRemountedPaneStillRetiresTheRightSession() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let date = MovableDate(Self.t0)
        let source = try await Self.sourceWithCompletedMessage(now: Self.t0)
        try await Self.addPlainTranscript(to: source, sessionID: "s2")
        let state = await Self.makeState(streaming: true, suite: suite)
        let clock = TestClock()
        let scheduler = TranscriptPollScheduler(source: source, clock: clock)

        // Mount one arms A's 60-second backstop.
        let mounted = Self.timerForMountingPane(scheduler)
        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: mounted, now: { date.now })
        #expect(await mounted.armedMessage(sessionID: "s1") == "msg_a")

        // The remount, half-way through the window.
        date.advance(by: 30)
        await clock.advanceWhenSuspended(by: .seconds(30))
        let remounted = Self.timerForMountingPane(scheduler)
        #expect(remounted === mounted, "a remount finds the timer, it does not build one")
        await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: remounted, now: { date.now })
        #expect(await remounted.armedMessage(sessionID: "s1") == "msg_a",
                "the row it inherited is still armed, on its original deadline")
        #expect(await remounted.armedSessionCount == 1)
        #expect(await Self.publishedIDs(state) == ["stream:msg_a"])

        // A publish for another session through the same timer, the case the
        // keying exists for.
        await TableTranscriptPaneView.publish(
            sessionID: "s2", state: state, source: source,
            retireTimer: remounted, now: { date.now })
        #expect(await remounted.armedMessage(sessionID: "s1") == "msg_a",
                "B's publish must not disarm A")

        date.advance(by: 31)
        await clock.advance(by: .seconds(31))
        let withdrawn = await pollUntilTrue(timeout: .seconds(10)) {
            await Self.publishedIDs(state).isEmpty
        }
        #expect(withdrawn == .satisfied,
                "the row retires on the deadline it was given before the remount")
        #expect(await Self.publishedIDs(state, session: "s2").isEmpty == false,
                "and B's transcript is untouched")
        let cleared = await pollUntilTrue(timeout: .seconds(10)) {
            await remounted.armedSessionCount == 0
        }
        #expect(cleared == .satisfied, "and nothing re-arms after firing")
    }

    /// One text line, no terminal line: what a stream in flight and a proxy
    /// killed mid-turn both leave on disk.
    private static func streamFileWithOneTextLine() throws -> String {
        let dir = fencedScratchRoot(prefix: "tbdprov")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/stream.jsonl"
        let line = try ModelProxyStreamLine
            .text(message: "msg_a", index: 0, text: "Hel").encodedLine()
        try (line + "\n").write(toFile: path, atomically: true, encoding: .utf8)
        return path
    }

    /// The publish path's own off branch: the same source and the same
    /// completed message, with capabilities reporting streaming off.
    @Test("publishing with streaming off writes no provisional row and arms nothing")
    func publishingWithStreamingOffWritesNoRow() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let source = try await Self.sourceWithCompletedMessage(now: Self.t0)
        let state = await Self.makeState(streaming: false, suite: suite)
        let timer = ProvisionalRetireTimer(clock: TestClock())
        let t0 = Self.t0

        let published = await TableTranscriptPaneView.publish(
            sessionID: "s1", state: state, source: source,
            retireTimer: timer, now: { t0 })

        #expect(published.isEmpty)
        #expect(await Self.publishedIDs(state).isEmpty)
        #expect(await timer.armedMessage(sessionID: "s1") == nil)
    }
}

/// `ProvisionalRetireTimer` on its own: the one-shot behind both deadline rules.
@Suite("ProvisionalRetireTimer", .clockDriven, .serialized)
struct ProvisionalRetireTimerTests {

    private static let t0 = Date(timeIntervalSince1970: 1_700_000_000)
    /// The instant every alarm below is nominally due. It is the alarm's
    /// identity, never a clock the timer reads — the sleeping is all done on
    /// the injected `TestClock`, which is why these two never have to agree.
    private static let due = t0.addingTimeInterval(60)

    private actor FireLog {
        private(set) var count = 0
        func record() { count += 1 }
    }

    @Test("the alarm fires once, after the delay and not before")
    func alarmFiresOnceAfterTheDelay() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let log = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) { await log.record() }
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a")

        await clock.advanceWhenSuspended(by: .seconds(59))
        #expect(await log.count == 0, "59 s is inside the window")

        await clock.advance(by: .seconds(2))
        let fired = await pollUntilTrue(timeout: .seconds(10)) { await log.count == 1 }
        #expect(fired == .satisfied, "the alarm must fire once past the deadline")
        #expect(await timer.armedMessage(sessionID: "s1") == nil, "and clear itself so a later arm is not a no-op")

        // Nothing re-arms it, so no second fire can arrive.
        await clock.advance(by: .seconds(600))
        #expect(await log.count == 1)
    }

    /// The idempotence that keeps a 100 ms poll from pushing the deadline
    /// forever: a re-arm for the id already armed must leave the alarm alone.
    @Test("re-arming the same message does not push the deadline out")
    func reArmingTheSameMessageIsANoOp() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let log = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) { await log.record() }
        await clock.advanceWhenSuspended(by: .seconds(59))
        // A poll one second before the deadline re-arms with the *same* due
        // instant and the remaining 1 s. The due instant is the identity, so
        // this is a no-op; if the shrinking delay replaced the alarm instead,
        // the fire below would be 60 s away.
        await timer.arm(
            sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(1)
        ) { await log.record() }

        await clock.advance(by: .seconds(2))
        let fired = await pollUntilTrue(timeout: .seconds(10)) { await log.count >= 1 }
        #expect(fired == .satisfied)
        #expect(await log.count == 1, "one alarm, not two")
    }

    /// The other half of that rule, and what the silent-stream window needs: a
    /// line arriving for the message already armed genuinely moves its due
    /// instant, and the pending alarm must give way to the later one.
    ///
    /// What discriminates: keyed by message id alone, the second arm below is
    /// a no-op, the first alarm fires at 60 s, and a row whose stream is still
    /// producing is withdrawn underneath it.
    @Test("re-arming the same message at a later deadline replaces the alarm")
    func reArmingAtALaterDeadlineReplacesTheAlarm() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let log = FireLog()

        await timer.arm(
            sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)
        ) { await log.record() }
        await clock.advanceWhenSuspended(by: .seconds(30))
        await timer.arm(
            sessionID: "s1", messageID: "msg_a",
            deadline: Self.due.addingTimeInterval(60), after: .seconds(60)
        ) { await log.record() }

        await clock.advanceWhenSuspended(by: .seconds(31))
        for _ in 0..<50 { await Task.yield() }
        #expect(await log.count == 0, "the original deadline no longer belongs to anything")
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a")

        await clock.advance(by: .seconds(30))
        let fired = await pollUntilTrue(timeout: .seconds(10)) { await log.count == 1 }
        #expect(fired == .satisfied, "the replacement fires on the later deadline")
        #expect(await log.count == 1, "one alarm, not two")
    }

    @Test("arming a different message replaces the alarm")
    func armingADifferentMessageReplacesTheAlarm() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let first = FireLog()
        let second = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) { await first.record() }
        await timer.arm(sessionID: "s1", messageID: "msg_b", deadline: Self.due, after: .seconds(60)) { await second.record() }
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_b")

        await clock.advanceWhenSuspended(by: .seconds(61))
        let fired = await pollUntilTrue(timeout: .seconds(10)) { await second.count == 1 }
        #expect(fired == .satisfied)
        #expect(await first.count == 0, "the superseded message's alarm was cancelled")
    }

    /// The keying itself, at the level below the publish test: one session's
    /// disarm must leave every other session's alarm exactly where it is.
    @Test("an alarm is scoped to its session and survives another session's disarm")
    func alarmsAreScopedToTheirSession() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let first = FireLog()
        let second = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) {
            await first.record()
        }
        await timer.arm(sessionID: "s2", messageID: "msg_b", deadline: Self.due, after: .seconds(60)) {
            await second.record()
        }
        #expect(await timer.armedSessionCount == 2, "two sessions, two alarms")

        await timer.disarm(sessionID: "s2")
        #expect(await timer.armedMessage(sessionID: "s1") == "msg_a")
        #expect(await timer.armedMessage(sessionID: "s2") == nil)

        await clock.advanceWhenSuspended(by: .seconds(61))
        let fired = await pollUntilTrue(timeout: .seconds(10)) { await first.count == 1 }
        #expect(fired == .satisfied, "s1's alarm was untouched by s2's disarm")
        #expect(await second.count == 0, "and s2's really was cancelled")
    }

    /// The teardown gesture itself. A pane whose loop ends disarms its own
    /// session and nothing else, because this instance is reachable from the
    /// scheduler's single app-wide slot and may hold alarms for sessions other
    /// panes are showing. The 60-second rule is announced by nothing, so an
    /// alarm cancelled here would never be re-armed and its row would stay on
    /// screen for good.
    @Test("a teardown disarm leaves another session's alarm to fire exactly once")
    func teardownDisarmLeavesOtherSessionsArmed() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let leaving = FireLog()
        let staying = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) {
            await leaving.record()
        }
        await timer.arm(sessionID: "s2", messageID: "msg_b", deadline: Self.due, after: .seconds(60)) {
            await staying.record()
        }

        // What `appSideLoop` now does when its pane goes away.
        await timer.disarm(sessionID: "s1")
        #expect(await timer.armedSessionCount == 1, "only the leaving pane's session was disarmed")
        #expect(await timer.armedMessage(sessionID: "s2") == "msg_b")

        await clock.advanceWhenSuspended(by: .seconds(61))
        let fired = await pollUntilTrue(timeout: .seconds(10)) { await staying.count == 1 }
        #expect(fired == .satisfied, "s2's backstop survived the other pane's teardown")
        #expect(await leaving.count == 0, "and the torn-down session's own alarm was cancelled")

        await clock.advance(by: .seconds(600))
        #expect(await staying.count == 1, "exactly once — nothing re-arms a fired backstop")
    }

    @Test("disarmAll cancels every session's alarm")
    func disarmAllCancelsEverything() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let first = FireLog()
        let second = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) {
            await first.record()
        }
        await timer.arm(sessionID: "s2", messageID: "msg_b", deadline: Self.due, after: .seconds(60)) {
            await second.record()
        }
        await timer.disarmAll()
        #expect(await timer.armedSessionCount == 0)

        await clock.advance(by: .seconds(600))
        for _ in 0..<50 { await Task.yield() }
        #expect(await first.count == 0)
        #expect(await second.count == 0)
    }

    @Test("disarming cancels a pending alarm")
    func disarmingCancelsThePendingAlarm() async {
        let clock = TestClock()
        let timer = ProvisionalRetireTimer(clock: clock)
        let log = FireLog()

        await timer.arm(sessionID: "s1", messageID: "msg_a", deadline: Self.due, after: .seconds(60)) { await log.record() }
        await clock.advanceWhenSuspended(by: .seconds(1))
        await timer.disarm(sessionID: "s1")
        #expect(await timer.armedMessage(sessionID: "s1") == nil)

        await clock.advance(by: .seconds(600))
        // Give a cancelled task every chance to run before asserting it did not.
        for _ in 0..<50 { await Task.yield() }
        #expect(await log.count == 0)
    }
}
