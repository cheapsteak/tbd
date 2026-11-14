// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalSession.swift (MIT, see LICENSE-tkzmux.txt).
// DEC 2026 hold edges adapted from termio 8196587 Shared/Sources/TermioStream/TermiodStreamTerminal.swift (MIT, see LICENSE-termio.txt).
// GhosttyTerminal — one libghostty-vt terminal behind one lock.
//
// ## Callbacks run *inside* `vt_write`
//
// libghostty invokes every effect callback (`WRITE_PTY`, `BELL`, `CLIPBOARD_WRITE`, ...)
// synchronously, on the calling thread, from within `ghostty_terminal_vt_write` (terminal.h: "All
// callbacks are invoked synchronously during VT writes ... no reentrancy"). `RENDER_HOLD` also
// runs from within `ghostty_terminal_reset` and `ghostty_terminal_resize`. All three only run
// with the lock held, so a callback that took the lock, directly or by calling back into
// `GhosttyTerminal`, would deadlock at once.
//
// The design makes that impossible rather than unlikely:
//
//   * `userdata` points at `IOContext`, a plain class the locked state owns, never at
//     `GhosttyTerminal`. A C callback has no way to reach the lock.
//   * A C callback only appends to `IOContext`'s buffers. It runs under the lock (its caller holds
//     it), so that access is exclusive by construction.
//   * After `vt_write` returns, still under the lock, the terminal *harvests* the buffers into one
//     delivery and appends it to an outbox. The lock is released, and only then are the owner's
//     callbacks run. So owner code never runs while the lock is held, and may call back into the
//     terminal.
//
// ## Deliveries go out in order, one at a time
//
// The IO thread feeds while the main thread resizes, and both produce replies: a DA answer from
// one, a mode 2048 size report from the other. Run straight from each caller after its unlock,
// they could reach `writePty` at the same moment, or in the opposite order from the one the
// terminal produced them in. So deliveries are appended to a FIFO under the terminal lock, which
// fixes production order, and drained under a second lock, the delivery lock, which makes them
// one at a time. Every call that queued a delivery drains before it returns, so a `feed`'s own
// replies have gone out by the time it returns, whichever thread ran them.
//
// A call that queued nothing does not touch the delivery lock, and neither does the render
// signal, which runs straight after its call with a `RenderHint` built under the lock. So a key,
// a click, or a feed with no reply never waits on a delivery running on another thread. A feed
// that does produce a reply waits for any drain in progress, which is why `writePty` must not
// block: see `GhosttyTerminalCallbacks`.
//
// The two query callbacks (`deviceAttributes`, `xtversion`) are the exception: their answer goes
// into the reply being parsed, so they are asked under the lock. `GhosttyTerminalCallbacks` says
// so.
//
// ## Closing
//
// `close()` frees the C terminal under the lock, after anything bound to it (the selection
// gesture). Every later call sees no handle and does nothing. A `feed` already inside the lock when
// `close()` is called finishes first, because `close()` waits for the lock; whatever that feed
// produced is still delivered to the callbacks after `close()` has returned. Nothing produced after
// the close is.
import Foundation
import GhosttyVt
import os

// MARK: - IO context (the only thing C callbacks ever see)

/// An effect a C callback recorded during a parse, delivered after the lock drops.
enum PendingEffect: Sendable {
    case bell
    case clipboardWrite(String)
    case desktopNotification(title: String, body: String)
    case programStatus(GhosttyTerminalCallbacks.ProgramStatus)
}

/// State the C callbacks read and append to. Owned by the locked `TerminalCore`, so it is only
/// touched while the lock is held. It never refers to `GhosttyTerminal` or the lock.
final class IOContext {
    let callbacks: GhosttyTerminalCallbacks
    /// While true, the callbacks drop what they would have produced. Set under the lock.
    var muted = false
    var pendingPty: [UInt8] = []
    var pendingEffects: [PendingEffect] = []
    /// Answered to XTWINOPS and mode 2048 size queries; kept in sync by `resize`.
    var reportedSize: GhosttySizeReportSize
    /// Answered to `CSI ? 996 n`.
    var colorScheme: GhosttyColorScheme = GHOSTTY_COLOR_SCHEME_DARK
    /// True while a DEC 2026 hold is open: from libghostty's begin edge to its end edge. The
    /// render tick skips frames while it is set. The edges cover every write, reset and resize.
    /// Two places set it without an edge: the watchdog's force-off, which turns the mode off
    /// through `OPT_MODE` and so raises none, and an attach, which reads the mode once.
    var holdOpen = false
    /// Set by every end edge. The next call that signals a render takes it into its `RenderHint`,
    /// reading and clearing it in the same lock hold, so an end that comes between two signals is
    /// not lost. A call that signals no render, as every call does while no view has a signal
    /// installed, leaves it for the next one that does. An attach clears it too: the view's first
    /// frame after an attach is a full rebuild, so an end from before it is no news to the view.
    ///
    /// `reset()` and `resize` end a hold that the program did not finish. When they signal, they
    /// take the flag and report no end, so the half-written frame is not let past the size rule
    /// as a finished one.
    var holdEnded = false

    /// XTVERSION must return a `GhosttyString` whose bytes outlive the callback body, so the answer
    /// is copied here and kept until the next query or until the context goes away.
    private var xtversionBytes: UnsafeMutableBufferPointer<UInt8>?

    init(callbacks: GhosttyTerminalCallbacks, size: GhosttySizeReportSize) {
        self.callbacks = callbacks
        self.reportedSize = size
    }

    deinit { xtversionBytes?.deallocate() }

    func storeXtversion(_ text: String) -> GhosttyString {
        xtversionBytes?.deallocate()
        xtversionBytes = nil
        let bytes = Array(text.utf8)
        var value = GhosttyString()
        guard !bytes.isEmpty else { return value }
        let buffer = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: bytes.count)
        _ = buffer.initialize(fromContentsOf: bytes)
        xtversionBytes = buffer
        value.ptr = UnsafePointer(buffer.baseAddress)
        value.len = buffer.count
        return value
    }
}

@inline(__always)
private func ioContext(_ userdata: UnsafeMutableRawPointer?) -> IOContext? {
    guard let userdata else { return nil }
    return Unmanaged<IOContext>.fromOpaque(userdata).takeUnretainedValue()
}

