import Darwin
import Foundation
import TBDShared

/// What the probe established about the tmux server a live tmux row names.
enum LeftoverTmuxServerState: Sendable, Equatable {
    /// The server may still be running. Every answer that is not positive
    /// evidence of absence lands here, a successful connect included.
    case running
    /// No socket the server could be listening on answers, and no live tmux
    /// process of this user names the server. The server is gone, and so is
    /// every session it carried.
    case absent
}

/// A live process whose executable is tmux, as the probe's process signal
/// reads it.
struct LeftoverTmuxProcess: Sendable, Equatable {
    let pid: pid_t
    /// The process's real user id, or nil when the process table did not give
    /// it.
    let owner: uid_t?
    /// The process's argv, `argv[0]` included, or nil when the kernel would
    /// not give it.
    let arguments: [String]?
}

/// The tmux server a live tmux row names, and what the probe said about it.
struct LeftoverTmuxServerSighting: Sendable, Equatable {
    /// The server's name, as `tmux -L` takes it.
    let server: String
    let state: LeftoverTmuxServerState
}

/// Whether the tmux server behind a live tmux row is still running, read off
/// its socket and the process table without running the tmux binary.
///
/// TBD no longer drives tmux. It cannot show, send to, park or end a tmux
/// session. A tmux server started by an earlier build can outlive `tbd update`
/// until the Mac restarts, though, so a row can still be live with its agent
/// running there. This probe tells the two cases apart:
///
/// - **Absent** — the row is parked, keeping its session id, and from there
///   the ordinary path moves it: a wake refuses and names
///   `tbd terminal migrate`, the migration rewrites the parked row, and a wake
///   opens it on the pty holder.
/// - **Running** — the row stays live. The app shows a notice in place of the
///   terminal (`LeftoverTmuxSession.notice(server:)`), and the migration and
///   every other request that would have to reach the session refuse with
///   `LeftoverTmuxSession.stillRunningRefusal(terminalID:server:)`.
///
/// It runs wherever reconcile does: at daemon startup, on demand (`tbd
/// cleanup`, a repo add), and every hour in `Daemon.performOrphanMaintenance`,
/// whose `reconcileScratchTerminals` pass probes the servers of scratch
/// worktrees' live tmux rows while the GC switch is on. It also runs when a
/// person asks to check again (`terminal.recreateWindow`) or to migrate the
/// row.
///
/// **This probe is a transition measure; on 2027-01-15 it is replaced by
/// parking on sight**, which parks every live tmux row without asking about
/// its server. By then no tmux server started before the pty holder
/// became the only spawn path (2026-11-14) should still be running, because a
/// restart ends one. Until then a row is parked only on positive evidence that
/// its server is gone, because parking a row whose agent still runs lets a
/// later wake start a second agent on the same session id. See
/// `docs/specs/2026-10-11-holder-transport-migration-design.md`, "A live row
/// whose tmux server outlived the update".
///
/// **Two signals, and the server is gone only when both say so.**
///
/// - **The socket.** A plain connect to every place this daemon can find the
///   server's socket (`candidateSocketPaths`). Every candidate must be
///   positively absent.
/// - **The process table.** No live tmux process of this user may name the
///   server with `-L` (`processState(server:processes:uid:)`). A tmux server
///   keeps the command line of the client that started it, so a running server
///   names itself there wherever its socket is. A process is tmux by its
///   kernel command name or its executable's name (`isTmux`). Another user's
///   tmux processes are left out: tmux keeps each user's sockets under
///   `tmux-<uid>`, so none of them can be a server this user's rows name.
///
/// The socket alone cannot settle it, because the candidates come from this
/// daemon's environment and working directory, and the daemon that started the
/// server may have had others: `tbd update` starts the daemon with the shell's
/// environment, `scripts/restart.sh` with the worktree as its working
/// directory, and the app's fallback launch with the LaunchServices
/// environment, usually without `TMUX_TMPDIR`, from `/`. A server started under
/// a `TMUX_TMPDIR` this daemon does not have is listening somewhere no
/// candidate names. The process table does not depend on either.
///
/// **Tests never get this probe by default.** `WorktreeLifecycle` and
/// `HibernationCoordinator` take one at construction and fall back to
/// `production()` only when none is passed. A test that reached it would read
/// the machine's process table, where a tmux process whose argv cannot be read
/// counts as running. So every construction under `Tests/` names its probe,
/// `.absent` from `DaemonTestSupport` when the suite does not exercise it, and
/// `scripts/lint-test-leftover-tmux-probe.py` holds them to that; only the
/// probe's own suite and the tier-3 reconcile test call `production()`. The
/// type is public so those initializers can take it; its members are
/// internal.
public struct LeftoverTmuxServerProbe: Sendable {
    /// The state of the tmux server with this name (`tmux -L <name>`).
    let state: @Sendable (_ server: String) async -> LeftoverTmuxServerState

