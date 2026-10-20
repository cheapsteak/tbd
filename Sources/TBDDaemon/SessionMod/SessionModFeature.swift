import Foundation
import TBDShared

/// A feature the session mod can provide. The raw value is the name used in
/// `spawn.json`, `alive.json` and the `TBD_MOD_FEATURES` environment variable.
public enum SessionModFeature: String, Codable, Sendable, CaseIterable {
    case composerDraft = "composer-draft"
    case usage

    /// The features enabled by `config`, in `allCases` order.
    public static func enabled(in config: Config) -> [SessionModFeature] {
        allCases.filter { feature in
            switch feature {
            case .composerDraft: config.composerDraftEnabled
            case .usage: config.sessionModUsageEnabled
            }
        }
    }
}
