import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

private typealias Fixture = TranscriptStreamFixtures

/// `ProvisionalRowComposer.compose` — the pure step that turns the session
/// mod's snapshot into provisional rows, and every retire rule but the ones
/// the source decides (which `TranscriptSourceStreamTests` covers).
@Suite("ProvisionalRowComposer")
struct ProvisionalRowComposerTests {

    private static let settled: [TranscriptItem] = [
        .userPrompt(id: "u1", text: "hi", timestamp: nil),
    ]

    private static func compose(
        _ stream: TranscriptStreamSnapshot?,
        confirmed: Set<String> = [],
        sessionEnded: Bool = false,
        streaming: Bool = true
    ) -> [TranscriptItem] {
        ProvisionalRowComposer.compose(
            items: settled, stream: stream, confirmedUUIDs: confirmed,
            sessionEnded: sessionEnded, streamingEnabled: streaming)
    }

    private static func provisional(_ items: [TranscriptItem]) -> [TranscriptItem] {
        items.filter { ProvisionalRowComposer.isProvisional(itemID: $0.id) }
    }

    private static let live = Fixture.snapshot([
        Fixture.step(0, [Fixture.thinking("Plan it.", ended: true, uuid: "r1"), Fixture.text("Hello")]),
    ])

    @Test("streaming off composes no rows whatever the file holds")
    func flagOffComposesNothing() {
        #expect(Self.compose(Self.live, streaming: false) == Self.settled)
    }

    /// Flag on with no file must match flag off exactly.
    @Test("no stream file composes no rows")
    func noFileComposesNothing() {
        #expect(Self.compose(nil) == Self.settled)
        #expect(Self.compose(nil) == Self.compose(nil, streaming: false))
    }

