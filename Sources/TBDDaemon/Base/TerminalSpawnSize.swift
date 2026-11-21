/// The cell size a session opens at when its caller names none, and the
/// smallest size the daemon takes from the app's main-area broadcast.
enum TerminalSpawnSize {
    /// Larger than the conventional 80x24, so an agent does not render into
    /// hard-wrapped scrollback that cannot be reflowed once a wider viewer
    /// attaches. A caller's own size wins whenever it sends one.
    static let defaultCols = 220
    static let defaultRows = 50

    /// A main-area size below either bound is ignored: the app can report a
    /// degenerate size while its window is still being laid out, and the next
    /// valid size follows.
    static let minCols = 80
    static let minRows = 24
}
