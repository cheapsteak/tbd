import Foundation
import TBDShared

/// TBD's own refusals of a phone's remote session create, which the router
/// writes before any provider is called: the form's first message is not a
/// string, or the form could not be written out again around it.
///
/// Each is TBD's fixed words with its code (`CodedRefusal`), so a client may
/// show it: a paired phone hears it as it is.
enum RemoteCreateRefusal {
    /// The form's `prompt` value is there and is not a string.
    static let promptNotString = CodedRefusal(
        text: "remote.create prompt must be a string", code: .remotePromptNotText)

    /// The form, with its first message's line endings made bare LFs, could
    /// not be encoded again.
    static let formNotWritable = CodedRefusal(
        text: "remote.create paramsJSON could not be written out again", code: .remoteFormNotWritable)
}
