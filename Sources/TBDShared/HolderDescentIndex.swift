import Foundation

/// How a holder-backed row's recorded job is told apart from a stranger that
/// inherited its pid.
///
/// Every reader that matches a holder row's `childPID` against the process
/// table asks the same question with the same number, so the number lives
/// here once: the daemon's reaper, park, wake and collectors, and `tbd peer
/// list`, which cannot link the daemon.
public enum HolderChildIdentity {
    /// How far a job's start time may sit from its row's anchor and still be
    /// believed to be that row's job.
    ///
    /// Five minutes, and the number is doing real work. A holder's job is
    /// forked within milliseconds of its session row being written — the
    /// holder is spawned just before the row, and the design's creation
    /// ordering puts it just after, so the window is symmetric around the
    /// anchor to cover both. Five minutes is therefore enormously generous for
    /// the true child and still excludes pid reuse: wrapping macOS's pid space
    /// inside the window would take on the order of hundreds of process spawns
    /// per second sustained.
    public static let startWindow: TimeInterval = 300

    /// When a holder row's current job was born, as every reader spells it: the
    /// row's own `createdAt` until a park/wake cycle gives it a younger child.
    public static func anchor(of terminal: Terminal) -> Date {
        terminal.holderChildStartedAt ?? terminal.createdAt
    }
}

/// Which holder-backed TBD terminal a process runs inside, by descent from the
/// terminal's live job.
///
/// A holder row has no tmux pane, so the pane fallback the tmux transport
/// joins on has nothing to match. What it does have is a process tree: the
/// holder `forkpty()`s one job per tab, and everything started in that tab —
/// a shell, a launcher script, an agent typed at the prompt — descends from
/// that job. This index answers from that tree and nothing else.
///
/// **Only true descent counts.** A row anchors the walk only while:
///   - it is holder-backed and not parked — a parked row names no process;
///   - its holder is alive;
///   - its recorded job is alive and is still that holder's child — the one
///     relationship a reused pid cannot fake by itself;
///   - and the job started within `HolderChildIdentity.startWindow` of the
///     row's anchor.
/// A working directory, an environment variable or a session name is never
/// consulted: any process can claim any of those, and a consumer that trusts
/// this join to say which tab a session belongs to would hand one tab's
/// identity to another's process.
///
/// It is a view. It reads values it was given and writes nothing — it cannot
/// stamp a session id onto a row, so a shell tab joined here is still a shell
/// tab to every path that decides whether to resume one.
public struct HolderDescentIndex: Sendable {
    /// Where a process sits below a row's job.
    public struct Descent: Sendable, Equatable {
        public let terminalID: UUID
        /// Hops from the row's job to the process: 0 when the process is the
        /// job itself.
        public let depth: Int

        public init(terminalID: UUID, depth: Int) {
            self.terminalID = terminalID
            self.depth = depth
        }
    }

    private let processes: ProcessTableSnapshot
    private let terminalsByJobPID: [pid_t: UUID]

    public init(
        terminals: [Terminal],
        processes: ProcessTableSnapshot,
        startWindow: TimeInterval = HolderChildIdentity.startWindow
    ) {
        self.processes = processes
        var byJob: [pid_t: UUID] = [:]
        var contested: Set<pid_t> = []
        for terminal in terminals {
            guard let job = Self.liveJob(of: terminal, in: processes, startWindow: startWindow)
            else { continue }
            if byJob[job] == nil {
                byJob[job] = terminal.id
            } else {
                contested.insert(job)
            }
        }
        // Two rows naming one live job cannot both be right, and nothing here
        // can say which is: neither anchors anything.
        for job in contested { byJob[job] = nil }
        self.terminalsByJobPID = byJob
    }

    /// The row whose live job `pid` is, or descends from — the nearest such
    /// row on the walk up — or nil when it descends from none.
    public func descent(of pid: pid_t) -> Descent? {
        for (depth, ancestor) in processes.ancestry(of: pid).enumerated() {
            if let terminalID = terminalsByJobPID[ancestor] {
                return Descent(terminalID: terminalID, depth: depth)
            }
        }
        return nil
    }

    /// The row's job pid when the row may anchor a walk, else nil. See the
    /// type's note for each condition.
    static func liveJob(
        of terminal: Terminal, in processes: ProcessTableSnapshot, startWindow: TimeInterval
    ) -> pid_t? {
        guard terminal.transport == .holder, !terminal.isParked,
              let holder = terminal.holderPID, holder > 1,
              let job = terminal.childPID, job > 1,
              processes.isAlive(holder),
              processes.parent(of: job) == holder,
              let started = processes.startTime(of: job),
              abs(started.timeIntervalSince(HolderChildIdentity.anchor(of: terminal))) <= startWindow
        else { return nil }
        return job
    }
}
