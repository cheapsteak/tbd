@testable import TBDDaemonLib

extension LeftoverTmuxServerProbe {
    /// Reads every tmux server as gone, and asks no socket and no process
    /// table. It is the probe a test passes to a `WorktreeLifecycle` or a
    /// `HibernationCoordinator` when the suite does not exercise the probe.
    ///
    /// Tests never fall back to the production probe: it reads the machine's
    /// process table, where a tmux process whose argv cannot be read counts as
    /// a running server, so a suite that reached it could refuse a revive or a
    /// wake on whatever tmux the machine happened to run.
    /// `scripts/lint-test-leftover-tmux-probe.py` fails a construction under
    /// `Tests/` that names no probe, and a call to `production()` outside the
    /// suites that test it.
    public static let absent = LeftoverTmuxServerProbe { _ in .absent }
}
