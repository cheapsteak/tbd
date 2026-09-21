import TBDShared

/// Whether a holder session's typed screen is something this daemon may judge,
/// and if not, which of the two refusals it earns.
///
/// One decision, in one place, because three callers ask it and a disagreement
/// between them would be invisible: the hibernation park refuses to check a
/// screen for unsent input, the idle sweep decides in advance which rows the
/// park could act on, and the auto-`/login` pump decides whether a caret it can
/// see is a caret the session actually has. All three turn on the same two
/// facts and must answer the same way.
///
/// It carries no wording. Each caller says what a refusal means in its own
/// terms — the park names a gesture the user can take, the pump writes a line
/// saying why it is still waiting — and those sentences have nothing in common
/// but the fact underneath them.
enum HolderScreenEvidence {
    /// Why a screen is not evidence.
    enum Refusal: Equatable, Sendable {
        /// Somebody else is at this session's pty. Either the daemon's
        /// emulator is frozen at the moment of that attach (`.staleDaemon`),
        /// or the viewer answered the pull itself (`.viewer`) — in both the
        /// daemon's grid is not the live screen, and a caret standing in it
        /// proves nothing about now.
        case viewerHoldsPty
        /// The daemon is rendering live, but its emulator was built over a
        /// child that was already running: the TUI above it paints
        /// differentially, so every cell nobody has repainted since holds
        /// something this grid invented rather than something the child wrote.
        case contentUnobserved
    }

    /// The refusal a screen's provenance implies, or nil when it may be judged.
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
