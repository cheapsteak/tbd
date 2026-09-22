import Foundation
import TBDShared
import os

/// The per-panel half of the terminal transport latency instrument: one small
/// lock-guarded object that watches every chunk of output on its way into the
/// emulator, and reports what it saw when that panel's view next draws.
///
/// See `docs/specs/2026-09-22-terminal-transport-latency-instrument-design.md`.
/// Two numbers come out of it, and they answer different questions:
///
/// - **The passive tap** (`noteChunk` + `noteDrawWillBegin`) measures
///   *bytes-waiting-for-a-draw*: how long the oldest chunk in a frame sat in
///   the emulator after being parsed and before the view started drawing. It
///   is identical in mechanism on both transports, because both arms feed
///   through `TerminalViewHolder.feed` and that one line of code takes the
///   timestamp. What it CANNOT see is everything before the app's read — which
///   is precisely where tmux sits — so it never compares transports by itself.
/// - **The echo probe** (`armEcho` + the match inside `noteChunk`) does. A
///   token is written through the panel's real keystroke path and the first
///   copy of it coming back is stamped at the same seam. That loop spans the
///   pty, the line discipline, and on tmux the server, so its number is the
///   transport's.
///
/// ## Line formats — pinned, because the scripts match them verbatim
///
/// All four are `.info` on subsystem `com.tbd.app`, category
/// `terminallatency`. `scripts/diag/terminal-latency-report.py` parses them.
///
///     draw transport=<t> terminal=<uuid> chunks=<n> oldestms=<f> newestms=<f> parsemaxms=<f> dropped=<n> vis=<0|1>
///     echo transport=<t> terminal=<uuid> seq=<n> ms=<f>
///     echolost transport=<t> terminal=<uuid> seq=<n>
///
/// (`echorefused terminal=<uuid> reason=<word>` is the fourth, and belongs to
/// `TerminalLatencyDiagnostic` — it is emitted for requests that never reach a
/// tap at all.)
///
/// ## Threading
///
/// `noteChunk` runs on the IO thread that owns the feed; `armEcho` and
/// `noteDrawWillBegin` run on the main actor. All three go through one
/// `OSAllocatedUnfairLock`, and every emission happens **outside** it — the
/// emit closure is a `Logger` call in production and a test's array append
/// otherwise, and neither belongs under a lock the IO thread holds per chunk.
///
/// The echo search is outside it too, and for the same reason: the main thread
/// takes this same unfair lock from `viewWillDraw`, so anything proportional to
/// a chunk's size must not run while the IO thread holds it. `noteChunk`
/// therefore *snapshots* the pending echo under the lock, searches outside it,
/// and re-acquires to commit — committing only if the pending echo is still the
/// one it snapshotted, since `armEcho` can land in that window. Two searches
/// never race each other: one panel's chunks arrive on one IO thread.
final class TerminalLatencyTap: @unchecked Sendable {
    /// How many un-drawn chunk timestamps one panel keeps. TBD feeds panels
    /// for unselected worktrees that never draw, so the ring is what bounds an
    /// off-screen panel's cost; the overflow is counted rather than silently
    /// discarded, so the eventual draw says how much it lost.
    static let ringCapacity = 512

    nonisolated static let logger = Logger(subsystem: "com.tbd.app", category: "terminallatency")

    let terminalID: UUID
    let transport: TerminalTransport

    /// Monotonic seconds. `Duration` is behaviour, `Date` is data, and every
    /// number here is behaviour — so uptime, never a wall clock, and never a
    /// `Date` difference. Read by `TerminalViewHolder.feed` and by
    /// `TBDTerminalView.viewWillDraw()` so both ends of a wait come off one
    /// source.
    let now: @Sendable () -> Double

    private let emit: @Sendable (String) -> Void

    /// Test seam: called by `noteChunk` after it has snapshotted the pending
    /// echo and before it commits, which is the one window where an `armEcho`
    /// from the main actor can invalidate a search already in flight. Empty in
    /// production, and never called while the lock is held.
    private let didSnapshotEcho: @Sendable () -> Void

    /// One pending token. There is at most one because the probe is
    /// deliberately stateless beyond it: a new request retires the old one as
    /// lost, which is also what bounds a lost echo — there is no timer here.
    private struct PendingEcho {
        let seq: UInt64
        let token: [UInt8]
        let sentAt: Double
        /// The last `token.count - 1` bytes seen, so a token split across two
        /// chunks still matches. Any shorter carry-over could straddle the
        /// boundary and be missed; any longer is wasted.
        var tail: [UInt8]
    }

    private struct State {
        /// Feed timestamps for chunks not yet reported by a draw, oldest
        /// first.
        var pendingFeeds: [Double] = []
        /// Chunks the ring had no room for since the last draw.
        var dropped: Int = 0
        /// The longest `feed` call since the last draw, in milliseconds.
        var parseMaxMs: Double = 0
        var echo: PendingEcho?
    }

    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(
        terminalID: UUID,
        transport: TerminalTransport,
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        emit: @escaping @Sendable (String) -> Void = { line in
            TerminalLatencyTap.logger.info("\(line, privacy: .public)")
        },
        didSnapshotEcho: @escaping @Sendable () -> Void = {}
    ) {
        self.terminalID = terminalID
        self.transport = transport
        self.now = now
        self.emit = emit
        self.didSnapshotEcho = didSnapshotEcho
    }

