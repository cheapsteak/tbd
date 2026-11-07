// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalSession.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// TerminalSession.swift — the VT bridge.
//
// One `TerminalSession` owns one libghostty-vt terminal: it feeds it pty bytes, answers the
// terminal's "effects" (queries, OSC), publishes `TerminalEvent`s, and hands the render layer a
// locked window onto the terminal handle.
//
// ## The single most important constraint: callbacks run *inside* `vt_write`
//
// Every effect callback (`WRITE_PTY`, `BELL`, `TITLE_CHANGED`, `CLIPBOARD_WRITE`, …) is invoked
// **synchronously, on the calling thread, from within `ghostty_terminal_vt_write`**
// (terminal.h: "All callbacks are invoked synchronously during VT writes … must not call
// ghostty_terminal_vt_write() on the same terminal (no reentrancy)"). `vt_write` only ever runs
// inside `state.withLock`, so a callback that tried to take the lock — directly, or indirectly by
// calling back into `TerminalSession` — would deadlock instantly.
//
// The design that makes that impossible rather than merely unlikely:
//
//   * `userdata` does **not** point at `TerminalSession` (whose state lives behind the `Mutex`).
//     It points at `IOContext`, a plain non-Sendable class that is *owned by* the locked state.
//     A callback therefore cannot reach the lock: it has no reference to the session at all.
//   * A callback only ever appends to `IOContext` buffers (`pendingPty`, `pendingEvents`) and
//     reads terminal data through the `terminal` handle it is given as its first argument.
//     Because it runs under the lock (transitively — its caller holds it), that access is
//     exclusive by construction.
//   * After `vt_write` returns, still under the lock, the session *harvests* the buffers.
//     The lock is then released, and only afterwards are the consumer closures (`onWritePty`,
//     the `AsyncStream` continuation, `renderSignal`) invoked. No consumer code ever runs while
//     the lock is held.
//
// ## Threading
//
// `ioQueue` is a serial `.userInteractive` queue that the pty layer (M1.2) reads on; ingestion
// (`write(ptyBytes:)`) is *synchronous* so it can also be driven straight from a test or from
// `tkzmux-vtdump replay` with no scheduling in between. `renderSignal` is the seam the view layer
// (M1.6) wires a `DispatchSourceUserDataOr` to; this module never touches AppKit.
import Darwin
import Foundation
import Synchronization
import GhosttyVt

// MARK: - Options

/// Everything that is configured on the terminal at construction (and re-applied after a restore).
public struct TerminalSessionOptions: Sendable {
    public var cols: UInt16
    public var rows: UInt16
    public var cellWidthPx: UInt32
    public var cellHeightPx: UInt32
    public var theme: Theme
    /// `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES`. The library default is only 10 000 bytes
    /// (measured; ≈557 rows at 120 cols), so this must always be set explicitly.
    public var scrollbackMaxBytes: Int
    /// `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES`. Whichever of the two limits is reached first wins.
    public var scrollbackMaxLines: Int
    /// `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT`. Small on purpose: we do not render
    /// Kitty graphics in v1, and a large limit is just a memory hole per session.
    public var kittyImageStorageLimit: UInt64
    /// Reported for `CSI > q` (XTVERSION).
    public var xtversion: String
    /// Reported for an XTGETTCAP `TN` query.
    public var terminfoName: String
    public var cursorStyle: CursorStyle
    public var cursorBlink: Bool
    /// Answered to `CSI ? 996 n`, and re-reported on a live change when mode 2031 is set.
    /// Defaults to `theme.isDark` — a light theme that still claimed "dark" would make Claude Code
    /// render dark-on-light.
    public var darkColorScheme: Bool

    public enum CursorStyle: Sendable, Hashable {
        case bar, block, underline, blockHollow

        // PORT: both old cursor-style enums merged into GhosttyCursorStyle (same values 0...3).
        var raw: GhosttyCursorStyle {
            switch self {
            case .bar: return GHOSTTY_CURSOR_STYLE_BAR
            case .block: return GHOSTTY_CURSOR_STYLE_BLOCK
            case .underline: return GHOSTTY_CURSOR_STYLE_UNDERLINE
            case .blockHollow: return GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW
            }
        }
    }

    public init(
        cols: UInt16 = 120,
        rows: UInt16 = 40,
        cellWidthPx: UInt32 = 0,
        cellHeightPx: UInt32 = 0,
        theme: Theme = .default,
        scrollbackMaxBytes: Int = 24 * 1024 * 1024,
        scrollbackMaxLines: Int = 10_000,
        kittyImageStorageLimit: UInt64 = 1 * 1024 * 1024,
        xtversion: String = "ghosttyview 0.0.1",
        terminfoName: String = "xterm-ghostty",
        cursorStyle: CursorStyle = .block,
        cursorBlink: Bool = true,
        darkColorScheme: Bool? = nil
    ) {
        self.cols = cols
        self.rows = rows
        self.cellWidthPx = cellWidthPx
        self.cellHeightPx = cellHeightPx
        self.theme = theme
        self.scrollbackMaxBytes = scrollbackMaxBytes
        self.scrollbackMaxLines = scrollbackMaxLines
        self.kittyImageStorageLimit = kittyImageStorageLimit
        self.xtversion = xtversion
        self.terminfoName = terminfoName
        self.cursorStyle = cursorStyle
        self.cursorBlink = cursorBlink
        self.darkColorScheme = darkColorScheme ?? theme.isDark
    }
}

