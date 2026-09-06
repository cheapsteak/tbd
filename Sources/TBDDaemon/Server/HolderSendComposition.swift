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
///
/// **A wrapped body carries no paste marker of its own.** Both markers are
/// taken out, for reasons that differ. `ESC[201~` inside the paste closes it
/// early, so everything after it — the rest of the body and the submitting
/// `\r` — arrives as keystrokes instead of text, which is precisely the failure
/// the wrapping exists to prevent, reached by content rather than by chunk
/// shape. `ESC[200~` inside the paste restarts it in a child whose reader takes
/// a nested start marker as the beginning of a new paste, discarding everything
/// before it — the dispatch envelope included — so what the child acts on is
/// not what the caller sent. `--text "$(cat some-file)"` is all either takes: a
/// log or a transcript that recorded raw terminal input holds both. A paste
/// marker inside a paste can only ever be a break-out or a restart: there is
/// nothing a child could display for one, so removing it loses nothing a caller
/// meant to send, and removal is done bytewise on the composed body so a marker
/// cannot re-form across a removal. Only the wrapped path touches the body; an
/// unwrapped send is delivered verbatim, because with no paste open there is
/// nothing to break out of and the bytes are the caller's to send.
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
        // Stripped before the emptiness test, not after, so the two rules
        // compose: a body that was nothing but paste markers has nothing left
        // to paste, and wrapping it would put the markers the empty-body rule
        // exists to avoid in front of the Enter.
        let payload = bracketedPaste ? removingPasteMarkers(from: Data(body.utf8)) : Data(body.utf8)
        var message = Data()
        if !payload.isEmpty {
            if bracketedPaste { message.append(pasteStart) }
            message.append(payload)
            if bracketedPaste { message.append(pasteEnd) }
        }
        if submit { message.append(submitByte) }
        return message
    }

    /// `body` with every `ESC[200~` and `ESC[201~` taken out, so the only paste
    /// markers in the composed message are the pair this type puts there.
    ///
    /// Written as an append-and-retract scan rather than a search-and-replace
    /// because a single replacing pass is not enough: removing the marker from
    /// `ESC[2` + `ESC[201~` + `01~` joins its neighbours into a fresh one, and
    /// the same holds for `ESC[200~`. Here a marker is retracted the moment the
    /// byte that completes it is appended, and the retraction is followed by a
    /// re-check, so neither pattern can leave a suffix that completes the other
    /// unnoticed — the invariant holds after every step and the output provably
    /// contains neither marker, in one pass over the body.
    ///
    /// The suffix is compared **in place**, and only when the byte just
    /// appended is the `~` both markers end in. This runs inside the
    /// per-terminal send serializer on a body with no size cap, and the obvious
    /// spelling — materialising `kept.suffix(pattern.count)` into an `Array` —
    /// allocates once per input byte for a comparison that ordinary text loses
    /// on its first byte.
    static func removingPasteMarkers(from body: Data) -> Data {
        let patterns = [[UInt8](pasteStart), [UInt8](pasteEnd)]
        // The shared last byte is what makes one cheap test enough to skip the
        // suffix scan on every byte of ordinary text.
        guard let terminator = pasteEnd.last, pasteStart.last == terminator else { return body }
        var kept: [UInt8] = []
        kept.reserveCapacity(body.count)
        for byte in body {
            kept.append(byte)
            guard byte == terminator else { continue }
            while retractTrailingMarker(from: &kept, patterns: patterns) {}
        }
        return Data(kept)
    }

    /// Removes one trailing marker from `kept`, answering whether it removed
    /// one so the caller can look again: a retraction rejoins the bytes on
    /// either side of what it took out, and the re-check is what keeps a
    /// removal of one pattern from leaving the other's bytes touching.
    ///
    /// The comparison runs from the end of the pattern backwards, which is
    /// where the two markers differ — they agree on everything but their
    /// second-to-last byte.
    private static func retractTrailingMarker(
        from kept: inout [UInt8], patterns: [[UInt8]]
    ) -> Bool {
        for pattern in patterns where kept.count >= pattern.count {
            let start = kept.count - pattern.count
            var index = pattern.count - 1
            while index >= 0, kept[start + index] == pattern[index] { index -= 1 }
            if index < 0 {
                kept.removeLast(pattern.count)
                return true
            }
        }
        return false
    }
}
