import Foundation
import TBDShared

/// What one `terminal.send` request is asking for, once its shape has passed
/// `RPCRouter.validateSendShape`.
///
/// Exactly one payload kind, by construction: the params type can spell
/// "both `--text` and `--keys`" and "neither", and this type cannot, so every
/// step past validation reads one payload without re-deriving which one it has.
/// The flags that only make sense for text — `--submit`, `--verify` — ride on
/// the text case for the same reason.
/// The verdict of `RPCRouter.validateSendShape`: a payload the daemon can act
/// on, or the error text a malformed request gets back before any row exists.
enum TerminalSendShape: Sendable, Equatable {
    case valid(TerminalSendPayload)
    case malformed(String)
}

enum TerminalSendPayload: Sendable, Equatable {
    /// The caller's message verbatim, without the dispatch envelope. §3's "the
    /// log records the message verbatim" means the message as the caller wrote
    /// it; the envelope is transport framing built at delivery time, and its id
    /// is the row's own — so recording it would copy the row's identifier into
    /// its own body (§12).
    case text(String, submit: Bool, verify: Bool)
    /// Named tmux keys, already tokenized and bounded by `PacedKeySender`.
    /// `verbatim` is the caller's string as written, which is what the record
    /// stores — the tokens are an implementation detail of delivery.
    case keys(names: [String], verbatim: String)
    /// An ordered list of pieces, each delivered as its own bracketed paste,
    /// then one Enter. `verify` is deliberately absent rather than defaulted:
    /// the delivery observation re-reads a pane for ONE delivered payload, and a
    /// multi-part send has no single payload to look for.
    case parts([SendPart], submit: Bool)

    /// The `message` field of the request row. The caller's payload as written,
    /// for both kinds.
    var recordedMessage: String {
        switch self {
        case .text(let text, _, _): return text
        case .keys(_, let verbatim): return verbatim
        // The row records what the caller asked to deliver, in order, with the
        // image parts named by path — which is what a human reading the
        // actuation log needs in order to tell what arrived where. It is not the
        // bytes: those are three pastes and an Enter, and no single string is
        // the message.
        case .parts(let parts, _):
            return parts.map { part in
                switch part {
                case .text(let value): return value
                case .imagePath(let path): return "[image \(path)]"
                }
            }.joined()
        }
    }

    /// The `submit` field of the request row. Absent for a keys payload:
    /// submission is not a thing a key sequence has, and recording `false`
    /// would imply the question was asked and answered no.
    var recordedSubmit: Bool? {
        switch self {
        case .text(_, let submit, _): return submit
        case .keys: return nil
        case .parts(_, let submit): return submit
        }
    }

    /// The `verify` field of the request row. Set only when the caller armed
    /// verification, so its presence alone identifies the sends that owe an
    /// observation — which is what the startup replay and the account read.
    var recordedVerify: Bool? {
        switch self {
        case .text(_, _, let verify): return verify ? true : nil
        case .keys: return nil
        case .parts: return nil
        }
    }

    /// Whether this send asked for delivery to be confirmed.
    var isVerifyArmed: Bool {
        if case .text(_, _, let verify) = self { return verify }
        return false
    }
}
