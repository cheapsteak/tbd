// Adapted from tkzmux c961533 Sources/TkzTerminalCore/TerminalSession.swift (MIT, see LICENSE-tkzmux.txt).
// GhosttyTerminal — one libghostty-vt terminal behind one lock.
//
// ## Callbacks run *inside* `vt_write`
//
// libghostty invokes every effect callback (`WRITE_PTY`, `BELL`, `CLIPBOARD_WRITE`, ...)
// synchronously, on the calling thread, from within `ghostty_terminal_vt_write` (terminal.h: "All
// callbacks are invoked synchronously during VT writes ... no reentrancy"). `vt_write` only runs
// with the lock held, so a callback that took the lock, directly or by calling back into
// `GhosttyTerminal`, would deadlock at once.
//
// The design makes that impossible rather than unlikely:
//
//   * `userdata` points at `IOContext`, a plain class the locked state owns, never at
//     `GhosttyTerminal`. A C callback has no way to reach the lock.
//   * A C callback only appends to `IOContext`'s buffers. It runs under the lock (its caller holds
//     it), so that access is exclusive by construction.
//   * After `vt_write` returns, still under the lock, the terminal *harvests* the buffers. The lock
//     is released, and only then are the owner's callbacks run. So owner code never runs while the
//     lock is held, and may call back into the terminal.
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

/// The engine's log. Subsystem and category are the app's, so one predicate shows every engine.
let terminalEngineLog = Logger(subsystem: "com.tbd.app", category: "terminalEngine")

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
// Each of these runs inside `ghostty_terminal_vt_write` (or `ghostty_terminal_paste`), with the
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
    var renderSignal: (@Sendable () -> Void)?
    var bound: (any TerminalBoundObject)?

    init(raw: VtTerminal, context: IOContext, cols: UInt16, rows: UInt16) {
        self.raw = raw
        self.context = context
        self.cols = cols
        self.rows = rows
    }

    /// Takes everything the callbacks accumulated. Called under the lock.
    func harvest(signal: Bool) -> Delivery {
        let delivery = Delivery(
            pty: context.pendingPty, effects: context.pendingEffects,
            renderSignal: signal ? renderSignal : nil)
        context.pendingPty.removeAll(keepingCapacity: true)
        context.pendingEffects.removeAll(keepingCapacity: true)
        return delivery
    }
}

/// What one locked call produced, to run after the lock drops.
struct Delivery: Sendable {
    var pty: [UInt8]
    var effects: [PendingEffect]
    var renderSignal: (@Sendable () -> Void)?

