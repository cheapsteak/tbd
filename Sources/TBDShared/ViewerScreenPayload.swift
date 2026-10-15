import Foundation

/// A viewer's half of a screen: everything the app can honestly say about the
/// terminal it is holding, and nothing it cannot.
///
/// The pty-holder transport has two stores, and while a viewer is attached its
/// SwiftTerm is the live one
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`). When a
/// machine read or the input path needs that store, the daemon asks for it over
/// the FD sidecar and the app answers with this — **not** with a
/// `TerminalScreen`.
///
/// ## Why not a `TerminalScreen`
///
/// Three of a screen's fields are facts about *which emulator answered and how
/// it came to exist*, and an app filling them in would be inventing them:
///
/// - **`source`** is a routing fact. Only the daemon knows the answer came from
///   a pull rather than from its own emulator.
/// - **`modesObserved` / `contentObserved`** say whether the answering emulator
///   watched the child from birth. A viewer's emulator was seeded by the
///   daemon's attach preamble and "can hand back no more than the daemon gave
///   it", so the honest values are the daemon reader's — not the app's.
/// - **Validation belongs where the throw is handled.** `TerminalScreen`'s
///   initializer refuses a disallowed character, and constructing on the daemon
///   side turns a broken projection into `terminal.output`'s existing error
///   naming the offending line, instead of a silent empty answer.
///
/// So the app sends what it can see and the daemon stamps the rest.
///
/// ## Cursor visibility is the one fact a viewer answer cannot promise
///
/// `DECTCEM` is not readable from any public SwiftTerm property. The daemon's
/// emulator gets it by implementing `showCursor`/`hideCursor` on its own
/// `TerminalDelegate`; the app's view *is* SwiftTerm's `TerminalView`, which
/// implements that protocol itself and forwards neither to a view delegate. The
/// one remaining route — a `DECRQM 25` probe — is forbidden against a live
/// parser, because an `ESC` fed into a terminal whose last chunk ended
/// mid-sequence aborts the child's pending sequence.
///
/// So a viewer answer reports the **mode default** (`DECTCEM` is set, the
/// cursor is shown) and says so on `cursorVisibleObserved`, which is the same
/// provenance axis `modesObserved` carries for an emulator reporting a fresh
/// terminal's defaults: the value is there, and the flag says to read it as a
/// default rather than as an observation. Nothing is lost today — the only
/// consumer of a screen's cursor is the hibernation pending-input rail, and
/// that rail refuses a `.viewer` screen outright, because a live screen
/// somebody is sitting at the keyboard of cannot prove the composer is empty.
/// A producer that one day *can* observe it flips one line here rather than
/// changing the wire.
public struct ViewerScreenPayload: Codable, Sendable, Equatable {
    /// The requested tail of scrollback plus the viewport, one entry per row,
    /// right-trimmed, with trailing blank rows dropped — produced by
    /// `TerminalScreenProjection`, the same walk the daemon's own emulator
    /// uses, so the two stores project identically by construction.
    public let lines: [String]
    /// The index in `lines` of the viewport's first row. `TerminalScreen`'s
    /// field of the same name, with the same two documented out-of-range cases,
    /// derived by the shared projection rather than by the app.
    public let viewportStart: Int
    /// The cursor in viewport coordinates.
    public let cursorRow: Int
    public let cursorColumn: Int
    /// Whether the child has asked for a visible cursor — **the mode default
    /// unless `cursorVisibleObserved` is true.** See the type's doc.
    public let cursorVisible: Bool
    /// Whether `cursorVisible` is an observation rather than the `DECTCEM`
    /// default. A viewer answer sends `false`, structurally, for as long as
    /// SwiftTerm's `TerminalView` keeps `showCursor`/`hideCursor` to itself.
    public let cursorVisibleObserved: Bool
    public let columns: Int
    public let rows: Int
    public let bracketedPaste: Bool
    public let applicationCursor: Bool
    public let alternateScreen: Bool
    /// How long ago this store last consumed a byte from the pty, in
    /// milliseconds.
    ///
    /// **The app measures an interval, not an instant.** It reports its own
    /// monotonic duration since its last byte and the daemon forwards it, so no
    /// clock has to be shared between the two processes — which is what lets
    /// the screen contract keep one age rule for every source without either
    /// side trusting the other's notion of now. A store that has never consumed
    /// a byte reports the age of the store itself, counted from its attach, the
    /// same way the daemon's emulator falls back to its adoption.
    ///
    /// Never negative. The daemon clamps on receipt anyway, because
    /// `TerminalScreen` refuses a negative age and an app-side clock seam that
    /// ever ran backwards must not be able to fail a machine read.
    public let ageMilliseconds: Int

    public init(
        lines: [String],
        viewportStart: Int,
        cursorRow: Int,
        cursorColumn: Int,
        cursorVisible: Bool,
        cursorVisibleObserved: Bool,
        columns: Int,
        rows: Int,
        bracketedPaste: Bool,
        applicationCursor: Bool,
        alternateScreen: Bool,
        ageMilliseconds: Int
    ) {
        self.lines = lines
        self.viewportStart = viewportStart
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.cursorVisible = cursorVisible
        self.cursorVisibleObserved = cursorVisibleObserved
        self.columns = columns
        self.rows = rows
        self.bracketedPaste = bracketedPaste
        self.applicationCursor = applicationCursor
        self.alternateScreen = alternateScreen
        self.ageMilliseconds = ageMilliseconds
    }

    /// The three child modes, in the shape the input path's oracle and
    /// `TerminalScreen` both read them.
    ///
    /// Flattened on the wire rather than nested, because the reply is a JSON
    /// payload on a per-send latency path and a nested object buys nothing; the
    /// composed value is what every consumer wants.
    public var modes: TerminalScreen.ChildModes {
        TerminalScreen.ChildModes(
            bracketedPaste: bracketedPaste,
            applicationCursor: applicationCursor,
            alternateScreen: alternateScreen)
    }

    /// The grid the lines were rendered from.
    public var size: TerminalScreen.Size {
        TerminalScreen.Size(columns: columns, rows: rows)
    }

    /// The cursor, in the shape `TerminalScreen` holds it.
    ///
    /// `TerminalScreen.Cursor` has no provenance field of its own, so
    /// `cursorVisibleObserved` does not survive this conversion — which is
    /// correct for the one screen a consumer can reach, because a `.viewer`
    /// screen's cursor is refused by the only consumer that reads one. A
    /// consumer that needs the flag reads it from the payload.
    public var cursor: TerminalScreen.Cursor {
        TerminalScreen.Cursor(row: cursorRow, column: cursorColumn, visible: cursorVisible)
    }
}