    /// How long the probe's connection may wait for a read. It reads nothing:
    /// an `AF_UNIX` connect on Darwin is answered or refused outright and never
    /// queues behind a listener, so the connect itself is the whole probe.
    static let receiveTimeout: Duration = .seconds(2)

    /// The directory tmux falls back to when `TMUX_TMPDIR` names nothing it
    /// can use: `/tmp`, which tmux resolves to its real path.
    static let defaultTemporaryDirectory = "/private/tmp"

    /// Every socket a tmux server named `server` may be listening on: the
    /// one under `TMUX_TMPDIR`, when that value resolves, and always the one
    /// under the fallback root, `<root>/tmux-<uid>/<server>`. Duplicates are
    /// dropped, so a `TMUX_TMPDIR` that resolves to the fallback root gives
    /// one path.
    ///
    /// tmux reads `TMUX_TMPDIR` as one path (a `:` in it does not make a
    /// list) and runs it through `realpath(3)`. When that succeeds the socket
    /// goes under the resolved directory; when it fails — a missing
    /// directory, or a `~/` path, which tmux does not expand here — tmux falls
    /// back to `/tmp` without a word. So this resolves the value the same way
    /// and drops it when the resolve fails. A relative value resolves against
    /// this daemon's working directory, because a daemon ran its tmux clients
    /// in its own. The fallback is probed even when the value resolves,
    /// because the two places cannot both be known to be empty any other way.
    ///
    /// `environment` is this daemon's own, and so is the working directory.
    /// They are the ones that placed the socket only when this daemon started
    /// the server. The daemon that did may have had another `TMUX_TMPDIR` or
    /// another working directory, so these candidates can miss its socket; the
    /// process signal is what covers that (see the type's documentation).
    /// `fallbackRoot` is a seam for tests.
    static func candidateSocketPaths(
        server: String,
        environment: [String: String],
        fallbackRoot: String = defaultTemporaryDirectory,
        uid: uid_t = getuid()
    ) -> [String] {
        var directories: [String] = []
        if let configured = environment["TMUX_TMPDIR"], !configured.isEmpty,
           let resolved = resolvedPath(configured) {
            directories.append(resolved)
        }
        if !directories.contains(fallbackRoot) {
            directories.append(fallbackRoot)
        }
        return directories.map { "\($0)/tmux-\(uid)/\(server)" }
    }

