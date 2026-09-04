import Foundation
import TBDTerminalSerialization

/// Reading a *view's* terminal modes, which cannot be done the way the daemon
/// does it.
///
/// `TerminalModeCapture` needs a `DECRQM` answer for every mode SwiftTerm keeps
/// private, and the only way to get one is to feed the query and catch what the
/// terminal sends back. The daemon's `DelegateModeReader` catches each answer
/// synchronously, inside the same `feed` call, because its emulator's delegate
/// is called straight out of the parser.
///
/// **A view's is not.** `MacTerminalView.send(source:data:)` hands every reply
/// to `onMain`, an unconditional `DispatchQueue.main.async`
/// (`AppleTerminalView.swift`), so nothing a query provokes has been delivered
/// by the time `feed` returns — a synchronous reader against a view reads
/// nothing at all and reports every mode as reset. That is not a cosmetic loss:
/// wraparound and cursor-visible are *on* by default, so "no answer" would hand
/// the daemon back a screen with autowrap off and the cursor hidden.
///
/// So the app asks in one batch and reads the answers a main-queue turn later —
/// the same FIFO argument the snapshot ingest rests on: the parse enqueues its
/// replies during `feed`, and a block appended afterwards runs behind all of
/// them. This type is the second half of that: the collected bytes, parsed by
/// mode.
enum HolderHandback {
    /// Every mode `TerminalModeCapture` asks about, as one `DECRQM` batch.
    ///
    /// Kept in lockstep with `TerminalModeCapture.capture` by construction:
    /// `capture` reads `cols`, `rows`, the cursor, the alt-screen flag,
    /// `applicationCursor`, `bracketedPaste` and the scroll region from public
    /// properties, and asks `requestMode` for exactly these. A mode missing
    /// here is answered nil and read as reset, which is the same failure the
    /// batch exists to prevent — so add to both or neither.
    static let modeProbe: String = {
        let privateModes = [1003, 1002, 1000, 66, 6, 7, 45, 69, 25, 1006, 1004]
        let ansiModes = [4]
        let queries = privateModes.map { "\u{1b}[?\($0)$p" } + ansiModes.map { "\u{1b}[\($0)$p" }
        return queries.joined()
    }()

    /// How much scrollback the viewer hands back.
    ///
    /// The same figure the daemon sends *out* on an attach
    /// (`HolderReader.scrollbackLines`), because the two directions carry the
    /// same screen and a viewer that handed back less would shrink a session's
    /// history a little on every tab close.
    static let handbackScrollbackLines = 5_000
}

/// The answers to one `HolderHandback.modeProbe`, read out of the bytes the
/// terminal sent back.
///
/// Pure: it feeds nothing and asks nothing, so it is safe to hand to
/// `TerminalSnapshotWriter` inside the terminal's own lock.
struct RecordedModeReplies: ModeReplyReader {
    /// Everything the terminal replied during the probe window, concatenated.
    let reply: String

    init(bytes: [UInt8]) {
        // Bytes that are not valid UTF-8 are no answer at all rather than a
        // mangled one — every reply here is a CSI sequence of digits and
        // punctuation — which matches what the daemon's reader does with the
        // same input.
        reply = String(bytes: bytes, encoding: .utf8) ?? ""
    }

    /// `CSI ? Pd ; Ps $y`, where `Ps` is 1 set, 2 reset, 4 permanently reset and
    /// 0 unknown.
    ///
    /// Located rather than matched whole, because the batch's answers arrive
    /// concatenated and in whatever order the terminal chose — but **anchored on
    /// the CSI introducer**, so that "mode 7" cannot be found inside the answer
    /// for mode 1007. That anchoring is the only thing that makes one batch
    /// safe to parse; the daemon's reader takes the same precaution against the
    /// same hazard for a different reason.
    func requestMode(_ mode: Int, decPrivate: Bool) -> Int? {
        let prefix = decPrivate ? "?" : ""
        guard let head = reply.range(of: "\u{1b}[\(prefix)\(mode);"),
              let tail = reply[head.upperBound...].range(of: "$y")
        else { return nil }
        return Int(reply[head.upperBound..<tail.lowerBound])
    }
}
