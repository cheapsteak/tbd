/// Where one SwiftTerm outgoing byte chunk goes. Pure decision logic so the
/// gated branches are unit-testable (the Coordinator just executes it).
///
/// - `.localPTY`: no control-mode attach — the grouped-sessions path writes to
///   the on-screen tmux viewer's PTY, exactly as before control mode existed.
/// - `.sidecarInput`: control mode, ≤ threshold — a keystroke/small-input frame
///   rides the framed sidecar (low latency, per addendum §2).
/// - `.pasteRPC`: control mode, > threshold — a bulk paste goes over the RPC
///   socket as `pane.paste` (load-buffer + paste-buffer), never keystroke-encoded.
enum OutgoingInputRoute: Equatable {
    case localPTY
    case sidecarInput
    case pasteRPC

    /// Chunks larger than this go the bulk-paste route. Matches the addendum's
    /// ">4 KB → load-buffer + paste-buffer" rule; at or below stays keystroke.
    static let pasteThresholdBytes = 4096

    static func decide(controlModeAttached: Bool, byteCount: Int) -> OutgoingInputRoute {
        guard controlModeAttached else { return .localPTY }
        return byteCount > pasteThresholdBytes ? .pasteRPC : .sidecarInput
    }
}