// MARK: - C callbacks
//
// Each of these runs inside `ghostty_terminal_vt_write` (or `ghostty_terminal_paste`, and the
// render-hold one inside `ghostty_terminal_reset` and `ghostty_terminal_resize` too), with the
// terminal's lock already held by the caller. They must not block, must not write to the terminal,
// and must not touch `GhosttyTerminal`. They are top-level functions, so they are nonisolated and
// capture nothing; everything they reach comes through `userdata`.

private func cbWritePty(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ data: UnsafePointer<UInt8>?, _ len: Int
) {
    guard let context = ioContext(userdata), !context.muted, let data, len > 0 else { return }
    context.pendingPty.append(contentsOf: UnsafeBufferPointer(start: data, count: len))
}

private func cbBell(_ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?) {
    guard let context = ioContext(userdata), !context.muted else { return }
    context.pendingEffects.append(.bell)
}

private func cbDesktopNotification(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ notification: UnsafePointer<GhosttyTerminalDesktopNotification>?
) {
    guard let context = ioContext(userdata), !context.muted, let notification else { return }
    context.pendingEffects.append(.desktopNotification(
        title: swiftString(notification.pointee.title), body: swiftString(notification.pointee.body)))
}

private func cbProgramStatus(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ report: UnsafePointer<GhosttyTerminalProgramStatus>?
) {
    guard let context = ioContext(userdata), !context.muted, let report else { return }
    let raw = report.pointee
    let state: GhosttyTerminalCallbacks.ProgramStatus.State
    switch raw.state {
    case GHOSTTY_PROGRAM_STATUS_STATE_IDLE: state = .idle
    case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: state = .working
    case GHOSTTY_PROGRAM_STATUS_STATE_DONE: state = .done
    case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: state = .blocked
    case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: state = .error
    case GHOSTTY_PROGRAM_STATUS_STATE_CLEAR: state = .clear
    default: return  // a state this build does not know: drop it rather than guess
    }
    let kind: GhosttyTerminalCallbacks.ProgramStatus.Kind
    switch raw.kind {
    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: kind = .permission
    case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: kind = .question
    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: kind = .auth
    default: kind = .none
    }
    context.pendingEffects.append(.programStatus(GhosttyTerminalCallbacks.ProgramStatus(
        state: state, kind: kind,
        progress: raw.progress < 0 ? nil : Int(raw.progress),
        id: swiftString(raw.id), app: swiftString(raw.app),
        title: swiftString(raw.title), message: swiftString(raw.message))))
}

private func cbColorScheme(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ outScheme: UnsafeMutablePointer<GhosttyColorScheme>?
) -> Bool {
    guard let context = ioContext(userdata), let outScheme else { return false }
    outScheme.pointee = context.colorScheme
    return true
}

private func cbSize(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ outSize: UnsafeMutablePointer<GhosttySizeReportSize>?
) -> Bool {
    guard let context = ioContext(userdata), let outSize else { return false }
    outSize.pointee = context.reportedSize
    return true
}

private func cbXtversion(_ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?) -> GhosttyString {
    guard let context = ioContext(userdata), !context.muted, let query = context.callbacks.xtversion else {
        return GhosttyString()
    }
    return context.storeXtversion(query())
}

private func cbDeviceAttributes(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ out: UnsafeMutablePointer<GhosttyDeviceAttributes>?
) -> Bool {
    guard let context = ioContext(userdata), !context.muted, let out,
          let query = context.callbacks.deviceAttributes else { return false }
    let answer = query()
    // libghostty zeroes `*out` before the call, so only the fields we report need setting.
    out.pointee.primary.conformance_level = answer.conformanceLevel
    let features = answer.features.prefix(64)
    withUnsafeMutableBytes(of: &out.pointee.primary.features) { raw in
        let slots = raw.bindMemory(to: UInt16.self)
        for (index, feature) in features.enumerated() where index < slots.count {
            slots[index] = feature
        }
    }
    out.pointee.primary.num_features = features.count
    out.pointee.secondary.device_type = answer.deviceType
    out.pointee.secondary.firmware_version = answer.firmwareVersion
    out.pointee.secondary.rom_cartridge = answer.romCartridge
    out.pointee.tertiary.unit_id = answer.unitID
    return true
}

