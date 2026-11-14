import Foundation

/// The words for moving a session from the tmux transport to the pty holder,
/// shared so that the app's menu and every message that sends a person to it
/// name the same item: the parked pane's notice and the composer's note in the
/// app, and the phone's reason for a session parked on tmux, which the daemon
/// writes.
public enum TransportMigrationVocabulary {
    /// The tab menu item that moves a session to the pty holder.
    public static let menuTitle = "Move to Holder (No tmux)"
}
