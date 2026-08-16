import Foundation
import Testing
@testable import TBDCLI
import TBDShared

/// Tier 1. `tbd hooks notification` is a dumb reporter, and these tests pin
/// exactly that: what it forwards, what it stays silent about, and that it
/// never interprets a field on the way through.
///
/// The decision is tested through `NotificationHookPlan.make` rather than
/// `run()`, because every path in `run()` is "make a plan, then either log or
/// speak to a socket" — the plan IS the behavior, and it is pure.
@Suite struct NotificationHookCommandTests {

    private let terminalID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private var env: [String: String] { ["TBD_TERMINAL_ID": terminalID.uuidString] }

    private func plan(_ json: String, environment: [String: String]? = nil) -> NotificationHookPlan {
        NotificationHookPlan.make(stdin: Data(json.utf8), environment: environment ?? env)
    }

    /// Thrown rather than `Issue.record`ed so the observed plan lands on the
    /// PRIMARY failure line — a trailing `↳` message is dropped by CI
    /// summaries (Tests/CLAUDE.md, assertion hygiene rule 4).
    private struct WrongPlan: Error, CustomStringConvertible {
        let expected: String
        let observed: NotificationHookPlan
        var description: String { "expected a \(expected) plan — observed \(observed)" }
    }

    private func forwarded(_ plan: NotificationHookPlan) throws -> TerminalNotificationEventParams {
        guard case .forward(let params) = plan else {
            throw WrongPlan(expected: "forwarded", observed: plan)
        }
        return params
    }

    private func suppression(_ plan: NotificationHookPlan) throws -> NotificationHookPlan.Suppression {
        guard case .suppressed(let reason) = plan else {
            throw WrongPlan(expected: "suppressed", observed: plan)
        }
        return reason
    }

    // MARK: - Forwarding

    @Test func fullPayloadForwardsEveryFieldAndTheVerbatimBody() throws {
        let json = #"""
        {"session_id":"abc123","transcript_path":"/x/00893aaf.jsonl","cwd":"/x/wt",\#
        "hook_event_name":"Notification","message":"Claude needs your permission to use Bash",\#
        "title":"Permission needed","notification_type":"permission_prompt"}
        """#
        let params = try forwarded(plan(json))
        #expect(params.terminalID == terminalID)
        #expect(params.notificationType == "permission_prompt")
        #expect(params.message == "Claude needs your permission to use Bash")
        #expect(params.title == "Permission needed")
        #expect(params.cwd == "/x/wt")
        // Verbatim: byte-for-byte what arrived, so a field this build does not
        // model still reaches whoever reads the record later.
        #expect(params.rawPayload == json)
    }

    @Test func payloadWithoutNotificationTypeForwardsWithNilType() throws {
        // An older Claude Code sends no `notification_type`. The absence is
        // carried as an absence — never filled in with a plausible type.
        let json = #"{"hook_event_name":"Notification","message":"Something happened"}"#
        let params = try forwarded(plan(json))
        #expect(params.notificationType == nil)
        #expect(params.message == "Something happened")
        #expect(params.title == nil)
    }

    @Test func payloadWithoutTitleForwardsWithNilTitle() throws {
        let json = #"{"message":"Waiting for your input","notification_type":"idle_prompt"}"#
        let params = try forwarded(plan(json))
        #expect(params.title == nil)
        #expect(params.notificationType == "idle_prompt")
        #expect(params.message == "Waiting for your input")
    }

    @Test func unknownNotificationTypeIsForwardedUntouched() throws {
        // The CLI matches nothing: a type this build never heard of goes to the
        // daemon spelled exactly as it arrived.
        let json = #"{"message":"?","notification_type":"some_future_type"}"#
        #expect(try forwarded(plan(json)).notificationType == "some_future_type")
    }

    @Test func payloadWithoutMessageForwardsAnEmptyOne() throws {
        // That a notification fired is itself the fact; text is never invented.
        let json = #"{"notification_type":"auth_success"}"#
        let params = try forwarded(plan(json))
        #expect(params.message == "")
        #expect(params.notificationType == "auth_success")
    }

    // MARK: - Silence

    @Test func absentTerminalIDIsSilent() throws {
        let json = #"{"message":"m","notification_type":"permission_prompt"}"#
        #expect(try suppression(plan(json, environment: [:])) == .noTerminalID)
    }

    @Test func unparseableTerminalIDIsSilent() throws {
        let json = #"{"message":"m"}"#
        let reason = try suppression(plan(json, environment: ["TBD_TERMINAL_ID": "not-a-uuid"]))
        #expect(reason == .noTerminalID)
    }

    @Test func malformedJSONIsSilent() throws {
        #expect(try suppression(plan("{not json")) == .malformedPayload)
    }

    @Test func nonObjectJSONIsSilent() throws {
        #expect(try suppression(plan("[1,2,3]")) == .malformedPayload)
    }

    @Test func emptyStdinIsSilent() throws {
        #expect(try suppression(plan("")) == .unusablePayloadSize)
    }

    @Test func oversizePayloadIsSilent() throws {
        let huge = Data(repeating: UInt8(ascii: "x"), count: (1 << 20) + 1)
        let reason = try suppression(NotificationHookPlan.make(stdin: huge, environment: env))
        #expect(reason == .unusablePayloadSize)
    }

    /// The terminal-ID check runs first: with no route for the event, the
    /// payload is never even parsed, so a malformed one is still just silence.
    @Test func absentTerminalIDWinsOverMalformedPayload() throws {
        #expect(try suppression(plan("{not json", environment: [:])) == .noTerminalID)
    }
}
