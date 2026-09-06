import Darwin
import Foundation

/// Who a pid was, at the moment it was recorded.
///
/// A pid on its own is not an identity: the kernel reissues numbers, and a
/// caller acting on one it wrote down earlier has no way to tell its own
/// process from a stranger that inherited the number. The two facts beside it
/// are what close that gap — the start time, which `execve` does not move, and
/// the command line, which says what is running there now.
/// `public` only because it names a parameter of `RPCRouter`'s public
/// initializer (the envelope-suppression seam). Its members stay internal:
/// nothing outside this module constructs or reads one.
public struct ProcessIdentity: Sendable, Equatable {
    let pid: Int32
    /// When the process holding `pid` started, as read from the kernel at the
    /// moment this identity was recorded.
    let startedAt: Date
    /// The command line that pid presented when this identity was recorded.
    let commandLine: String

    init(pid: Int32, startedAt: Date, commandLine: String) {
        self.pid = pid
        self.startedAt = startedAt
        self.commandLine = commandLine
    }

    /// The identity of the process at the other end of a connected `AF_UNIX`
    /// socket, or nil when any part of it could not be read.
    ///
    /// `LOCAL_PEERPID` is a property of the **socket**, not of the path, so it
    /// names the process that actually connected — a peer cannot claim somebody
    /// else's pid on the wire, and no protocol version is needed to carry one.
    /// `HolderClient.peerPID` reads it the same way for the same reason.
    ///
    /// All-or-nothing on purpose: a partial identity would have to be verified
    /// partially, and a check missing either half is the check that lets a
    /// reused pid pass.
    static func ofPeer(onSocket fd: Int32, signaller: any ProcessSignaller) -> ProcessIdentity? {
        guard fd >= 0 else { return nil }
        var pid: pid_t = 0
        var size = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &size) == 0, pid > 0 else {
            return nil
        }
        guard let startedAt = signaller.startTime(pid) else { return nil }
        guard let commandLine = signaller.commandLine(pid), !commandLine.isEmpty else {
            return nil
        }
        return ProcessIdentity(pid: pid, startedAt: startedAt, commandLine: commandLine)
    }
}

/// What a pid looks like now, measured against what was recorded for it.
///
/// Every case except `.same` is a *distinct* reason, because the two callers of
/// this check fail in opposite directions and must be able to tell "this is
/// somebody else" from "the kernel would not say".
enum ProcessIdentityVerdict: Sendable, Equatable {
    /// Alive, started when it was recorded as starting, and presenting an
    /// acceptable executable.
    case same
    /// Nothing holds this pid.
    case notRunning
    /// The pid is alive but its start time could not be read.
    case startTimeUnreadable
    /// The pid is alive and started at a different time: a different process.
    case startTimeMismatch
    /// The pid is alive but its command line could not be read.
    case commandUnreadable
    /// The pid is alive and running something the recorded process was not.
    case foreignExecutable
}

/// The one identity check in this daemon, and deliberately the only one.
///
/// Two callers use it, and they disagree about what to do with every answer —
/// which is exactly why the *check* has to be shared and the *policy* must not
/// be:
///
///   - `AgentReaper.decideHolderChild` is deciding whether to **signal**, so
///     every non-`.same` answer keeps: an uncertain identity must never become
///     a kill.
///   - `AppLivenessArbiter` is deciding whether the daemon may **read a pty
///     again**, so `.notRunning` and both mismatches are death (the app is gone
///     and its descriptors closed with it) while the two unreadable answers are
///     "not yet determined" and change nothing.
///
/// A second implementation of the check is how those two drift apart, and the
/// half that drifts is always the anti-pid-reuse half — the one whose absence
/// is silent until the day a pid is reused.
enum ProcessIdentityCheck {
    /// Whether `pid` still names the process the caller recorded.
    ///
    /// The gate order is the argument, and it is `decideHolderChild`'s:
    /// liveness first (a pid naming nothing is not a stranger, it is nothing),
    /// then the start time (the fact `execve` cannot move), then the
    /// executable (which narrows what a colliding pid could be on top of that).
    ///
    /// `tolerance` is how far the observed start time may sit from `anchor`.
    /// It is a window for a caller whose anchor is a *proxy* for the start —
    /// the reaper anchors on the session row's `createdAt` — and zero for a
    /// caller that recorded the start time itself, where anything but equality
    /// is a different process.
    ///
    /// Empty counts as unreadable, not as a foreign command: `ps` prints
    /// nothing at all for a pid that vanished between the liveness check and
    /// this call, and reporting that as a stranger's executable would name the
    /// wrong reason for the right decision.
    static func verify(
        pid: Int32,
        startedWithin tolerance: TimeInterval,
        of anchor: Date,
        executableIsAcceptable: (String) -> Bool,
        signaller: any ProcessSignaller
    ) -> ProcessIdentityVerdict {
        guard signaller.isAlive(pid) else { return .notRunning }
        guard let started = signaller.startTime(pid) else { return .startTimeUnreadable }
        guard abs(started.timeIntervalSince(anchor)) <= tolerance else { return .startTimeMismatch }
        guard let command = signaller.commandLine(pid), !command.isEmpty else {
            return .commandUnreadable
        }
        guard executableIsAcceptable(command) else { return .foreignExecutable }
        return .same
    }
}
