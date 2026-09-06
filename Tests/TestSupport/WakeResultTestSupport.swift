import TBDDaemonLib

/// Test-only helper for `WakeResult.ok`, whose `sessionIncarnationID` payload
/// (added so `terminal.wake` can report the incarnation a respawn minted) most
/// callers in this suite don't care about — they only care that the wake
/// succeeded. Pattern-matches the case instead of comparing full equality so
/// `== .ok` call sites don't need to hardcode which incarnation (or none) a
/// given respawn actually minted.
public func isWakeOk(_ result: WakeResult) -> Bool {
    if case .ok = result {
        return true
    }
    return false
}
