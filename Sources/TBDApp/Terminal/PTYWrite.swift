import Darwin
import Foundation

/// One non-blocking attempt to hand a payload to a pty master, from the app's
/// side.
///
/// Exists because the app writes to a session's pty as well as reading it (a
/// holder-backed panel holds its own `dup` of the master), and a single
/// `write(2)` to a tty is not a delivery: a raw-mode master accepts
/// `TTYHOG − 2` — measured at 1,022 bytes — and then refuses, so every payload
/// above a kilobyte into an agent session is short-written whenever the child
/// is not draining it at that instant.
///
/// ## Why it does not wait
///
/// It used to spend a 20 ms `poll(POLLOUT)` budget looking for room, because
/// there was nowhere to keep what the kernel refused: the budget's expiry was
/// the truncation point. `OutgoingInputQueue` now keeps the remainder and
/// finishes it on write-readiness, so waiting here buys nothing and costs the
/// main actor — the caller is `TerminalPanelView.performOutgoingWrite`, which
/// is synchronous, main-actor, and must answer in the turn a keystroke arrived
/// in. One `write(2)`, no `poll`, and the refusal is reported rather than
/// waited out.
///
/// **Nothing here decides where the payload is cut.** The kernel commits per
/// byte (`ptcwrite` feeds the tty queue a byte at a time and returns how many
/// it took), so a marker or a multi-byte UTF-8 sequence can be split. That is
/// healed by the *next* accepted bytes continuing the same stream with nothing
/// written in between — which is the outbox's hold, not this function's
/// business.
enum PTYWrite {
    /// What one attempt achieved. Three outcomes, and the middle one is not a
    /// failure: it is the normal shape of writing to a tty whose child is busy.
    enum Outcome: Equatable {
        /// Every byte reached the terminal's input queue.
        case complete
        /// The kernel took `written` bytes (possibly zero, for a queue that was
        /// already full) and refused the rest with `EAGAIN`. **The transport is
        /// alive**; the remainder is the caller's to keep and finish. The
        /// caller must not report this as a failed write — the prefix is
        /// committed and cannot be un-written, so a `false` here is what makes
        /// a sender re-send on top of it.
        case partial(written: Int)
        /// The descriptor rejected the write (`EIO` once the last slave closes,
        /// `EBADF` after teardown, …). Nothing more will ever land through it.
        /// `written` may be non-zero: a prefix can be committed and the
        /// descriptor die before the rest goes, and the caller needs to know
        /// both — it drops what it was holding *and* reports the write
        /// unwritten, because the honest answer to "did this arrive" for a
        /// child that is gone is no.
        case failed(errno: Int32, written: Int)
    }

    // The absence of the poll is not testable. A test that "proves" no wait
    // happens has to assert on elapsed time, and every threshold that
    // separates 0 ms from the old 20 ms budget is inside the noise of a loaded
    // shared box. What replaces the test is the type: there is no budget
    // parameter to pass, and no `poll` in the body. Reviewers enforce it.

    /// Write as much of `data` to `fd` as the kernel will take, right now.
    ///
    /// The pty master this is called on is `O_NONBLOCK` — the flag lives on the
    /// open file description the daemon opened and rides the `dup` (see
    /// `HolderAttachment.ptyFD`) — so `write` returns rather than parking the
    /// main actor. A blocking descriptor would park it, which is why this call
    /// must never be given one and must never change the flags out from under
    /// a concurrent reader.
    static func all(_ data: Data, to fd: Int32) -> Outcome {
        guard !data.isEmpty else { return .complete }
        guard fd >= 0 else { return .failed(errno: EBADF, written: 0) }
        return data.withUnsafeBytes { raw -> Outcome in
            var offset = 0
            while offset < raw.count {
                let written = Darwin.write(
                    fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                let code = errno
                if code == EAGAIN || code == EWOULDBLOCK {
                    return .partial(written: offset)
                }
                return .failed(errno: code, written: offset)
            }
            return .complete
        }
    }
}
