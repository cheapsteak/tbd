import Foundation
import Testing
@testable import TBDDaemonLib

/// Tier 1 — the out-of-tmux evidence `serverPresence` uses to decide what a
/// `list-sessions` that did not answer means, with no tmux server anywhere and
/// no `ps` subprocess. Both halves are pure functions for exactly that reason:
/// the interesting condition (a machine with no tmux process running at all) is
/// not something a test on a shared box can arrange.
@Suite("Tmux server presence")
struct TmuxServerPresenceTests {

    // MARK: - The verdict

    /// The reboot case, and the regression this whole seam exists to fix. Every
    /// tmux server is genuinely gone, so nothing can be listening on any socket
    /// whatever `TMUX_TMPDIR` resolves to — and reconcile must reclaim, or the
    /// rows of every pre-reboot server accumulate forever.
    @Test("no tmux server process anywhere makes a failed list-sessions absent")
    func noTmuxProcessesIsAbsent() {
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: false) == .absent)
    }

    /// The field bug: something IS running and our `-L <name>` did not reach
    /// it, which says nothing about whether it is ours. Protect the rows.
    @Test("a running tmux server process keeps a failed list-sessions unreachable")
    func tmuxProcessesPresentIsUnreachable() {
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: true) == .unreachable)
    }

    /// The doctrine of this change in one assertion: a probe that could not be
    /// taken is not evidence of absence. Two failed reads still say nothing,
    /// and `.absent` is the only verdict that licenses parking or deleting.
    @Test("a probe that itself failed is unreachable, never absent")
    func failedProbeIsUnreachable() {
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: nil) == .unreachable)
        #expect(TmuxManager.classifyFailedServerConsultation(
            tmuxServerProcessesExist: nil) != .absent)
    }

    // MARK: - The matching rule

    @Test("a tmux invocation matches by argv[0] basename, absolute or bare")
    func matchesTmuxBasename() {
        #expect(TmuxManager.isTmuxProcessCommand("tmux -L tbd-acme new-session -d -s main"))
        #expect(TmuxManager.isTmuxProcessCommand("/opt/homebrew/bin/tmux -L tbd-acme attach"))
        #expect(TmuxManager.isTmuxProcessCommand("tmux"))
    }

    /// The rewritten process title, which is what a tmux server shows wherever
    /// `setproctitle` is available.
    @Test("the rewritten tmux: title matches for server and client alike")
    func matchesRewrittenTitle() {
        #expect(TmuxManager.isTmuxProcessCommand("tmux: server (/tmp/tmux-501/tbd-acme)"))
        #expect(TmuxManager.isTmuxProcessCommand("tmux: client (/tmp/tmux-501/tbd-acme)"))
    }

    /// Basename discipline, the same one `AgentReaper.isAgentBinary` keeps: a
    /// path that merely CONTAINS "tmux" is not a tmux process. Over-matching
    /// here would pin `.unreachable` forever on any box that happens to hold a
    /// tmux-ish path, and nothing would ever be reclaimed after a reboot.
    @Test("a path that merely contains tmux does not match")
    func doesNotMatchIncidentalPaths() {
        #expect(!TmuxManager.isTmuxProcessCommand("/Users/me/tmux-notes/bin/editor --flag"))
        #expect(!TmuxManager.isTmuxProcessCommand("tmuxinator start acme"))
        #expect(!TmuxManager.isTmuxProcessCommand("/bin/zsh -ic \"sleep 300\""))
        #expect(!TmuxManager.isTmuxProcessCommand(""))
        #expect(!TmuxManager.isTmuxProcessCommand("   "))
    }

    // MARK: - The snapshot gate

    private static func entry(
        pid: Int32, ppid: Int32, uid: uid_t, command: String
    ) -> ProcessSnapshotEntry {
        ProcessSnapshotEntry(
            pid: pid, ppid: ppid, pgid: pid, uid: uid,
            elapsedSeconds: 120, command: command)
    }

    /// A machine with no tmux anywhere. The reboot state, and the one that must
    /// answer "no".
    @Test("a snapshot with no tmux row reports no server processes")
    func emptyOfTmuxReportsFalse() {
        let snapshot = [
            Self.entry(pid: 10, ppid: 1, uid: 501, command: "/bin/zsh -l"),
            Self.entry(pid: 11, ppid: 1, uid: 501, command: "/usr/bin/ssh-agent -l"),
        ]
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: [], uid: 501, daemonPID: 99))
    }

    /// A tmux server daemonizes away from whoever started it, so its ppid is 1
    /// — never the daemon's. Name-agnostic on purpose: the socket name is what
    /// is under suspicion, so a server under ANY name counts.
    @Test("a daemonized tmux server under any name reports as present")
    func daemonizedServerReportsTrue() {
        let snapshot = [
            Self.entry(pid: 10, ppid: 1, uid: 501, command: "/bin/zsh -l"),
            Self.entry(
                pid: 42, ppid: 1, uid: 501,
                command: "tmux -L someone-elses-name new-session -d -s main"),
        ]
        #expect(TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
    }

    /// Another user's tmux server cannot be ours and is not reachable on our
    /// socket directory either, so it must not veto the reclaim.
    @Test("another uid's tmux server does not count")
    func foreignUIDDoesNotCount() {
        let snapshot = [
            Self.entry(pid: 42, ppid: 1, uid: 502, command: "tmux: server (/tmp/tmux-502/default)"),
        ]
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
    }

    /// The daemon's own in-flight `tmux …` CLI calls are clients, not servers.
    /// Counting them would let a concurrent reconcile probe veto its own
    /// reclaim, and the post-reboot sweep — which runs many tmux commands —
    /// would be exactly when that happens.
    @Test("this daemon's own tmux CLI children do not count")
    func ownCLIChildrenDoNotCount() {
        let snapshot = [
            Self.entry(pid: 43, ppid: 99, uid: 501, command: "tmux -L tbd-acme list-windows -a"),
        ]
        #expect(!TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))

        // …but a real server that happens to sit next to one still counts.
        let withServer = snapshot + [
            Self.entry(pid: 44, ppid: 1, uid: 501, command: "tmux: server (/tmp/tmux-501/tbd-acme)"),
        ]
        #expect(TmuxManager.tmuxServerProcessesExist(
            in: withServer, uid: 501, daemonPID: 99))
    }

    /// A tmux client only exists while attached to a server, so it is evidence
    /// FOR one — and on platforms where tmux does not rewrite its title a
    /// server is indistinguishable from a client by argv anyway. Counting both
    /// errs toward `.unreachable`, the verdict that protects rows.
    @Test("a tmux client counts as evidence that a server is running")
    func clientCountsAsEvidence() {
        let snapshot = [
            Self.entry(pid: 45, ppid: 30, uid: 501, command: "tmux -L tbd-acme attach -t main"),
        ]
        #expect(TmuxManager.tmuxServerProcessesExist(
            in: snapshot, uid: 501, daemonPID: 99))
    }
}
