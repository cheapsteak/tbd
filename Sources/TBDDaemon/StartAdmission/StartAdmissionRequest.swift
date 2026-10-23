import Foundation
import TBDShared

/// What an agent start would do on this machine.
enum StartAdmissionKind: String, Sendable, Equatable {
    /// A new agent process in a new or replaced session: create, revive, swap
    /// profile, continue in the other provider.
    case create
    /// A parked agent session coming back.
    case wake
}

/// Which agent the start would launch.
enum StartAdmissionAgent: String, Sendable, Equatable {
    case claude
    case codex

    init(_ preference: PrimaryAgentPreference) {
        switch preference {
        case .claude: self = .claude
        case .codex: self = .codex
        }
    }
}

/// One question for the start-admission command: may this agent start now?
///
/// Carries only what the command receives as environment variables. The actor
/// is the kind string, not the full `ActuationActor`: the command is told who
/// asked, and nothing else about them.
struct StartAdmissionRequest: Sendable, Equatable {
    var kind: StartAdmissionKind
    var agent: StartAdmissionAgent
    var actorKind: String
    var worktreeID: UUID
    var terminalID: UUID?
}

/// The command's answer.
enum StartAdmissionVerdict: Sendable, Equatable {
    case admit
    /// The start is held. `reason` is what the caller is told.
    case hold(reason: String)
}

/// Who is checked.
///
/// Every actor kind is checked except two: `app` (everything the app sends
/// follows something the person did in it, including the wake that selecting a
/// parked tab performs) and `daemon` (TBD's own rails are out of scope for this
/// version). No declared actor is the anonymous actor and is checked. The
/// actor is self-declared, so this is a resource policy and not a security
/// boundary.
enum StartAdmissionActorRule {
    static func isChecked(_ actor: ActuationActor?) -> Bool {
        isChecked(kind: (actor ?? .anonymous).kind)
    }

    static func isChecked(kind: String) -> Bool {
        kind != ActuationActor.Kind.app && kind != ActuationActor.Kind.daemon
    }
}

/// Answers a `StartAdmissionRequest`. A protocol so router tests stub the
/// verdict without writing a script.
protocol StartAdmissionEvaluating: Sendable {
    func evaluate(_ request: StartAdmissionRequest) async -> StartAdmissionVerdict
}
