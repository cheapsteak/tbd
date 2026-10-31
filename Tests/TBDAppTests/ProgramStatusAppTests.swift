import AppKit
import Foundation
import SwiftTerm
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 2: a real `TBDTerminalView` parsing real bytes, observed through the
// main queue and SwiftTerm's OSC observer queue with bounded waits.

/// The app half of the Program Status Protocol (OSC 7501) reader: which panels
/// answer the probe, that the answer is synchronous and silent during snapshot
/// replay, and that live reports are forwarded in order.
/// Design: `docs/specs/2026-10-10-program-status-protocol-design.md`.
@MainActor
@Suite("Program Status Protocol: app reader", .fastPassBounded)
struct ProgramStatusAppTests {

    // MARK: - Fixtures

    private static let probe = "\u{1b}]7501;?\u{07}"
    private static let probeST = "\u{1b}]7501;?\u{1b}\\"
    private static let reportData = "state=working;app=claude-code"
    private static var report: String { "\u{1b}]7501;\(reportData)\u{07}" }
    private static var replyBytes: [UInt8] { Array(ProgramStatusProtocol.probeReply.utf8) }

    private func makeAppState() -> (AppState, () -> Void) {
        let suite = TestDefaultsSuite("TBDAppTests.ProgramStatus")
        let defaults = suite.defaults
        let state = AppState(userDefaults: defaults)
        return (state, { suite.tearDown() })
    }

    private func seed(
        _ state: AppState,
        kind: TerminalKind?,
        label: String? = nil,
        transport: TerminalTransport,
        incarnation: UUID? = nil
    ) -> UUID {
        let worktreeID = UUID()
        let terminalID = UUID()
        state.terminals[worktreeID] = [TBDShared.Terminal(
            id: terminalID,
            worktreeID: worktreeID,
            tmuxWindowID: "@1",
            tmuxPaneID: "%1",
            label: label,
            sessionIncarnationID: incarnation,
            kind: kind,
            transport: transport
        )]
        return terminalID
    }

    // MARK: - Eligibility

