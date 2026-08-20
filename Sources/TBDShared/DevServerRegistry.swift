import Darwin
import Foundation

/// Reads the machine-global dev-server registry: a small cross-app convention
/// for declaring long-lived development servers so that "what is running, for
/// which worktree, and how do I stop it" is a lookup rather than a guess.
///
/// ## Why TBD reads this
///
/// Archiving a worktree removes its checkout and kills the terminal windows its
/// sessions live in. A development server started inside that worktree does not
/// necessarily die with them — a detached supervisor, or a process whose parent
/// exited, is reparented to `launchd` and keeps running with nothing left
/// pointing at it. The directory it was started from can be gone while the
/// process is still holding memory and a port.
///
/// So before an archive removes the last thing that would have told you the
/// server existed, TBD can say: this worktree still has something running.
///
/// ## What this is not
///
/// **Read-only.** TBD never writes a record. Records are written by whatever
/// launcher started the process; a reader that also wrote would have to agree
/// with every writer about fields it does not own.
///
/// **Not a census.** Only a launcher that opts in declares anything. A server
/// started by hand from a shell declares nothing, so an empty result means "no
/// declarations", never "nothing is running".
///
/// **Never a command interpreter.** A record's `command` field is display text.
/// Records are written at runtime by any process, with no review, while this app
/// is trusted and long-running — so executing a string out of one would let a
/// process that cannot run arbitrary commands itself get one run on its behalf.
/// The stop vocabulary is a closed set of typed methods for the same reason.
public enum DevServerLiveness: String, Sendable {
    /// A process with the recorded identity is alive.
    case running
    /// The recorded process is definitively gone.
    case stale
    /// The record could not be read, or the process table could not be. This is
    /// deliberately distinct from `stale`: "cannot tell" must never be treated
    /// as "safe to act on".
    case indeterminate
}

/// One declared server.
public struct DevServerRecord: Sendable, Equatable {
    /// The schema version this reader understands. An unrecognised version
    /// reads `indeterminate` — a future record's fields cannot be interpreted,
    /// so nothing may be concluded from them.
    public static let supportedVersion = 1

    /// Implementations may differ on truncate-vs-round when converting a process
    /// start time to whole seconds. One second of slack costs nothing and
    /// prevents a cross-implementation disagreement from reporting every live
    /// server as dead.
    public static let startEpochToleranceSeconds = 1

    public let version: Int
    public let label: String
    /// Absolute path of the worktree this server belongs to.
    public let root: String
    /// Display text. Never executed.
    public let command: String
    public let pid: Int32?
    public let startEpoch: Int?

    public init(
        version: Int, label: String, root: String, command: String,
        pid: Int32?, startEpoch: Int?
    ) {
        self.version = version
        self.label = label
        self.root = root
        self.command = command
        self.pid = pid
        self.startEpoch = startEpoch
    }

    /// Parse one record, or `nil` when it cannot be read.
    ///
    /// `nil` means indeterminate, never stale.
    public static func decode(from data: Data) -> DevServerRecord? {
        guard
            let object = try? JSONSerialization.jsonObject(with: data),
            let json = object as? [String: Any],
            let version = json["version"] as? Int,
            let label = json["label"] as? String,
            let root = json["root"] as? String
        else { return nil }
        let proc = json["proc"] as? [String: Any]
        return DevServerRecord(
            version: version,
            label: label,
            root: root,
            command: json["command"] as? String ?? "",
            pid: (proc?["pid"] as? Int).map(Int32.init),
            startEpoch: proc?["start_epoch"] as? Int
        )
    }
}

/// Answers the kernel questions a record's liveness depends on.
///
/// A protocol because the states that matter — a reused pid, a process that
/// exited without being reaped — cannot be produced on demand from a test.
public protocol DevServerProcessProbe: Sendable {
    /// Unix epoch seconds at which `pid` started, or `nil` if no such process.
    func startEpoch(pid: Int32) -> Int?
    /// Has `pid` exited without being reaped?
    func isZombie(pid: Int32) -> Bool
}

/// `sysctl(KERN_PROC_PID)`, which answers both questions from one struct.
public struct SysctlDevServerProbe: DevServerProcessProbe {
    public init() {}

    /// `SZOMB` from `<sys/proc.h>`; a C `#define`, so it does not come across in
    /// the Darwin module.
    private static let zombieState: Int32 = 5