    /// The token written for `seq`: short lowercase ASCII, no escape bytes, and
    /// nothing a shell prompt or `cat` would transform. The probe appends a
    /// carriage return when it writes, so each token starts a fresh line and
    /// can never wrap mid-token; the matcher searches for the token WITHOUT
    /// that return, because the echo of a `\r` is `\r\n` on a cooked tty.
    static func token(seq: UInt64) -> [UInt8] {
        Array("lp\(seq)z".utf8)
    }

    // MARK: - The IO thread

    /// One chunk of output reached the feed seam. Called on the IO thread that
    /// owns the read, from `TerminalViewHolder.feed`, immediately after the
    /// emulator has parsed it.
    func noteChunk(_ bytes: ArraySlice<UInt8>, feedAt: Double, feedReturnedAt: Double) {
        let parseMs = (feedReturnedAt - feedAt) * 1000
        // Under the lock: only the ring and parse bookkeeping, both O(1), plus
        // a snapshot of the pending echo. The copy and the search are not here.
        let pending: PendingEcho? = state.withLockUnchecked { state in
            if state.pendingFeeds.count < Self.ringCapacity {
                state.pendingFeeds.append(feedAt)
            } else {
                state.dropped += 1
            }
            if parseMs > state.parseMaxMs { state.parseMaxMs = parseMs }
            return state.echo
        }
        guard let pending else { return }

        var haystack = pending.tail
        haystack.append(contentsOf: bytes)
        let found = Self.contains(haystack, pending.token)
        // Carry only what a match could still straddle.
        let carry = max(0, pending.token.count - 1)
        let tail = carry >= haystack.count ? haystack : Array(haystack.suffix(carry))

        didSnapshotEcho()

        let matched: (seq: UInt64, sentAt: Double)? = state.withLockUnchecked { state in
            // An `armEcho` may have landed while the search ran. A result
            // computed against the token it replaced must neither report that
            // token nor clear its successor — drop it and let the next chunk
            // match the live one.
            guard state.echo?.seq == pending.seq else { return nil }
            if found {
                state.echo = nil
                return (pending.seq, pending.sentAt)
            }
            state.echo?.tail = tail
            return nil
        }
        guard let matched else { return }
        // `feedAt`, not "now": the echo's arrival is the moment the bytes
        // reached the seam, the same endpoint the passive tap uses. Timing it
        // after the parse would fold the emulator's work into the transport's
        // number.
        emit(
            "echo transport=\(transport.rawValue)"
                + " terminal=\(terminalID.uuidString)"
                + " seq=\(matched.seq)"
                + " ms=\(Self.millis(feedAt - matched.sentAt))"
        )
    }

    // MARK: - The main actor

    /// Arm the tap for one outbound token. A token still pending is retired as
    /// lost first: the replacement rule is what bounds a lost echo, since this
    /// instrument owns no timer.
    func armEcho(seq: UInt64, token: [UInt8], sentAt: Double) {
        var lost: UInt64?
        state.withLockUnchecked { state in
            lost = state.echo?.seq
            state.echo = PendingEcho(seq: seq, token: token, sentAt: sentAt, tail: [])
        }
        guard let lost else { return }
        emit(
            "echolost transport=\(transport.rawValue)"
                + " terminal=\(terminalID.uuidString)"
                + " seq=\(lost)"
        )
    }

    /// This panel's view is about to draw. Reports the chunks that have been
    /// waiting and resets the window.
    ///
    /// A draw with nothing waiting — a caret blink — emits nothing, which is
    /// what keeps an idle panel silent. The line reports the OLDEST chunk's
    /// wait because that is the symptom: bytes parsed into the emulator and
    /// sitting there undrawn. One line per draw carries the tail exactly, since
    /// the oldest chunk in a frame is that frame's worst wait.
    func noteDrawWillBegin(at drawAt: Double, isOnScreen: Bool) {
        var taken: (feeds: [Double], dropped: Int, parseMaxMs: Double)?
        state.withLockUnchecked { state in
            guard !state.pendingFeeds.isEmpty else { return }
            taken = (state.pendingFeeds, state.dropped, state.parseMaxMs)
            state.pendingFeeds.removeAll(keepingCapacity: true)
            state.dropped = 0
            state.parseMaxMs = 0
        }
        guard let taken, let oldest = taken.feeds.first, let newest = taken.feeds.last else {
            return
        }
        emit(
            "draw transport=\(transport.rawValue)"
                + " terminal=\(terminalID.uuidString)"
                + " chunks=\(taken.feeds.count)"
                + " oldestms=\(Self.millis(drawAt - oldest))"
                + " newestms=\(Self.millis(drawAt - newest))"
                + " parsemaxms=\(Self.formatted(taken.parseMaxMs))"
                + " dropped=\(taken.dropped)"
                + " vis=\(isOnScreen ? 1 : 0)"
        )
    }

    // MARK: - Helpers

    /// Naive substring search. The needle is a handful of bytes and the
    /// haystack is one terminal chunk, so nothing cleverer earns its
    /// complexity here — and its caller runs it on the IO thread with the
    /// state lock RELEASED, so the main thread's `viewWillDraw` never waits
    /// behind a scan proportional to a chunk.
    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let last = haystack.count - needle.count
        var start = 0
        while start <= last {
            var offset = 0
            while offset < needle.count, haystack[start + offset] == needle[offset] {
                offset += 1
            }
            if offset == needle.count { return true }
            start += 1
        }
        return false
    }

    private static func millis(_ seconds: Double) -> String {
        formatted(seconds * 1000)
    }

    private static func formatted(_ milliseconds: Double) -> String {
        String(format: "%.3f", milliseconds)
    }
}
