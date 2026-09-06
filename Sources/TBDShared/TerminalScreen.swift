import Foundation

/// What a machine reader is told when it asks a session what is on its screen.
///
/// `terminal.output` used to answer with a bare `String`, and a string cannot
/// carry the two facts every consumer's policy turns on: **which store
/// answered**, and **how stale that store's view is**. A consumer reading text
/// alone cannot tell a live render from a frozen one, so it cannot have a
/// policy at all — it can only hope. Those two facts are `source` and
/// `ageMilliseconds`, and they are why this is a type rather than a string.
///
/// The second reason is the whitelist. Every cell that reaches `lines` is
/// printable or a tab: a never-written cell is projected as a space by the
/// render, the trailing half of a wide glyph is omitted, and every other
/// disallowed scalar is projected as `U+FFFD`. The render does that against
/// `isDisallowed`, the same predicate the initializer checks with, so the two
/// cannot disagree about what a screen line may hold.
///
/// **The render substitutes; the initializer refuses.** A child may legitimately
/// store a `DEL` or a C1 byte in a cell — SwiftTerm's ground-state fast path
/// keeps them verbatim — so refusing those at construction would make one
/// `printf '\x7f'` break every later read of the session until the line left
/// scrollback. Substituting at the render keeps the whitelist true without
/// making a session's own output able to silence it. What survives to the
/// initializer is therefore a *projection bug* rather than anything a session
/// can do: a render that forgot the predicate, or a producer that never ran
/// one. A bug is better raised at the boundary than shipped to a consumer that
/// matches on text and silently fails to find the characters on either side of
/// the hole. (1,595 `U+0000` cells were measured across five of nine live
/// sessions in one sweep, and no consumer had noticed.)
///
/// Plain data, in `TBDShared`, with no emulator in it. The projection from a
/// grid to these lines belongs to whichever store did the rendering; this is
/// only what comes out.
public struct TerminalScreen: Codable, Sendable, Equatable {
    /// Where the cursor sits, in **viewport** coordinates — so
    /// `lines[viewportStart + cursor.row]` is the cursor's line whenever that
    /// row survived the trailing-blank trim.
    public struct Cursor: Codable, Sendable, Equatable {
        public let row: Int
        public let column: Int
        /// Whether the child has asked for a visible cursor (`DECTCEM`, mode
        /// 25). A composer waiting for input and a program that has hidden the
        /// cursor to repaint look identical without it.
        ///
        /// **A tracked fact, not a probed one.** The holder producer keeps it
        /// from the emulator's own notifications, because probing a parser that
        /// may be mid-sequence would abort the child's sequence — so what this
        /// field can promise is bounded by which changes the emulator
        /// announces. Both resets stay inside that bound: a soft reset
        /// (`DECSTR`, `CSI ! p`) shows the cursor and says so, and a full reset
        /// (`RIS`) restores the visibility it found. A change made without a
        /// notification would sit here undetected, and a bare `DECSET 25` would
        /// not repair it, since an already-shown cursor is shown again silently
        /// — the mechanism, and the bound, are `HolderReader`'s `cursorVisible`.
        public let visible: Bool

        public init(row: Int, column: Int, visible: Bool) {
            self.row = row
            self.column = column
            self.visible = visible
        }
    }

    /// The grid the lines were rendered from. A consumer that compares this
    /// against the pty's own size can see an emulator that disagrees with the
    /// child — which is how a session ends up wrapping every line at a width
    /// nobody is painting at.
    public struct Size: Codable, Sendable, Equatable {
        public let columns: Int
        public let rows: Int

        public init(columns: Int, rows: Int) {
            self.columns = columns
            self.rows = rows
        }
    }

    /// The child-facing modes a writer needs before it composes input.
    ///
    /// Read from the same emulator that produced the lines, in the same
    /// observation, so a caller can never pair one store's modes with another
    /// store's screen.
    public struct ChildModes: Codable, Sendable, Equatable {
        /// `DECSET 2004`. Decides whether a pasted body is wrapped in
        /// `ESC[200~`…`ESC[201~`, which is what puts a submitting `\r`
        /// provably outside the paste.
        public let bracketedPaste: Bool
        /// `DECCKM`, mode 1. Decides `ESCOA` over `ESC[A` for the arrows.
        public let applicationCursor: Bool
        /// Whether the child is on the alternate screen buffer (`1049`).
        public let alternateScreen: Bool

        public init(bracketedPaste: Bool, applicationCursor: Bool, alternateScreen: Bool) {
            self.bracketedPaste = bracketedPaste
            self.applicationCursor = applicationCursor
            self.alternateScreen = alternateScreen
        }
    }

