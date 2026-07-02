import Foundation
import os

/// Delivers bulk paste bytes to a control-mode pane over the `-CC` stream
/// (addendum §2, the >4 KB paste rule). Rather than keystroke-encoding a large
/// payload (`send-keys -H`, chunked), the app-owned bytes are written to a temp
/// file, `load-buffer`ed into a uniquely named tmux buffer, then `paste-buffer`ed
/// into the pane **without `-p`**: the byte stream already carries the app's
/// bracketed-paste markers when the pane enabled them, so `-p` would double-wrap.
enum PasteExecutor {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    enum PasteError: Error, Equatable {
        /// The temp path contained a character that can't be safely single-quoted
        /// into a tmux command (should never happen for a FileManager temp path).
        case unsafeTempPath(String)
    }

    /// Write `bytes` to a temp file, load it into a unique buffer, paste it into
    /// `paneID`, and delete the buffer. Both commands tolerate errors (a failed
    /// paste must not tear down the repo's `-CC` connection) but a failure is
    /// rethrown so the caller (the RPC handler) surfaces it as an error string.
    /// The temp file is removed in all paths.
    static func paste(client: TmuxControlCommandClient, paneID: String, bytes: Data) async throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-paste-\(UUID().uuidString)")
        let path = tempURL.path
        // Single-quote the path in the command (temp paths can contain spaces).
        // tmux single-quote rules: everything inside '…' is literal except '.
        // A FileManager temp path never contains a quote or newline; guard
        // defensively rather than attempt clever escaping.
        guard !path.contains("'"), !path.contains("\n") else {
            throw PasteError.unsafeTempPath(path)
        }

        try bytes.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        // Unique buffer per call so two concurrent pastes never clobber each
        // other's buffer (input frames interleaving between these two commands
        // is harmless — different buffer namespace, and paste-buffer names it).
        let bufferName = "tbd-paste-\(UUID().uuidString.prefix(8))"

        // FIFO keeps these ordered; awaited sequentially so paste follows load.
        _ = try await client.send("load-buffer -b \(bufferName) '\(path)'", tolerateErrors: true)
        _ = try await client.send(
            "paste-buffer -d -b \(bufferName) -t \(paneID)", tolerateErrors: true)
    }
}
