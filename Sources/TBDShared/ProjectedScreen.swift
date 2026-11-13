// What one walk of a terminal grid yields for a typed screen, whichever emulator
// it walked. Here beside `TerminalScreen` rather than in either walk's module,
// so a producer that links only one emulator still names the same type:
// `TerminalScreenProjection` (SwiftTerm) and `GhosttyScreenProjection`
// (libghostty) both return it.

/// Everything a `TerminalScreen` needs that can be read from a grid, and
/// nothing that cannot.
///
/// The split is the point. A screen's lines, its viewport offset, its cursor
/// *position*, its size and the three child modes are all properties of a
/// `Terminal`, so one walk can produce them for either store. A screen's
/// `source`, `ageMilliseconds`, `modesObserved`, `contentObserved` and its
/// cursor's *visibility* are not: they are facts about which emulator answered,
/// how it came to exist and what it was told, and only the daemon knows them.
/// So this type carries the first set and the daemon stamps the second —
/// which is also why nothing here throws. `TerminalScreen`'s construction is
/// the one place the whitelist is enforced, and it is enforced where the throw
/// can be handled.
public struct ProjectedScreen: Sendable, Equatable {
    /// The requested tail of scrollback plus the viewport, one entry per row,
    /// right-trimmed, with trailing blank rows dropped.
    public let lines: [String]
    /// The index in `lines` of the viewport's first row — `TerminalScreen`'s
    /// field of the same name, with the same two documented out-of-range
    /// cases, derived here so the two stores cannot disagree about the
    /// arithmetic.
    public let viewportStart: Int
    /// The cursor in viewport coordinates. **Position only**: visibility is
    /// `DECTCEM`, which no public SwiftTerm property exposes and which a
    /// `DECRQM` probe must not be used to read (see
    /// `TerminalScreenProjection.project`), so whoever tracks the child's
    /// notifications supplies it.
    public let cursorRow: Int
    public let cursorColumn: Int
    public let size: TerminalScreen.Size
    public let modes: TerminalScreen.ChildModes

    public init(
        lines: [String],
        viewportStart: Int,
        cursorRow: Int,
        cursorColumn: Int,
        size: TerminalScreen.Size,
        modes: TerminalScreen.ChildModes
    ) {
        self.lines = lines
        self.viewportStart = viewportStart
        self.cursorRow = cursorRow
        self.cursorColumn = cursorColumn
        self.size = size
        self.modes = modes
    }
}