    @Test("a holder row answers the probe")
    func holderClaudeAnswers() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = seed(state, kind: .claude, transport: .holder)
        #expect(state.answersProgramStatusProbe(terminalID: id))
        #expect(AppState.answersProgramStatusProbe(transport: .holder))
    }

    @Test("a tmux-transport panel answers nothing")
    func tmuxRowAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = seed(state, kind: .claude, transport: .tmux)
        #expect(!state.answersProgramStatusProbe(terminalID: id))
        #expect(!AppState.answersProgramStatusProbe(transport: .tmux))
        #expect(!AppState.answersProgramStatusProbe(transport: nil))
    }

    /// The probe rule is the daemon reader's: holder transport, blind to the
    /// agent. Ingestion, not the probe, filters by agent.
    @Test("a holder row answers whatever its agent: Codex, shell, or no kind")
    func holderRowAnswersRegardlessOfKind() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let codexByKind = seed(state, kind: .codex, transport: .holder)
        let codexByLabel = seed(state, kind: nil, label: TerminalLabel.codex, transport: .holder)
        let shell = seed(state, kind: .shell, transport: .holder)
        let legacy = seed(state, kind: nil, transport: .holder)
        for id in [codexByKind, codexByLabel, shell, legacy] {
            #expect(state.answersProgramStatusProbe(terminalID: id))
        }
    }

    @Test("an unknown terminal answers nothing")
    func unknownTerminalAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        #expect(!state.answersProgramStatusProbe(terminalID: UUID()))
    }

    @Test("forwarding is filtered to holder Claude and Codex rows, including legacy rows with no kind")
    func forwardingEligibility() {
        let holder: (TerminalKind?, String?) -> TBDShared.Terminal = { kind, label in
            TBDShared.Terminal(
                worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                label: label, kind: kind, transport: .holder)
        }
        #expect(AppState.isProgramStatusEligible(holder(.claude, nil)))
        #expect(AppState.isProgramStatusEligible(holder(nil, nil)))
        #expect(AppState.isProgramStatusEligible(holder(.codex, nil)))
        #expect(AppState.isProgramStatusEligible(holder(nil, TerminalLabel.codex)))
        #expect(AppState.isProgramStatusEligible(holder(.claude, TerminalLabel.codex)))
        #expect(AppState.isProgramStatusEligible(holder(.shell, TerminalLabel.codex)))
        #expect(!AppState.isProgramStatusEligible(holder(.shell, nil)))
        #expect(!AppState.isProgramStatusEligible(TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .claude, transport: .tmux)))
        #expect(!AppState.isProgramStatusEligible(TBDShared.Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: .codex, transport: .tmux)))
    }

    // MARK: - Forwarding

    @Test("an eligible report is forwarded with the row's incarnation, in order")
    func forwardsInOrder() async throws {
        try await assertForwardsInOrder(
            kind: .claude, payloads: ["state=working", "state=blocked;kind=permission"])
    }

    @Test("a Codex holder row's report is forwarded with the row's incarnation")
    func codexReportForwarded() async throws {
        try await assertForwardsInOrder(
            kind: .codex, payloads: ["state=blocked:app=codex:kind=permission"])
    }

    /// Seeds a holder row of `kind`, sends each payload through
    /// `forwardProgramStatusReport`, and asserts they arrive in order carrying
    /// the row's id, incarnation and observation time.
    private func assertForwardsInOrder(kind: TerminalKind, payloads: [String]) async throws {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let incarnation = UUID()
        let id = seed(state, kind: kind, transport: .holder, incarnation: incarnation)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })

        let observedAt = Date(timeIntervalSince1970: 1_000)
        for payload in payloads {
            state.forwardProgramStatusReport(
                terminalID: id, payload: Array(payload.utf8), observedAt: observedAt)
        }

        let expected = payloads.count
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count == expected }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        let params = sent.all
        try #require(params.count == expected)
        #expect(params.map(\.payload) == payloads)
        #expect(params.allSatisfy { $0.terminalID == id })
        #expect(params.allSatisfy { $0.incarnationID == incarnation })
        #expect(params.allSatisfy { $0.observedAt == observedAt })
    }

    /// A wake mints a new incarnation, and the woken view's first reports are
    /// forwarded under the cached row's: the wake's delta must carry it, and a
    /// delta without one (an older daemon) leaves the cached value alone.
    @Test("a report after a wake is forwarded under the incarnation the wake's delta carried")
    func wakeDeltaIncarnationIsForwarded() async throws {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let parkedIncarnation = UUID()
        let wokenIncarnation = UUID()
        let id = seed(state, kind: .claude, transport: .holder, incarnation: parkedIncarnation)
        let worktreeID = try #require(state.terminals.first { $0.value.contains { $0.id == id } }?.key)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })

        state.applyTerminalHibernationDelta(TerminalHibernationDelta(
            terminalID: id, worktreeID: worktreeID, hibernated: false, keepWarm: false))
        state.forwardProgramStatusReport(
            terminalID: id, payload: Array("state=idle:app=claude-code".utf8), observedAt: Date())
        state.applyTerminalHibernationDelta(TerminalHibernationDelta(
            terminalID: id, worktreeID: worktreeID, hibernated: false, keepWarm: false,
            sessionIncarnationID: wokenIncarnation))
        state.forwardProgramStatusReport(
            terminalID: id, payload: Array("state=working:app=claude-code".utf8), observedAt: Date())

        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count == 2 }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        let params = sent.all
        try #require(params.count == 2)
        #expect(params[0].incarnationID == parkedIncarnation)
        #expect(params[1].incarnationID == wokenIncarnation)
    }

    @Test("a report for an ineligible terminal is not forwarded")
    func ineligibleNotForwarded() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let holder = seed(state, kind: .claude, transport: .holder)
        let tmux = seed(state, kind: .claude, transport: .tmux)
        let shell = seed(state, kind: .shell, transport: .holder)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })

        state.forwardProgramStatusReport(terminalID: tmux, payload: Array("state=idle".utf8), observedAt: Date())
        // A shell holder panel answers the probe but its reports stay local.
        state.forwardProgramStatusReport(terminalID: shell, payload: Array("state=idle".utf8), observedAt: Date())

        // Positive control on the same forwarder: an eligible report behind
        // them arrives, and being serial, it arrives after anything they sent.
        state.forwardProgramStatusReport(terminalID: holder, payload: Array("state=done".utf8), observedAt: Date())
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count >= 1 }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        #expect(sent.all.map(\.payload) == ["state=done"])
    }

    // MARK: - Re-sending after a reconnect

    /// A report forwarded while the daemon was unreachable is lost, and the
    /// agent reports again only on change: a restarted subscription forwards
    /// each terminal's latest report again, with the incarnation and
    /// observation time it was first sent with — and only the latest.
    @Test("a restarted subscription forwards the latest report again")
    func reconnectResendsTheLatestReport() async throws {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let incarnation = UUID()
        let id = seed(state, kind: .claude, transport: .holder, incarnation: incarnation)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })
        // `startSubscription` re-seeds program status from the daemon;
        // answered here, so the test sends no RPC of its own for it.
        state.programStatusListFetcher = { @MainActor in [] }
        let earlier = Date(timeIntervalSince1970: 1_000)
        let latest = earlier.addingTimeInterval(1)
        state.forwardProgramStatusReport(
            terminalID: id, payload: Array("state=blocked:app=claude-code".utf8), observedAt: earlier)
        state.forwardProgramStatusReport(
            terminalID: id, payload: Array("state=working:app=claude-code".utf8), observedAt: latest)

        state.startSubscription()
        // Only the re-send is under test: the subscription it started has no
        // daemon to reach, and is ended at once.
        state.stopSubscription()

        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count >= 3 }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        let params = sent.all
        try #require(params.count == 3)
        #expect(params[2].terminalID == id)
        #expect(params[2].payload == "state=working:app=claude-code")
        #expect(params[2].incarnationID == incarnation)
        #expect(params[2].observedAt == latest)
    }

    /// The memory is kept to terminals the app caches. A terminal the app
    /// removes has its entry forgotten at once; one that leaves the cache by
    /// any other path keeps it until the next re-send, which drops it and
    /// re-sends nothing for it. Forwarding another report prunes nothing,
    /// because that runs on every report. A cached terminal's report is still
    /// re-sent. Both uncached terminals' reports were observed first, so a
    /// re-send of either would arrive ahead of the cached one's.
    @Test("a re-send forwards nothing for a terminal the app no longer caches")
    func resendDropsAnUncachedTerminalsReport() async throws {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let removed = seed(state, kind: .claude, transport: .holder)
        let dropped = seed(state, kind: .claude, transport: .holder)
        let kept = seed(state, kind: .codex, transport: .holder)
        let removedWorktreeID = try #require(
            state.terminals.first { $0.value.contains { $0.id == removed } }?.key)
        let droppedWorktreeID = try #require(
            state.terminals.first { $0.value.contains { $0.id == dropped } }?.key)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })
        let earlier = Date(timeIntervalSince1970: 1_000)
        state.forwardProgramStatusReport(
            terminalID: removed, payload: Array("state=working:app=claude-code".utf8), observedAt: earlier)
        state.forwardProgramStatusReport(
            terminalID: dropped, payload: Array("state=working:app=claude-code".utf8),
            observedAt: earlier.addingTimeInterval(1))

        state.removeDeletedTerminalFromState(terminalID: removed, worktreeID: removedWorktreeID)
        #expect(state.lastForwardedProgramStatusReports[removed] == nil)
        state.terminals[droppedWorktreeID] = nil
        state.forwardProgramStatusReport(
            terminalID: kept, payload: Array("state=idle:app=codex".utf8),
            observedAt: earlier.addingTimeInterval(2))
        #expect(state.lastForwardedProgramStatusReports[dropped] != nil,
                "forwarding a report pruned another terminal's entry")

        state.resendLastProgramStatusReports()

        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count >= 4 }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        let params = sent.all
        try #require(params.count == 4)
        #expect(params[3].terminalID == kept)
        #expect(state.lastForwardedProgramStatusReports[dropped] == nil)
        #expect(state.lastForwardedProgramStatusReports[kept] != nil)
    }

    // MARK: - The view's holder-vs-tmux switch

    @Test("the gate starts off, and set turns it on and back off")
    func gateSetAndRead() {
        let gate = ProgramStatusGate()
        #expect(gate.isEnabled == false)
        gate.set(true)
        #expect(gate.isEnabled == true)
        gate.set(false)
        #expect(gate.isEnabled == false)
    }

    // MARK: - The view: probe answer

    @Test("with the gate on, the probe is answered with ESC ] 7501 ; ? BEL")
    func probeAnsweredWhenGateOn() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = SendRecordingDelegate()
        harness.terminalView.terminalDelegate = spy
        harness.terminalView.programStatusGate.set(true)

        harness.terminalView.feed(text: Self.probe)
        let answered = await harness.waitUntil { spy.sent == Self.replyBytes }
        #expect(answered, "observed \(spy.sent)")
    }

    @Test("a probe terminated by ST is answered too")
    func probeWithSTAnswered() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = SendRecordingDelegate()
        harness.terminalView.terminalDelegate = spy
        harness.terminalView.programStatusGate.set(true)

        harness.terminalView.feed(text: Self.probeST)
        let answered = await harness.waitUntil { spy.sent == Self.replyBytes }
        #expect(answered, "observed \(spy.sent)")
    }

    @Test("with the gate off, the probe goes unanswered")
    func probeSilentWhenGateOff() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = SendRecordingDelegate()
        harness.terminalView.terminalDelegate = spy

        harness.terminalView.feed(text: Self.probe)
        await harness.settle()
        #expect(spy.sent.isEmpty)

        // Positive control: the same view, gate on, answers the same bytes.
        harness.terminalView.programStatusGate.set(true)
        harness.terminalView.feed(text: Self.probe)
        let answered = await harness.waitUntil { spy.sent == Self.replyBytes }
        #expect(answered, "observed \(spy.sent)")
    }

    @Test("the probe reply precedes the DA1 reply queued behind it")
    func replyPrecedesDA1() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = SendRecordingDelegate()
        harness.terminalView.terminalDelegate = spy
        harness.terminalView.programStatusGate.set(true)

        harness.terminalView.feed(text: Self.probe + "\u{1b}[c")
        let both = await harness.waitUntil { spy.sent.count > Self.replyBytes.count }
        #expect(both, "the DA1 fixture must be answered at all; observed \(spy.sent)")
        #expect(Array(spy.sent.prefix(Self.replyBytes.count)) == Self.replyBytes,
                "observed \(spy.sent)")
    }

    @Test("a probe fed while OSC observation is suspended for replay goes unanswered")
    func probeSilentWhileSuspended() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        // The spy, not the coordinator, so the coordinator's own ingest guard
        // in `send` is not what keeps this silent — the view's mute is.
        let spy = SendRecordingDelegate()
        harness.terminalView.terminalDelegate = spy
        harness.terminalView.programStatusGate.set(true)

        let suspension = harness.terminalView.suspendOscObservation()
        harness.terminalView.feed(text: Self.probe)
        await harness.settle()
        #expect(spy.sent.isEmpty, "a replayed probe was answered: \(spy.sent)")

        // Positive control: once resumed, the same bytes are answered.
        suspension.resume()
        harness.terminalView.feed(text: Self.probe)
        let answered = await harness.waitUntil { spy.sent == Self.replyBytes }
        #expect(answered, "observed \(spy.sent)")
    }

    // MARK: - The view: reports

    @Test("a live report reaches onProgramStatusReport with its exact payload; a probe does not")
    func reportDelivered() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let spy = SendRecordingDelegate()
        harness.terminalView.terminalDelegate = spy
        harness.terminalView.programStatusGate.set(true)
        let reports = ReportBox()
        harness.terminalView.onProgramStatusReport = { payload, _ in reports.payloads.append(payload) }
        defer { harness.terminalView.onProgramStatusReport = nil }

        harness.terminalView.feed(text: Self.probe + Self.report)
        let delivered = await harness.waitUntil { reports.payloads.count >= 1 }
        #expect(delivered)
        await harness.settle()
        #expect(reports.payloads == [Array(Self.reportData.utf8)])
    }

    @Test("with the gate off, a live report is not delivered")
    func reportNotDeliveredWhenGateOff() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        let reports = ReportBox()
        harness.terminalView.onProgramStatusReport = { payload, _ in reports.payloads.append(payload) }
        defer { harness.terminalView.onProgramStatusReport = nil }

        harness.terminalView.feed(text: Self.report)
        await harness.settle()
        #expect(reports.payloads.isEmpty)

        // Positive control: gate on, the same bytes are delivered.
        harness.terminalView.programStatusGate.set(true)
        harness.terminalView.feed(text: Self.report)
        let delivered = await harness.waitUntil { reports.payloads.count == 1 }
        #expect(delivered)
    }

    @Test("a snapshot carrying a probe and a report sends nothing and forwards nothing")
    func snapshotIsSilent() async {
        let harness = makeCoordinatorHarness()
        defer { harness.tearDown() }
        harness.terminalView.programStatusGate.set(true)
        let reports = ReportBox()
        harness.terminalView.onProgramStatusReport = { payload, _ in reports.payloads.append(payload) }
        defer { harness.terminalView.onProgramStatusReport = nil }

        harness.coordinator.feedSnapshot(
            Data((Self.probe + Self.report).utf8), into: harness.terminalView)
        await harness.settle()
        #expect(harness.sentBytes.isEmpty, "a replayed probe's reply reached the child")
        #expect(reports.payloads.isEmpty, "a replayed report was forwarded")

        // Positive control: live, on the production wiring, the probe's reply
        // reaches the child and the report is delivered.
        harness.terminalView.feed(text: Self.probe + Self.report)
        let answered = await harness.waitUntil { !harness.sentBytes.isEmpty }
        let delivered = await harness.waitUntil { reports.payloads.count == 1 }
        #expect(answered, "a live probe must still be answered")
        #expect(delivered, "a live report must still be delivered")
    }
}