// MARK: - DEC 2026 watchdog

/// The DEC 2026 (synchronized output) policy, as a pure value so it can be tested without a VT.
///
/// libghostty-vt does **not** hide unsynchronized frames: with mode 2026 set the render state still
/// reports rows dirty (verified, M1.3). Hiding is the host's job, exactly as in Ghostty's own
/// renderer: skip frames while the mode is set, and force it off if a program leaves it set.
public struct SyncOutputWatchdog: Sendable, Equatable {
    /// How long a program may hold mode 2026 before we stop believing it.
    public var timeout: Duration

    private var activeSince: ContinuousClock.Instant?

    public init(timeout: Duration = .seconds(1)) {
        self.timeout = timeout
        self.activeSince = nil
    }

    public enum Decision: Sendable, Equatable {
        /// Mode 2026 is not set: render normally.
        case render
        /// Mode 2026 has been set for less than `timeout`: skip this frame, keep the link running.
        case skipFrame
        /// Mode 2026 has been held too long: force it off and render.
        case forceOffAndRender
    }

    /// `modeActive` comes from `ghostty_terminal_get(DATA_MODE, ghostty_mode_new(2026, false))`.
    public mutating func evaluate(modeActive: Bool, now: ContinuousClock.Instant) -> Decision {
        guard modeActive else {
            activeSince = nil
            return .render
        }
        guard let since = activeSince else {
            activeSince = now
            return .skipFrame
        }
        if since.duration(to: now) >= timeout {
            activeSince = nil
            return .forceOffAndRender
        }
        return .skipFrame
    }

    /// Test/inspection helper: has the mode been continuously active?
    public var isTracking: Bool { activeSince != nil }
}

// MARK: - IO context (the only thing C callbacks ever see)

/// State that the C effect callbacks append to. Owned by the locked `SessionState`, so it is
/// exclusively accessed while `vt_write` runs. Never touches `TerminalSession` or the `Mutex`.
final class IOContext {
    var pendingPty: [UInt8] = []
    var pendingEvents: [TerminalEvent] = []

    /// XTVERSION must return a `GhosttyString` whose bytes outlive the callback body, so it
    /// cannot be produced from a temporary. Allocated once here, freed in `deinit`.
    private(set) var xtversion: UnsafeMutableBufferPointer<UInt8>

    /// Answered to XTWINOPS / mode 2048 size queries; kept in sync by `resize`.
    var reportedSize: GhosttySizeReportSize

    var colorScheme: GhosttyColorScheme

    init(xtversion versionString: String, size: GhosttySizeReportSize, colorScheme: GhosttyColorScheme) {
        let bytes = Array(versionString.utf8)
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: max(bytes.count, 1))
        _ = buffer.initialize(fromContentsOf: bytes)
        self.xtversion = UnsafeMutableBufferPointer(rebasing: buffer[0..<bytes.count])
        self.reportedSize = size
        self.colorScheme = colorScheme
        self.allocation = buffer
    }

    private let allocation: UnsafeMutableBufferPointer<UInt8>
    deinit { allocation.deallocate() }
}

/// Resolves the `userdata` pointer every callback receives.
@inline(__always)
private func ioContext(_ userdata: UnsafeMutableRawPointer?) -> IOContext? {
    guard let userdata else { return nil }
    return Unmanaged<IOContext>.fromOpaque(userdata).takeUnretainedValue()
}

@inline(__always)
private func string(_ value: GhosttyString) -> String {
    guard let ptr = value.ptr, value.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
}

/// Reads a borrowed `GhosttyString` out of the terminal. Valid only until the next mutating call,
/// which is why the result is copied into a Swift `String` immediately.
@inline(__always)
private func terminalString(_ terminal: GhosttyTerminal?, _ data: GhosttyTerminalData) -> String {
    guard let terminal else { return "" }
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, data, &value) == GHOSTTY_SUCCESS else { return "" }
    return string(value)
}

// MARK: - C callbacks
//
// Every one of these runs inside `ghostty_terminal_vt_write` (or `ghostty_terminal_paste`), i.e.
// with the session lock already held by the caller. They must not block, must not re-enter the
// terminal's VT writer, and must not touch `TerminalSession`.

private func cbWritePty(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?, _ len: Int
) {
    guard let context = ioContext(userdata), let data, len > 0 else { return }
    context.pendingPty.append(contentsOf: UnsafeBufferPointer(start: data, count: len))
}

private func cbBell(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    ioContext(userdata)?.pendingEvents.append(.bell)
}

private func cbTitleChanged(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    guard let context = ioContext(userdata) else { return }
    context.pendingEvents.append(.title(terminalString(terminal, GHOSTTY_TERMINAL_DATA_TITLE)))
}

private func cbPwdChanged(_ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    guard let context = ioContext(userdata) else { return }
    // terminal.h explicitly says to read DATA_PWD *inside* this callback.
    context.pendingEvents.append(.pwd(terminalString(terminal, GHOSTTY_TERMINAL_DATA_PWD)))
}

