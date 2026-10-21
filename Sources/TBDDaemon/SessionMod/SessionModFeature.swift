import Foundation
import TBDShared

/// A feature the session mod can provide. The raw value is the name used in
/// `spawn.json`, `alive.json` and the `TBD_MOD_FEATURES` environment variable.
public enum SessionModFeature: String, Codable, Sendable, CaseIterable {
    case composerDraft = "composer-draft"
    /// Streams the main loop's answer into `transcript-stream.json` for the
    /// transcript pane's provisional rows.
    /// Design: docs/specs/2026-10-20-transcript-stream-mod-design.md.
    case transcriptStream = "transcript-stream"
    case usage

    /// The features enabled by `config`, in `allCases` order.
    public static func enabled(in config: Config) -> [SessionModFeature] {
        allCases.filter { feature in
            switch feature {
            case .composerDraft: config.composerDraftEnabled
            case .transcriptStream: config.transcriptStreamingEnabled
            case .usage: config.sessionModUsageEnabled
            }
        }
    }
}
