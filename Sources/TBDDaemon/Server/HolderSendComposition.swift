import Foundation

/// Turns one `terminal.send` into the exact bytes the holder transport writes.
///
/// Split out of `performHolderSend` because it is the whole of the decision and
/// none of the plumbing: given a body, whether the send submits, and what the
/// child's bracketed-paste mode is, there is exactly one right answer in bytes.
/// A pure function is testable on whole `Data` values, and whole `Data` values
/// are the only assertion worth making here — a substring check would pass on a
/// message with the submitting `\r` *inside* the paste, which is the defect
/// this composition exists to fix.
///
/// **Why the wrapping matters.** An agent TUI's paste-burst heuristic keys on
/// the *shape* of a chunk, not its byte count, so a `\r` arriving in the same
/// read as a multi-line body gets absorbed into the pasted text and nothing
/// submits — measured at ~230 bytes and again at 4 KB, which is what shows it
/// is not a size effect. Wrapping the body in `ESC[200~`…`ESC[201~` and putting
/// the `\r` after the end marker makes the Enter provably outside the paste.
/// That is the property the tmux arm had, by pasting and pressing Enter as two
/// separate acts; this gets it without splitting the message, so a payload is
/// still never split across a routing decision.
///
/// **An empty body is never wrapped.** `--text "" --submit` is a real way to
/// press Enter, and a bracketed paste of nothing is a pair of markers the child
/// has to interpret for no reason — a shell at its prompt would show them.
enum HolderSendComposition {
    /// `ESC [ 2 0 0 ~` — the start of a bracketed paste.
    static let pasteStart = Data([0x1b, 0x5b, 0x32, 0x30, 0x30, 0x7e])
    /// `ESC [ 2 0 1 ~` — the end of a bracketed paste.
    static let pasteEnd = Data([0x1b, 0x5b, 0x32, 0x30, 0x31, 0x7e])
    /// Carriage return, not newline: what a terminal delivers when Return is
    /// pressed, and what tmux's `send-keys Enter` sends.
    static let submitByte: UInt8 = 0x0d

    /// - Parameter body: everything the message says, envelope included. The
    ///   envelope goes *inside* the paste, because it is part of the text the
    ///   child is being handed and splitting it out would be a second chunk.
    /// - Parameter submit: whether a Return follows.
    /// - Parameter bracketedPaste: what the child's mode is, as the oracle
    ///   answered. `false` when the oracle could not answer at all — bare bytes
    ///   are what every child understood before this existed, and markers a
    ///   child never asked for are printed rather than obeyed.
    /// - Returns: one `Data`, written in one call, so the message is never
    ///   interleaved with another writer's.
    static func compose(body: String, submit: Bool, bracketedPaste: Bool) -> Data {
        var message = Data()
        if !body.isEmpty {
            if bracketedPaste {
                message.append(pasteStart)
                message.append(Data(body.utf8))
                message.append(pasteEnd)
            } else {
                message.append(Data(body.utf8))
            }
        }
        if submit { message.append(submitByte) }
        return message
    }
}