private func cbDesktopNotification(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ notification: UnsafePointer<GhosttyTerminalDesktopNotification>?
) {
    guard let context = ioContext(userdata), let notification else { return }
    context.pendingEvents.append(
        .notification(title: string(notification.pointee.title), body: string(notification.pointee.body))
    )
}

private func cbProgressReport(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ report: UnsafePointer<GhosttyTerminalProgressReport>?
) {
    guard let context = ioContext(userdata), let report else { return }
    let state: TerminalProgressState
    switch report.pointee.state {
    case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: state = .set
    case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: state = .error
    case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: state = .indeterminate
    case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: state = .pause
    default: state = .remove
    }
    let progress = report.pointee.progress
    context.pendingEvents.append(.progress(state: state, value: progress < 0 ? nil : Int(progress)))
}

private func cbColorScheme(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ outScheme: UnsafeMutablePointer<GhosttyColorScheme>?
) -> Bool {
    guard let context = ioContext(userdata), let outScheme else { return false }
    outScheme.pointee = context.colorScheme
    return true
}

private func cbSize(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ outSize: UnsafeMutablePointer<GhosttySizeReportSize>?
) -> Bool {
    guard let context = ioContext(userdata), let outSize else { return false }
    outSize.pointee = context.reportedSize
    return true
}

private func cbXtversion(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?
) -> GhosttyString {
    guard let context = ioContext(userdata) else { return GhosttyString() }
    var value = GhosttyString()
    value.ptr = UnsafePointer(context.xtversion.baseAddress)
    value.len = context.xtversion.count
    return value
}

private func cbClipboardWrite(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ write: UnsafePointer<GhosttyClipboardWrite>?
) {
    guard let context = ioContext(userdata), let write else { return }
    let request = write.pointee

    var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    if request.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD {
        if request.contents_len == 0 {
            // A zero-length contents array asks for the destination to be cleared.
            context.pendingEvents.append(.clipboardWrite(""))
            result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        } else if let contents = request.contents {
            for index in 0..<request.contents_len {
                let entry = contents[index]
                let mime = string(entry.mime)
                guard mime.isEmpty || mime.hasPrefix("text/") else { continue }
                context.pendingEvents.append(.clipboardWrite(string(entry.data)))
                result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
                break
            }
        }
    }

    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.stride  // C sizeof == Swift stride
    reply.result = result
    reply.remember = false
    request.reply?(write, &reply)
}

private func cbClipboardRead(
    _ terminal: GhosttyTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ read: UnsafePointer<GhosttyClipboardRead>?
) {
    guard let read else { return }
    // Programs never get to read the user's clipboard.
    var reply = GhosttyClipboardReadReply()
    reply.size = MemoryLayout<GhosttyClipboardReadReply>.stride
    reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
    read.pointee.reply?(read, &reply)
}

// MARK: - Locked state

/// The terminal handle plus everything that must move under the lock with it.
///
/// The three input objects (`keyEncoder`, `mouseEncoder`, `selection`) live here, not in the view
/// layer, for two reasons: none of them is `Sendable`, and `SelectionController` binds to a
/// *specific* `GhosttyTerminalHandle` for its lifetime. `restore(from:)` swaps that handle, so all
/// three are rebuilt there — a controller held anywhere else would silently keep driving the
/// discarded terminal.
final class SessionState {
    var terminal: GhosttyTerminalHandle
    let context: IOContext
    var options: TerminalSessionOptions
    var watchdog: SyncOutputWatchdog
    var onWritePty: (@Sendable (Data) -> Void)?
    var renderSignal: (@Sendable () -> Void)?

    /// Key press → pty bytes. Rebuilt on restore only for symmetry; it holds no terminal.
    var keyEncoder: KeyEncoder
    /// Pointer event → mouse report. Holds no terminal, but does hold `geometry`.
    var mouseEncoder: MouseEncoder
    /// The selection gesture machine. **Holds `terminal` strongly** — must be rebuilt on restore.
    var selection: SelectionController
    /// The last geometry the view pushed, kept so the rebuilt objects start where the old ones
    /// left off rather than at the option-derived guess.
    var mouseGeometry: TerminalPixelGeometry
    /// `NSEvent.doubleClickInterval`, pushed down by the app (this module cannot read AppKit).
    var doubleClickInterval: Double

    init(
        terminal: GhosttyTerminalHandle,
        context: IOContext,
        options: TerminalSessionOptions,
        keyEncoder: KeyEncoder,
        mouseEncoder: MouseEncoder,
        selection: SelectionController,
        mouseGeometry: TerminalPixelGeometry,
        doubleClickInterval: Double
    ) {
        self.terminal = terminal
        self.context = context
        self.options = options
        self.watchdog = SyncOutputWatchdog()
        self.keyEncoder = keyEncoder
        self.mouseEncoder = mouseEncoder
        self.selection = selection
        self.mouseGeometry = mouseGeometry
        self.doubleClickInterval = doubleClickInterval
    }

    /// Takes everything the callbacks accumulated. Called under the lock, right after `vt_write`.
    func harvest() -> (pty: Data, events: [TerminalEvent]) {
        let pty = context.pendingPty.isEmpty ? Data() : Data(context.pendingPty)
        let events = context.pendingEvents
        context.pendingPty.removeAll(keepingCapacity: true)
        context.pendingEvents.removeAll(keepingCapacity: true)
        return (pty, events)
    }
}