    @Test("blocks follow the transcript, in the order the step produced them")
    func blocksAreAppendedInStepOrder() {
        let items = Self.compose(Self.live)

        #expect(Array(items.prefix(1)) == Self.settled)
        #expect(Array(items.dropFirst()) == [
            .thinking(id: "stream:turn-1:0:0", text: "Plan it.", timestamp: nil),
            .assistantText(
                id: "stream:turn-1:0:1", text: "Hello" + ProvisionalRowComposer.cursor,
                timestamp: nil, usage: nil),
        ])
    }

    @Test("blocks of two steps keep step order")
    func stepsKeepTheirOrder() {
        let stream = Fixture.snapshot([
            Fixture.step(0, ended: true, stopReason: "tool_use", [Fixture.text("First", ended: true)]),
            Fixture.step(1, [Fixture.text("Second")]),
        ])

        #expect(Self.provisional(Self.compose(stream)).map(\.id)
                == ["stream:turn-1:0:0", "stream:turn-1:1:0"])
    }

    @Test("a streaming text block carries the cursor; an ended one does not")
    func theCursorMarksOnlyAStreamingBlock() {
        let stream = Fixture.snapshot([
            Fixture.step(0, [Fixture.text("Done", ended: true), Fixture.text("Going")]),
        ])

        let texts = Self.provisional(Self.compose(stream)).map { item -> String in
            guard case .assistantText(_, let text, _, _) = item else { return "" }
            return text
        }
        #expect(texts == ["Done", "Going" + ProvisionalRowComposer.cursor])
    }

    /// The step ending ends its blocks even if the mod never saw a later
    /// chunk: a text block left waiting on a permission prompt shows without
    /// the cursor.
    @Test("a text block in an ended step shows without the cursor")
    func anEndedStepHasNoCursor() {
        let stream = Fixture.snapshot([Fixture.step(0, ended: true, stopReason: "tool_use", [Fixture.text("Waiting")])])

        #expect(Self.provisional(Self.compose(stream)) == [
            .assistantText(id: "stream:turn-1:0:0", text: "Waiting", timestamp: nil, usage: nil),
        ])
    }

    @Test("a text block that just started shows the cursor alone")
    func anEmptyStreamingTextBlockShowsTheCursor() {
        let stream = Fixture.snapshot([Fixture.step(0, [Fixture.text("")])])
        #expect(Self.provisional(Self.compose(stream)) == [
            .assistantText(
                id: "stream:turn-1:0:0", text: ProvisionalRowComposer.cursor,
                timestamp: nil, usage: nil),
        ])
    }

    @Test("an ended empty text block, an empty thinking block and an unknown kind show nothing")
    func blocksWithNothingToShowAreSkipped() {
        let stream = Fixture.snapshot([Fixture.step(0, [
            Fixture.text("", ended: true, uuid: "r1"),
            Fixture.thinking("", ended: true),
            .init(kind: .other("image"), text: "x", ended: true, uuid: nil),
        ])])

        #expect(Self.compose(stream) == Self.settled)
    }

    /// Retire rule 1: a block whose row is in the JSONL leaves; its unconfirmed
    /// sibling stays, with the same id it had before.
    @Test("a block the JSONL confirmed leaves and its sibling keeps its id")
    func aConfirmedBlockLeaves() {
        let stream = Fixture.snapshot([Fixture.step(0, [
            Fixture.text("First", ended: true, uuid: "r1"),
            Fixture.text("Second", ended: true, uuid: "r2"),
        ])])

        #expect(Self.provisional(Self.compose(stream, confirmed: ["r1"])).map(\.id)
                == ["stream:turn-1:0:1"])
        #expect(Self.compose(stream, confirmed: ["r1", "r2"]) == Self.settled)
    }

    /// Retire rules 2 and 3 reach the composer as one input: the pane folds a
    /// terminal exit and a stale heartbeat into `sessionEnded`.
    @Test("an ended session composes no rows")
    func anEndedSessionComposesNothing() {
        #expect(Self.compose(Self.live, sessionEnded: true) == Self.settled)
    }

    /// Retire rule 4: the file is a live view, so a block a new turn cleared
    /// is simply not there to compose.
    @Test("a block no longer in the snapshot is gone")
    func aBlockGoneFromTheSnapshotIsGone() {
        let before = Self.compose(Self.live)
        let cleared = Self.compose(Fixture.snapshot(turn: "turn-2", []))

        #expect(Self.provisional(before).count == 2)
        #expect(cleared == Self.settled)
    }

    /// There is no timer: an unconfirmed block whose step ended long ago stays
    /// for as long as the session lives, because a permission wait can hold
    /// the JSONL write for minutes.
    @Test("composition depends on no clock")
    func noTimeRuleExists() {
        let stream = Fixture.snapshot([Fixture.step(0, ended: true, stopReason: "tool_use", [Fixture.text("Waiting", ended: true)])])
        #expect(Self.compose(stream) == Self.compose(stream))
        #expect(Self.provisional(Self.compose(stream)).count == 1)
    }

    @Test("a row's id stays put while its text grows")
    func idsAreStableAsTextGrows() {
        let early = Self.compose(Fixture.snapshot([Fixture.step(0, [Fixture.text("Hel")])]))
        let later = Self.compose(Fixture.snapshot([Fixture.step(0, [Fixture.text("Hello, world")])]))
        #expect(Self.provisional(early).map(\.id) == Self.provisional(later).map(\.id))
    }

    @Test("settledOnly removes every provisional row and nothing else")
    func settledOnlyDropsProvisionalRows() {
        let items = Self.compose(Self.live)
        #expect(ProvisionalRowComposer.settledOnly(items) == Self.settled)
        #expect(ProvisionalRowComposer.isProvisional(itemID: "stream:turn-1:0:0"))
        #expect(!ProvisionalRowComposer.isProvisional(itemID: "u1"))
    }
}

/// How a provisional row reaches the screen: the render projection marks it,
/// a provisional thinking summary shows where settled thinking stays hidden,
/// and the native activity row draws it.
@MainActor
@Suite("ProvisionalRowPresentation")
struct ProvisionalRowPresentationTests {

    @Test("a stream: text item builds a provisional bubble and a plain one does not")
    func streamPrefixMarksTheBubble() {
        let presentation = TranscriptPresentation.build(
            items: [
                .assistantText(id: "msg_old", text: "settled", timestamp: nil),
                .assistantText(id: "stream:t:0:0", text: "arriving", timestamp: nil),
            ],
            memo: TranscriptPresentationMemo())

        #expect(presentation.nodes.count == 2)
        #expect(presentation.nodes[0].isProvisional == false)
        #expect(presentation.nodes[1].isProvisional)
    }

