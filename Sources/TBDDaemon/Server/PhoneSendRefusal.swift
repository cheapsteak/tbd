import Foundation
import TBDShared

/// A refusal of a paired phone's send, with the code it carries when it has
/// one. A value of this type is always a refusal: unlike an `RPCResponse`, it
/// cannot hold a success, so the send core cannot be handed one by mistake.
struct PhoneSendRefusal: Sendable, Equatable {
    /// The refusal's words.
    let text: String
    /// The refusal's code, or nil for a refusal that carries none.
    let code: RPCErrorCode?

    init(text: String, code: RPCErrorCode? = nil) {
        self.text = text
        self.code = code
    }

    init(_ coded: CodedRefusal) {
        self.init(text: coded.text, code: coded.code)
    }

    /// The error response that carries this refusal.
    var response: RPCResponse {
        RPCResponse(error: text, code: code?.rawValue)
    }
}
