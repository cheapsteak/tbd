// MARK: - Permission class

/// The permission class a `<cross-session-message>` attests in `from-mode`.
///
/// **These two values are Claude Code's whole vocabulary, and an enum keeps any
/// other value unrepresentable.** Claude Code 2.1.300's envelope parser accepts
/// exactly `bypass` and `prompting` (its binary carries
/// `var x=["bypass","prompting"]`); any other value — `default` among them —
/// fails that parse and the message counts as attesting no mode at all. Its
/// inbound policy then compares the attested class against the receiving
/// session's own: equal classes deliver, unequal ones are held as
/// `mode-mismatch`, and a message attesting no mode is held as
/// `no-mode-asserted` when the receiver bypasses permission prompts (it is
/// delivered when the receiver prompts). Every hold waits for a human to
/// approve it in the receiving session.
public enum ShadowPeerPermissionClass: String, Sendable, Equatable, CaseIterable {
    /// The receiver runs without permission prompts
    /// (`--dangerously-skip-permissions`, or `bypassPermissions` mode).
    case bypass
    /// The receiver asks before it acts.
    case prompting
}