    /// Which of the transport's two stores answered.
    ///
    /// A consumer's policy is keyed on this field, so the policy cannot be
    /// applied by accident. Of the consumers the design names, two are on the
    /// contract today: the input-path oracle proceeds on `staleDaemon` modes
    /// and records the source on the actuation row, and a person reading `tbd
    /// terminal output` is shown the source and the age on stderr. The
    /// hibernation pending-input check is still on its own screen read; the
    /// policy it is to apply when it moves onto this contract is to fail closed
    /// on `staleDaemon`, because a frozen screen cannot prove the composer is
    /// empty.
    ///
    /// **The raw values must stay identical to `ActuationModeSource`'s.** A
    /// supervisor correlates the `screen.source` it read from `tbd terminal
    /// output --json` against the `modeSource` on the actuation row its send
    /// produced, and it does that by string comparison — so two spellings of
    /// one fact make exactly the case that matters, `staleDaemon`, fail to
    /// match. The default synthesised raw values are the wire spellings
    /// (`daemon`, `viewer`, `staleDaemon`); there is nothing to write out, and
    /// a case added here must be added there with the same name.
    /// `ActuationLogTests` pins the correspondence over `allCases`, which is
    /// what `CaseIterable` is here for.
    public enum Source: String, Codable, Sendable, CaseIterable {
        /// The daemon is this session's reader and rendered its live emulator.
        case daemon
        /// A viewer holds the pty and answered a pull from its own terminal.
        case viewer
        /// A viewer holds the pty and did not answer, so this is the daemon's
        /// emulator — retained and suspended since the attach.
        case staleDaemon
    }

    /// The requested tail of scrollback plus the viewport, one entry per row,
    /// right-trimmed, with trailing blank rows dropped.
    public let lines: [String]
    /// The index in `lines` of the viewport's first row; everything before it
    /// is scrollback.
    ///
    /// Carried explicitly because it cannot be derived: trailing blank rows are
    /// dropped, so `lines.count` is not `scrollback + size.rows` and a consumer
    /// that subtracted would land in the wrong row.
    ///
    /// **It may be negative**, when the requested tail cut inside the viewport
    /// — ask for 6 lines of a 24-row screen and the first four rows of that
    /// viewport are simply not in `lines`. **It may also exceed `lines.count`**,
    /// because the trailing-blank trim does not stop at the viewport's first
    /// row: a blank viewport over scrollback whose own last row is blank has
    /// both trimmed away, and the index is left past the end rather than at it.
    /// Both are well-formed answers, and a consumer indexing `lines` with it
    /// must bounds check rather than assume.
    public let viewportStart: Int
    public let cursor: Cursor
    public let size: Size
    public let modes: ChildModes
    public let source: Source
    /// How long ago the answering store's emulator last consumed a byte from
    /// the pty, in milliseconds, on a monotonic clock — never wall time, so no
    /// clock adjustment can defeat a staleness threshold.
    ///
    /// One rule for every source. A store that has never consumed a byte
    /// reports its own age, counted from adoption, so the field is never absent
    /// and a fresh silent session reads as exactly as old as it is. Always
    /// non-negative: the producer clamps and this type refuses the rest.
    public let ageMilliseconds: Int

    /// The lines joined with `\n`.
    ///
    /// Derived, carrying no information of its own, and kept for exactly one
    /// reason: scripts and skills read `tbd terminal output` today, and it is
    /// what lets the in-place change to this RPC result be invisible to every
    /// consumer that has not migrated. It is written to the wire by
    /// `encode(to:)` and ignored on the way back in.
    public var output: String { lines.joined(separator: "\n") }

    /// The three modes, their provenance, and their age — everything the input
    /// path needs and nothing it does not.
    public var modeReading: TerminalModeReading {
        TerminalModeReading(modes: modes, source: source, ageMilliseconds: ageMilliseconds)
    }

    /// Why a screen could not be constructed.
    ///
    /// Both cases are producer bugs rather than conditions a session can be in,
    /// which is why they are thrown rather than represented: a control
    /// character in a row means the projection is wrong, and a negative age
    /// means whoever measured it subtracted the wrong way round.
    public enum ValidationError: LocalizedError, Equatable, CustomStringConvertible {
        /// A row carried a character no screen line may contain: any C0 control
        /// but tab, `DEL`, or a C1 control.
        ///
        /// **Not something a child can cause.** A render substitutes every one
        /// of these — `U+0000` as a space, the rest as `U+FFFD` — using the
        /// same `isDisallowed` predicate checked here, so a session that prints
        /// a `DEL` produces a replacement character rather than an unreadable
        /// session. One arriving here means a render skipped the predicate.
        case disallowedCharacter(lineIndex: Int, scalar: UInt32)
        /// An age measured as a negative interval.
        case negativeAge(milliseconds: Int)