// MARK: - Probes

/// Records every `send` the terminal view makes, in order.
final class SendRecordingDelegate: TerminalViewDelegate {
    private(set) var sent: [UInt8] = []

    func send(source: TerminalView, data: ArraySlice<UInt8>) { sent.append(contentsOf: data) }

    func clipboardCopy(source: TerminalView, content: Data) {}
    func bell(source: TerminalView) {}
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func scrolled(source: TerminalView, position: Double) {}
    func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    func clipboardRead(source: TerminalView) -> Data? { nil }
    func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

/// Collects `onProgramStatusReport` payloads, which arrive on main.
@MainActor
final class ReportBox {
    var payloads: [[UInt8]] = []
}

/// What the forwarder handed to its `send`, from the draining task.
final class SentParamsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var params: [TerminalProgramStatusReportParams] = []

    func append(_ value: TerminalProgramStatusReportParams) {
        lock.lock()
        params.append(value)
        lock.unlock()
    }

    var all: [TerminalProgramStatusReportParams] {
        lock.lock()
        defer { lock.unlock() }
        return params
    }

    var count: Int { all.count }
}

/// Carries the observed count onto the primary failure line.
struct ForwardTimeout: Error, CustomStringConvertible {
    let observed: Int
    var description: String {
        "program-status forwarder: \(observed) report(s) reached send before the deadline"
    }
}
