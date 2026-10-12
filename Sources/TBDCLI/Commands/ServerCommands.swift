import ArgumentParser
import Foundation
import TBDShared

struct ServerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Start, stop and inspect a worktree's dev servers",
        discussion: """
            Servers are declared in .claude/launch.json, tbd.toml or \
            ~/tbd/repos/<repoID>/servers.toml, and report their URLs through a \
            running file. Logs are the server's tab: read them with \
            `tbd terminal output <terminal-id>`. See docs/dev-servers.md.
            """,
        subcommands: [ServerList.self, ServerStart.self, ServerStop.self, ServerRestart.self,
                      ServerStatus.self, ServerOpen.self, ServerReport.self])

    /// `--url` values: `<url>` or `<name>=<url>`. Unnamed ones are `main`,
    /// then `main-2`, `main-3`.
    static func parseEndpoints(_ raw: [String], server: String) throws -> [DevServerEndpoint] {
        var endpoints: [DevServerEndpoint] = []
        var unnamed = 0
        for value in raw {
            let name: String
            let url: String
            if let eq = value.firstIndex(of: "="), !value[..<eq].contains(":") {
                name = String(value[..<eq])
                url = String(value[value.index(after: eq)...])
                guard !name.isEmpty else { throw CLIError.invalidArgument("--url \(value): the endpoint name is empty") }
            } else {
                url = value
                unnamed += 1
                name = unnamed == 1 ? "main" : "main-\(unnamed)"
            }
            guard let parsed = URL(string: url), parsed.scheme != nil, parsed.host != nil else {
                throw CLIError.invalidArgument("--url \(value): not an absolute URL (include the scheme, e.g. http://localhost:3000)")
            }
            guard !endpoints.contains(where: { $0.name == name }) else {
                throw CLIError.invalidArgument("--url \(value): endpoint name \(name) is used twice; give each --url a distinct name")
            }
            endpoints.append(DevServerEndpoint(name: name, url: url))
        }
        return endpoints
    }

    static func urlToOpen(in list: DevServerListResult, server: String?, endpoint: String?) throws -> String {
        let candidates: [DevServerInfo]
        if let server {
            guard let info = list.servers.first(where: { $0.name == server }) else {
                throw CLIError.invalidArgument("No server named \(server) in this worktree.")
            }
            candidates = [info]
        } else {
            candidates = list.servers.filter { $0.state == .running && !$0.endpoints.isEmpty }
        }
        for info in candidates {
            if let endpoint {
                if let match = info.endpoints.first(where: { $0.name == endpoint }) { return match.url }
            } else if let url = info.mainURL {
                return url
            }
        }
        let subject = server ?? "Any running server"
        if let endpoint {
            throw CLIError.invalidArgument("\(subject) has reported no endpoint named \(endpoint).")
        }
        throw CLIError.invalidArgument(
            "\(subject) has reported no URL. A server reports URLs by writing a running file (see `tbd server report`).")
    }

    static func describe(_ info: DevServerInfo) -> String {
        switch info.state {
        case .running: return info.endpoints.isEmpty ? "running" : "running, with URLs"
        case .exited: return info.exitCode.map { "exited (code \($0))" } ?? "exited"
        case .stopped: return "stopped"
        case .unknown: return "unknown (status command timed out)"
        }
    }

    static func render(_ list: DevServerListResult) -> String {
        var lines: [String] = []
        if list.servers.isEmpty { lines.append("No dev servers declared or reported in this worktree.") }
        for info in list.servers {
            lines.append(tableRow([
                (info.name, 16), (describe(info), 28),
                (info.source ?? "undeclared", 0),
            ]))
            for endpoint in info.endpoints { lines.append("    \(endpoint.name): \(endpoint.url)") }
            if let terminalID = info.terminalID { lines.append("    tab: \(terminalID.uuidString)") }
        }
        for error in list.parseErrors { lines.append("Could not read \(error.path): \(error.message)") }
        return lines.joined(separator: "\n")
    }

    static func render(_ result: DevServerActionResult, verb: String) -> String {
        if result.outcomes.isEmpty { return "No servers to \(verb)." }
        return result.outcomes.map { outcome in
            switch outcome.status {
            case .started: return "\(outcome.name): started in tab \(outcome.terminalID?.uuidString ?? "?")"
            case .alreadyRunning: return "\(outcome.name): already running" + (outcome.terminalID.map { " in tab \($0.uuidString)" } ?? "")
            case .stopped: return "\(outcome.name): stopped"
            case .notRunning: return "\(outcome.name): not running"
            case .failed: return "\(outcome.name): failed — \(outcome.message ?? "unknown error")"
            }
        }.joined(separator: "\n")
    }
}

