import Foundation
import TBDShared

/// A feature the session mod can provide. The raw value is the name used in
/// `spawn.json`, `alive.json` and the `TBD_MOD_FEATURES` environment variable.
public enum SessionModFeature: String, Codable, Sendable, CaseIterable {
    case composerDraft = "composer-draft"

    /// The features enabled by `config`.
    public static func enabled(in config: Config) -> [SessionModFeature] {
        config.composerDraftEnabled ? [.composerDraft] : []
    }
}
