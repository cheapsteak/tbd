import Foundation
import TBDShared

/// Durable provider identity and launch metadata for recovery and wake.
/// Eligibility here does not authorize stopping a live process: recovery must
/// first prove transport ownership is gone. Other parking paths remain Claude-only.
enum AgentResumePlan: Sendable, Equatable {
    case claude(sessionID: String, transcriptPath: String?, profileID: UUID?, spawnExtras: ClaudeSpawnExtras?)
    case codex(sessionID: String, transcriptPath: String?, launchOptions: CodexLaunchOptions?)

    var identity: AgentSessionIdentity {
        switch self {
        case let .claude(sessionID, _, _, _):
            return AgentSessionIdentity(agentKind: .claude, sessionID: sessionID)
        case let .codex(sessionID, _, _):
            return AgentSessionIdentity(agentKind: .codex, sessionID: sessionID)
        }
    }
}

extension Terminal {
    var recoveryResumePlan: AgentResumePlan? {
        guard let sessionID = claudeSessionID,
              !sessionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let claudeID = claudeResumeDecision.resumableSessionID {
            return .claude(sessionID: claudeID, transcriptPath: transcriptPath,
                           profileID: profileID, spawnExtras: claudeSpawnExtras)
        }
        // A Codex label prevents a Claude resume for compatibility, but only
        // an explicit kind is positive evidence that the native ID is Codex's.
        guard kind == .codex else { return nil }
        return .codex(sessionID: sessionID, transcriptPath: transcriptPath,
                      launchOptions: codexLaunchOptions)
    }
}