// MARK: - TerminalSession

public final class TerminalSession: Sendable {
    private let state: Mutex<SessionState>
    private let continuation: AsyncStream<TerminalEvent>.Continuation

    /// Events for the app to consume (on the main actor). Buffering is unbounded so nothing that
    /// happened before a consumer attached is dropped.
    public let events: AsyncStream<TerminalEvent>

    /// The serial queue the pty layer should read and write on. Ingestion is synchronous, so this
    /// is a convention for callers rather than something this class dispatches to itself.
    public let ioQueue: DispatchQueue

    public init(options: TerminalSessionOptions = TerminalSessionOptions(), label: String = "tkzmux.session") throws {
        let handle = try GhosttyTerminalHandle(cols: options.cols, rows: options.rows)
        let context = IOContext(
            xtversion: options.xtversion,
            size: GhosttySizeReportSize(
                rows: options.rows, columns: options.cols,
                cell_width: options.cellWidthPx, cell_height: options.cellHeightPx
            ),
            colorScheme: options.darkColorScheme ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT
        )
        // A guess until the view pushes real geometry: options carry cell pixels only when the
        // host already measured a font. Cells are clamped to 1 because `SelectionController`
        // refuses to map a pointer at all with a zero cell size.
        let geometry = TerminalSession.geometry(for: options)
        let sessionState = SessionState(
            terminal: handle,
            context: context,
            options: options,
            keyEncoder: try KeyEncoder(),
            mouseEncoder: try MouseEncoder(geometry: geometry),
            selection: try SelectionController(
                terminal: handle, geometry: geometry, doubleClickInterval: 0.5),
            mouseGeometry: geometry,
            doubleClickInterval: 0.5
        )
        try TerminalSession.applyOptions(to: sessionState)

        self.state = Mutex(sessionState)
        self.ioQueue = DispatchQueue(label: label, qos: .userInteractive)
        var escapee: AsyncStream<TerminalEvent>.Continuation!
        self.events = AsyncStream(bufferingPolicy: .unbounded) { escapee = $0 }
        self.continuation = escapee
    }

    deinit { continuation.finish() }

    // MARK: Configuration

    /// Installs the sink for bytes the terminal wants written back to the pty (query replies,
    /// mode reports, paste output). Called **outside** the lock, right after a write completes.
    public func setOnWritePty(_ sink: (@Sendable (Data) -> Void)?) {
        state.withLock { $0.onWritePty = sink }
    }

    /// The seam the view layer wires a `DispatchSourceUserDataOr` to in M1.6.
    /// Called outside the lock after every non-empty ingestion.
    public func setRenderSignal(_ signal: (@Sendable () -> Void)?) {
        state.withLock { $0.renderSignal = signal }
    }

    /// The geometry implied by the session options, for use before the view has measured one.
    private static func geometry(for options: TerminalSessionOptions) -> TerminalPixelGeometry {
        let cellWidth = max(options.cellWidthPx, 1)
        let cellHeight = max(options.cellHeightPx, 1)
        return TerminalPixelGeometry(
            screenWidth: UInt32(options.cols) * cellWidth,
            screenHeight: UInt32(options.rows) * cellHeight,
            cellWidth: cellWidth,
            cellHeight: cellHeight
        )
    }

    /// Applies every option in `state.options` to `state.terminal`. Re-run after `restore(from:)`,
    /// because a snapshot restores grid content only — no callbacks, colors or limits.
    private static func applyOptions(to state: SessionState) throws {
        try applyOptions(terminal: state.terminal.raw, context: state.context, options: state.options)
    }

    /// Applies every option to a bare terminal handle. Split out of the `SessionState` overload so
    /// `restore(from:)` can fully configure a decoded terminal *before* committing it.
    private static func applyOptions(
        terminal: GhosttyTerminal, context: IOContext, options: TerminalSessionOptions
    ) throws {

        func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?, _ name: String) throws {
            try ghosttyCheck(ghostty_terminal_set(terminal, option, value), "ghostty_terminal_set(\(name))")
        }
        func setCallback(_ option: GhosttyTerminalOption, _ pointer: UnsafeRawPointer, _ name: String) throws {
            try set(option, pointer, name)
        }

        // USERDATA first: every callback below is handed this pointer. It refers to the IOContext,
        // never to TerminalSession — see the file header for why that is load-bearing.
        try set(GHOSTTY_TERMINAL_OPT_USERDATA, UnsafeRawPointer(Unmanaged.passUnretained(context).toOpaque()), "USERDATA")

