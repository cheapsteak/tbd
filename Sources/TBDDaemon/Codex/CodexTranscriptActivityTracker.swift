import Foundation
import TBDShared

struct CodexTurnLifecycleReducer: Sendable {
    private struct EventEnvelope: Decodable {
        let type: String
        let payload: Payload
    }

    private struct Payload: Decodable {
        let type: String
        let turnID: String?

        enum CodingKeys: String, CodingKey {
            case type
            case turnID = "turn_id"
        }
    }

    private var openTurnIDs: Set<String> = []
    private var hasLifecycleEvidence = false

    var activityState: TerminalActivityState? {
        guard hasLifecycleEvidence else { return nil }
        return openTurnIDs.isEmpty ? .idle : .working
    }

    mutating func consume(line: Data) {
        guard let envelope = try? JSONDecoder().decode(EventEnvelope.self, from: line),
              envelope.type == "event_msg",
              let turnID = envelope.payload.turnID else { return }

        switch envelope.payload.type {
        case "task_started":
            hasLifecycleEvidence = true
            openTurnIDs.insert(turnID)
        case "task_complete", "turn_aborted":
            hasLifecycleEvidence = true
            openTurnIDs.remove(turnID)
        default:
            break
        }
    }
}