/// `--worktree`, else `TBD_WORKTREE_ID`, else the current directory.
struct ServerWorktreeOption: ParsableArguments {
    @Option(name: .long, help: "Worktree name, display name or UUID (defaults to TBD_WORKTREE_ID, then the current directory)")
    var worktree: String?

    func resolve(client: SocketClient, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> UUID {
        if let worktree { return try resolveWorktreeNameOrID(worktree, client: client) }
        if let value = environment["TBD_WORKTREE_ID"], let id = UUID(uuidString: value) { return id }
        return try PathResolver(client: client).resolveWorktreeID()
    }
}

private func fetchList(_ client: SocketClient, _ id: UUID, runStatusCommands: Bool) throws -> DevServerListResult {
    try client.call(method: RPCMethod.serverList,
                    params: DevServerListParams(worktreeID: id, runStatusCommands: runStatusCommands),
                    resultType: DevServerListResult.self)
}

private func act(_ method: String, _ client: SocketClient, _ id: UUID, _ names: [String]) throws -> DevServerActionResult {
    try client.call(method: method, params: DevServerActionParams(worktreeID: id, names: names),
                    resultType: DevServerActionResult.self)
}

struct ServerList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list", abstract: "Every declared or reported server, its state, URLs and source")
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let list = try fetchList(client, try target.resolve(client: client), runStatusCommands: true)
        if json { printJSON(list) } else { print(ServerCommand.render(list)) }
    }
}

struct ServerStart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start servers (all declared servers when none are named)")
    @Argument(help: "Server names") var names: [String] = []
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let result = try act(RPCMethod.serverStart, client, try target.resolve(client: client), names)
        if json { printJSON(result) } else { print(ServerCommand.render(result, verb: "start")) }
        if !result.allSucceeded { throw ExitCode(1) }
    }
}

struct ServerStop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop servers (every running server when none are named)")
    @Argument(help: "Server names") var names: [String] = []
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let result = try act(RPCMethod.serverStop, client, try target.resolve(client: client), names)
        if json { printJSON(result) } else { print(ServerCommand.render(result, verb: "stop")) }
        if !result.allSucceeded { throw ExitCode(1) }
    }
}

struct ServerRestart: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Stop, then start, the named servers (every running server when none are named)")
    @Argument(help: "Server names") var names: [String] = []
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let id = try target.resolve(client: client)
        // With no names, the declarations decide what the start half may
        // start; read them before the stop, which clears what it stops.
        var declared: Set<String> = []
        if names.isEmpty {
            let list = try fetchList(client, id, runStatusCommands: false)
            declared = Set(list.servers.filter { $0.isDeclared }.map { $0.name })
        }
        let stopped = try act(RPCMethod.serverStop, client, id, names)
        guard stopped.allSucceeded else {
            if json { printJSON(stopped) } else { print(ServerCommand.render(stopped, verb: "stop")) }
            throw ExitCode(1)
        }
        let plan = Self.restartPlan(requested: names, stopped: stopped, declared: declared)
        let skippedNote = plan.skipped.map {
            "\($0): not started again — it has no declaration to start it from"
        }
        guard !plan.start.isEmpty else {
            if json {
                printJSON(stopped)
            } else if plan.skipped.isEmpty {
                print("No server is running; nothing to restart.")
            } else {
                print(ServerCommand.render(stopped, verb: "stop"))
                skippedNote.forEach { print($0) }
            }
            return
        }
        let started = try act(RPCMethod.serverStart, client, id, plan.start)
        if json {
            printJSON(DevServerActionResult(outcomes: stopped.outcomes + started.outcomes))
        } else {
            print(ServerCommand.render(stopped, verb: "stop"))
            skippedNote.forEach { print($0) }
            print(ServerCommand.render(started, verb: "start"))
        }
        if !started.allSucceeded { throw ExitCode(1) }
    }

    /// What the start half of a restart starts. Named servers are started
    /// as named. With no names the stop half stopped every running server,
    /// and those of them that are declared are started again — not every
    /// declared one. A server known only from a running file or from a tab
    /// whose declaration is gone has nothing to start it from: it is
    /// stopped, reported in `skipped`, and left stopped.
    static func restartPlan(
        requested: [String], stopped: DevServerActionResult, declared: Set<String>
    ) -> (start: [String], skipped: [String]) {
        guard requested.isEmpty else { return (requested, []) }
        let names = stopped.outcomes.filter { $0.status == .stopped }.map { $0.name }
        return (names.filter { declared.contains($0) }, names.filter { !declared.contains($0) })
    }
}