    static let none = Delivery(pty: [], effects: [], renderSignal: nil)

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
        renderSignal?()
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
            throw GhosttyError.terminalInit(result == 0 ? -1 : result)
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
            throw GhosttyError.terminalInit(-1)
        }
        self.core = TerminalCore(raw: handle, context: context, cols: columns, rows: lines)
        self.callbacks = callbacks
    }

    deinit { close() }

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
        // Whichever limit is reached first applies, so the byte limit is a generous ceiling.
        var scrollbackBytes = max(scrollbackLines, 256) * 4096
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &scrollbackBytes, "SCROLLBACK_MAX_BYTES")
        var scrollbackMaxLines = scrollbackLines
        try set(GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &scrollbackMaxLines, "SCROLLBACK_MAX_LINES")
        // Mode 2027: grapheme clustering, set as the reset default too so RIS does not lose it.
        var graphemes = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
        try set(GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &graphemes, "MODE_DEFAULT(2027)")
        // A program can set a title and read it back into the input stream; keep that off.
        var titleReport = false
        try set(GHOSTTY_TERMINAL_OPT_TITLE_REPORT, &titleReport, "TITLE_REPORT")
    }

    // MARK: Locking

    /// Runs `body` under the lock. The one place the lock is taken.
    private func locked<T>(_ body: (TerminalCore) throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(core)
    }

    /// Runs `body` with the live C terminal under the lock, then delivers whatever the terminal
    /// produced after the lock drops. Returns nil, without running `body`, once the terminal is
    /// closed. `body` must not call back into this terminal.
    @discardableResult
    func withRaw<T>(signalsRender: Bool = false, _ body: (VtTerminal) throws -> T) rethrows -> T? {
        var delivery = Delivery.none
        let value: T? = try locked { core in
            guard let raw = core.raw else { return nil }
            let value = try body(raw)
            delivery = core.harvest(signal: signalsRender)
            return value
        }
        delivery.run(callbacks)
        return value
    }

    /// `withRaw`, plus the object bound to this terminal, made by `make` on first use. The terminal
    /// owns that object from then on and releases it before it frees the C terminal.
    @discardableResult
    func withBound<Object: TerminalBoundObject, T>(
        signalsRender: Bool = false,
        make: (VtTerminal) throws -> Object,
        _ body: (VtTerminal, Object) throws -> T
    ) rethrows -> T? {
        var delivery = Delivery.none
        let value: T? = try locked { core in
            guard let raw = core.raw else { return nil }
            let object: Object
            if let existing = core.bound as? Object {
                object = existing
            } else {
                object = try make(raw)
                core.bound = object
            }
            let value = try body(raw, object)
            delivery = core.harvest(signal: signalsRender)
            return value
        }
        delivery.run(callbacks)
        return value
    }

    /// The view's frame request. Called after the lock drops whenever the screen may have changed.
    func setRenderSignal(_ signal: (@Sendable () -> Void)?) {
        let previous = locked { core -> (@Sendable () -> Void)? in
            let previous = core.renderSignal
            core.renderSignal = signal
            return previous
        }
        // Released after the lock drops, so nothing it captured is torn down under the lock.
        _ = previous
    }

    // MARK: Public API

    /// Feeds bytes from the program into the parser. Any thread. The callbacks for whatever the
    /// bytes caused run after the lock drops and before this returns. Does nothing once closed.
    public func feed(_ bytes: ArraySlice<UInt8>) {
        guard !bytes.isEmpty else { return }
        withRaw(signalsRender: true) { raw in
            bytes.withUnsafeBufferPointer { buffer in
                ghostty_terminal_vt_write(raw, buffer.baseAddress, buffer.count)
            }
        }
    }

    /// A full reset (RIS): screens, scrollback, modes and the cursor go back to their initial
    /// state. The size is kept. Use before replaying a snapshot into a terminal that was used
    /// before, so nothing from its earlier life (an alternate screen, a colour) survives.
    public func reset() {
        withRaw(signalsRender: true) { raw in ghostty_terminal_reset(raw) }
    }

    /// Resizes the grid. The primary screen reflows; the alternate screen does not.
    public func resize(cols: Int, rows: Int) {
        resize(cols: cols, rows: rows, cellWidthPx: nil, cellHeightPx: nil)
    }

    /// `resize(cols:rows:)` plus the cell size in pixels, which size reports and image protocols
    /// use. The view passes it; nil keeps the last one.
    func resize(cols: Int, rows: Int, cellWidthPx: UInt32?, cellHeightPx: UInt32?) {
        let columns = UInt16(clamping: max(cols, 1))
        let lines = UInt16(clamping: max(rows, 1))
        var delivery = Delivery.none
        var failure: GhosttyResult?
        locked { core in
            guard let raw = core.raw else { return }
            if let cellWidthPx { core.cellWidthPx = cellWidthPx }
            if let cellHeightPx { core.cellHeightPx = cellHeightPx }
            let result = ghostty_terminal_resize(raw, columns, lines, core.cellWidthPx, core.cellHeightPx)
            if result == GHOSTTY_SUCCESS {
                core.cols = columns
                core.rows = lines
                core.context.reportedSize = GhosttySizeReportSize(
                    rows: lines, columns: columns,
                    cell_width: core.cellWidthPx, cell_height: core.cellHeightPx)
            } else {
                failure = result
            }
            delivery = core.harvest(signal: true)
        }
        if let failure {
            let error = GhosttyCallError(result: failure, operation: "ghostty_terminal_resize")
            terminalEngineLog.error(
                "resize to \(columns, privacy: .public)x\(lines, privacy: .public) failed: \(error.description, privacy: .public)")
        }
        delivery.run(callbacks)
    }

    /// Runs `body` with a read-only view of the terminal, under the lock. The state is valid only
    /// inside `body`; do not keep it. `body` must not call back into this terminal. After `close()`
    /// the state reports a closed terminal: `isClosed` is true and every reading is empty.
    public func withLocked<T>(_ body: (GhosttyTerminalState) throws -> T) rethrows -> T {
        try locked { core in try body(GhosttyTerminalState(raw: core.raw)) }
    }

    /// While true, `writePty` and the effect callbacks are dropped, and the queries are not asked.
    /// For replaying a snapshot, whose replies must not reach the program.
    public var isMuted: Bool {
        get { locked { $0.context.muted } }
        set { locked { $0.context.muted = newValue } }
    }

    /// True once `close()` has run.
    public var isClosed: Bool { locked { $0.raw == nil } }

    /// Frees the C terminal, under the lock, after what is bound to it. Idempotent. Every later
    /// call does nothing.
    public func close() {
        let released = locked { core -> (bound: (any TerminalBoundObject)?, signal: (@Sendable () -> Void)?) in
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
        // Dropped here, after the lock, so no deinit they trigger can run under it.
        _ = released
    }
}

// MARK: - Colours

extension GhosttyTerminal {
    /// An opaque 8-bit sRGB colour as libghostty takes it.
    struct VtColor: Equatable {
        var r: UInt8, g: UInt8, b: UInt8
        var ghostty: GhosttyColorRgb { GhosttyColorRgb(r: r, g: g, b: b) }
    }

    /// Sets the default colours, cursor style and colour scheme. A program's own OSC 4/10/11/12
    /// overrides are kept: these are the defaults beneath them. Safe on a live terminal.
    func applyDefaults(
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
