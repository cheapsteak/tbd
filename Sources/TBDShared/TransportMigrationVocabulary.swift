import Foundation

/// The words for moving a session from the tmux transport to the pty holder,
/// shared so that the app's menu and every message that sends a person to it
/// name the same item, such as the notice the app shows for a session still
/// running in tmux (`LeftoverTmuxSession.notice(server:)`).
public enum TransportMigrationVocabulary {
    /// The tab menu item that moves a session to the pty holder.
    public static let menuTitle = "Move to Holder (No tmux)"
}