    @Test("a provisional thinking summary shows; settled thinking stays hidden")
    func onlyProvisionalThinkingShows() {
        let nodes = transcriptRenderNodes(from: [
            .thinking(id: "settled", text: "old thought", timestamp: nil),
            .thinking(id: "stream:t:0:0", text: "new thought", timestamp: nil),
        ])

        #expect(nodes.count == 1)
        #expect(nodes.first?.id == "stream:t:0:0")
        #expect(nodes.first?.isProvisional == true)
        #expect(nodes.first?.kind == .thinking(id: "stream:t:0:0", text: "new thought"))
    }

    /// Folded into an activity group the summary would be hidden while it
    /// streams, so it stands alone like a bubble.
    @Test("a provisional thinking summary is never folded into an activity group")
    func thinkingStandsAloneInThePresentation() {
        let presentation = TranscriptPresentation.build(
            items: [
                .toolCall(id: "t1", name: "Bash", inputJSON: #"{"command":"ls"}"#,
                          inputTruncatedTo: nil, result: nil, subagent: nil, timestamp: nil, usage: nil),
                .toolCall(id: "t2", name: "Bash", inputJSON: #"{"command":"pwd"}"#,
                          inputTruncatedTo: nil, result: nil, subagent: nil, timestamp: nil, usage: nil),
                .thinking(id: "stream:t:0:0", text: "Considering", timestamp: nil),
            ],
            memo: TranscriptPresentationMemo())

        #expect(presentation.nodes.last?.id == "stream:t:0:0")
        #expect(presentation.nodes.contains { node in
            if case .thinking = node.kind { return true } else { return false }
        })
    }

    @Test("the native row draws the summary on one line, with no overlay target")
    func theActivityRowShowsTheSummary() throws {
        let node = TranscriptRenderNode(
            id: "stream:t:0:0", kind: .thinking(id: "stream:t:0:0", text: "Line one\nline two"),
            badgeUsage: nil, isProvisional: true)

        let presentation = try #require(ActivityRowFormatter.presentation(for: node))

        #expect(presentation.iconSystemName == "brain")
        #expect(presentation.titleSegments.map(\.text) == ["Thinking", "Line one line two"])
        #expect(presentation.openTargetID == nil)
        #expect(presentation.badges == [ActivityRowBadge(text: "streaming", kind: .neutral)])
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

    /// The cursor is content: the bubble renders exactly the text it is given.
    @Test("the bubble renders the composer's cursor as text")
    func theBubbleRendersTheCursorItCarries() {
        let item = TranscriptItem.assistantText(
            id: "stream:t:0:0", text: "Hello" + ProvisionalRowComposer.cursor, timestamp: nil)

        let blocks = TranscriptBubbleGeometry.composedBlocks(for: item, badgeUsage: nil, linkResolver: nil)

        let prose = blocks.compactMap { block -> String? in
            guard case .prose(let string) = block else { return nil }
            return string.string
        }.joined()
        #expect(prose == "Hello" + ProvisionalRowComposer.cursor)
    }
}

/// The publish step in `TableTranscriptPaneView` — where the source, the
/// streaming flag and the terminal's state meet the composer.
///
/// Driven directly rather than through a SwiftUI view tree, the same shape as
/// `TaskKey.resolve`. Deliberately not `@MainActor`: `publish` is
/// `nonisolated`, the isolation it runs under in the app.
@Suite("ProvisionalRowPublish", .serialized)
struct ProvisionalRowPublishTests {

    private static let worktreeID = UUID()

    @MainActor
    private static func makeState(
        streaming: Bool, suite: String, sessionID: String = "s1", exited: Bool = false
    ) -> AppState {
        let state = AppState(userDefaults: UserDefaults(suiteName: suite)!)
        state.daemonCapabilities = DaemonCapabilitiesResult(
            controlModeEnabled: false, transcriptStreamingEnabled: streaming)
        state.terminals = [worktreeID: [
            Terminal(worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
                     claudeSessionID: sessionID, kind: .claude,
                     hibernatedAt: exited ? Date(timeIntervalSince1970: 1_700_000_000) : nil,
                     hibernateReason: exited ? .exited : nil),
        ]]
        return state
    }

