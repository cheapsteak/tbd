import Foundation
import os

/// Delivers bulk paste bytes to a control-mode pane over the `-CC` stream
/// (every control-mode paste, any size — the paste ruling v2). Rather than
/// keystroke-encoding the payload (`send-keys -H`, chunked), the app-owned
/// bytes are written to a temp file,
/// `load-buffer`ed into a uniquely named tmux buffer, then `paste-buffer`ed into
/// the pane **with `-p`**.
///
/// The app intercepts the paste at the SwiftTerm VIEW level, BEFORE SwiftTerm
/// would add bracketed-paste markers — so the payload that reaches here is bare.
/// `-p` hands wrapping authority to tmux: tmux surrounds the paste with
/// `ESC[200~`/`ESC[201~` IFF the target pane has bracketed-paste mode enabled,
/// and emits the bare bytes otherwise. tmux is the single authority on the
/// pane's mode, so there is no double-wrap and no missing wrap.
enum PasteExecutor {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

    enum PasteError: LocalizedError, Equatable {
        /// The temp path contained a character that can't be safely single-quoted
        /// into a tmux command (should never happen for a FileManager temp path).
        case unsafeTempPath(String)

        var errorDescription: String? {
            switch self {
            case .unsafeTempPath(let path):
                return "Paste temp path can't be safely quoted into a tmux command: \(path)"
            }
        }
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

        // Register the cleanup defer BEFORE the write, so a mid-write throw
        // (e.g. disk full) still removes any partial temp file rather than
        // orphaning it — the doc comment's "removed in all paths" guarantee.
        defer { try? FileManager.default.removeItem(at: tempURL) }
        try bytes.write(to: tempURL)

        // Unique buffer per call so two concurrent pastes never clobber each
        // other's buffer (input frames interleaving between these two commands
        // is harmless — different buffer namespace, and paste-buffer names it).
        let bufferName = "tbd-paste-\(UUID().uuidString.prefix(8))"

        // FIFO keeps these ordered; awaited sequentially so paste follows load.
        _ = try await client.send("load-buffer -b \(bufferName) '\(path)'", tolerateErrors: true)
        do {
            _ = try await client.send(
                "paste-buffer -d -p -b \(bufferName) -t \(paneID)", tolerateErrors: true)
        } catch {
            // load-buffer succeeded but paste-buffer threw (e.g. the pane died
            // between the two awaits). The `-d` on paste-buffer would have
            // deleted the buffer on success; since it didn't run, the uniquely
            // named buffer would otherwise accumulate forever in the long-lived
            // `-CC` server. Best-effort delete before rethrowing (errors
            // tolerated — a failed cleanup must not mask the real error), but
            // a cleanup failure is at least made VISIBLE: the leaked
            // tbd-paste-<uuid> buffer is otherwise undiscoverable. Narrow
            // residual race: if paste-buffer actually ran (its -d deleted the
            // buffer) and only its REPLY was lost, this delete-buffer fails
            // on an already-gone buffer — that harmless case logs too.
            do {
                _ = try await client.send("delete-buffer -b \(bufferName)", tolerateErrors: true)
            } catch let cleanupError {
                Self.logger.debug("""
                    delete-buffer cleanup failed for \(bufferName, privacy: .public): \
                    \(String(describing: cleanupError), privacy: .public) — the buffer may \
                    linger on the tmux server (original paste error is rethrown)
                    """)
            }
            throw error
        }
    }
}
