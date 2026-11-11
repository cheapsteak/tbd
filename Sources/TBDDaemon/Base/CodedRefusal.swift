import Foundation
import TBDShared

/// One of TBD's own refusals: its text and its code, written once, together.
///
/// A handler answers with `response`, so it cannot send the text without the
/// code. The code never changes the text, so a client that reads no codes
/// shows the same words. A refusal gets a code only when TBD wrote all of its
/// text (`RPCErrorCode`), so one that can quote a provider is never a
/// `CodedRefusal`.
///
/// It lives in `Base` because the router (`Server`) answers with these and
/// the phone app service (`PhoneBridge`) holds the phone message rule's.
/// Design: `docs/specs/2026-11-11-structured-refusal-codes-design.md`.
struct CodedRefusal: Sendable, Equatable {
    /// The refusal's words, as every client shows them.
    let text: String
    /// What kind of refusal it is (`RPCErrorCode`).
    let code: RPCErrorCode

    /// The error response that carries this refusal: `text` as the error and
    /// `code` beside it.
    var response: RPCResponse {
        RPCResponse(error: text, code: code.rawValue)
    }
}