    private func info(pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var record = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = sysctl(&mib, UInt32(mib.count), &record, &size, nil, 0)
        // A missing pid is not an error: sysctl returns 0 and sets size to 0.
        // Checking only the return value reads "no such process" as a valid
        // all-zero record, i.e. a process that started at the epoch.
        guard result == 0, size > 0 else { return nil }
        return record
    }

    public func startEpoch(pid: Int32) -> Int? {
        guard pid > 0, let record = info(pid: pid) else { return nil }
        return Int(record.kp_proc.p_starttime.tv_sec)
    }

    public func isZombie(pid: Int32) -> Bool {
        guard pid > 0, let record = info(pid: pid) else { return false }
        return record.kp_proc.p_stat == Self.zombieState
    }
}

/// A record plus the verdict derived from the kernel.
public struct DevServerEntry: Sendable, Equatable {
    public let label: String
    public let root: String
    /// Display text. Never executed.
    public let command: String
    public let liveness: DevServerLiveness

    public init(label: String, root: String, command: String, liveness: DevServerLiveness) {
        self.label = label
        self.root = root
        self.command = command
        self.liveness = liveness
    }
}

public struct DevServerRegistry: Sendable {
    private let probe: DevServerProcessProbe

    public init(probe: DevServerProcessProbe = SysctlDevServerProbe()) {
        self.probe = probe
    }

    /// `${XDG_STATE_HOME:-~/.local/state}/dev-servers/`.
    ///
    /// No vendor segment: the directory is a shared surface that several
    /// unrelated applications write to, and a name owned by one of them gives
    /// the next adopter a reason to invent a second directory instead.
    public static func directory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let state = environment["XDG_STATE_HOME"], !state.isEmpty {
            return URL(fileURLWithPath: state).appendingPathComponent("dev-servers")
        }
        return home.appendingPathComponent(".local/state/dev-servers")
    }

    /// Liveness of `(pid, startEpoch)`, asked of the kernel.
    ///
    /// The identity is the pair, not the pid: a pid alone is reused, and a
    /// record naming a recycled pid would otherwise describe a stranger.
    static func liveness(
        pid: Int32?, startEpoch: Int?, probe: DevServerProcessProbe
    ) -> DevServerLiveness {
        guard let pid, let startEpoch, pid > 0 else { return .indeterminate }
        guard let actual = probe.startEpoch(pid: pid) else { return .stale }
        guard abs(actual - startEpoch) <= DevServerRecord.startEpochToleranceSeconds else {
            return .stale
        }
        // A process that exited without being reaped still reports its original
        // start time, so the pair alone reads a dead server as running forever.
        return probe.isZombie(pid: pid) ? .stale : .running
    }

    static func liveness(of record: DevServerRecord, probe: DevServerProcessProbe) -> DevServerLiveness {
        guard record.version == DevServerRecord.supportedVersion else { return .indeterminate }
        return liveness(pid: record.pid, startEpoch: record.startEpoch, probe: probe)
    }

    /// Every declared server, whatever its state.
    public func all(directory: URL? = nil) -> [DevServerEntry] {
        let dir = directory ?? Self.directory()
        let files =
            (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )) ?? []

        return files.filter { $0.pathExtension == "json" }.map { url in
            guard
                let data = try? Data(contentsOf: url),
                let record = DevServerRecord.decode(from: data)
            else {
                // An unreadable file is surfaced rather than dropped: skipping it
                // would make a malformed record indistinguishable from no record.
                return DevServerEntry(
                    label: url.deletingPathExtension().lastPathComponent,
                    root: "", command: "", liveness: .indeterminate
                )
            }
            return DevServerEntry(
                label: record.label,
                root: record.root,
                command: record.command,
                liveness: Self.liveness(of: record, probe: probe)
            )
        }
    }

    /// Servers still running in `worktreePath`.
    ///
    /// Only `running` — the question this answers is "will archiving this strand
    /// something", and neither a definitively-dead record nor one that cannot be
    /// read is evidence that it will.
    ///
    /// Paths are compared after symlink resolution: a record is written with a
    /// fully-resolved root, while a worktree path can arrive through a symlinked
    /// ancestor, and the two would otherwise never match.
    public func running(inWorktree worktreePath: String, directory: URL? = nil) -> [DevServerEntry] {
        let target = URL(fileURLWithPath: worktreePath).resolvingSymlinksInPath().path
        return all(directory: directory).filter { entry in
            guard entry.liveness == .running, !entry.root.isEmpty else { return false }
            return URL(fileURLWithPath: entry.root).resolvingSymlinksInPath().path == target
        }
    }
}