    /// `path` with every symlink and relative component resolved, or nil
    /// when it does not name something that exists — `realpath(3)`, which is
    /// what tmux runs on `TMUX_TMPDIR`.
    static func resolvedPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The probe the daemon runs: a plain connect to each candidate socket,
    /// each closed at once, then, only when every one of them is absent, one
    /// read of the process table. `uid` is the user whose servers the rows
    /// name: it places the candidate sockets and picks out the tmux processes
    /// that count. `uid` and `tmuxProcesses`, which is handed `uid`, are seams
    /// for tests, so no test depends on what tmux the machine is running or
    /// whose it is.
    static func production(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fallbackRoot: String = defaultTemporaryDirectory,
        uid: uid_t = getuid(),
        tmuxProcesses: @escaping @Sendable (_ uid: uid_t) -> [LeftoverTmuxProcess]? = {
            LeftoverTmuxServerProbe.liveTmuxProcesses(uid: $0)
        }
    ) -> LeftoverTmuxServerProbe {
        LeftoverTmuxServerProbe { server in
            await state(
                server: server,
                socketPaths: candidateSocketPaths(
                    server: server, environment: environment, fallbackRoot: fallbackRoot,
                    uid: uid),
                uid: uid,
                tmuxProcesses: { tmuxProcesses(uid) })
        }
    }

    /// Both signals: the server is gone only when every candidate socket is
    /// absent and no tmux process of `uid` names it. The table is read only
    /// when the sockets are all absent, because a socket that answers settles
    /// it.
    static func state(
        server: String,
        socketPaths: [String],
        uid: uid_t,
        tmuxProcesses: () -> [LeftoverTmuxProcess]?
    ) async -> LeftoverTmuxServerState {
        guard await state(ofSocketsAt: socketPaths) == .absent else { return .running }
        return processState(server: server, processes: tmuxProcesses(), uid: uid)
    }

    /// The process signal: absent only when the process table was read and
    /// every tmux process in it that may be `uid`'s has a readable command
    /// line that does not name `server` with `-L`.
    ///
    /// A process whose owner was read and is another user is passed over,
    /// readable command line or not. A table that could not be read is
    /// running, and so is a tmux process that may be `uid`'s — its owner is
    /// `uid` or could not be read — whose command line could not be read,
    /// whatever server is asked about: it may be this server, and nothing else
    /// can say it is not.
    static func processState(
        server: String, processes: [LeftoverTmuxProcess]?, uid: uid_t
    ) -> LeftoverTmuxServerState {
        guard let processes else { return .running }
        for process in processes {
            if let owner = process.owner, owner != uid { continue }
            guard let arguments = process.arguments else { return .running }
            if commandLine(arguments, namesServer: server) { return .running }
        }
        return .absent
    }

    /// tmux's global options that take a value, from its `getopt` string
    /// (`2c:CDdf:lL:NqS:T:uUvV`).
    static let optionsTakingAValue: Set<Character> = ["c", "f", "L", "S", "T"]

