import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// The gate the composer opts into: refuse a send when the session has a dialog
/// on screen, because a pasted body plus Enter into a permission dialog commits
/// whichever option is highlighted.
///
/// Every branch fails toward REFUSING, and the unrecognized class is the reason
/// why: a newer Claude Code's new dialog type looks exactly like an unknown
/// notification to this build, and allowing it would mean the gate silently
/// stops working the day a dialog is added.
///
/// Tier 1: pure decisions, one case per class.
@Suite("AwaitingInputSendGate")
struct AwaitingInputSendGateTests {

    private func reason(_ type: String?, message: String = "Claude needs your permission")
        -> AwaitingInputReason {
        AwaitingInputReason(
            message: message, hookEventName: "Notification", raw: nil, notificationType: type)
    }

    @Test func noStandingReasonAllows() {
        #expect(AwaitingInputSendGate.decide(reason: nil, superseded: false) == .allow)
    }

    @Test func aPromptOnScreenRefusesAndCarriesItsMessage() {
        let decision = AwaitingInputSendGate.decide(
            reason: reason("permission_prompt", message: "Allow Bash(rm -rf)?"),
            superseded: false)
        guard case .refuse(let message) = decision else {
            Issue.record("expected a refusal, got \(decision)")
            return
        }
        #expect(message.contains("Allow Bash(rm -rf)?"))
    }

    @Test func everyPromptOnScreenTypeRefuses() {
        for type in [
            "permission_prompt", "elicitation_dialog", "agent_needs_input",
            "worker_permission_prompt", "elicitation_url_dialog",
        ] {
            guard case .refuse = AwaitingInputSendGate.decide(
                reason: reason(type), superseded: false) else {
                Issue.record("\(type) must refuse")
                continue
            }
        }
    }

    /// **The one that keeps the gate working as Claude Code changes.** A type
    /// this build has never heard of is treated as a dialog.
    @Test func anUnrecognizedTypeIsTreatedAsADialog() {
        guard case .refuse = AwaitingInputSendGate.decide(
            reason: reason("brand_new_dialog_kind"), superseded: false) else {
            Issue.record("an unknown notification type must be treated as a dialog")
            return
        }
        guard case .refuse = AwaitingInputSendGate.decide(
            reason: reason(nil), superseded: false) else {
            Issue.record("an absent notification type must be treated as a dialog")
            return
        }
    }

    /// The idle prompt is the agent waiting for its next instruction — the exact
    /// state the composer exists to answer.
    @Test func theIdlePromptIsAllowed() {
        #expect(AwaitingInputSendGate.decide(
            reason: reason("idle_prompt"), superseded: false) == .allow)
    }

    @Test func informationalReasonsAreAllowed() {
        for type in ["agent_completed", "auth_success", "push_notification"] {
            #expect(
                AwaitingInputSendGate.decide(reason: reason(type), superseded: false) == .allow,
                "\(type) must be allowed")
        }
    }

    /// The supersession check is what stops a stale hand from blocking sends
    /// forever: the session's own transcript showed it moved on.
    @Test func aSupersededPromptIsAllowedThrough() {
        #expect(AwaitingInputSendGate.decide(
            reason: reason("permission_prompt"), superseded: true) == .allow)
        #expect(AwaitingInputSendGate.decide(
            reason: reason("brand_new_dialog_kind"), superseded: true) == .allow)
    }
}

/// The gate is OPT-IN, and that is the whole reason it can exist: agents use
/// `terminal.send` to answer permission dialogs deliberately, and a daemon-wide
/// gate would refuse exactly those sends.
@Suite("AwaitingInputSendGate opt-in")
struct AwaitingInputSendGateOptInTests {

    @Test func anOptedInSendIntoAPromptIsRefused() async throws {
        let harness = try await SendHarness.make()
        try await harness.db.terminals.recordAwaitingInputReason(
            id: harness.terminal.id,
            reason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "yes", submit: true,
            gateOnAwaitingInput: true),
            actor: .app)

        #expect(!response.success)
        #expect(try #require(response.error).contains("Allow Bash(rm -rf)?"))
        #expect(harness.tmux.pastedBodies.isEmpty, "nothing may be typed")
    }

    /// **The load-bearing negative.** The same row, the same prompt, no opt-in:
    /// the send goes through, because that is how an agent answers a dialog.
    @Test func anOptedOutSendIntoTheSamePromptIsNotGated() async throws {
        let harness = try await SendHarness.make()
        try await harness.db.terminals.recordAwaitingInputReason(
            id: harness.terminal.id,
            reason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "yes", submit: true),
            actor: ActuationActor.session(worktree: "W", terminal: "T"))

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(!(harness.tmux.pastedBodies.isEmpty))
    }

    @Test func anOptedInSendToAnIdleSessionGoesThrough() async throws {
        let harness = try await SendHarness.make()
        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "hi", submit: true,
            gateOnAwaitingInput: true),
            actor: .app)
        #expect(response.success, "error was: \(response.error ?? "none")")
    }

    /// **The gate applies to BOTH transports.** It used to sit after the
    /// early return that dispatches a holder-backed row to its own delivery
    /// arm, so a holder row was never gated at all: a composer send answered a
    /// permission dialog by committing whichever option was highlighted. The
    /// spec applies the gate before dispatching to either transport.
    @Test func anOptedInSendToAHolderRowIsRefused() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        try await harness.db.terminals.recordAwaitingInputReason(
            id: harness.terminal.id,
            reason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "yes", submit: true,
            gateOnAwaitingInput: true),
            actor: .app)

        #expect(!response.success)
        #expect(try #require(response.error).contains("Allow Bash(rm -rf)?"))
        #expect(recorder.writes.isEmpty, "nothing may be written to the pty")
    }

    /// The load-bearing negative for the transport above: no opt-in, same row,
    /// same prompt — the send goes through, because that is how an agent answers
    /// a dialog on a holder-backed session too.
    @Test func anOptedOutSendToAHolderRowIsNotGated() async throws {
        let recorder = HolderWriteRecorder()
        let harness = try await SendHarness.make(
            transport: .holder, holderDeliveryRecorder: { recorder.record($0) })
        try await harness.db.terminals.recordAwaitingInputReason(
            id: harness.terminal.id,
            reason: AwaitingInputReason(
                message: "Allow Bash(rm -rf)?", hookEventName: "Notification",
                notificationType: "permission_prompt"),
            observedAt: Date(timeIntervalSince1970: 1_800_000_000))

        let response = try await harness.send(TerminalSendParams(
            terminalID: harness.terminal.id, text: "yes", submit: true),
            actor: ActuationActor.session(worktree: "W", terminal: "T"))

        #expect(response.success, "error was: \(response.error ?? "none")")
        #expect(recorder.writes.count == 1)
    }
}

/// Collects the bytes the harness's stubbed `HolderInjectionCourier` was asked
/// to write. Lock-guarded, because the courier's closure runs off the test's
/// task.
private final class HolderWriteRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _writes: [Data] = []
    var writes: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return _writes
    }
    func record(_ bytes: Data) {
        lock.lock()
        defer { lock.unlock() }
        _writes.append(bytes)
    }
}
