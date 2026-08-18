import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("Codex transcript activity tracker")
struct CodexTranscriptActivityTrackerTests {
    @Test func taskStartedProducesWorking() {
        var reducer = CodexTurnLifecycleReducer()

        reducer.consume(line: event(type: "task_started", turnID: "a"))

        #expect(reducer.activityState == .working)
    }

    @Test func matchingTaskCompleteProducesIdle() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "task_complete", turnID: "a"))

        #expect(reducer.activityState == .idle)
    }

    @Test func matchingTurnAbortedProducesIdle() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "turn_aborted", turnID: "a"))

        #expect(reducer.activityState == .idle)
    }

    @Test func completionForUnknownTurnDoesNotCloseOpenTurn() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "task_complete", turnID: "b"))

        #expect(reducer.activityState == .working)
    }

    @Test func duplicateStartsAreIdempotent() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))
        reducer.consume(line: event(type: "task_started", turnID: "a"))

        reducer.consume(line: event(type: "task_complete", turnID: "a"))

        #expect(reducer.activityState == .idle)
    }

    @Test func multipleTurnsRemainWorkingUntilAllClose() {
        var reducer = CodexTurnLifecycleReducer()
        reducer.consume(line: event(type: "task_started", turnID: "a"))
        reducer.consume(line: event(type: "task_started", turnID: "b"))

        reducer.consume(line: event(type: "task_complete", turnID: "a"))
        #expect(reducer.activityState == .working)

        reducer.consume(line: event(type: "turn_aborted", turnID: "b"))
        #expect(reducer.activityState == .idle)
    }

    @Test func malformedUnrelatedAndWrongOuterRecordsAreIgnored() {
        var reducer = CodexTurnLifecycleReducer()

        reducer.consume(line: Data("not json\n".utf8))
        reducer.consume(line: Data(#"{"type":"response_item","payload":{"type":"task_started","turn_id":"a"}}"#.utf8))
        reducer.consume(line: event(type: "agent_message", turnID: "a"))

        #expect(reducer.activityState == nil)
    }

    @Test func noLifecycleEvidenceProducesNil() {
        let reducer = CodexTurnLifecycleReducer()

        #expect(reducer.activityState == nil)
    }

    private func event(type: String, turnID: String) -> Data {
        Data((#"{"type":"event_msg","payload":{"type":"\#(type)","turn_id":"\#(turnID)"}}"# + "\n").utf8)
    }
}
