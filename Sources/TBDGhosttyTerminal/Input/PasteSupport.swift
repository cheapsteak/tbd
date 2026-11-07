// Adapted from tkzmux c961533 Sources/TkzTerminalCore/PasteSupport.swift (MIT, see LICENSE-tkzmux.txt). PORT comments mark vt-1.0.0 changes.
// PasteSupport.swift — pasting text into a terminal (libghostty-vt `paste.h`, `io.h`).
//
// Headless: the view layer reads `NSPasteboard` and hands us a `String`; nothing here knows about
// AppKit.
//
// ## `GhosttyMimeReader` contract (spike result)
//
// `GhosttyPaste.reader` is `{ read: GhosttyMimeReaderFn, userdata: void* }`, both required
// whenever `mimes_len > 0`. Exactly one callback, `read`; there is no free/finish callback.
//
// - **When**: called *at most once* per `ghostty_terminal_paste()` call, and only for the text
//   representation actually being pasted — never for a MIME type that is merely listed, and never
//   at all for a Kitty paste event (mode 5522). A rejected-then-retried paste therefore reads
//   twice, once per call, and the two reads need not agree.
// - **Ownership / lifetime**: the `mimes` array, the `GhosttyString`s it points at, the `mime`
//   handed to the callback and the `GhosttyWriter` are all *borrowed for the duration of the
//   `ghostty_terminal_paste()` call only*. The `mime` passed in is the identical pointer+length
//   from `mimes`, so a callback may compare by pointer. Nothing the callback writes is retained
//   past the individual `writer.write` call, so the bytes may be borrowed from anywhere and
//   streamed in pieces of any size.
// - **Threading / re-entrancy**: invoked synchronously on the calling thread, inside
//   `ghostty_terminal_paste`. It must **not** re-enter the terminal — the encoded bytes reach
//   `WRITE_PTY` while the paste is in flight, so the write_pty callback must only buffer (which is
//   what `GhosttyTerminal`'s does) and the reader must only produce bytes.
// - **Errors**: return `false` (or stop early when `writer.write` returns `false`) to fail the
//   paste with `GHOSTTY_IO_ERROR`. Nothing is written on any error path.
// - `ghostty_terminal_paste` returns `GHOSTTY_INVALID_VALUE` when no `WRITE_PTY` callback is
//   installed on the terminal. `GhosttyTerminal` always installs one.
import GhosttyVt

/// Why a paste is happening. Mirrors `GhosttyPasteSource`.
enum PasteSource: Sendable, Equatable {
    /// A real user paste (⌘V, menu, middle click). May become a Kitty paste event.
    case clipboard
    /// Text inserted some other way — IME commit, emoji picker, dictation, drag & drop.
    /// Always written as text, never as a paste event.
    case text

    var ghostty: GhosttyPasteSource {
        switch self {
        case .clipboard: GHOSTTY_PASTE_SOURCE_CLIPBOARD
        case .text: GHOSTTY_PASTE_SOURCE_TEXT
        }
    }
}

/// What `PasteSupport.paste` did.
enum PasteOutcome: Sendable, Equatable {
    /// Bytes (the framed text, or a paste event) went to the pty.
    case written
    /// There was nothing to paste.
    case nothingToPaste
    /// The text could inject commands and `allowUnsafe` was false; **nothing was written**.
    /// Confirm with the user, then call again with `allowUnsafe: true`.
    case rejectedUnsafe
}

/// Paste plumbing: safety check plus the `GhosttyMimeReader` bridge.
enum PasteSupport {
    /// Ghostty's conservative safety rule, ignoring terminal state: unsafe if the text contains a
    /// newline (command injection) or the bracketed-paste terminator `ESC [ 201 ~`.
    ///
    /// This is the *stricter* check to apply on top of `paste`, which additionally knows that
    /// newlines are fine inside a bracketed paste.
    static func isSafe(_ text: String) -> Bool {
        var copy = text
        return copy.withUTF8 { bytes in
            guard let base = bytes.baseAddress else { return true }
            return base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                ghostty_paste_is_safe($0, bytes.count)
            }
        }
    }

    /// Paste `text` into `terminal`. Bracketing (mode 2004), unsafe-byte stripping, newline→CR
    /// conversion and chunking all happen inside libghostty; the encoded bytes stream out through
    /// the terminal's `WRITE_PTY` callback, possibly in several pieces.
    ///
    /// Caller holds the terminal lock.
    @discardableResult
    static func paste(
        text: String,
        into terminal: VtTerminal,
        source: PasteSource = .clipboard,
        allowUnsafe: Bool = false
    ) throws -> PasteOutcome {
        guard !text.isEmpty else { return .nothingToPaste }
        var bytes = Array(text.utf8)
        let mimeBytes = Array(Self.plainTextMime.utf8)

        return try bytes.withUnsafeMutableBufferPointer { payload in
            try mimeBytes.withUnsafeBufferPointer { mimePtr in
                var context = TextPayload(base: payload.baseAddress, count: payload.count)
                let mime = GhosttyString(ptr: mimePtr.baseAddress, len: mimePtr.count)

                return try withUnsafePointer(to: mime) { mimeStorage in
                    try withUnsafeMutablePointer(to: &context) { contextPtr in
                        var request = GhosttyPaste()
                        request.size = MemoryLayout<GhosttyPaste>.stride
                        request.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                        request.source = source.ghostty
                        request.mimes = mimeStorage
                        request.mimes_len = 1
                        request.reader = GhosttyMimeReader(read: readTextPayload, userdata: contextPtr)
                        request.allow_unsafe = allowUnsafe

                        var written = false
                        let result = ghostty_terminal_paste(terminal, &request, &written)
                        if result == GHOSTTY_REJECTED { return .rejectedUnsafe }
                        try ghosttyCheck(result, "ghostty_terminal_paste")
                        return written ? .written : .nothingToPaste
                    }
                }
            }
        }
    }

    /// The MIME type we always advertise; the view layer only ever hands us plain text.
    static let plainTextMime = "text/plain"
}

/// Userdata for `readTextPayload` — a borrowed view of the UTF-8 bytes being pasted.
/// A plain struct so the C callback captures nothing.
private struct TextPayload {
    var base: UnsafeMutablePointer<UInt8>?
    var count: Int
}

/// `GhosttyMimeReaderFn`: hand the whole representation to the writer in one call.
/// Must not capture context — userdata carries it (see the contract at the top of this file).
/// A function rather than a global closure constant, like the terminal's own callbacks, so there
/// is no global state for strict concurrency checking to question.
private func readTextPayload(
    _ userdata: UnsafeMutableRawPointer?, _ mime: GhosttyString, _ writer: GhosttyWriter
) -> Bool {
    guard let userdata, let write = writer.write else { return false }
    let payload = userdata.assumingMemoryBound(to: TextPayload.self).pointee
    guard let base = payload.base, payload.count > 0 else { return true }
    // The MIME type is not inspected: we advertise exactly one, so this is the only one asked for.
    return write(writer.userdata, base, payload.count)
}

