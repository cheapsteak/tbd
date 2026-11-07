// Adapted from tkzmux c961533 Sources/TkzTerminalCore/GhosttyVt+Swift.swift (MIT, see third_party/tkzmux). PORT comments mark vt-1.0.0 changes.
// GhosttyVt+Swift.swift — RAII wrappers over the libghostty-vt C API (vendor/ghostty-vt; pinned commit in COMMIT).
// Raw C calls are confined to this file plus KeyEncoder / MouseEncoder / SelectionController / ScrollMetrics / FrameBuilder.
// Handles are deliberately *not* Sendable: TerminalSession (M1.3)
// serialises every access with a lock, and the C objects are not thread-safe.
import GhosttyVt

/// A libghostty-vt call returned something other than `GHOSTTY_SUCCESS`.
public struct GhosttyError: Error, Equatable, Sendable {
    public let result: GhosttyResult
    public let operation: String
}

@inline(__always)
func ghosttyCheck(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else { throw GhosttyError(result: result, operation: operation) }
}

/// Owns a `GhosttyTerminal` (full headless terminal: parser, screens, scrollback).
public final class GhosttyTerminalHandle {
    package let raw: GhosttyTerminal

    public init(cols: UInt16, rows: UInt16) throws {
        var terminal: GhosttyTerminal?
        try ghosttyCheck(ghostty_terminal_new(nil, &terminal, cols, rows), "ghostty_terminal_new")
        guard let terminal else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_terminal_new") }
        raw = terminal
    }

    deinit { ghostty_terminal_free(raw) }

    /// Feed raw pty bytes to the VT parser.
    public func write(_ bytes: UnsafeRawBufferPointer) {
        guard let base = bytes.baseAddress, !bytes.isEmpty else { return }
        ghostty_terminal_vt_write(raw, base.assumingMemoryBound(to: UInt8.self), bytes.count)
    }

    public func write(_ text: String) {
        var copy = text
        copy.withUTF8 { write(UnsafeRawBufferPointer($0)) }
    }

    public func resize(cols: UInt16, rows: UInt16, cellWidthPx: UInt32 = 0, cellHeightPx: UInt32 = 0) throws {
        try ghosttyCheck(ghostty_terminal_resize(raw, cols, rows, cellWidthPx, cellHeightPx), "ghostty_terminal_resize")
    }

    /// The active screen rendered through libghostty's formatter (plain text by default).
    public func formatted(
        _ format: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN,
        trim: Bool = true,
        unwrap: Bool = false
    ) throws -> String {
        // PORT: GhosttyFormatterTerminalOptions is gone in vt-1.0.0. `ghostty_formatter_terminal_new`
        // takes no options any more; each one is set afterwards through `ghostty_formatter_set`.
        var formatter: GhosttyFormatter?
        try ghosttyCheck(ghostty_formatter_terminal_new(nil, &formatter, raw), "ghostty_formatter_terminal_new")
        guard let formatter else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_formatter_terminal_new") }
        defer { ghostty_formatter_free(formatter) }
        var emit = format, wantTrim = trim, wantUnwrap = unwrap
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit), "OPT_EMIT")
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &wantTrim), "OPT_TRIM")
        try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &wantUnwrap), "OPT_UNWRAP")

        var buffer: UnsafeMutablePointer<UInt8>?
        var length = 0
        try ghosttyCheck(ghostty_formatter_format_alloc(formatter, nil, &buffer, &length), "ghostty_formatter_format_alloc")
        guard let buffer else { return "" }
        defer { ghostty_free(nil, buffer, length) }
        return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
    }
}

/// Owns a `GhosttyRenderState` (incremental dirty-row view of a terminal; used by FrameBuilder in M1.5).
public final class GhosttyRenderStateHandle {
    package let raw: GhosttyRenderState

    public init() throws {
        var state: GhosttyRenderState?
        try ghosttyCheck(ghostty_render_state_new(nil, &state), "ghostty_render_state_new")
        guard let state else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_render_state_new") }
        raw = state
    }

    deinit { ghostty_render_state_free(raw) }
}

/// Owns a `GhosttyKeyEncoder` (keyboard events → bytes; wired up in M1.7).
public final class GhosttyKeyEncoderHandle {
    package let raw: GhosttyKeyEncoder

    public init() throws {
        var encoder: GhosttyKeyEncoder?
        try ghosttyCheck(ghostty_key_encoder_new(nil, &encoder), "ghostty_key_encoder_new")
        guard let encoder else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_key_encoder_new") }
        raw = encoder
    }

    deinit { ghostty_key_encoder_free(raw) }
}

/// Owns a `GhosttyMouseEncoder` (mouse events → bytes; wired up in M1.8).
public final class GhosttyMouseEncoderHandle {
    package let raw: GhosttyMouseEncoder

    public init() throws {
        var encoder: GhosttyMouseEncoder?
        try ghosttyCheck(ghostty_mouse_encoder_new(nil, &encoder), "ghostty_mouse_encoder_new")
        guard let encoder else { throw GhosttyError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_mouse_encoder_new") }
        raw = encoder
    }

    deinit { ghostty_mouse_encoder_free(raw) }
}