struct ServerStatus: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Exit 0 when the server is running, and print its URLs")
    @Argument(help: "Server name") var name: String
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let list = try fetchList(client, try target.resolve(client: client), runStatusCommands: true)
        guard let info = list.servers.first(where: { $0.name == name }) else {
            throw CLIError.invalidArgument("No server named \(name) in this worktree.")
        }
        if json {
            printJSON(info)
        } else {
            print("\(info.name): \(ServerCommand.describe(info))")
            for endpoint in info.endpoints { print("  \(endpoint.name): \(endpoint.url)") }
        }
        if info.state != .running { throw ExitCode(1) }
    }
}

struct ServerOpen: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open a server's main URL, or a named endpoint, in the default browser")
    @Argument(help: "Server name (default: the first running server with a URL)") var name: String?
    @Option(name: .long, help: "Endpoint name") var endpoint: String?
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func run() async throws {
        let client = SocketClient()
        let list = try fetchList(client, try target.resolve(client: client), runStatusCommands: false)
        let url = try ServerCommand.urlToOpen(in: list, server: name, endpoint: endpoint)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url]
        try process.run()
        process.waitUntilExit()
        if json { printJSON(["url": url]) } else { print("Opened \(url)") }
    }
}

struct ServerReport: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Write (or --clear) this worktree's running file for a server",
        discussion: """
            Writes a file to $DEV_SERVERS_DIR (default ~/.local/state/dev-servers) \
            naming the server, its process and its URLs. --pid must be the server \
            process itself, not a launcher that exits. Example: \
            tbd server report web --pid $! --url https://localhost:24123 --url api=http://localhost:8004/api
            """)
    @Argument(help: "Server name") var name: String
    @Option(name: .long, help: "The server's process id (required unless --clear)") var pid: Int32?
    @Option(name: .customLong("url"), help: "An endpoint URL, or <name>=<url>; repeatable. The first is the main URL.")
    var urls: [String] = []
    @Flag(name: .long, help: "Delete this server's running file instead") var clear = false
    @OptionGroup var target: ServerWorktreeOption
    @Flag(name: .long, help: "Output JSON") var json = false

    mutating func validate() throws {
        guard DeclaredDevServer.isValidName(name) else {
            throw ValidationError("Server names use lowercase letters, digits and -.")
        }
        if clear {
            guard pid == nil, urls.isEmpty else { throw ValidationError("--clear takes no --pid or --url.") }
        } else {
            guard pid != nil else { throw ValidationError("--pid is required: name the server process itself.") }
            guard !urls.isEmpty else { throw ValidationError("At least one --url is required.") }
        }
    }

    /// The worktree root: `--worktree` via the daemon, else
    /// `TBD_WORKTREE_PATH` (set in every server TBD starts), else the daemon.
    private func worktreeRoot(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        if target.worktree == nil, let path = environment["TBD_WORKTREE_PATH"], !path.isEmpty { return path }
        let client = SocketClient()
        let id = try target.resolve(client: client, environment: environment)
        let worktrees: [Worktree] = try client.call(
            method: RPCMethod.worktreeList, params: WorktreeListParams(), resultType: [Worktree].self)
        guard let worktree = worktrees.first(where: { $0.id == id }) else {
            throw CLIError.invalidArgument("Worktree \(id) is not known to TBD.")
        }
        return worktree.localPath
    }

    /// The reported process's start time, read the way the daemon's
    /// liveness check reads it (`DevServerProcessProbe`), or a refusal: no
    /// such process, or a zombie — one that has exited and waits to be
    /// reaped, which the daemon reads as stale, so its file would never show
    /// the server as running.
    static func reportedStartTime(pid: Int32, probe: DevServerProcessProbe = .live) throws -> Date {
        guard let info = probe.info(pid) else {
            throw CLIError.invalidArgument("No process with pid \(pid) is running.")
        }
        guard !info.isZombie else {
            throw CLIError.invalidArgument(
                "Process \(pid) has exited (a zombie waiting to be reaped); report the server process while it runs.")
        }
        return info.startTime
    }

    mutating func run() async throws {
        let root = try worktreeRoot()
        let store = DevServerRunningFileStore()
        if clear {
            let removed = store.remove(root: root, server: name)
            if json { printJSON(["removed": "\(removed.count)"]) } else { print("Removed \(removed.count) running file(s) for \(name).") }
            return
        }
        guard let pid else { throw CLIError.invalidArgument("--pid is required: name the server process itself.") }
        let started = try Self.reportedStartTime(pid: pid)
        let file = DevServerRunningFile(
            root: root, server: name, endpoints: try ServerCommand.parseEndpoints(urls, server: name),
            pid: pid, startTime: started.timeIntervalSince1970)
        let path = try store.write(file)
        if json { printJSON(["path": path]) } else { print("Reported \(name) at \(path)") }
    }
}
