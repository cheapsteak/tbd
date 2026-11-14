import Foundation

/// What a terminal engine tells the coordinator that runs it.
///
/// **Every method arrives on the main thread.** That includes the ones a parse
/// provokes: SwiftTerm hops each callback through `TerminalView.onMain`, an
/// unconditional `DispatchQueue.main.async`, so a callback the IO thread's
/// parse produces is queued on main during the parse and delivered a later
/// main-queue turn. Which turn matters in two places, and each is written on
/// the method it governs: `engine(_:send:)` for parser replies, and the ingest
/// mute that `TerminalEngine.ingestSnapshot(_:)` holds.
///
/// **What the engine swallows before it gets here.** While a snapshot preamble
/// is being ingested, `send`, `sizeChanged`, `engineBell` and `clipboardCopy`
/// are not called, and the preamble's OSC 777 notifications and OSC 7501
/// reports are never observed, so `notification` and `programStatusPayload`
/// cannot carry them. The preamble is replayed history: acting on it would type
/// replies into the child, ring stale bells and overwrite the pasteboard. While
/// the handback's mode probe is open, `send` is not called either; those bytes
/// are the terminal answering the panel, and the engine keeps them for the
/// handback.
@MainActor
protocol TerminalEngineDelegate: AnyObject {
    /// Bytes for the session's pty: keys, pastes, and the terminal's own
    /// replies to queries such as DA1, DSR, DECRQM and the OSC 7501 probe.
    ///
    /// A key or paste arrives in the main-thread turn after the event that
    /// produced it. A parser reply is queued on main while the parse runs and
    /// arrives a later main turn, in parse order: the OSC 7501 probe answer,
    /// which the parse writes synchronously, reaches here ahead of the DA1
    /// reply that follows it in the same chunk.
    func engine(_ e: any TerminalEngine, send data: ArraySlice<UInt8>)

    /// The terminal's grid has changed size. The engine has already resized
    /// its terminal, so `e.gridSize` reads the new size.
    func engine(_ e: any TerminalEngine, sizeChanged cols: Int, rows: Int)

    /// A BEL in live output.
    func engineBell(_ e: any TerminalEngine)

    /// An OSC 52 copy in live output.
    func engine(_ e: any TerminalEngine, clipboardCopy content: Data)

    /// A Cmd-click on a link or a path the terminal did not resolve itself: an
    /// OSC 8 hyperlink, or text the link detector matched.
    func engine(_ e: any TerminalEngine, openLink link: String, params: [String: String])

    /// An OSC 777 `notify;title;body` in live output, delivered only while the
    /// terminal's window is not the key window.
    func engine(_ e: any TerminalEngine, notification title: String, body: String)

    /// An OSC 7501 report (the raw data after `7501;`) read off live output,
    /// with the time it was observed. Never a probe, never replayed bytes, and
    /// only while `TerminalEngine.setProgramStatusReporting(enabled:)` is on.
    func engine(_ e: any TerminalEngine, programStatusPayload payload: [UInt8], observedAt: Date)

    /// A Cmd-click on a path the terminal resolved to a file.
    func engine(_ e: any TerminalEngine, filePathClicked path: String)

    /// The close-tab key equivalent, pressed while the terminal has focus.
    func engineRequestsCloseTab(_ e: any TerminalEngine)

    /// The view has been laid out with non-zero bounds, so the grid has its
    /// real size. Called once, a main turn after that first layout.
    func engineReady(_ e: any TerminalEngine)

    /// The view became, or stopped being, first responder, however focus
    /// moved. Called only while `TerminalEngine.setClickRouting(enabled:)` is
    /// on.
    func engine(_ e: any TerminalEngine, focusChanged focused: Bool)

    /// A left mouse-down landed on the terminal. Return true to take focus and
    /// let the terminal's own click handling run; false when something drawn
    /// over the terminal owns its events. Asked only while click routing is
    /// on; with it off, the terminal neither asks nor takes the click that
    /// activates its window.
    func engineMouseDownClaimsFocus(_ e: any TerminalEngine) -> Bool

    /// The view was inserted into a window, including a kept-alive pane that a
    /// tab switch puts back on screen.
    func engineMovedToWindow(_ e: any TerminalEngine)
}
