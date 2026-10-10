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
        let suiteName = "TBDAppTests.ProgramStatus.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let state = AppState(userDefaults: defaults)
        return (state, { defaults.removePersistentDomain(forName: suiteName) })
    }

    private func capabilities(programStatus: Bool) -> DaemonCapabilitiesResult {
        var caps = DaemonCapabilitiesResult(controlModeEnabled: false, panelSurfaceEnabled: false)
        caps.programStatusEnabled = programStatus
        return caps
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

    @Test("a holder Claude row with the flag on answers the probe")
    func holderClaudeAnswers() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let id = seed(state, kind: .claude, transport: .holder)
        #expect(state.answersProgramStatusProbe(terminalID: id))
    }

    @Test("the flag off answers nothing, explicitly off or capabilities not loaded")
    func flagOffAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let id = seed(state, kind: .claude, transport: .holder)
        state.daemonCapabilities = nil
        #expect(!state.answersProgramStatusProbe(terminalID: id))
        state.daemonCapabilities = capabilities(programStatus: false)
        #expect(!state.answersProgramStatusProbe(terminalID: id))
    }

    @Test("a tmux-transport Claude row answers nothing")
    func tmuxRowAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let id = seed(state, kind: .claude, transport: .tmux)
        #expect(!state.answersProgramStatusProbe(terminalID: id))
    }

    @Test("a Codex row answers nothing, by kind or by legacy label")
    func codexRowAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let byKind = seed(state, kind: .codex, transport: .holder)
        let byLabel = seed(state, kind: nil, label: TerminalLabel.codex, transport: .holder)
        #expect(!state.answersProgramStatusProbe(terminalID: byKind))
        #expect(!state.answersProgramStatusProbe(terminalID: byLabel))
    }

    @Test("a shell row answers nothing")
    func shellRowAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let id = seed(state, kind: .shell, transport: .holder)
        #expect(!state.answersProgramStatusProbe(terminalID: id))
    }

    @Test("a legacy row with no kind that is not Codex is treated as Claude")
    func legacyKindlessRowAnswers() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let id = seed(state, kind: nil, transport: .holder)
        #expect(state.answersProgramStatusProbe(terminalID: id))
    }

    @Test("an unknown terminal answers nothing")
    func unknownTerminalAnswersNothing() {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        #expect(!state.answersProgramStatusProbe(terminalID: UUID()))
    }

    // MARK: - Forwarding

    @Test("an eligible report is forwarded with the row's incarnation, in order")
    func forwardsInOrder() async throws {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        state.daemonCapabilities = capabilities(programStatus: true)
        let incarnation = UUID()
        let id = seed(state, kind: .claude, transport: .holder, incarnation: incarnation)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })

        let observedAt = Date(timeIntervalSince1970: 1_000)
        state.forwardProgramStatusReport(
            terminalID: id, payload: Array("state=working".utf8), observedAt: observedAt)
        state.forwardProgramStatusReport(
            terminalID: id, payload: Array("state=blocked;kind=permission".utf8), observedAt: observedAt)

        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count == 2 }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        let params = sent.all
        try #require(params.count == 2)
        #expect(params.map(\.payload) == ["state=working", "state=blocked;kind=permission"])
        #expect(params.allSatisfy { $0.terminalID == id })
        #expect(params.allSatisfy { $0.incarnationID == incarnation })
        #expect(params.allSatisfy { $0.observedAt == observedAt })
    }

    @Test("a report for an ineligible terminal, or with the flag off, is not forwarded")
    func ineligibleNotForwarded() async {
        let (state, cleanup) = makeAppState()
        defer { cleanup() }
        let holder = seed(state, kind: .claude, transport: .holder)
        let tmux = seed(state, kind: .claude, transport: .tmux)
        let sent = SentParamsBox()
        state.programStatusForwarder = ProgramStatusForwarder(send: { params in sent.append(params) })

        state.daemonCapabilities = capabilities(programStatus: false)
        state.forwardProgramStatusReport(terminalID: holder, payload: Array("state=idle".utf8), observedAt: Date())
        state.daemonCapabilities = capabilities(programStatus: true)
        state.forwardProgramStatusReport(terminalID: tmux, payload: Array("state=idle".utf8), observedAt: Date())

        // Positive control on the same forwarder: an eligible report behind
        // them arrives, and being serial, it arrives after anything they sent.
        state.forwardProgramStatusReport(terminalID: holder, payload: Array("state=done".utf8), observedAt: Date())
        let outcome = await pollUntilTrue(timeout: TestDeadlines.saturatedPass) { @Sendable in sent.count >= 1 }
        if outcome == .timedOut {
            Issue.record(ForwardTimeout(observed: sent.count))
        }
        #expect(sent.all.map(\.payload) == ["state=done"])
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
