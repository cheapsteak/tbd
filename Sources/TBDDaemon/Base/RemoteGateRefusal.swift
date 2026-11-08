import Foundation

/// TBD's own refusals from the gates every provider-named remote verb passes
/// first: remote backends are off, or the compiled cloud provider is.
///
/// They live in `Base` because the router (`Server`) writes them and the
/// phone app service (`PhoneBridge`) tells them from a provider's own words:
/// a phone hears these as they are, and never a provider's text, which can
/// quote a secret.
enum RemoteGateRefusal {
    /// `remote_backends_enabled` is off, or the daemon started without the
    /// remote manager.
    static let backendsDisabled = "remote backends disabled"

    /// `claude_cloud_enabled` is off, for the compiled cloud provider.
    static let claudeCloudDisabled = "claude cloud sessions disabled"
}
