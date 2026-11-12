import Foundation
import TBDShared

/// TBD's own refusals from the gates every provider-named remote verb passes
/// first: remote backends are off, or the compiled cloud provider is.
///
/// Each is TBD's fixed words with its code (`CodedRefusal`), so a client may
/// show it: a paired phone hears it as it is on every remote path.
enum RemoteGateRefusal {
    /// `remote_backends_enabled` is off, or the daemon started without the
    /// remote manager.
    static let backendsDisabled = CodedRefusal(text: "remote backends disabled", code: .remoteBackendsOff)

    /// `claude_cloud_enabled` is off, for the compiled cloud provider.
    static let claudeCloudDisabled = CodedRefusal(text: "claude cloud sessions disabled", code: .claudeCloudOff)
}