    /// Whether a tmux command line names `server` as its `-L` socket name.
    ///
    /// Read the way `getopt` reads a cluster of short options, so all of these
    /// name `tbd-acme`: `-L tbd-acme`, `-Ltbd-acme`, `-uL tbd-acme` and
    /// `-uLtbd-acme`. Within one argument after `argv[0]` that starts with a
    /// single `-`, each letter is an option. The first letter that takes a
    /// value ends the cluster, and its value is the rest of the argument, or
    /// the next argument when nothing is left. A cluster names the server when
    /// that letter is `L` and its value is `server` exactly.
    ///
    /// Every argument is read this way, past the command and past `--`, and a
    /// value is read again as an argument in its own right. Both can only find
    /// a match a strict parse would not, which reads a gone server as running,
    /// never the reverse.
    static func commandLine(_ arguments: [String], namesServer server: String) -> Bool {
        var index = 1
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            guard argument.hasPrefix("-"), !argument.hasPrefix("--") else { continue }
            var letters = argument.dropFirst()
            while let letter = letters.first {
                letters = letters.dropFirst()
                guard optionsTakingAValue.contains(letter) else { continue }
                let value: String?
                if !letters.isEmpty {
                    value = String(letters)
                } else if index < arguments.count {
                    value = arguments[index]
                } else {
                    value = nil
                }
                if letter == "L", value == server { return true }
                break
            }
        }
        return false
    }

    /// Every live process of `uid`'s that is tmux, with its command line; nil
    /// when the process table could not be read.
    ///
    /// The table is one `sysctl(KERN_PROC_ALL)` (`ProcessTableSnapshot`),
    /// which gives each process's real user id and command name. A process's
    /// executable path is its `proc_pidpath` (`ProcessLiveness`), and its
    /// command line the argv in its `KERN_PROCARGS2` buffer
    /// (`ProcessEnvironmentReader.procArgs`).
    static func liveTmuxProcesses(uid: uid_t) -> [LeftoverTmuxProcess]? {
        guard let table = ProcessTableSnapshot.read() else { return nil }
        return tmuxProcesses(
            in: table,
            uid: uid,
            names: tmuxExecutableNames(savedPath: savedTmuxExecutablePath()),
            executablePath: { ProcessLiveness.executablePath(pid: $0) },
            procArgs: { ProcessEnvironmentReader.procArgs(pid: $0) })
    }

    /// The processes of `uid` in `table` that are tmux, by `isTmux`, each
    /// with the command line `procArgs` gives.
    ///
    /// A process the table says another user owns is passed over before
    /// anything else is asked of it: tmux keeps each user's sockets under
    /// `tmux-<uid>`, so it cannot be one of `uid`'s servers, and the kernel
    /// would not give its command line to a daemon that is not root anyway. A
    /// process whose owner the table does not give counts as one of `uid`'s.
    static func tmuxProcesses(
        in table: ProcessTableSnapshot,
        uid: uid_t,
        names: Set<String>,
        executablePath: (pid_t) -> String?,
        procArgs: (pid_t) -> [UInt8]?
    ) -> [LeftoverTmuxProcess] {
        var processes: [LeftoverTmuxProcess] = []
        for (pid, entry) in table.entries.sorted(by: { $0.key < $1.key }) {
            if let owner = entry.realUserID, owner != uid { continue }
            let tmux = isTmux(
                command: entry.command, executablePath: executablePath(pid), names: names)
            guard tmux else { continue }
            let argv = procArgs(pid).flatMap { Self.arguments(inProcArgs: $0) }
            processes.append(LeftoverTmuxProcess(pid: pid, owner: entry.realUserID, arguments: argv))
        }
        return processes
    }

    /// The tmux path saved in `tmux-executable-path` under the TBD home
    /// (`TBDConstants.tmuxExecutablePathFile`), trimmed of surrounding
    /// whitespace, or nil when the file is missing, unreadable or blank.
    ///
    /// The probe reads the file itself, because a server an earlier build
    /// started may run from the binary that file names. The read goes when
    /// the probe does. `file` is a seam for tests.
    static func savedTmuxExecutablePath(
        file: URL = TBDConstants.tmuxExecutablePathFile
    ) -> String? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    /// The names a tmux binary runs under: `tmux`, which is what a `PATH`
    /// lookup finds, and the last component of the saved path
    /// (`savedTmuxExecutablePath`), which can name a binary of any name, both
    /// as saved and with its symlinks resolved.
    static func tmuxExecutableNames(savedPath: String?) -> Set<String> {
        var names: Set<String> = ["tmux"]
        if let savedPath {
            names.insert((savedPath as NSString).lastPathComponent)
            if let resolved = resolvedPath(savedPath) {
                names.insert((resolved as NSString).lastPathComponent)
            }
        }
        names.remove("")
        return names
    }

    /// Whether a process is tmux: its command name is the bytes of one of
    /// `names` cut to `MAXCOMLEN`, as the kernel cuts it, or the last
    /// component of its executable path is one of `names`. The command name
    /// is compared as bytes, so a name whose cut splits a character still
    /// matches.
    ///
    /// The command name comes first because it survives the binary being
    /// deleted: a package manager that upgrades tmux removes the old version's
    /// files, a server started from them keeps running, and from then on
    /// `proc_pidpath` fails for it. The path is asked only when the command
    /// name does not match, and covers a binary run through a link of another
    /// name.
    static func isTmux(
        command: [UInt8]?, executablePath: @autoclosure () -> String?, names: Set<String>
    ) -> Bool {
        if let command, names.contains(where: { commandName($0) == command }) { return true }
        guard let path = executablePath() else { return false }
        return names.contains((path as NSString).lastPathComponent)
    }

    /// `name` as the kernel keeps it for a process it was executed as: the
    /// first `MAXCOMLEN` bytes of its UTF-8, even where that cut splits a
    /// character.
    static func commandName(_ name: String) -> [UInt8] {
        Array(name.utf8.prefix(Int(MAXCOMLEN)))
    }

    /// The argv in a `KERN_PROCARGS2` buffer, `argv[0]` included, or nil when
    /// the buffer claims no arguments or `ProcArgsLayout` cannot read it: too
    /// short, not laid out as the kernel lays it out, or ending before argv
    /// does.
    ///
    /// `ProcArgsLayout` holds the layout, and `ProcessEnvironmentReader` reads
    /// the same buffer through it. argv starts at the boundary the kernel pads
    /// the executable path to, so an empty `argv[0]` is read as one: skipping
    /// every NUL after the path instead would take it for padding and shift
    /// every argument by one. A buffer whose padding is not all NULs is not
    /// that layout, and is unreadable. The tests that start a process with an
    /// empty `argv[0]`, under paths that need each amount of padding, pin it
    /// against the real kernel.
    ///
    /// The environment holds secrets and is never read: the layout stops after
    /// the last argument. An argument that is not UTF-8 reads as empty: it
    /// cannot be a server name TBD chose, so this can only miss a match it
    /// could never have made.
    static func arguments(inProcArgs raw: [UInt8]) -> [String]? {
        guard let layout = ProcArgsLayout(procArgs: raw),
              !layout.argumentRanges.isEmpty else { return nil }
        return layout.argumentRanges.map { String(bytes: raw[$0], encoding: .utf8) ?? "" }
    }

    /// The socket signal: absent only when every candidate socket is
    /// positively absent. One candidate that answers, or fails in any way that
    /// is not evidence of absence, reads as running, and the rest are not
    /// asked.
    static func state(ofSocketsAt socketPaths: [String]) async -> LeftoverTmuxServerState {
        guard !socketPaths.isEmpty else { return .running }
        for socketPath in socketPaths {
            if await state(ofSocketAt: socketPath) == .running {
                return .running
            }
        }
        return .absent
    }

    /// The state of whatever is behind one socket path. Connects, asks nothing
    /// and closes.
    ///
    /// The connect is `HolderClient.connectOnly`, so its failures arrive as
    /// the same `HolderClient.Error.cannotConnect` every holder probe reads,
    /// and `classify(connecting:)` reads them by the same rules.
    static func state(ofSocketAt socketPath: String) async -> LeftoverTmuxServerState {
        let client = HolderClient(socketPath: socketPath, receiveTimeout: receiveTimeout)
        let state = await classify { try await client.connectOnly() }
        await client.close()
        return state
    }

    /// What one connection attempt says about the server.
    ///
    /// The errno rules are `HolderRegistry.exitProbeOutcome(for:)`'s, the one
    /// place they live: only `ENOENT` and `ECONNREFUSED` are evidence that
    /// nothing is listening. A successful connect, any other errno, and a
    /// socket path too long to try are all `running`, because none of them is
    /// evidence that the session ended, and parking a row whose agent still
    /// runs is the one mistake this probe must not make.
    static func classify(
        connecting connect: () async throws -> Void
    ) async -> LeftoverTmuxServerState {
        do {
            try await connect()
            return .running
        } catch {
            switch HolderRegistry.exitProbeOutcome(for: error) {
            case .established:
                return .absent
            case .retry, .keep:
                return .running
            }
        }
    }
}
