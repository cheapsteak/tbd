import AppKit
import Foundation

/// One terminal emulator and the view that draws it, as the coordinators that
/// run a terminal see it.
///
/// `TerminalPanelRepresentable`'s coordinator and `LocalPTYTerminalView`'s talk
/// to this protocol, never to SwiftTerm directly, so a second emulator can stand
/// behind them without either coordinator changing. The design and the reasons
/// for each part are in `docs/specs/2026-11-07-libghostty-terminal-engine-design.md`.
///
/// ## Threads
///
/// The engine is main-actor, and so is everything on it except `feed(_:)`.
///
/// - `feed(_:)` is callable from any thread. The IO thread calls it for live
///   output, through `TerminalViewHolder`. The engine serialises it with every
///   other read and write of the model under its own lock.
/// - `withScreen(_:)` takes that same lock, so a read never races a feed.
/// - Every `TerminalEngineDelegate` method arrives on main. A callback that a
///   parse provokes, on whatever thread the parse ran, is queued on main
///   during the parse and delivered a later main-queue turn.
/// - **Parser replies take that path too.** A reply the parser writes, such as
///   the OSC 7501 probe answer or a DECRQM report, is produced inside the parse,
///   in parse order, and reaches `TerminalEngineDelegate.engine(_:send:)` a
///   main-queue turn after the `feed` that provoked it. The OSC 7501 answer is
///   written synchronously by a handler inside the parse precisely so it is
///   queued ahead of the DA1 reply that follows the probe in the same chunk;
///   Claude Code settles the protocol off when DA1's reply arrives first.
@MainActor
protocol TerminalEngine: AnyObject, Sendable {
    /// Which emulator this is.
    var kind: TerminalEngineKind { get }
    /// What SwiftUI embeds, what focus targets, and what the scroll monitor
    /// hit-tests. The engine owns it.
    var view: NSView { get }
    /// Where the engine reports. Held weakly.
    var delegate: (any TerminalEngineDelegate)? { get set }
    /// The panel's facts about this terminal. Reads and writes go straight to
    /// the view, so the engine never holds a second copy that could go stale.
    var configuration: TerminalEngineConfiguration { get set }

    // MARK: Input

    /// Live bytes from the session. Callable from any thread.
    nonisolated func feed(_ bytes: ArraySlice<UInt8>)
    /// Called before a preamble goes into a view that has been used before.
    func prepareForPreamble()
    /// Feeds a snapshot preamble so that no callback, OSC event or pty reply it
    /// provokes reaches the delegate.
    ///
    /// The rule is about that outcome, not about timing: the mute stays up
    /// until every callback the preamble queued has been delivered and dropped.
    /// Feed the preamble before live output is wired to this engine, because
    /// the mute cannot tell a preamble's callbacks from live ones.
    func ingestSnapshot(_ data: Data)
    /// Whether a snapshot preamble is being ingested, so its callbacks are
    /// being dropped.
    var isIngestingSnapshot: Bool { get }
    /// Draws a status line of the app's own, such as a placard or a detach
    /// notice. Not session output.
    func writeLocalText(_ text: String)

    // MARK: Locked reads

    /// Runs `body` with the model locked. One hold for every read a caller
    /// needs from one observation; see `TerminalScreenReader`.
    ///
    /// Main-actor, because SwiftTerm's `withTerminal` is.
    func withScreen<T>(_ body: (any TerminalScreenReader) throws -> T) rethrows -> T

    // MARK: Handback

    /// The VT text that recreates this terminal's screen, history and modes in
    /// another emulator, written when a viewer hands its session back.
    ///
    /// Async because SwiftTerm's handback first sends the terminal a DECRQM
    /// probe and waits a main-queue turn for its replies.
    func handbackPreamble(maxScrollbackLines: Int) async -> Data
    /// Whether `handbackPreamble` is collecting its probe's replies right now.
    /// While it is, `engine(_:send:)` is not called.
    var isCollectingHandbackReplies: Bool { get }

    // MARK: Geometry (main thread)

    var gridSize: (cols: Int, rows: Int) { get }
    var cellSize: CGSize { get }
    /// The grid cell under a point in window coordinates, or nil off the grid.
    func gridPosition(atWindowLocation point: CGPoint) -> (col: Int, row: Int)?

    // MARK: Appearance and routing

    /// Applies font, colours, cursor style and stroke weight now.
    func apply(appearance: AppearanceSettings)
    /// Asks for the GPU draw path. Returns whether it engaged now. SwiftTerm
    /// only; an engine that always draws with Metal returns true.
    @discardableResult
    func applyRendererPreference(metalEnabled: Bool) -> Bool
    /// Whether the terminal answers the OSC 7501 probe and forwards its reports.
    func setProgramStatusReporting(enabled: Bool)
    /// Whether clicks and focus changes are routed to the delegate. Off, the
    /// terminal leaves clicks to itself and does not take the click that
    /// activates its window.
    func setClickRouting(enabled: Bool)
    /// Whether pastes are offered to the delegate before the terminal brackets
    /// them. On only while a control-mode attach is live.
    func setControlModePasteInterception(enabled: Bool)
    /// Routes text a drop produced, such as the shell-quoted paths of dropped
    /// files, exactly as the view routes a real drop: offered to the delegate
    /// while paste interception is on, else sent as typed. The view's drop
    /// handler calls the same entry, and a test drives it here, because a test
    /// can neither build an `NSDraggingInfo` nor write the general pasteboard.
    func deliverDroppedText(_ text: String)

    // MARK: Instruments

    /// The panel's latency tap, called as each frame begins drawing. Installed
    /// only while the default-off terminal latency diagnostic is on.
    var latencyTap: TerminalLatencyTap? { get set }
    /// Called as each frame begins drawing.
    var onDrawStart: (@MainActor () -> Void)? { get set }
    /// Called when a frame has been presented, as each emulator can say it,
    /// and the two say different things. SwiftTerm: its Core Graphics draw
    /// has returned, the app's last work on the frame. libghostty: Metal has
    /// reported the drawable presented, a frame or so later and closer to the
    /// glass. Compare the two engines with the latency tap and the commit
    /// probe, which stamp the same points in both, not with this.
    var onFramePresented: (@MainActor () -> Void)? { get set }
}
