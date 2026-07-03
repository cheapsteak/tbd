/// Where one SwiftTerm outgoing byte chunk goes. Pure decision logic so the
/// gated branches are unit-testable (the Coordinator just executes it).
///
/// - `.localPTY`: no control-mode attach — the grouped-sessions path writes to
///   the on-screen tmux viewer's PTY, exactly as before control mode existed.
/// - `.sidecarInput`: control mode — every keystroke chunk rides the framed
///   sidecar (low latency, per addendum §2).
///
/// Large pastes are NOT routed here: they are intercepted at the VIEW level
/// (before SwiftTerm brackets them) and shipped as a `.paste` sidecar frame —
/// see `PasteInterception` for the size gate. Everything that reaches
/// SwiftTerm's `send(...)` in control mode is a keystroke (or a ≤4 KiB paste
/// SwiftTerm already bracketed), so there is no size branch here.
enum OutgoingInputRoute: Equatable {
    case localPTY
    case sidecarInput

    static func decide(controlModeAttached: Bool, byteCount: Int) -> OutgoingInputRoute {
        controlModeAttached ? .sidecarInput : .localPTY
    }
}
