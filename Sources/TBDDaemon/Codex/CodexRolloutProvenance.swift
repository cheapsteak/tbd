import Foundation

enum CodexRolloutOrigin: Sendable {
    case topLevel(CodexRolloutProof)
    case subagent
    case unproven
}

/// Only the first complete session_meta can establish rollout origin. Missing
/// metadata is not evidence of a top-level session; cwd is never consulted.
enum CodexRolloutProvenance {
    static func classify(path: String) -> CodexRolloutOrigin {
        guard let metadata = BoundedJSONLRecordProof.read(path: path, recordType: "session_meta"),
              let payload = metadata.record["payload"] as? [String: Any] else { return .unproven }
        if let source = payload["source"] as? [String: Any], source.keys.contains("subagent") {
            return .subagent
        }
        guard let source = payload["source"] as? String,
              !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .unproven }
        return .topLevel(metadata.proof)
    }
}
