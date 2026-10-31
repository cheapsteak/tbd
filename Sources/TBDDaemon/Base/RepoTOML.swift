import Foundation

/// The repository's committed `tbd.toml`: its name, and where it lives.
///
/// One constant for every reader of the file, so the dev-server parser and the
/// peer-messaging switch can never disagree about which file a repository
/// declares its settings in.
enum RepoTOML {
    static let fileName = "tbd.toml"

    /// The `tbd.toml` at the root of a checkout.
    static func path(inCheckout checkoutPath: String) -> String {
        URL(fileURLWithPath: checkoutPath, isDirectory: true)
            .appendingPathComponent(fileName).path
    }
}