private func cbClipboardWrite(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ write: UnsafePointer<GhosttyClipboardWrite>?
) {
    guard let context = ioContext(userdata), let write else { return }
    let request = write.pointee

    var result = GHOSTTY_CLIPBOARD_WRITE_RESULT_UNSUPPORTED
    if !context.muted, context.callbacks.clipboardWrite != nil,
       request.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD {
        if request.contents_len == 0 {
            // A zero-length contents array asks for the destination to be cleared.
            context.pendingEffects.append(.clipboardWrite(""))
            result = GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS
        } else if let contents = request.contents {
            for index in 0..<request.contents_len {
                let entry = contents[index]
                let mime = swiftString(entry.mime)
                guard mime.isEmpty || mime.hasPrefix("text/") else { continue }
                context.pendingEffects.append(.clipboardWrite(swiftString(entry.data)))
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

/// A DEC 2026 hold began (`held`) or ended. libghostty raises it from `vt_write`, `reset` and
/// `resize`, and pairs the calls: a set during a hold and a reset with no hold raise nothing.
///
/// The mute does not apply. A hold is terminal state, not an effect for the owner, and a muted
/// call can end one: `prepareForPreamble()` resets a muted terminal, and a muted preamble can
/// replay `?2026h`. Dropping those edges would leave `holdOpen` wrong.
private func cbRenderHold(_ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?, _ held: Bool) {
    guard let context = ioContext(userdata) else { return }
    context.holdOpen = held
    if !held { context.holdEnded = true }
}

private func cbClipboardRead(
    _ terminal: VtTerminal?, _ userdata: UnsafeMutableRawPointer?,
    _ read: UnsafePointer<GhosttyClipboardRead>?
) {
    guard let read else { return }
    // Programs never get to read the user's clipboard.
    var reply = GhosttyClipboardReadReply()
    reply.size = MemoryLayout<GhosttyClipboardReadReply>.stride
    reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
    read.pointee.reply?(read, &reply)
}

// MARK: - Bound objects

/// An object holding C memory tied to one terminal, which must be freed while that terminal is
/// still alive (the selection gesture is one). The terminal owns it from `withBound` on and calls
/// `releaseBinding` once, under its lock, just before it frees the C terminal.
protocol TerminalBoundObject: AnyObject {
    func releaseBinding(_ terminal: VtTerminal)
    /// The terminal parsed program output or was reset, so its modes may have changed. Called
    /// under the lock, once per `feed` or `reset`.
    func terminalModesMayHaveChanged(_ terminal: VtTerminal)
}

// MARK: - Locked state

/// The C terminal plus everything that must move under the lock with it.
final class TerminalCore {
    /// nil once the terminal is closed.
    var raw: VtTerminal?
    let context: IOContext
    var cols: UInt16
    var rows: UInt16
    var cellWidthPx: UInt32 = 0
    var cellHeightPx: UInt32 = 0
    /// Called after the lock drops whenever what is on screen may have changed. Set by the view.
    var renderSignal: (@Sendable (RenderHint) -> Void)?
    /// Which `setRenderSignal` call installed `renderSignal`. Every call takes the next number.
    var renderSignalID: UInt64 = 0
    var bound: (any TerminalBoundObject)?
    /// Deliveries produced under the lock and not yet run, oldest first.
    var outbox: [Delivery] = []
    /// Program output fed since a frame last read the terminal. `feed` adds the bytes it writes;
    /// `FrameBuilder.update` reads and zeroes it in the lock hold it takes for
    /// `ghostty_render_state_begin_update`, so each frame's count is exactly the output it consumed.
    /// There is one counter per terminal, so the count is exact only while one view draws the
    /// terminal, as each engine has one view per terminal. Two attached views would split it.
    var outputBytesSinceFrame = 0

    init(raw: VtTerminal, context: IOContext, cols: UInt16, rows: UInt16) {
        self.raw = raw
        self.context = context
        self.cols = cols
        self.rows = rows
    }

    /// The object bound to `raw`, made by `make` on first use. A bound object of another type is
    /// released first, so a binding never outlives its terminal unreleased. Called under the lock.
    func boundObject<Object: TerminalBoundObject>(
        _ raw: VtTerminal, make: (VtTerminal) throws -> Object
    ) rethrows -> Object {
        if let existing = bound as? Object { return existing }
        let object = try make(raw)
        bound?.releaseBinding(raw)
        bound = object
        return object
    }

    /// Takes everything the callbacks accumulated and appends it to the outbox, so it goes out
    /// after everything produced before it. Returns whether it appended anything; only then must
    /// the caller drain. Called under the lock.
    func harvest() -> Bool {
        guard !context.pendingPty.isEmpty || !context.pendingEffects.isEmpty else { return false }
        outbox.append(Delivery(pty: context.pendingPty, effects: context.pendingEffects))
        context.pendingPty.removeAll(keepingCapacity: true)
        context.pendingEffects.removeAll(keepingCapacity: true)
        return true
    }

    /// What a locked call leaves to do once the lock drops: whether to drain the outbox, and the
    /// render signal to run, with its hint, if the call changed the screen. Called under the lock.
    ///
    /// A call signals a render only when it changed the screen and a view has a signal installed.
    /// Such a call takes `IOContext.holdEnded`, clearing it, and puts it in its hint unless
    /// `reportsHoldEnd` is false: a reset or a resize ends a hold the program did not finish. Any
    /// other call leaves it for the next call that signals.
    func aftermath(signalsRender: Bool, reportsHoldEnd: Bool = true) -> Aftermath {
        let drain = harvest()
        guard signalsRender, let renderSignal else { return Aftermath(drain: drain, render: nil) }
        let hint = RenderHint(
            outputBytesSinceFrame: outputBytesSinceFrame,
            holdOpen: context.holdOpen,
            holdEnded: reportsHoldEnd && context.holdEnded)
        context.holdEnded = false
        return Aftermath(drain: drain, render: (signal: renderSignal, hint: hint))
    }
}

/// See `TerminalCore.aftermath(signalsRender:reportsHoldEnd:)`.
struct Aftermath {
    var drain: Bool
    /// The render signal to run and the hint to hand it, when the call changed the screen with a
    /// signal installed. The hint is built under the lock, so it is the terminal as the call left
    /// it.
    var render: (signal: @Sendable (RenderHint) -> Void, hint: RenderHint)?
}

/// What a render signal tells the view about the call that raised it, so the view can decide
/// whether to draw at once or leave the frame to the display link: see `LeadingEdgePolicy`, and
/// "Where the facts come from" in `docs/specs/2026-11-08-libghostty-frame-timing-design.md`.
package struct RenderHint: Sendable, Equatable {
    /// Program output fed since a frame last read the terminal, as the call left it:
    /// `TerminalCore.outputBytesSinceFrame`.
    package var outputBytesSinceFrame = 0
    /// Whether a DEC 2026 hold was open as the call left it: `IOContext.holdOpen`.
    package var holdOpen = false
    /// Whether the program ended a hold since the last call that signalled a render:
    /// `IOContext.holdEnded`, which this call took. A reset's or a resize's hint reports none,
    /// though either ends a hold: the program finished no frame.
    package var holdEnded = false

    /// What `close()` signals: no output and no hold.
    package static let empty = RenderHint()

    /// This hint with a newer one folded in, for a relay that delivers several signals at once.
    /// The byte count and the open hold are state that every call reads afresh, so the newer value
    /// stands. An ended hold is an event that one call takes, so it stands if either hint saw one.
    package func merged(with newer: RenderHint) -> RenderHint {
        RenderHint(
            outputBytesSinceFrame: newer.outputBytesSinceFrame,
            holdOpen: newer.holdOpen,
            holdEnded: holdEnded || newer.holdEnded)
    }
}

/// The DEC 2026 hold as the edges left it: `IOContext.holdOpen` and `IOContext.holdEnded`.
struct RenderHold: Equatable, Sendable {
    var isOpen: Bool
    var ended: Bool
}

/// Names one `setRenderSignal` call, so only the view that installed a signal can clear it.
package struct RenderSignalToken: Equatable, Sendable {
    fileprivate let id: UInt64
}

/// What one locked call produced for the owner's callbacks, to run after the lock drops. The
/// render signal is not part of it: a frame request needs no place in the reply order, so it runs
/// straight after the call and never waits behind another thread's delivery.
struct Delivery: Sendable {
    var pty: [UInt8]
    var effects: [PendingEffect]

    func run(_ callbacks: GhosttyTerminalCallbacks) {
        if !pty.isEmpty { callbacks.writePty?(pty) }
        for effect in effects {
            switch effect {
            case .bell: callbacks.bell?()
            case .clipboardWrite(let text): callbacks.clipboardWrite?(text)
            case .desktopNotification(let title, let body): callbacks.desktopNotification?(title, body)
            case .programStatus(let report): callbacks.programStatus?(report)
            }
        }
    }
}

// MARK: - GhosttyTerminal

/// One libghostty-vt terminal: a VT parser, its screens and scrollback.
///
/// `@unchecked Sendable` because one `NSLock` guards the C handle and everything that moves with it,
/// and every method takes that lock. `feed` may be called from any thread, typically an IO thread,
/// while the view reads the screen on the main thread.
public final class GhosttyTerminal: @unchecked Sendable {
    private let lock = NSLock()
    /// Guarded by `lock`.
    private let core: TerminalCore
    private let callbacks: GhosttyTerminalCallbacks
    /// Held while the outbox is drained, so deliveries run one at a time. Taken only with `lock`
    /// released, and `lock` is taken inside it only briefly, to take the outbox: the order is
    /// always delivery lock, then terminal lock. Recursive so that an owner callback calling back
    /// into the terminal does not deadlock: see `drainOutbox`.
    private let deliveryLock = NSRecursiveLock()
    /// True while a drain runs. Guarded by `deliveryLock`.
    private var isDraining = false

    /// - Parameters:
    ///   - cols: Width in cells, at least 1.
    ///   - rows: Height in cells, at least 1.
    ///   - scrollbackLines: Lines of scrollback kept above the screen.
    ///   - callbacks: Fixed for the terminal's life.
    public init(
        cols: Int, rows: Int, scrollbackLines: Int, callbacks: GhosttyTerminalCallbacks
    ) throws(GhosttyError) {
        let columns = UInt16(clamping: max(cols, 1))
        let lines = UInt16(clamping: max(rows, 1))
        var handle: VtTerminal?
        let created = ghostty_terminal_new(nil, &handle, columns, lines)
        guard created == GHOSTTY_SUCCESS, let handle else {
            let result = GhosttyCallError(result: created, operation: "ghostty_terminal_new").result
            terminalEngineLog.error("ghostty_terminal_new failed: \(result, privacy: .public)")
            // Success with no terminal has no result to report.
            throw GhosttyError.terminalInit(result == 0 ? nil : result)
        }
        let context = IOContext(
            callbacks: callbacks,
            size: GhosttySizeReportSize(rows: lines, columns: columns, cell_width: 0, cell_height: 0))
        do {
            try GhosttyTerminal.configure(handle, context: context, scrollbackLines: max(scrollbackLines, 0))
        } catch let error as GhosttyCallError {
            ghostty_terminal_free(handle)
            terminalEngineLog.error("libghostty terminal setup failed: \(error.description, privacy: .public)")
            throw GhosttyError.terminalInit(error.result)
        } catch {
            ghostty_terminal_free(handle)
            throw GhosttyError.terminalInit(nil)
        }
        self.core = TerminalCore(raw: handle, context: context, cols: columns, rows: lines)
        self.callbacks = callbacks
    }

    deinit { close() }

    /// The most scrollback lines a terminal keeps, whatever it is asked for. A million lines is
    /// beyond any real setting, and keeps the byte ceiling (lines × 4 KiB, about 4 GB) far inside
    /// `Int`.
    static let maxScrollbackLines = 1_000_000
    /// The byte ceiling allowed per scrollback line, generous for wide, styled rows.
    private static let scrollbackBytesPerLine = 4096
    /// The longest unfinished sequence kept for replay. A longer one still parses, but a clone taken
    /// in the middle of it fails.
    /// 64 KiB: the tracker allocates 4 KiB up front, grows on demand, and keeps its largest size.
    static let continuationMaxBytes = 64 << 10
    /// The Kitty image storage limit every terminal is given. Zero disables the protocol: nothing
    /// draws images, so no program should be told they are shown.
    static let kittyImageStorageLimit: UInt64 = 0

    /// Sets every option a new terminal needs. Runs before any byte is fed.
    private static func configure(_ terminal: VtTerminal, context: IOContext, scrollbackLines: Int) throws {
        func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?, _ name: String) throws {
            try ghosttyCheck(ghostty_terminal_set(terminal, option, value), "ghostty_terminal_set(\(name))")
        }

        // USERDATA first: every callback below is handed this pointer. It refers to the IOContext,
        // never to GhosttyTerminal; see the file header for why that is load-bearing. The context
        // outlives the C terminal: both are owned by the core, and the C terminal is freed first.
        try set(GHOSTTY_TERMINAL_OPT_USERDATA,
                UnsafeRawPointer(Unmanaged.passUnretained(context).toOpaque()), "USERDATA")

        // Effects. A function pointer is passed *as* the value, not as a pointer to it.
        // WRITE_PTY is always set: without it paste goes nowhere and no query is answered.
        let writePty: GhosttyTerminalWritePtyFn = cbWritePty
        try set(GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(writePty, to: UnsafeRawPointer.self), "WRITE_PTY")
        let bell: GhosttyTerminalBellFn = cbBell
        try set(GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(bell, to: UnsafeRawPointer.self), "BELL")
        let clipboardWrite: GhosttyTerminalClipboardWriteFn = cbClipboardWrite
        try set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE,
                unsafeBitCast(clipboardWrite, to: UnsafeRawPointer.self), "CLIPBOARD_WRITE")
        let clipboardRead: GhosttyTerminalClipboardReadFn = cbClipboardRead
        try set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ,
                unsafeBitCast(clipboardRead, to: UnsafeRawPointer.self), "CLIPBOARD_READ")
        let notification: GhosttyTerminalDesktopNotificationFn = cbDesktopNotification
        try set(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION,
                unsafeBitCast(notification, to: UnsafeRawPointer.self), "DESKTOP_NOTIFICATION")
        let colorScheme: GhosttyTerminalColorSchemeFn = cbColorScheme
        try set(GHOSTTY_TERMINAL_OPT_COLOR_SCHEME,
                unsafeBitCast(colorScheme, to: UnsafeRawPointer.self), "COLOR_SCHEME")
        let size: GhosttyTerminalSizeFn = cbSize
        try set(GHOSTTY_TERMINAL_OPT_SIZE, unsafeBitCast(size, to: UnsafeRawPointer.self), "SIZE")
        // Set before the first byte, so `holdOpen` sees every edge from the terminal's start.
        let renderHold: GhosttyTerminalRenderHoldFn = cbRenderHold
        try set(GHOSTTY_TERMINAL_OPT_RENDER_HOLD,
                unsafeBitCast(renderHold, to: UnsafeRawPointer.self), "RENDER_HOLD")

        // Optional ones. Left unset, libghostty answers DA and XTVERSION with its own defaults, and
        // gives an OSC 7501 support query no reply.
        if context.callbacks.programStatus != nil {
            let programStatus: GhosttyTerminalProgramStatusFn = cbProgramStatus
            try set(GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS,
                    unsafeBitCast(programStatus, to: UnsafeRawPointer.self), "PROGRAM_STATUS")
        }
        if context.callbacks.deviceAttributes != nil {
            let deviceAttributes: GhosttyTerminalDeviceAttributesFn = cbDeviceAttributes
            try set(GHOSTTY_TERMINAL_OPT_DEVICE_ATTRIBUTES,
                    unsafeBitCast(deviceAttributes, to: UnsafeRawPointer.self), "DEVICE_ATTRIBUTES")
        }
        if context.callbacks.xtversion != nil {
            let xtversion: GhosttyTerminalXtversionFn = cbXtversion
            try set(GHOSTTY_TERMINAL_OPT_XTVERSION, unsafeBitCast(xtversion, to: UnsafeRawPointer.self), "XTVERSION")
        }

        // The name reported to an XTGETTCAP `TN` query: the TERM TBD gives its sessions.
        try "xterm-256color".withCString { cString in
            var terminfo = GhosttyString()
            terminfo.ptr = UnsafeRawPointer(cString).assumingMemoryBound(to: UInt8.self)
            terminfo.len = strlen(cString)
            // The string is copied into the terminal, so a temporary is fine here.
            try set(GHOSTTY_TERMINAL_OPT_TERMINFO_NAME, &terminfo, "TERMINFO_NAME")
        }

        // The byte limit must be set explicitly, and before the line limit: its library default is
        // only 10,000 bytes (about 550 rows at 120 columns) and would otherwise win silently.
        // Whichever limit is reached first applies, so the byte limit is a generous ceiling. The
        // line count is clamped first, so the multiplication cannot overflow.
        let lines = min(scrollbackLines, maxScrollbackLines)
        var scrollbackBytes = max(lines, 256) * scrollbackBytesPerLine
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollbackBytes, "SCROLLBACK_MAX_BYTES")
        var scrollbackMaxLines = lines
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackMaxLines, "SCROLLBACK_MAX_LINES")
        // Mode 2027: grapheme clustering, set as the reset default too so RIS does not lose it.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        try set(GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes, "MODE_DEFAULT(2027)")
        // A program can set a title and read it back into the input stream; keep that off.
        var titleReport = false
        try set(GHOSTTY_TERMINAL_OPT_TITLE_REPORT, &titleReport, "TITLE_REPORT")
        // Keep the bytes of a sequence a write leaves unfinished. Without them libghostty cannot
        // clone a terminal stopped in the middle of one: `ghostty_snapshot_encode` refuses. It has
        // to be on before the sequence starts, so it is set here, before the first byte.
        var retainedBytes = continuationMaxBytes
        try set(GHOSTTY_TERMINAL_OPT_CONTINUATION_MAX_BYTES, &retainedBytes, "CONTINUATION_MAX_BYTES")
        // Kitty graphics off. The renderer draws no images, but libghostty stores them by default
        // (a 10 MB limit) and answers a program's support query with OK, so the program sends
        // images nobody sees. A limit of zero turns the protocol off on both screens, and through
        // a reset: libghostty then answers no Kitty graphics command at all, as a terminal without
        // the protocol does. A library built without Kitty graphics has nothing to turn off, and
        // says so with GHOSTTY_UNSUPPORTED.
        var kittyImageLimit = kittyImageStorageLimit
        let kitty = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &kittyImageLimit)
        if kitty != GHOSTTY_UNSUPPORTED {
            try ghosttyCheck(kitty, "ghostty_terminal_set(KITTY_IMAGE_STORAGE_LIMIT)")
        }
    }

    // MARK: Locking

    /// Runs `body` under the lock. The one place the lock is taken.
    private func locked<T>(_ body: (TerminalCore) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(core)
    }

    /// Runs every queued delivery, oldest first, one at a time. Called, after its lock drops, by
    /// every method that queued a delivery, so what it produced has gone out before it returns:
    /// either this drain runs it, or a drain already running on another thread does, and this one
    /// waits for that drain to finish before finding the outbox empty.
    ///
    /// A call that queued nothing does not drain, and so never waits for another thread's
    /// delivery. That keeps a key, a click or a feed with no reply from waiting on a `writePty`
    /// running on another thread. Nothing it produced is left behind: everything queued was
    /// queued by a call that drains, or by a nested call inside a drain that is still running.
    ///
    /// A callback that calls back into the terminal re-enters here on the same thread. The nested
    /// call only queues its delivery and returns; the drain already running delivers it after the
    /// current callback returns, so callbacks never nest and the order still holds.
    private func drainOutbox() {
        deliveryLock.lock()
        defer { deliveryLock.unlock() }
        guard !isDraining else { return }
        isDraining = true
        defer { isDraining = false }
        while true {
            let batch = locked { core -> [Delivery] in
                var batch: [Delivery] = []
                swap(&batch, &core.outbox)
                return batch
            }
            guard !batch.isEmpty else { return }
            for delivery in batch { delivery.run(callbacks) }
        }
    }

    /// Finishes a locked call once its lock has dropped: drains if it queued a delivery, then
    /// asks for a frame, with its hint, if it changed the screen.
    private func finish(_ aftermath: Aftermath) {
        if aftermath.drain { drainOutbox() }
        if let render = aftermath.render { render.signal(render.hint) }
    }

    /// `withRaw`, plus the locked state, for the calls that keep a count in it: `feed` and a
    /// frame's `begin_update`.
    @discardableResult
    private func withCore<T>(
        signalsRender: Bool, changesModes: Bool, reportsHoldEnd: Bool = true,
        _ body: (TerminalCore, VtTerminal) throws -> T
    ) rethrows -> T? {
        let (value, aftermath): (T?, Aftermath?) = try locked { core in
            guard let raw = core.raw else { return (nil, nil) }
            let value = try body(core, raw)
            if changesModes { core.bound?.terminalModesMayHaveChanged(raw) }
            return (value, core.aftermath(signalsRender: signalsRender, reportsHoldEnd: reportsHoldEnd))
        }
        if let aftermath { finish(aftermath) }
        return value
    }

    /// Runs `body` with the live C terminal under the lock, then delivers whatever the terminal
    /// produced after the lock drops. Returns nil, without running `body`, once the terminal is
    /// closed. `body` must not call back into this terminal. With `changesModes`, the bound
    /// object hears about it after `body`, still under the lock.
    @discardableResult
    func withRaw<T>(
        signalsRender: Bool = false, changesModes: Bool = false, _ body: (VtTerminal) throws -> T
    ) rethrows -> T? {
        try withCore(signalsRender: signalsRender, changesModes: changesModes) { _, raw in try body(raw) }
    }

    /// `withRaw` for a frame's `ghostty_render_state_begin_update`, which also takes the byte
    /// counter: it reads `TerminalCore.outputBytesSinceFrame` and zeroes it in the same lock hold,
    /// so the count returned is exactly the output this update consumed. Returns nil once closed.
    package func withRawTakingOutputBytes<T>(
        _ body: (VtTerminal) throws -> T
    ) rethrows -> (value: T, outputBytes: Int)? {
        try withCore(signalsRender: false, changesModes: false) { core, raw -> (value: T, outputBytes: Int) in
            let value = try body(raw)
            let outputBytes = core.outputBytesSinceFrame
            core.outputBytesSinceFrame = 0
            return (value: value, outputBytes: outputBytes)
        }
    }

    /// `withRaw`, plus the object bound to this terminal, made by `make` on first use, and the
    /// callbacks' context. The terminal owns that object from then on and releases it before it
    /// frees the C terminal. The context is for the DEC 2026 watchdog, which reads `holdOpen` in
    /// the same lock hold as the rest of its work, and sets it after a mode change that raised no
    /// hold edge.
    @discardableResult
    func withBound<Object: TerminalBoundObject, T>(
        signalsRender: Bool = false,
        make: (VtTerminal) throws -> Object,
        _ body: (VtTerminal, Object, IOContext) throws -> T
    ) rethrows -> T? {
        let (value, aftermath): (T?, Aftermath?) = try locked { core in
            guard let raw = core.raw else { return (nil, nil) }
            let value = try body(raw, try core.boundObject(raw, make: make), core.context)
            return (value, core.aftermath(signalsRender: signalsRender))
        }
        if let aftermath { finish(aftermath) }
        return value
    }

    /// `withBound`, except that what the C terminal writes to the pty while `body` runs is returned
    /// instead of delivered to `writePty`. A paste is the one input libghostty writes through
    /// `WRITE_PTY` itself; its bytes are the user's input, so the view sends them the way it sends
    /// a key, and `writePty` keeps carrying only the program's replies. Nothing is captured while
    /// the terminal is muted, because the C callback drops those writes.
    func withBoundCapturingPty<Object: TerminalBoundObject, T>(
        make: (VtTerminal) throws -> Object,
        _ body: (VtTerminal, Object) throws -> T
    ) rethrows -> (value: T, pty: [UInt8])? {
        let (result, aftermath): ((value: T, pty: [UInt8])?, Aftermath?) = try locked { core in
            guard let raw = core.raw else { return (nil, nil) }
            let value = try body(raw, try core.boundObject(raw, make: make))
            let pty = core.context.pendingPty
            core.context.pendingPty.removeAll(keepingCapacity: true)
            return ((value: value, pty: pty), core.aftermath(signalsRender: false))
        }
        if let aftermath { finish(aftermath) }
        return result
    }

    /// Installs the view's frame request, replacing any other. It is called after the lock drops
    /// whenever the screen may have changed, and once more by `close()`. Returns the token that
    /// takes it off again.
    @discardableResult
    package func setRenderSignal(_ signal: @escaping @Sendable (RenderHint) -> Void) -> RenderSignalToken {
        let (token, previous) = locked { core -> (RenderSignalToken, (@Sendable (RenderHint) -> Void)?) in
            let previous = core.renderSignal
            core.renderSignalID &+= 1
            core.renderSignal = signal
            return (RenderSignalToken(id: core.renderSignalID), previous)
        }
        // Released after the lock drops, so nothing it captured is torn down under the lock.
        _ = previous
        return token
    }

    /// Takes the render signal off, if it is still the one `token` installed. A second view over
    /// the same terminal may have installed its own since; clearing that one would leave it
    /// drawing nothing.
    package func clearRenderSignal(_ token: RenderSignalToken) {
        let previous = locked { core -> (@Sendable (RenderHint) -> Void)? in
            guard core.renderSignalID == token.id else { return nil }
            let previous = core.renderSignal
            core.renderSignal = nil
            return previous
        }
        _ = previous
    }

    /// Whether a render signal is installed. A test seam.
    var hasRenderSignal: Bool { locked { $0.renderSignal != nil } }

    /// What the hold edges have recorded, read without clearing anything. A test seam.
    var renderHold: RenderHold {
        locked { RenderHold(isOpen: $0.context.holdOpen, ended: $0.context.holdEnded) }
    }

    /// The byte counter, read without zeroing it. A test seam.
    var outputBytesSinceFrame: Int { locked { $0.outputBytesSinceFrame } }

    // MARK: Public API

    /// Feeds bytes from the program into the parser. Any thread. The callbacks for whatever the
    /// bytes caused run after the lock drops and before this returns. Does nothing once closed.
    ///
    /// The bytes count toward `TerminalCore.outputBytesSinceFrame`, muted or not: a replayed
    /// preamble is output that the next frame draws too.
    public func feed(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        withCore(signalsRender: true, changesModes: true) { core, raw in
            bytes.withUnsafeBufferPointer { buffer in
                ghostty_terminal_vt_write(raw, buffer.baseAddress, buffer.count)
            }
            core.outputBytesSinceFrame += bytes.count
        }
    }

    /// `feed(_:)`, with `underLock` run in the same hold of the lock as the parse, just before it,
    /// for an owner that keeps state of its own beside the terminal's and must change it in the
    /// same step: the daemon's holder emulator stamps when it last took in bytes there, so a
    /// reading of the screen and its age is always of one moment.
    ///
    /// With `muted`, the terminal is muted for exactly this parse, inside the same hold: `writePty`
    /// and the effect callbacks drop what the bytes produce, and the queries are not asked. The
    /// previous mute is put back before the lock drops, so a feed on another thread is never
    /// muted by this one. For replaying a screen whose replies and reports must not reach the
    /// program. `isMuted` is the setting for a mute that spans several calls.
    ///
    /// With `resetFirst`, the parse starts from a cleared terminal, in the same hold, after
    /// `underLock`: every mode back to its default, whether or not the replay names it. Two steps,
    /// both muted. A CAN comes first, because a full reset (`reset()`) clears the screen model and
    /// leaves libghostty's stream parser where it was: inside a sequence the terminal was left in,
    /// the replay's first ESC would otherwise end that sequence, dispatching an open OSC, DCS or
    /// APC, and a partial OSC 8 would put a link on every cell the replay writes. CAN ends the
    /// sequence instead and returns the parser to ground. Whether libghostty dispatches a cut OSC
    /// on the CAN is not relied on: it is muted, and the reset after it puts the screen model
    /// back to its initial state either way. The reset keeps the palette and the dynamic
    /// colours, which a handback does not carry anyway. The program-status clear libghostty
    /// reports for the reset reaches nobody, and like `reset()` it reports no end for a DEC 2026
    /// hold it ends.
    ///
    /// `underLock` must not call back into this terminal: the lock is not recursive. It runs even
    /// for an empty `bytes`, and not at all once the terminal is closed. The bytes count toward
    /// `TerminalCore.outputBytesSinceFrame`, muted or not, as `feed(_:)`'s do.
    package func feed(
        _ bytes: ArraySlice<UInt8>, muted: Bool = false, resetFirst: Bool = false, underLock: () -> Void
    ) {
        withCore(signalsRender: true, changesModes: true, reportsHoldEnd: !resetFirst) { core, raw in
            underLock()
            let wasMuted = core.context.muted
            defer { core.context.muted = wasMuted }
            if resetFirst {
                core.context.muted = true
                Self.cancelSequence.withUnsafeBufferPointer { buffer in
                    ghostty_terminal_vt_write(raw, buffer.baseAddress, buffer.count)
                }
                ghostty_terminal_reset(raw)
            }
            guard !bytes.isEmpty else { return }
            core.context.muted = muted || wasMuted
            bytes.withUnsafeBufferPointer { buffer in
                ghostty_terminal_vt_write(raw, buffer.baseAddress, buffer.count)
            }
            core.outputBytesSinceFrame += bytes.count
        }
    }

    /// CAN: ends any sequence the parser is inside and returns it to ground.
    private static let cancelSequence: [UInt8] = [0x18]

    /// Whether this terminal's lock is held right now, by any thread, the calling one included.
    /// A test seam: from inside `feed(_:muted:resetFirst:underLock:)`'s closure it reads true.
    var isLockHeldForTesting: Bool {
        guard lock.try() else { return true }
        lock.unlock()
        return false
    }

    /// A full reset (RIS) of the screen model: screens, scrollback, modes and the cursor go back
    /// to their initial state. The size is kept. Use before replaying a snapshot into a terminal
    /// that was used before, so nothing from its earlier life (an alternate screen, a colour on
    /// the pen) survives in the model.
    ///
    /// It does not reset libghostty's stream parser: a terminal left inside a sequence is still
    /// inside it, and the next ESC ends it, dispatching an open OSC, DCS or APC.
    /// `feed(_:muted:resetFirst:underLock:)` writes a CAN first for that reason.
    ///
    /// A reset ends any DEC 2026 hold, and its render signal reports no end: the program finished
    /// no frame.
    public func reset() {
        withCore(signalsRender: true, changesModes: true, reportsHoldEnd: false) { _, raw in
            ghostty_terminal_reset(raw)
        }
    }

    /// Resizes the grid. The primary screen reflows; the alternate screen does not.
    public func resize(cols: Int, rows: Int) {
        resize(cols: cols, rows: rows, cellWidthPx: nil, cellHeightPx: nil)
    }

    /// `resize(cols:rows:)`, muted for exactly this resize when `muted` is true: what the resize
    /// produces is dropped, the in-band size report a program asked for with mode 2048 included.
    /// For an owner that keeps a copy of a terminal some other terminal answers the program for.
    package func resize(cols: Int, rows: Int, muted: Bool) {
        resize(cols: cols, rows: rows, cellWidthPx: nil, cellHeightPx: nil, muted: muted)
    }

    /// `resize(cols:rows:)` plus the cell size in pixels, which size reports and image protocols
    /// use. The view passes it; nil keeps the last one.
    ///
    /// With `muted`, the terminal is muted for exactly this resize, inside its hold, and the
    /// previous mute is put back before the lock drops, as `feed(_:muted:resetFirst:underLock:)`
    /// does for a parse.
    package func resize(cols: Int, rows: Int, cellWidthPx: UInt32?, cellHeightPx: UInt32?, muted: Bool = false) {
        let columns = UInt16(clamping: max(cols, 1))
        let lines = UInt16(clamping: max(rows, 1))
        var failure: GhosttyResult?
        let aftermath = locked { core -> Aftermath? in
            guard let raw = core.raw else { return nil }
            let wasMuted = core.context.muted
            if muted { core.context.muted = true }
            defer { core.context.muted = wasMuted }
            let previousSize = core.context.reportedSize
            if let cellWidthPx { core.cellWidthPx = cellWidthPx }
            if let cellHeightPx { core.cellHeightPx = cellHeightPx }
            // Set before the resize: a size report sent from inside it must give the new size.
            core.context.reportedSize = GhosttySizeReportSize(
                rows: lines, columns: columns,
                cell_width: core.cellWidthPx, cell_height: core.cellHeightPx)
            let result = ghostty_terminal_resize(raw, columns, lines, core.cellWidthPx, core.cellHeightPx)
            if result == GHOSTTY_SUCCESS {
                core.cols = columns
                core.rows = lines
            } else {
                core.context.reportedSize = previousSize
                failure = result
            }
            // A resize ends any DEC 2026 hold, and the program finished no frame: no end reported.
            return core.aftermath(signalsRender: true, reportsHoldEnd: false)
        }
        if let failure {
            let error = GhosttyCallError(result: failure, operation: "ghostty_terminal_resize")
            terminalEngineLog.error(
                "resize to \(columns, privacy: .public)x\(lines, privacy: .public) failed: \(error.description, privacy: .public)")
        }
        if let aftermath { finish(aftermath) }
    }

    /// Runs `body` with a read-only view of the terminal, under the lock. `body` must not call back
    /// into this terminal. After `close()` the state reports a closed terminal: `isClosed` is true
    /// and every reading is empty.
    ///
    /// **The state must not escape `body`.** Do not return it, store it, or capture it in a
    /// closure that outlives the call: it reads the C terminal directly, and once the lock drops
    /// another thread may be changing or freeing that terminal. Copy out the values you need
    /// instead. Debug builds enforce this: every reading asserts that `body` has not returned.
    public func withLocked<T>(_ body: (GhosttyTerminalState) throws -> T) rethrows -> T {
        try locked { core in
            let state = GhosttyTerminalState(raw: core.raw, scoped: true)
            defer { state.invalidate() }
            return try body(state)
        }
    }

    /// `withLocked`, plus the mouse encoder the view routes by, in the same lock hold: see
    /// `GhosttyScreenAccess`. The access must not escape `body`.
    ///
    /// The encoder is made first, in a hold of its own, if no input has made it yet. Making it
    /// writes nothing to the terminal.
    public func withScreenAccess<T>(_ body: (GhosttyScreenAccess) throws -> T) rethrows -> T {
        let binding = inputBindingIfOpen()
        return try locked { core in
            let state = GhosttyTerminalState(raw: core.raw, scoped: true)
            defer { state.invalidate() }
            let open = core.raw != nil
            return try body(GhosttyScreenAccess(
                state: state, raw: core.raw, binding: open ? binding : nil))
        }
    }

    /// While true, `writePty` and the effect callbacks are dropped, and the queries are not asked.
    /// For replaying a snapshot, whose replies must not reach the program. A mute for one parse
    /// only is `feed(_:muted:resetFirst:underLock:)`, and for one resize `resize(cols:rows:muted:)`,
    /// each of which sets and restores it inside its own hold.
    public var isMuted: Bool {
        get { locked { $0.context.muted } }
        set { locked { $0.context.muted = newValue } }
    }

    /// True once `close()` has run.
    public var isClosed: Bool { locked { $0.raw == nil } }

    /// Frees the C terminal, under the lock, after what is bound to it. Idempotent. Every later
    /// call does nothing.
    ///
    /// A close calls the installed render signal one last time, after the lock, with an empty
    /// hint, and takes it off. That is how a view over the terminal hears the close: it stops its
    /// cursor blink, and it never draws again.
    public func close() {
        let released = locked { core -> (bound: (any TerminalBoundObject)?, signal: (@Sendable (RenderHint) -> Void)?) in
            let bound = core.bound
            let signal = core.renderSignal
            core.bound = nil
            core.renderSignal = nil
            if let raw = core.raw {
                bound?.releaseBinding(raw)
                core.raw = nil
                ghostty_terminal_free(raw)
            }
            core.context.pendingPty.removeAll()
            core.context.pendingEffects.removeAll()
            return (bound, signal)
        }
        // After the lock, as every render signal runs: a view reads `isClosed` from it.
        released.signal?(.empty)
        // Dropped here, after the lock, so no deinit they trigger can run under it.
        _ = released
    }
}

