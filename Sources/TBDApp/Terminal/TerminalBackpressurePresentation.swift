import Foundation

/// The panel-level backpressure banner's copy.
///
/// Panel-level rather than in-pane: an in-pane status line writes into the
/// scrollback of a session that is, by construction, in the middle of a paste,
/// so the notice would land inside the person's pasted text.
///
/// A pure function of the byte count so the copy can be pinned by a test
/// without driving SwiftUI. Whether the banner *appears* is the queue's
/// business (`OutgoingInputQueue`'s backpressure edges); this is only what it
/// says once it does.
enum TerminalBackpressurePresentation {
    /// What the banner reads while `pendingBytes` are queued behind a pty that
    /// has stopped accepting writes.
    ///
    /// Deliberately says nothing about loss: nothing is dropped and nothing
    /// has failed. The bytes are queued and land when the agent reads them,
    /// and telling a person otherwise sends them to restart a working session.
    static func message(pendingBytes: Int) -> String {
        "This session is not accepting input — \(amount(pendingBytes)) waiting"
    }

    private static func amount(_ bytes: Int) -> String {
        guard bytes >= 1_024 else { return "\(bytes) bytes" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB]
        formatter.countStyle = .file
        formatter.isAdaptive = false
        return formatter.string(fromByteCount: Int64(bytes))
    }
}