        public var description: String {
            switch self {
            case .disallowedCharacter(let lineIndex, let scalar):
                let hex = String(format: "%04X", scalar)
                return """
                    screen line \(lineIndex) carries the disallowed control character U+\(hex); \
                    a screen line may hold only printable characters and tabs
                    """
            case .negativeAge(let milliseconds):
                return "a screen's age cannot be negative, and this one is \(milliseconds)ms"
            }
        }

        /// `localizedDescription` consults only this, and the whole value of
        /// either message is the payload it names — the offending line, or the
        /// number that was measured. Forwarded so a log or an RPC error carries
        /// it rather than the `NSError` bridge string.
        public var errorDescription: String? { description }
    }

    /// The one construction site. Everything the type promises is checked here,
    /// so no caller can produce a screen that breaks it.
    public init(
        lines: [String],
        viewportStart: Int,
        cursor: Cursor,
        size: Size,
        modes: ChildModes,
        source: Source,
        ageMilliseconds: Int
    ) throws {
        guard ageMilliseconds >= 0 else {
            throw ValidationError.negativeAge(milliseconds: ageMilliseconds)
        }
        for (index, line) in lines.enumerated() {
            for scalar in line.unicodeScalars where Self.isDisallowed(scalar) {
                throw ValidationError.disallowedCharacter(lineIndex: index, scalar: scalar.value)
            }
        }
        self.lines = lines
        self.viewportStart = viewportStart
        self.cursor = cursor
        self.size = size
        self.modes = modes
        self.source = source
        self.ageMilliseconds = ageMilliseconds
    }

    /// Whether a scalar is one a screen line may not hold.
    ///
    /// Public and static because it has **two** call sites that must agree: the
    /// initializer below, which refuses, and each render's character provider,
    /// which substitutes. Two copies of this rule would drift, and the shape of
    /// the drift is a render that lets through exactly what the initializer
    /// throws on — a session whose every read fails.
    ///
    /// Tab is the one control a line may hold: a program that lays a screen out
    /// with tabs is doing something a reader can see, and stripping them would
    /// move every column after one.
    public static func isDisallowed(_ scalar: Unicode.Scalar) -> Bool {
        if scalar == "\t" { return false }
        let value = scalar.value
        return value < 0x20 || value == 0x7f || (0x80...0x9f).contains(value)
    }

    // MARK: - Coding

    private enum CodingKeys: String, CodingKey {
        case lines, viewportStart, cursor, size, modes, source, ageMilliseconds, output
    }

    /// Writes `output` beside `lines`, because it is a field a script reads out
    /// of `tbd terminal output --json` and a computed property would otherwise
    /// never reach the wire.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(lines, forKey: .lines)
        try container.encode(viewportStart, forKey: .viewportStart)
        try container.encode(cursor, forKey: .cursor)
        try container.encode(size, forKey: .size)
        try container.encode(modes, forKey: .modes)
        try container.encode(source, forKey: .source)
        try container.encode(ageMilliseconds, forKey: .ageMilliseconds)
        try container.encode(output, forKey: .output)
    }

    /// **Any `output` on the wire is ignored** and the field is re-derived from
    /// `lines`, so the two can never disagree in a decoded value — including
    /// for a payload that carries no `output` at all, which is what a future
    /// producer that stopped writing it would send.
    ///
    /// Decoding runs the same validation construction does. A screen that
    /// arrives with a control character in it is refused at the boundary rather
    /// than handed on, for the same reason it is refused at the producer.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            lines: container.decode([String].self, forKey: .lines),
            viewportStart: container.decode(Int.self, forKey: .viewportStart),
            cursor: container.decode(Cursor.self, forKey: .cursor),
            size: container.decode(Size.self, forKey: .size),
            modes: container.decode(ChildModes.self, forKey: .modes),
            source: container.decode(Source.self, forKey: .source),
            ageMilliseconds: container.decode(Int.self, forKey: .ageMilliseconds))
    }
}

/// The mode oracle's answer: what the child is in, who says so, and how old
/// that answer is.
///
/// A `TerminalScreen` without the line walk. The input path needs the three
/// modes and their provenance and nothing else, and asking for a whole screen
/// to compose one message would walk the scrollback on every send.
public struct TerminalModeReading: Sendable, Equatable {
    public let modes: TerminalScreen.ChildModes
    public let source: TerminalScreen.Source
    public let ageMilliseconds: Int

    public init(
        modes: TerminalScreen.ChildModes, source: TerminalScreen.Source, ageMilliseconds: Int
    ) {
        self.modes = modes
        self.source = source
        self.ageMilliseconds = ageMilliseconds
    }
}