// MARK: - Colours

extension GhosttyTerminal {
    /// An opaque 8-bit sRGB colour as libghostty takes it.
    package struct VtColor: Equatable {
        var r: UInt8, g: UInt8, b: UInt8
        var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
    }

    /// Sets the default colours, cursor style and colour scheme. A program's own OSC 4/10/11/12
    /// overrides are kept: these are the defaults beneath them. Safe on a live terminal.
    package func applyDefaults(
        foreground: VtColor, background: VtColor, cursor: VtColor, palette: [VtColor],
        cursorStyle: GhosttyCursorStyle, cursorBlink: Bool, darkScheme: Bool
    ) {
        var failure: GhosttyCallError?
        withRaw(signalsRender: true) { raw in
            func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?, _ name: String) throws {
                try ghosttyCheck(ghostty_terminal_set(raw, option, value), "ghostty_terminal_set(\(name))")
            }
            do {
                var fg = foreground.ghostty
                try set(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg, "COLOR_FOREGROUND")
                var bg = background.ghostty
                try set(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg, "COLOR_BACKGROUND")
                var cursorColor = cursor.ghostty
                try set(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursorColor, "COLOR_CURSOR")
                var colors = [GhosttyColorRgb](repeating: GhosttyColorRgb(), count: 256)
                colors.withUnsafeMutableBufferPointer { buffer in ghostty_color_palette_default(buffer.baseAddress) }
                for (index, color) in palette.prefix(256).enumerated() { colors[index] = color.ghostty }
                try colors.withUnsafeBufferPointer { buffer in
                    try set(GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, buffer.baseAddress, "COLOR_PALETTE")
                }
                var style = cursorStyle
                try set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style, "DEFAULT_CURSOR_STYLE")
                var blink = cursorBlink
                try set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink, "DEFAULT_CURSOR_BLINK")
            } catch let error as GhosttyCallError {
                failure = error
            } catch {
                failure = GhosttyCallError(result: GHOSTTY_INVALID_VALUE, operation: "applyDefaults")
            }
        }
        locked { $0.context.colorScheme = darkScheme ? GHOSTTY_COLOR_SCHEME_DARK : GHOSTTY_COLOR_SCHEME_LIGHT }
        if let failure {
            terminalEngineLog.error("applying colours failed: \(failure.description, privacy: .public)")
        }
    }
}
