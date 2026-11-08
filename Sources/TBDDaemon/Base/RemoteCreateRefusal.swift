import Foundation

/// TBD's own refusals of a phone's remote session create, which the router
/// writes before any provider is called: the form's first message is not a
/// string, or the form could not be written out again around it.
///
/// They live in `Base` because the router (`Server`) writes them and the
/// phone app service (`PhoneBridge`) tells them from a provider's own words:
/// a phone hears these as they are, and never a provider's text, which can
/// quote a secret.
enum RemoteCreateRefusal {
    /// The form's `prompt` value is there and is not a string.
    static let promptNotString = "remote.create prompt must be a string"

    /// The form, with its first message's line endings made bare LFs, could
    /// not be encoded again.
    static let formNotWritable = "remote.create paramsJSON could not be written out again"
}
