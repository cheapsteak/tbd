/// Where one SwiftTerm outgoing byte chunk goes. Pure decision logic so the
/// gated branches are unit-testable (the Coordinator just executes it).
///
/// - `.localPTY`: no control-mode attach — the grouped-sessions path writes to
///   the on-screen tmux viewer's PTY, exactly as before control mode existed.
/// - `.sidecarInput`: control mode — every keystroke chunk rides the framed
///   sidecar (low latency, per addendum §2).
///
/// Pastes are NOT routed here: while attached, EVERY paste — any size — is
/// intercepted at the VIEW level (before SwiftTerm brackets it) and shipped as
/// a `.paste` sidecar frame, or refused when oversize — see `PasteInterception`
/// (the paste ruling v2). Everything that reaches SwiftTerm's `send(...)` in
/// control mode is a keystroke, so there is no size branch here.
enum OutgoingInputRoute: Equatable {
    case localPTY
    case sidecarInput

    static func decide(controlModeAttached: Bool, byteCount: Int) -> OutgoingInputRoute {
        controlModeAttached ? .sidecarInput : .localPTY
    }
}
