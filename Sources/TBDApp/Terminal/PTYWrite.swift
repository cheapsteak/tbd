import Darwin
import Foundation

/// Writing a whole payload to a pty master, from the app's side.
///
/// Exists because the app now writes to a session's pty as well as reading it
/// (a holder-backed panel holds its own `dup` of the master), and a single
/// `write(2)` to a tty is not a delivery: the terminal's input queue is small
/// — a few hundred bytes to a couple of KiB — so a multi-KiB injected prompt
/// short-writes routinely whenever the child is not draining it fast.
///
/// ## Why it waits at all, and why so briefly
///
/// The caller is `TerminalPanelView.performOutgoingWrite`, which is
/// synchronous and main-actor: it has to answer "did this go out?" in the turn
/// the bytes arrived in, because that answer is the ack the daemon reads and
/// because a keystroke must not acquire a scheduling hop. So the wait is a
/// `poll(POLLOUT)` loop with a **20 ms** ceiling — enough for the kernel to
/// hand a few buffer-fulls to a child that is reading, far too short to be
/// felt as typing latency, and self-limiting for a child that is not reading
/// at all (the budget expires once and the payload is refused).
enum PTYWrite {
    /// What one attempt achieved. Three outcomes, not two, because the middle
    /// one is the case that decides how the daemon's fail-open fallback
    /// behaves.
    enum Outcome: Equatable {
        /// Every byte reached the terminal's input queue.
        case complete
        /// Nothing was written — the queue was full for the whole budget, or
        /// the descriptor is gone. The clean refusal: the caller reports
        /// `false`, the daemon rewrites the payload itself, and the session
        /// sees it exactly once.
        case nothingWritten
        /// A prefix went and the rest did not. The caller reports it as a
        /// failure — and what that buys today is less than it looks.
        ///
        /// The intent is that the daemon rewrites the whole payload on top of
        /// the prefix: visibly doubled rather than quietly truncated, the
        /// deliberate side of the fork this design takes everywhere. **The
        /// daemon usually cannot do that**, and least of all in the state this
        /// case arises in. A short write happens while a viewer is attached
        /// and its child is not draining; an acknowledged attach has already
        /// released the daemon's reader and closed its descriptor, so
        /// `HolderInjectionCourier`'s fallback finds nothing to write to and
        /// answers `.notDelivered`. What is actually left behind is a
        /// truncated fragment on the session and a transport error at the
        /// caller — the duplicate-versus-loss fork resolved, here, on the loss
        /// side.
        ///
        /// The behavior stands rather than being patched because whether the
        /// daemon can rewrite is the descriptor question — whether it keeps a
        /// **write-only** dup across an attach — and that is a human decision
        /// already filed. Decided one way, the paragraph above becomes true as
        /// written and nothing here changes; decided the other, this is where
        /// the honest resolution goes.
        case partial(written: Int)
        /// The descriptor rejected the write outright (`EIO` on a pty whose
        /// child is gone, `EBADF`, …). Nothing was written.
        case failed(errno: Int32)
    }

    /// Default ceiling on how long one call may spend waiting for room.
    static let defaultBudgetMilliseconds: Int32 = 20

    /// Write all of `data` to `fd`, waiting for room only within `budget`.
    ///
    /// The pty master this is called on is `O_NONBLOCK` — the flag lives on the
    /// open file description the daemon opened and rides the `dup` (see
    /// `HolderAttachment.ptyFD`) — so `write` returns rather than parking the
    /// main actor, and the `poll` below is the only waiting that happens. A
    /// blocking descriptor would still be correct here, just less bounded; the
    /// flags belong to whoever vended the descriptor and this call must not
    /// change them out from under a concurrent reader.
    static func all(
        _ data: Data, to fd: Int32,
        budgetMilliseconds budget: Int32 = defaultBudgetMilliseconds
    ) -> Outcome {
        guard !data.isEmpty else { return .complete }
        guard fd >= 0 else { return .nothingWritten }
        return data.withUnsafeBytes { raw -> Outcome in
            var offset = 0
            var remaining = budget
            while offset < raw.count {
                let written = Darwin.write(
                    fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0, errno == EINTR { continue }
                guard written < 0, errno == EAGAIN || errno == EWOULDBLOCK else {
                    let code = errno
                    return offset == 0 ? .failed(errno: code) : .partial(written: offset)
                }
                guard remaining > 0 else {
                    return offset == 0 ? .nothingWritten : .partial(written: offset)
                }
                // Slices rather than one long wait, so a descriptor that never
                // becomes writable still costs at most `budget` in total and a
                // spurious `EINTR` from `poll` does not restart the clock.
                let slice = min(remaining, 5)
                var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&watched, 1, slice)
                if ready < 0, errno != EINTR {
                    let code = errno
                    return offset == 0 ? .failed(errno: code) : .partial(written: offset)
                }
                remaining -= slice
            }
            return .complete
        }
    }
}
