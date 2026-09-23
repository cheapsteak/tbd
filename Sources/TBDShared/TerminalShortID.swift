import Foundation

/// The short form of a terminal row's id: the first eight characters of its
/// UUID, exactly as `tbd terminal list` prints the full id (upper-case hex).
///
/// This is how TBD names *which* terminal a peer or a listing row is, whatever
/// transport the terminal runs on. A tmux pane cannot serve: a holder-backed
/// terminal has no pane, so every holder row in a worktree would name the same
/// empty coordinate, and a tmux terminal is given a new pane when it is woken
/// from a park, so a pane-based name would change under its peers.
/// The terminal id is minted once, when the row is created, and carried by
/// both transports alike — and because it is a prefix of what `tbd terminal
/// list` prints, a reader holding the short form can find the row it names in
/// that listing. No command accepts the short form as an argument.
public enum TerminalShortID {
    /// How many leading characters of the UUID the short form keeps.
    public static let length = 8

    /// The short form of `id`.
    public static func of(_ id: UUID) -> String {
        String(id.uuidString.prefix(length))
    }
}
