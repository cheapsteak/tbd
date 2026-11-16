import Foundation

/// The words for a session that is still running in a tmux server, which this
/// version of TBD can no longer show, send to, park or end.
///
/// TBD starts sessions only on the pty holder, and it no longer drives tmux at
/// all. A tmux server started by an earlier build can outlive `tbd update`,
/// though, until the Mac restarts, so a row can still be live with its agent
/// running there. The daemon probes that server's socket and the tmux
/// processes that name it: a server that is positively gone gets its row
/// parked, and a server still running leaves the row live, with these words in
/// place of a terminal. Shared so the app's notice and every daemon refusal
/// give a person the same command.
///
/// See `docs/specs/2026-10-11-holder-transport-migration-design.md`, "A live
/// row whose tmux server outlived the update".
public enum LeftoverTmuxSession {
    /// The command that ends every session on `server`.
    public static func killServerCommand(server: String) -> String {
        "tmux -L \(server) kill-server"
    }

    /// How a person ends a leftover session, and what else that ends. One
    /// tmux server carries every tmux tab of a repo, so the command cannot end
    /// one of them alone.
    public static func endingAdvice(server: String) -> String {
        "To end it, run `\(killServerCommand(server: server))`, which also ends this repo's "
            + "other tmux tabs, or restart the Mac, which ends it too."
    }

    /// The label of the app's button that asks the daemon to look again.
    public static let checkAgainTitle = "Check Again"

    /// The notice the app shows in place of the terminal of a row still
    /// running in tmux.
    ///
    /// Written for every kind of tab, because the notice is the same for
    /// all of them: a tab with a conversation is parked once tmux has
    /// stopped, and a tab with none — a shell, a hook tab, an agent tab whose
    /// session never began — has nothing a park could keep
    /// (`nothingToKeepRefusal`).
    public static func notice(server: String) -> String {
        "This session is still running in tmux, which this version of TBD can no longer show. "
            + endingAdvice(server: server)
            + " Then choose \(checkAgainTitle). Once tmux has stopped, a tab with a conversation "
            + "is parked, and \(TransportMigrationVocabulary.menuTitle) brings it back on the "
            + "pty holder; a tab with none has nothing to keep, and can be closed."
    }

    /// What Check Again says about a tab with no conversation once its tmux
    /// server has stopped: a shell, a hook tab, or an agent tab whose session
    /// never began. A park keeps a conversation, and this tab has none, so
    /// there is nothing to bring back and closing it is all that is left.
    public static let nothingToKeepRefusal =
        "tmux has stopped. This tab had no conversation to keep, so close it."

    /// The refusal for any request that would have to reach a session still
    /// running in tmux: a view, a send, a move, a recreate, a wake.
    ///
    /// Names the session, because `tbd terminal migrate` takes its id, and
    /// says what the move does once tmux has stopped.
    public static func stillRunningRefusal(terminalID: UUID, server: String) -> String {
        "Terminal \(terminalID.uuidString) is still running in tmux, which this version of TBD "
            + "can no longer show, send to or stop. "
            + endingAdvice(server: server)
            + " Then run `tbd terminal migrate \(terminalID.uuidString)` to move it to the pty holder."
    }
}
