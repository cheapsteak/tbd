import TBDDaemonLib

/// `WakeResult.ok`'s `sessionIncarnationID` payload (added so `terminal.wake`
/// can report the incarnation a respawn minted) is more detail than most
/// callers in this suite care about — they only care that the wake succeeded.
/// Pattern-matches the case instead of comparing full equality so `.isOk`
/// call sites don't need to hardcode which incarnation (or none) a given
/// respawn actually minted.
extension WakeResult {
    public var isOk: Bool {
        if case .ok = self {
            return true
        }
        return false
    }
}