    private static func removeSuite(_ suite: String) {
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
    }

    private static func publishedIDs(_ state: AppState) async -> [String] {
        await MainActor.run { (state.sessionTranscripts["s1"] ?? []).map(\.id) }
    }

    /// A source holding a one-row transcript (`r1`) and a stream with one
    /// confirmed block (`r1`) and one still streaming.
    private static func source() async throws -> TranscriptSource {
        let transcript = try Fixture.transcript([Fixture.assistantRow(uuid: "r1", text: "First")])
        let stream = try Fixture.streamPath()
        try Fixture.write(Fixture.snapshot([Fixture.step(0, [
            Fixture.text("First", ended: true, uuid: "r1"),
            Fixture.text("Second"),
        ])]), to: stream)

        let source = TranscriptSource()
        await source.refresh(sessionID: "s1", path: transcript)
        await source.refreshStream(sessionID: "s1", path: stream, now: Date(timeIntervalSince1970: 1_700_000_000))
        return source
    }

    @Test("flag on: the confirmed block leaves and the streaming one is published last")
    func publishComposesTheUnconfirmedBlock() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let source = try await Self.source()
        let state = await Self.makeState(streaming: true, suite: suite)

        let published = await TableTranscriptPaneView.publish(sessionID: "s1", state: state, source: source)

        #expect(published.map(\.id) == ["r1#0", "stream:turn-1:0:1"])
        #expect(await Self.publishedIDs(state) == ["r1#0", "stream:turn-1:0:1"])
    }

    @Test("flag off: the publish is the transcript alone")
    func publishWithTheFlagOffIsTheTranscript() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let source = try await Self.source()
        let state = await Self.makeState(streaming: false, suite: suite)

        #expect(await TableTranscriptPaneView.publish(sessionID: "s1", state: state, source: source)
                .map(\.id) == ["r1#0"])
    }

    /// Retire rule 2.
    @Test("an exited terminal's blocks are retired")
    func anExitedTerminalPublishesNoBlocks() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let source = try await Self.source()
        let state = await Self.makeState(streaming: true, suite: suite, exited: true)

        #expect(await TableTranscriptPaneView.publish(sessionID: "s1", state: state, source: source)
                .map(\.id) == ["r1#0"])
    }

    @Test("a session no terminal runs any more publishes no blocks")
    func aSessionWithNoTerminalPublishesNoBlocks() async throws {
        let suite = "tbd-provisional-publish-\(UUID().uuidString)"
        defer { Self.removeSuite(suite) }
        let source = try await Self.source()
        let state = await Self.makeState(streaming: true, suite: suite, sessionID: "other")

        #expect(await TableTranscriptPaneView.publish(sessionID: "s1", state: state, source: source)
                .map(\.id) == ["r1#0"])
    }

    @Test("terminalHasExited reads parks and suspends as exits, and a live terminal as live")
    func terminalExitIsParkedOrSuspended() {
        let worktree = UUID()
        func terminals(_ terminal: Terminal) -> [UUID: [Terminal]] { [worktree: [terminal]] }
        let live = Terminal(worktreeID: worktree, tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSessionID: "s1")
        let parked = Terminal(worktreeID: worktree, tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSessionID: "s1",
                              hibernatedAt: Date(timeIntervalSince1970: 1))
        let suspended = Terminal(worktreeID: worktree, tmuxWindowID: "@1", tmuxPaneID: "%1", claudeSessionID: "s1",
                                 suspendedAt: Date(timeIntervalSince1970: 1))

        #expect(!TableTranscriptPaneView.terminalHasExited(claudeSessionID: "s1", terminals: terminals(live)))
        #expect(TableTranscriptPaneView.terminalHasExited(claudeSessionID: "s1", terminals: terminals(parked)))
        #expect(TableTranscriptPaneView.terminalHasExited(claudeSessionID: "s1", terminals: terminals(suspended)))
        #expect(TableTranscriptPaneView.terminalHasExited(claudeSessionID: "s2", terminals: terminals(live)))
    }
}
