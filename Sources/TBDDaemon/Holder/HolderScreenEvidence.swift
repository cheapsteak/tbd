import TBDShared

/// Whether a holder session's typed screen is the session's live one, and if
/// not, which of the two reasons it is not.
///
/// Its one caller is `HibernationCoordinator.holderParkSnapshot`, which freezes
/// a parked session's last frame as the tab's backdrop only when that frame is
/// the one the session was showing. The screen decides nothing about whether
/// the park goes ahead.
///
/// It carries no wording, only the fact underneath.
enum HolderScreenEvidence {
    /// Why a screen is not the session's live frame.
    enum Refusal: Equatable, Sendable {
        /// Somebody else is at this session's pty. Either the daemon's
        /// emulator is frozen at the moment of that attach (`.staleDaemon`),
        /// or the viewer answered the pull itself (`.viewer`) — in both the
        /// daemon's grid is not the live screen.
        case viewerHoldsPty
        /// The daemon is rendering live, but its emulator was built over a
        /// child that was already running: the TUI above it paints
        /// differentially, so every cell nobody has repainted since holds
        /// something this grid invented rather than something the child wrote.
        case contentUnobserved
    }

    /// The refusal a screen's provenance implies, or nil when it is the live
    /// screen.
    ///
    /// The source is asked first because it is the coarser fact: it says which
    /// store is rendering live. A screen the daemon does render live then still
    /// has to answer for its content, which is what `contentObserved` says —
    /// whether that store's grid was ever painted by this child.
    static func refusal(
        forSource source: TerminalScreen.Source, contentObserved: Bool
    ) -> Refusal? {
        switch source {
        case .staleDaemon, .viewer: return .viewerHoldsPty
        case .daemon: return contentObserved ? nil : .contentUnobserved
        }
    }
}