        // Effects. Function pointers are passed *as* the value (not a pointer to them).
        let writePty: GhosttyTerminalWritePtyFn = cbWritePty
        try setCallback(GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self), "WRITE_PTY")
        let bell: GhosttyTerminalBellFn = cbBell
        try setCallback(GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self), "BELL")
        let titleChanged: GhosttyTerminalTitleChangedFn = cbTitleChanged
        try setCallback(GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(titleChanged, to: UnsafeRawPointer.self), "TITLE_CHANGED")
        let pwdChanged: GhosttyTerminalPwdChangedFn = cbPwdChanged
        try setCallback(GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(pwdChanged, to: UnsafeRawPointer.self), "PWD_CHANGED")
        let clipboardWrite: GhosttyTerminalClipboardWriteFn = cbClipboardWrite
        try setCallback(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(clipboardWrite, to: UnsafeRawPointer.self), "CLIPBOARD_WRITE")
        let clipboardRead: GhosttyTerminalClipboardReadFn = cbClipboardRead
        try setCallback(GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, unsafeBitCast(clipboardRead, to: UnsafeRawPointer.self), "CLIPBOARD_READ")
        let notification: GhosttyTerminalDesktopNotificationFn = cbDesktopNotification
        try setCallback(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(notification, to: UnsafeRawPointer.self), "DESKTOP_NOTIFICATION")
        let progress: GhosttyTerminalProgressReportFn = cbProgressReport
        try setCallback(GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, unsafeBitCast(progress, to: UnsafeRawPointer.self), "PROGRESS_REPORT")
        let colorScheme: GhosttyTerminalColorSchemeFn = cbColorScheme
        try setCallback(GHOSTTY_TERMINAL_OPT_COLOR_SCHEME, unsafeBitCast(colorScheme, to: UnsafeRawPointer.self), "COLOR_SCHEME")
        let size: GhosttyTerminalSizeFn = cbSize
        try setCallback(GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self), "SIZE")
        let xtversion: GhosttyTerminalXtversionFn = cbXtversion
        try setCallback(GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self), "XTVERSION")
        // DEVICE_ATTRIBUTES is deliberately *not* installed: libghostty already answers DA1 with
        // `ESC[?62;22c` and DA2 with `ESC[>1;<version>;0c` on its own (verified M1.3). A callback
        // would only be needed to advertise a different feature set.

        // Values.
        var terminfo = GhosttyString()
        try options.terminfoName.withCString { cString in
            let bytes = UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self)
            terminfo.ptr = bytes
            terminfo.len = strlen(cString)
            // The string is copied into the terminal, so a temporary is fine here.
            try set(GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &terminfo, "TERMINFO_NAME")
        }

        var scrollback = options.scrollbackMaxBytes
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollback, "SCROLLBACK_MAX_BYTES")
        // The line limit goes second: the byte limit defaults to 10,000 BYTES and would otherwise
        // override it silently.
        var scrollbackLines = options.scrollbackMaxLines
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackLines, "SCROLLBACK_MAX_LINES")
        // Mode 2027: grapheme clustering, as the reset default too so RIS does not lose it.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        try set(GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes, "MODE_DEFAULT(2027)")
        var kittyLimit = options.kittyImageStorageLimit
        try set(GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyLimit, "KITTY_IMAGE_STORAGE_LIMIT")
        var cursorStyle = options.cursorStyle.raw
        try set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &cursorStyle, "DEFAULT_CURSOR_STYLE")
        var cursorBlink = options.cursorBlink
        try set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &cursorBlink, "DEFAULT_CURSOR_BLINK")
        // A program can set a title and read it back into the input stream; keep that off.
        var titleReport = false
        try set(GHOSTTY_TERMINAL_OPT_TITLE_REPORT, &titleReport, "TITLE_REPORT")

        try applyThemeColors(terminal: terminal, theme: options.theme)
    }

    /// The four colour options, and nothing else — the only part of `applyOptions` that is safe to
    /// re-run on a live terminal, which is what the ☾/☀ toggle does through ``setTheme(_:)``.
    ///
    /// Everything else in `applyOptions` must not re-run: `CONTINUATION_MAX_BYTES` has to be set
    /// before any bytes are fed (snapshot encoding depends on it), re-setting `SCROLLBACK_MAX_BYTES`
    /// re-evaluates the prune limit and rehydrates an idle-compressed session, the cursor defaults
    /// are RIS-restore values that would fight whatever the running program set, and `USERDATA` plus
    /// the callback pointers are an identity this file's header calls load-bearing.
    ///
    /// These options set the *default*; libghostty keeps any per-index OSC 4/10/11/12 override a
    /// program has applied, so a re-theme never stomps a program's own colours.
    private static func applyThemeColors(terminal: GhosttyTerminal, theme: Theme) throws {
        func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?, _ name: String) throws {
            try ghosttyCheck(ghostty_terminal_set(terminal, option, value), "ghostty_terminal_set(\(name))")
        }

        // Colors from the theme. 0…15 come from the design tokens; 16…255 stay Ghostty's defaults.
        var foreground = theme.terminalForeground.ghostty
        try set(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &foreground, "COLOR_FOREGROUND")
        var background = theme.terminalBackground.ghostty
        try set(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &background, "COLOR_BACKGROUND")
        var cursor = theme.accent.ghostty
        try set(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor, "COLOR_CURSOR")

        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
        palette.withUnsafeMutableBufferPointer { buffer in
            ghostty_color_palette_default(buffer.baseAddress)
        }
        for (index, color) in theme.terminalPalette16.enumerated() where index < 16 {
            palette[index] = color.ghostty
        }
        try palette.withUnsafeBufferPointer { buffer in
            try set(GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress, "COLOR_PALETTE")
        }
    }

    // MARK: Ingestion

    /// Feed bytes read from the pty master into the VT parser.
    ///
    /// Synchronous: the caller (the pty read source on `ioQueue`, a test, or `vtdump replay`) owns
    /// the timing. Everything the terminal produced in response is delivered after the lock drops.
    public func write(ptyBytes bytes: Data) {
        guard !bytes.isEmpty else { return }
        let (pty, events, sink, signal) = state.withLock {
            (state: inout SessionState) -> (Data, [TerminalEvent], (@Sendable (Data) -> Void)?, (@Sendable () -> Void)?) in
            bytes.withUnsafeBytes { state.terminal.write($0) }
            let harvest = state.harvest()
            return (harvest.pty, harvest.events, state.onWritePty, state.renderSignal)
        }
        deliver(pty: pty, events: events, sink: sink, signal: signal)
    }

    /// Convenience for tests and `vtdump`.
    public func write(ptyText text: String) { write(ptyBytes: Data(text.utf8)) }

    private func deliver(
        pty: Data, events: [TerminalEvent],
        sink: (@Sendable (Data) -> Void)?, signal: (@Sendable () -> Void)?
    ) {
        if !pty.isEmpty { sink?(pty) }
        for event in events { continuation.yield(event) }
        signal?()
    }

    /// Publishes a child-process exit. The pty layer owns `waitpid`; this only republishes.
    public func noteExit(_ status: ExitStatus) { continuation.yield(.exited(status)) }

    /// Publishes a foreground-process change observed by the pty layer.
    public func noteForeground(pgid: pid_t, path: String?, cwd: String?) {
        continuation.yield(.foreground(pgid: pgid, path: path, cwd: cwd))
    }

    /// Ends the event stream. Call when the session row is removed.
    public func finishEvents() { continuation.finish() }

    // MARK: Geometry

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32? = nil, cellHeightPx: UInt32? = nil) throws {
        let (pty, events, sink, signal) = try state.withLock {
            (state: inout SessionState) -> (Data, [TerminalEvent], (@Sendable (Data) -> Void)?, (@Sendable () -> Void)?) in
            state.options.cols = cols
            state.options.rows = rows
            if let cellWidthPx { state.options.cellWidthPx = cellWidthPx }
            if let cellHeightPx { state.options.cellHeightPx = cellHeightPx }
            try state.terminal.resize(
                cols: cols, rows: rows,
                cellWidthPx: state.options.cellWidthPx, cellHeightPx: state.options.cellHeightPx
            )
            state.context.reportedSize = GhosttySizeReportSize(
                rows: rows, columns: cols,
                cell_width: state.options.cellWidthPx, cell_height: state.options.cellHeightPx
            )
            let harvest = state.harvest()
            return (harvest.pty, harvest.events, state.onWritePty, state.renderSignal)
        }
        deliver(pty: pty, events: events, sink: sink, signal: signal)
    }

    public var size: (cols: UInt16, rows: UInt16) {
        state.withLock { ($0.options.cols, $0.options.rows) }
    }

    // MARK: Queries

    /// Whether a DEC private (or ANSI) mode is currently set.
    public func mode(_ value: UInt16, ansi: Bool = false) -> Bool {
        state.withLock { state in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(value, ansi), value: false)
            guard ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS
            else { return false }
            return config.value
        }
    }

    /// `GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS` — the current kitty keyboard protocol flags.
    public var kittyKeyboardFlags: UInt8 {
        state.withLock { state in
            var flags: UInt8 = 0
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
            return flags
        }
    }

    /// True when any mouse tracking mode (X10 / normal / button / any) is active.
    public var mouseTrackingEnabled: Bool {
        state.withLock { state in
            var tracking = false
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking)
            return tracking
        }
    }

    public var title: String {
        state.withLock { terminalString($0.terminal.raw, GHOSTTY_TERMINAL_DATA_TITLE) }
    }

    public var pwd: String {
        state.withLock { terminalString($0.terminal.raw, GHOSTTY_TERMINAL_DATA_PWD) }
    }

    public var scrollbackRows: Int {
        state.withLock { state in
            var rows = 0
            _ = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &rows)
            return rows
        }
    }

    /// Where the viewport sits in the scrollable area, right now.
    ///
    /// The frame path does **not** read this — `FrameBuilder.update` folds the same read into the
    /// one lock it already takes, rather than acquiring a second one per frame. This is for
    /// tooling and tests.
    public var scrollMetrics: TerminalScrollMetrics {
        state.withLock { TerminalScrollMetrics.read($0.terminal.raw) }
    }

    /// The active screen through libghostty's formatter.
    public func formatted(
        _ format: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN,
        trim: Bool = true,
        unwrap: Bool = false
    ) throws -> String {
        try state.withLock { try $0.terminal.formatted(format, trim: trim, unwrap: unwrap) }
    }

    // MARK: DEC 2026

    /// One render-tick decision. Reads mode 2026 under the lock, runs the watchdog, and forces the
    /// mode off when a program has held it past the timeout.
    ///
    /// - Parameter now: injected so the policy is testable; pass `ContinuousClock.now` in the app.
    @discardableResult
    public func syncOutputDecision(now: ContinuousClock.Instant = ContinuousClock.now) -> SyncOutputWatchdog.Decision {
        state.withLock { state in
            var config = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            let active = ghostty_terminal_get(state.terminal.raw, GHOSTTY_TERMINAL_DATA_MODE, &config) == GHOSTTY_SUCCESS
                && config.value
            let decision = state.watchdog.evaluate(modeActive: active, now: now)
            if decision == .forceOffAndRender {
                var off = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
                _ = ghostty_terminal_set(state.terminal.raw, GHOSTTY_TERMINAL_OPT_MODE, &off)
            }
            return decision
        }
    }

    // MARK: Input seam
    //
    // The view layer has no way to reach a `GhosttyTerminalHandle` — `withTerminal` yields the raw
    // `GhosttyTerminal`, and adopting one would double-free — so every encoder call goes through
    // one of the methods below. They all follow the same shape as `write(ptyBytes:)`: take the
    // lock, do the libghostty work, release the lock, and only *then* run any consumer closure.
    //
    // ## Where the bytes come out — the one distinction that matters
    //
    //   * **Key and mouse bytes are returned to the caller.** Nothing is written anywhere: the
    //     view layer sends them itself (`TerminalInputController.writeInput` /
    //     `MouseController.sendBytes`). The encoders never touch the terminal's WRITE_PTY sink.
    //   * **Paste bytes leave through the session's own pty sink.** `ghostty_terminal_paste`
    //     frames, chunks and escapes the text *inside* libghostty and pushes the result out
    //     through WRITE_PTY, so `pasteText` harvests and delivers exactly like `write(ptyBytes:)`
    //     and returns only an outcome. A caller that also wrote something would paste twice.

    /// Encode one key press against this terminal's current mode state.
    ///
    /// Takes the lock (the encoder re-reads DECCKM / kitty flags / `modifyOtherKeys` from the
    /// terminal on every call) and returns the bytes for the caller to write. **Nothing is sent**:
    /// an empty array is the normal result for a bare modifier, a release in legacy mode, or a
    /// composing key.
    public func encodeKey(_ press: KeyPress, optionAsAlt: OptionAsAlt = .never) throws -> [UInt8] {
        try state.withLock { state in
            try state.keyEncoder.encode(press, terminal: state.terminal, optionAsAlt: optionAsAlt)
        }
    }

    /// Paste `text` into the terminal.
    ///
    /// Unlike `encodeKey`, this **writes**: bracketing (mode 2004), newline conversion, unsafe-byte
    /// stripping and chunking all happen inside libghostty, and the encoded bytes reach the
    /// WRITE_PTY callback while the paste is in flight. They are harvested under the lock and
    /// handed to `onWritePty` after it drops, exactly as an ingested VT sequence would be. The
    /// caller must not write the text itself as well.
    ///
    /// - Returns: `.rejectedUnsafe` means **nothing was written** — confirm with the user and call
    ///   again with `allowUnsafe: true`.
    @discardableResult
    public func pasteText(
        _ text: String, source: PasteSource, allowUnsafe: Bool
    ) throws -> PasteOutcome {
        let (outcome, pty, events, sink, signal) = try state.withLock {
            (state: inout SessionState) -> (PasteOutcome, Data, [TerminalEvent], (@Sendable (Data) -> Void)?, (@Sendable () -> Void)?) in
            let outcome = try PasteSupport.paste(
                text: text, into: state.terminal, source: source, allowUnsafe: allowUnsafe)
            let harvest = state.harvest()
            return (outcome, harvest.pty, harvest.events, state.onWritePty, state.renderSignal)
        }
        deliver(pty: pty, events: events, sink: sink, signal: signal)
        return outcome
    }

    /// `pasteText(_:source:allowUnsafe:)` for a real clipboard paste. A separate method rather than
    /// a defaulted argument so it can witness the view layer's `MouseControllerTerminal`.
    @discardableResult
    public func pasteText(_ text: String, allowUnsafe: Bool) throws -> PasteOutcome {
        try pasteText(text, source: .clipboard, allowUnsafe: allowUnsafe)
    }

    // MARK: Mouse

    /// `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING`. Spelled to witness `MouseControllerTerminal`;
    /// ``mouseTrackingEnabled`` is the same value under the older name.
    public var isMouseTrackingEnabled: Bool { mouseTrackingEnabled }

    /// Push rendered geometry to the mouse encoder *and* the selection controller, and remember it
    /// so `restore(from:)` can rebuild both where they left off. Takes the lock; sends nothing.
    public func setMousePixelGeometry(_ geometry: TerminalPixelGeometry) {
        state.withLock { state in
            state.mouseGeometry = geometry
            state.mouseEncoder.geometry = geometry
            state.selection.geometry = geometry
        }
    }

    /// Encode one pointer event. Takes the lock; **returns** the report for the caller to write,
    /// and `nil` when the terminal wants none (tracking off, or a motion inside the same cell).
    public func encodeMouse(_ press: MousePress) throws -> [UInt8]? {
        try state.withLock { state in
            try state.mouseEncoder.encode(press, terminal: state.terminal)
        }
    }

    /// Whole rows of wheel scrolling. With tracking on the reports are **returned** in
    /// `.report(_:)`; with tracking off the viewport is scrolled under the lock and the render
    /// signal fires after it drops, because what is on screen changed.
    public func mouseWheel(
        rows: Int, at position: SurfacePoint, mods: TerminalModifiers = []
    ) throws -> WheelOutcome {
        let (outcome, signal) = try state.withLock {
            (state: inout SessionState) -> (WheelOutcome, (@Sendable () -> Void)?) in
            let outcome = try state.mouseEncoder.wheel(
                rows: rows, at: position, mods: mods, terminal: state.terminal)
            if case .scrolledViewport = outcome { return (outcome, state.renderSignal) }
            return (outcome, nil)
        }
        signal?()
        return outcome
    }

    /// Forget held buttons and motion de-duplication. Call on focus loss.
    public func resetMouseEncoder() {
        state.withLock { $0.mouseEncoder.reset() }
    }

    // MARK: Selection
    //
    // Every gesture method installs (or clears) the terminal's selection, which the renderer reads,
    // so each one signals a frame after the lock drops. None of them writes to the pty.

    @discardableResult
    public func selectionPress(at position: SurfacePoint, timestamp: Double) throws -> Bool {
        try selectionChange { try $0.selection.press(at: position, timestamp: timestamp) }
    }

    @discardableResult
    public func selectionDrag(to position: SurfacePoint, rectangle: Bool = false) throws -> Bool {
        try selectionChange { try $0.selection.drag(to: position, rectangle: rectangle) }
    }

    public func selectionRelease(at position: SurfacePoint?) throws {
        _ = try selectionChange { state -> Bool in
            try state.selection.release(at: position)
            return false
        }
    }

    /// One tick of the view layer's autoscroll timer. Returns the rows scrolled (0 = none due).
    @discardableResult
    public func selectionAutoscrollTick(at position: SurfacePoint, rectangle: Bool = false) throws -> Int {
        try selectionChange { try $0.selection.autoscrollTick(at: position, rectangle: rectangle) }
    }

    /// What the last drag is asking the view to autoscroll. Read-only; takes the lock.
    public var selectionAutoscrollDirection: SelectionAutoscroll {
        state.withLock { $0.selection.autoscrollDirection }
    }

    /// Click count of the active gesture sequence (1 single, 2 double, 3 triple, 0 idle).
    public var selectionClickCount: Int {
        state.withLock { $0.selection.clickCount }
    }

    /// The click-granularity table (single = cell, double = word, triple = line by default).
    public var selectionBehaviors: SelectionBehaviors {
        get { state.withLock { $0.selection.behaviors } }
        set { state.withLock { $0.selection.behaviors = newValue } }
    }

    /// `NSEvent.doubleClickInterval`, in seconds. Without it libghostty only ever sees single
    /// clicks; the app pushes the real value because this module cannot read AppKit.
    public var selectionDoubleClickInterval: Double {
        get { state.withLock { $0.doubleClickInterval } }
        set {
            state.withLock { state in
                state.doubleClickInterval = newValue
                state.selection.doubleClickInterval = newValue
            }
        }
    }

    /// Drop the terminal's active selection and end the click sequence.
    public func clearSelection() {
        let signal = state.withLock { (state: inout SessionState) -> (@Sendable () -> Void)? in
            state.selection.reset()
            state.selection.clearSelection()
            return state.renderSignal
        }
        signal?()
    }

    /// The selected text, formatted the way a terminal copy does it. `nil` with no selection.
    public func copySelectionText() -> String? {
        state.withLock { $0.selection.copySelection() }
    }

    /// The OSC 8 URI under `position` plus the run of cells sharing it, for the hover underline.
    ///
    /// Grid refs are only valid until the next mutating terminal call, so the whole lookup — and
    /// the row-walk that widens it — happens inside one lock hold.
    public func hyperlinkRun(
        at position: SurfacePoint
    ) -> (uri: String, columns: ClosedRange<UInt16>, row: UInt32)? {
        state.withLock { state -> (uri: String, columns: ClosedRange<UInt16>, row: UInt32)? in
            guard let point = state.selection.gridPoint(at: position) else { return nil }
            guard let run = HyperlinkLookup.run(
                at: point, in: state.terminal, columns: state.options.cols
            ) else { return nil }
            return (run.uri, run.columns, point.y)
        }
    }

    /// Shared shape for the gesture methods: mutate under the lock, signal a frame after it drops.
    private func selectionChange<T: Sendable>(
        _ body: (inout SessionState) throws -> T
    ) throws -> T {
        let (value, signal) = try state.withLock {
            (state: inout SessionState) -> (T, (@Sendable () -> Void)?) in
            (try body(&state), state.renderSignal)
        }
        signal?()
        return value
    }

    // MARK: Render seam

    /// Runs `body` with exclusive access to the terminal handle.
    ///
    /// This is how `TerminalSurface` (M1.5) calls `ghostty_render_state_begin_update` — and *only*
    /// begin_update: `end_update` and row/cell iteration touch render-state memory only and must
    /// happen outside this closure so the IO thread is not blocked (verified M1.3, render.h).
    /// `body` must not call back into `TerminalSession`.
    package func withTerminal<T: Sendable>(_ body: (GhosttyTerminal) throws -> T) rethrows -> T {
        try state.withLock { (state: inout SessionState) in
            let terminal = state.terminal.raw
            return try body(terminal)
        }
    }
}

// MARK: - Theme bridging

extension RGB {
    /// The opaque 8-bit sRGB triple libghostty wants. Alpha is dropped (terminal colors are opaque).
    var ghostty: GhosttyColorRgb {
        let (r, g, b) = bytes
        return GhosttyColorRgb(r: r, g: g, b: b)
    }
}
