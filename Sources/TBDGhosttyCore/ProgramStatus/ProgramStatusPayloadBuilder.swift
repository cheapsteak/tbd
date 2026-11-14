import Foundation
// Scoped: only the protocol's value types are needed from TBDShared.
import enum TBDShared.ProgramStatusBlockKind
import enum TBDShared.ProgramStatusState

/// A parsed OSC 7501 report written back in the wire form TBD forwards: the
/// data after `7501;`, fields joined with `:`, `title` and `msg` in base64,
/// as the protocol sends them. `ProgramStatusParser` reads it as it reads the
/// raw bytes.
package enum ProgramStatusPayloadBuilder {
    package static func payload(for status: GhosttyTerminalCallbacks.ProgramStatus) -> [UInt8] {
        var fields = ["state=\(stateValue(status.state))"]
        if !status.app.isEmpty { fields.append("app=\(status.app)") }
        if !status.id.isEmpty { fields.append("id=\(status.id)") }
        if let kind = kindValue(status.kind) { fields.append("kind=\(kind)") }
        if let progress = status.progress { fields.append("progress=\(progress)") }
        if !status.title.isEmpty { fields.append("title=\(Data(status.title.utf8).base64EncodedString())") }
        if !status.message.isEmpty { fields.append("msg=\(Data(status.message.utf8).base64EncodedString())") }
        return Array(fields.joined(separator: ":").utf8)
    }

    private static func stateValue(_ state: GhosttyTerminalCallbacks.ProgramStatus.State) -> String {
        switch state {
        case .idle: return ProgramStatusState.idle.rawValue
        case .working: return ProgramStatusState.working.rawValue
        case .done: return ProgramStatusState.done.rawValue
        case .blocked: return ProgramStatusState.blocked.rawValue
        case .error: return ProgramStatusState.error.rawValue
        case .clear: return ProgramStatusState.clear.rawValue
        }
    }

    private static func kindValue(_ kind: GhosttyTerminalCallbacks.ProgramStatus.Kind) -> String? {
        switch kind {
        case .none: return nil
        case .permission: return ProgramStatusBlockKind.permission.rawValue
        case .question: return ProgramStatusBlockKind.question.rawValue
        case .auth: return ProgramStatusBlockKind.auth.rawValue
        }
    }
}
