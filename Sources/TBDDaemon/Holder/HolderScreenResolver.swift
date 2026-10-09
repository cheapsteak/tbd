import Foundation
import TBDShared
import os

/// What the resolver needs from the daemon's own store for one session.
///
/// Two facts, bound together because they come from one reader and a caller
/// must not pair one reader's screen with another's provenance. Built from
/// `HolderRegistry.reader(for:)` in production and from a double in a test,
/// which is what lets the three-way decision below be exercised without a real
/// pty, a real holder and a real attach.
struct HolderDaemonStore: Sendable {
    /// The reader's own typed screen, at the requested depth. **The reader
    /// stamps `source` itself**, from its own drain state, which is the only
    /// place it can be read honestly.
    let screen: @Sendable (Int) async throws -> TerminalScreen
    /// Whether this reader's emulator was built with its child, so its mode
    /// flags and its grid are observations rather than a fresh terminal's
    /// defaults over a blank screen. A `nonisolated let` on the reader, so
    /// reading it costs nothing and cannot race.
    let observedChildFromStart: Bool
}

/// Which of the transport's two stores answers a machine read — and the single
/// place that decision lives.
///
/// The pty-holder transport has two stores: the daemon's retained emulator
/// while a session is detached, a viewer's SwiftTerm while it is attached
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`). Before
/// this type, every consumer asked the daemon's reader and got whatever it had
/// — which is right while detached and a frozen screen while attached. This is
/// the piece that reaches the live one.
///
/// ## Who is reading is asked once, of the ledger that knows
///
/// The routing decision reads `HolderRegistry.ptyReader(for:)`, the census
/// ledger's per-session answer, and nothing else. That matters because the
/// registry holds three facts that each *look* like the answer and are not:
/// `reader(for:)` answers for a suspended reader as well as a draining one,
/// `viewerAttachment(for:)` deliberately conflates an acknowledged attach with
/// one that timed out, and `isDraining` describes a loop rather than a store.
/// Composing an answer out of them here would be a second answer to a question
/// the census already answers, free to drift from it.
///
/// So the division is: **the ledger decides whether to pull; the reader stamps
/// what it honestly is.** `HolderReader.screen` reads its own drain state for
/// `source`, and this type never overrides that — the one source it sets
/// itself is `.viewer`, which no reader can produce because it describes an
/// answer that did not come from one.
///
/// ## The three ways, and what each costs
///
/// - **`.daemon`** — the daemon is this session's reader and its emulator is
///   live. Answer from it and **send no frame at all**. This is the ordinary
///   fleet case, and it is why a thousand detached sessions pay nothing for
///   this path existing.
/// - **`.viewer(attach:)`** — a viewer holds the pty. Pull, and on an answer
///   compose a `.viewer` screen with the provenance taken from the *daemon's*
///   reader (below). On any non-answer, **re-read the daemon's reader and take
///   whatever source it honestly reports then** — normally `.staleDaemon`, but
///   `.daemon` if the viewer detached while the pull was in flight and the
///   reader has resumed draining. Hard-coding `.staleDaemon` on the failure
///   path would label a live screen stale, and the re-read costs one actor hop.
/// - **`nil`** — nobody is reading. A published reader still answers (it
///   reports `.staleDaemon`, which is the truthful reading of an emulator
///   nothing is feeding); with no published reader there is nothing to answer
///   with, and the caller's own error says which.
///
/// ## Why the daemon composes the viewer's screen
///
/// The reply carries a `ViewerScreenPayload`, not a `TerminalScreen`, and the
/// three fields it omits are the reason. `modesObserved` and `contentObserved`
/// are facts about whether an emulator watched the child from birth; a
/// viewer's was seeded by the daemon's attach preamble and "can hand back no
/// more than the daemon gave it", so the honest values are the daemon reader's.
/// `source` is a routing fact only this type knows. And validation belongs
/// where the throw is handled: constructing here means a broken app-side
/// projection surfaces as `terminal.output`'s existing error naming the
/// offending line, instead of a silent empty answer.
///
/// **"The app answered, so the screen must be observed" is the plausible wrong
/// reading**, and it is wrong in exactly the case that matters: a session the
/// daemon re-adopted after a restart answers `false` on both flags for that
/// emulator's whole life, and attaching a viewer to it does not earn
/// provenance the daemon never had.
struct HolderScreenResolver: Sendable {
    private static let logger = Logger(
        subsystem: "com.tbd.daemon", category: "holderScreenResolver")

    /// Who the census says is reading a session's pty right now.
    private let ptyReader: @Sendable (UUID) async -> PtyReaderRole?
    /// The daemon's own store for a session, or nil when it publishes none.
    private let daemonStore: @Sendable (UUID) async -> HolderDaemonStore?
    /// The pull, or nil in a daemon with no sidecar wiring — the tmux-only
    /// configuration, which then resolves straight from the reader as before.
    private let pull: HolderScreenPull?
    /// The daemon's retained scrollback depth, which caps what a viewer is
    /// asked for so the contract does not vary by who is looking.
    private let retainedScrollbackLines: Int

    init(
        ptyReader: @escaping @Sendable (UUID) async -> PtyReaderRole?,
        daemonStore: @escaping @Sendable (UUID) async -> HolderDaemonStore?,
        pull: HolderScreenPull?,
        retainedScrollbackLines: Int = HolderReader.scrollbackLines
    ) {
        self.ptyReader = ptyReader
        self.daemonStore = daemonStore
        self.pull = pull
        self.retainedScrollbackLines = retainedScrollbackLines
    }

    /// The typed screen for `terminalID`, from whichever store is live.
    ///
    /// - Returns: nil when the daemon publishes no reader for this session —
    ///   it is gone, was never adopted, or is mid-transition. The caller turns
    ///   that into the error it has always produced.
    /// - Throws: only what `TerminalScreen`'s construction refuses, which is a
    ///   projection bug on whichever side produced the lines rather than a
    ///   state a session can be in.
    func screen(terminalID: UUID, maxLines: Int) async throws -> TerminalScreen? {
        guard let store = await daemonStore(terminalID) else { return nil }
        guard case .viewer = await ptyReader(terminalID) else {
            // `.daemon` and `nil` both answer from the reader, and the reader
            // stamps which of the two it is. No frame is sent, so a detached
            // session pays nothing.
            return try await store.screen(maxLines)
        }
        guard let pull else { return try await store.screen(maxLines) }

        let answer = await pull.pull(
            terminalID: terminalID,
            lines: maxLines,
            retainedScrollbackLines: retainedScrollbackLines,
            wantStyledCapture: false)
        switch answer {
        case .answered(let payload, _):
            return try Self.screen(from: payload, provenance: store.observedChildFromStart)
        case .refused, .undeliverable, .timedOut:
            // The honest re-read: whatever the reader says *now*. A viewer that
            // detached while the pull was in flight has left the reader
            // draining again, and calling that stale would make the
            // hibernation rail refuse a park it could safely take.
            return try await store.screen(maxLines)
        }
    }

    /// Compose a viewer's answer into a screen, with the provenance the daemon
    /// knows and the viewer cannot.
    ///
    /// The age is clamped on receipt as well as at the producer, and neither
    /// clamp makes the other redundant: the producer's keeps a bad measurement
    /// off the wire, and this one keeps a bad *sender* from failing a machine
    /// read, because `TerminalScreen` refuses a negative age.
    private static func screen(
        from payload: ViewerScreenPayload, provenance: Bool
    ) throws -> TerminalScreen {
        try TerminalScreen(
            lines: payload.lines,
            viewportStart: payload.viewportStart,
            cursor: payload.cursor,
            size: payload.size,
            modes: payload.modes,
            // From the daemon's reader, never from the payload — see the type's
            // doc. A re-adopted session stays unobserved on both axes through
            // every attach, and a viewer answering for it does not change that.
            modesObserved: provenance,
            contentObserved: provenance,
            source: .viewer,
            ageMilliseconds: max(0, payload.ageMilliseconds))
    }
}
