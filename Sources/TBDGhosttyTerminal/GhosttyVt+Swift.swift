// Adapted from tkzmux c961533 Sources/TkzTerminalCore/GhosttyVt+Swift.swift (MIT, see LICENSE-tkzmux.txt).
// Thin wrappers over the libghostty-vt C API.
//
// None of these is Sendable and none is thread-safe: the C objects are not. `GhosttyTerminal`
// serialises every access to the C terminal with its lock, and the objects bound to a terminal
// (key and mouse encoders, the selection gesture) are only used while that lock is held.
import GhosttyVt

/// The C terminal handle. `GhosttyTerminal` is this module's Swift class, which shadows the C
/// typedef of the same name, so the C one is always spelled through this alias.
typealias VtTerminal = GhosttyVt.GhosttyTerminal

/// A libghostty-vt call returned something other than `GHOSTTY_SUCCESS`. Internal: the public
/// surface reports `GhosttyError`, and this is what goes in the log line.
struct GhosttyCallError: Error, Equatable, Sendable, CustomStringConvertible {
    let result: Int32
    let operation: String

    init(result: GhosttyResult, operation: String) {
        self.result = Int32(truncatingIfNeeded: result.rawValue)
        self.operation = operation
    }

    var description: String { "\(operation) returned \(result)" }
}

@inline(__always)
func ghosttyCheck(_ result: GhosttyResult, _ operation: String) throws {
    guard result == GHOSTTY_SUCCESS else { throw GhosttyCallError(result: result, operation: operation) }
}

/// Copies a borrowed `GhosttyString` into a Swift `String`. The bytes are only valid until the
/// next call that mutates the terminal, so they are never kept.
@inline(__always)
func swiftString(_ value: GhosttyString) -> String {
    guard let ptr = value.ptr, value.len > 0 else { return "" }
    // Lossy on purpose: a program's bytes are not always valid UTF-8, and a terminal shows what it can.
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: UnsafeBufferPointer(start: ptr, count: value.len), as: UTF8.self)
}

/// Reads a string-valued `GhosttyTerminalData` field, copied out at once.
func terminalString(_ terminal: VtTerminal, _ data: GhosttyTerminalData) -> String {
    var value = GhosttyString()
    guard ghostty_terminal_get(terminal, data, &value) == GHOSTTY_SUCCESS else { return "" }
    return swiftString(value)
}

/// The active screen rendered through libghostty's formatter (plain text by default).
func formatTerminal(
    _ terminal: VtTerminal,
    format: GhosttyFormatterFormat = GHOSTTY_FORMATTER_FORMAT_PLAIN,
    trim: Bool = true,
    unwrap: Bool = false
) throws -> String {
    // vt-1.0.0: `ghostty_formatter_terminal_new` takes no options. Each one is set afterwards
    // through `ghostty_formatter_set`.
    var formatter: GhosttyFormatter?
    try ghosttyCheck(ghostty_formatter_terminal_new(nil, &formatter, terminal), "ghostty_formatter_terminal_new")
    guard let formatter else {
        throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_formatter_terminal_new")
    }
    defer { ghostty_formatter_free(formatter) }
    var emit = format, wantTrim = trim, wantUnwrap = unwrap
    try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_EMIT, &emit), "FORMATTER_OPT_EMIT")
    try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_TRIM, &wantTrim), "FORMATTER_OPT_TRIM")
    try ghosttyCheck(ghostty_formatter_set(formatter, GHOSTTY_FORMATTER_OPT_UNWRAP, &wantUnwrap), "FORMATTER_OPT_UNWRAP")

    var buffer: UnsafeMutablePointer<UInt8>?
    var length = 0
    try ghosttyCheck(
        ghostty_formatter_format_alloc(formatter, nil, &buffer, &length), "ghostty_formatter_format_alloc")
    guard let buffer else { return "" }
    defer { ghostty_free(nil, buffer, length) }
    // swiftlint:disable:next optional_data_string_conversion
    return String(decoding: UnsafeBufferPointer(start: buffer, count: length), as: UTF8.self)
}

/// Owns a `GhosttyRenderState`: the incremental, dirty-row view of a terminal the frame builder
/// reads. A render state copies what it needs out of the terminal in `begin_update`, so it does
/// not depend on the terminal staying alive.
final class GhosttyRenderStateHandle {
    let raw: GhosttyRenderState

    init() throws {
        var state: GhosttyRenderState?
        try ghosttyCheck(ghostty_render_state_new(nil, &state), "ghostty_render_state_new")
        guard let state else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_render_state_new")
        }
        raw = state
    }

    deinit { ghostty_render_state_free(raw) }
}

/// Owns a `GhosttyKeyEncoder` (keyboard events to bytes). Holds no terminal.
final class GhosttyKeyEncoderHandle {
    let raw: GhosttyKeyEncoder

    init() throws {
        var encoder: GhosttyKeyEncoder?
        try ghosttyCheck(ghostty_key_encoder_new(nil, &encoder), "ghostty_key_encoder_new")
        guard let encoder else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_key_encoder_new")
        }
        raw = encoder
    }

    deinit { ghostty_key_encoder_free(raw) }
}

/// Owns a `GhosttyMouseEncoder` (pointer events to bytes). Holds no terminal.
final class GhosttyMouseEncoderHandle {
    let raw: GhosttyMouseEncoder

    init() throws {
        var encoder: GhosttyMouseEncoder?
        try ghosttyCheck(ghostty_mouse_encoder_new(nil, &encoder), "ghostty_mouse_encoder_new")
        guard let encoder else {
            throw GhosttyCallError(result: GHOSTTY_OUT_OF_MEMORY, operation: "ghostty_mouse_encoder_new")
        }
        raw = encoder
    }

    deinit { ghostty_mouse_encoder_free(raw) }
}
