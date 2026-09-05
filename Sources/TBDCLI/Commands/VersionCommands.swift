import ArgumentParser
import Foundation
import TBDShared

// MARK: - This CLI's own identity

/// What commit this `tbd` binary was built from.
///
/// Two resolutions, deliberately, because they cost different amounts and are
/// wanted in different places:
///
/// - `stamped` reads the sidecar and nothing else. `tbd --version` and every
///   `--help` render through it, and hooks invoke this CLI many times a
///   minute, so that path must never spawn a subprocess.
/// - `resolved()` adds the `git rev-parse` fallback. Only `tbd version` calls
///   it, once, because only there is a possibly-stale answer better than none.
enum CLIBuildIdentity {
    /// The resolved path of this binary, symlinks followed. `nil` when `argv[0]`
    /// is empty, which nothing in practice produces.
    static let executablePath: String? = {
        guard let argv0 = CommandLine.arguments.first, !argv0.isEmpty else { return nil }
        let url: URL
        if argv0.hasPrefix("/") {
            url = URL(fileURLWithPath: argv0)
        } else {
            url = URL(
                fileURLWithPath: argv0,
                relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        }
        return url.resolvingSymlinksInPath().standardizedFileURL.path
    }()

    /// Sidecar only. Cheap enough to sit on the `--version` path.
    static let stamped: BuildIdentity? = BuildIdentityLoader.load(
        executablePath: executablePath)

    /// Sidecar, else the HEAD of the worktree this binary sits inside.
    static func resolved() -> BuildIdentity? {
        BuildIdentityLoader.load(
            executablePath: executablePath,
            gitHead: BuildIdentityLoader.systemGitHead)
    }

    /// What `tbd --version` prints: `0.1.0` or `0.1.0 (abc1234)`.
    ///
    /// The installed CLI at `~/.local/bin/tbd` is a hard link with no sidecar
    /// beside it and no `.build` in its path, so it prints the bare version.
    /// That is acceptable and deliberate: the daemon's identity is the one that
    /// decides whether an update is available, and `tbd version` asks it.
    static var versionString: String {
        guard let identity = stamped else { return TBDConstants.version }
        return "\(TBDConstants.version) (\(identity.displayCommit))"
    }
}

// MARK: - tbd version

/// The rendered `tbd version` report.
///
/// Pure and separated from the RPC call for the usual reason: the interesting
/// behavior is the verdict line, there are four of them, and a test that has to
/// stand up a daemon to read one is a test nobody writes.
enum VersionReport {
    /// Compose the whole report.
    ///
    /// - Parameters:
    ///   - cli: this binary's identity, or nil when it could not be learned.
    ///   - daemon: the `daemon.status` response, or nil when the daemon could
    ///     not be reached.
    ///   - update: the observation to render. Passed separately from `daemon`
    ///     so `--check` can render the fresh answer it just forced rather than
    ///     the cached one the status carried.
    static func render(
        cli: BuildIdentity?,
        daemon: DaemonStatusResult?,
        update: UpdateStatus?
    ) -> String {
        var lines: [String] = []
        lines.append("TBD \(TBDConstants.version)")
        lines.append("  CLI:    \(describe(cli))")
        lines.append("  Daemon: \(describeDaemon(daemon))")
        lines.append("  Latest: \(describeLatest(update))")
        lines.append("")
        lines.append(verdict(daemon: daemon?.buildIdentity, update: update))
        return lines.joined(separator: "\n")
    }

    /// Exactly one of four sentences. Every branch is reachable and each says
    /// something different about what the reader should do next.
    static func verdict(daemon: BuildIdentity?, update: UpdateStatus?) -> String {
        guard let update else { return "Unknown — run tbd version --check" }
        switch update.relation {
        case .upToDate:
            return "Up to date"
        case .unknown:
            return "Unknown — run tbd version --check"
        case .behind:
            let ours = daemon?.displayCommit ?? "unknown"
            let latest = update.latestCommit.map { String($0.prefix(7)) } ?? "unknown"
            if let count = update.behindBy, count > 0 {
                let plural = count == 1 ? "commit" : "commits"
                return "Update available: \(ours) → \(latest) (\(count) \(plural) behind). Run: tbd update"
            }
            // No count is the ordinary case on a machine that has not fetched
            // the newer objects — `ls-remote` moves none. Say less rather than
            // inventing a number.
            return "Update available: \(ours) → \(latest). Run: tbd update"
        }
    }

    static func describe(_ identity: BuildIdentity?) -> String {
        guard let identity else { return "unknown" }
        var text = identity.displayCommit
        if !identity.branch.isEmpty, identity.branch != "HEAD" {
            text += " (\(identity.branch))"
        }
        if identity.origin == .worktreeHead {
            // The stamp is what describes the binary; this is the tree it came
            // from as it stands now, which is not the same claim.
            text += " [worktree HEAD, may be newer than this binary]"
        }
        return text
    }

    static func describeDaemon(_ daemon: DaemonStatusResult?) -> String {
        guard let daemon else { return "not running" }
        let identity = describe(daemon.buildIdentity)
        guard let path = daemon.executablePath, !path.isEmpty else { return identity }
        return "\(identity) — \(path)"
    }

    static func describeLatest(_ update: UpdateStatus?) -> String {
        guard let update, let commit = update.latestCommit else { return "never checked" }
        let short = String(commit.prefix(7))
        guard let observedAt = update.observedAt else { return short }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return "\(short) (observed \(formatter.string(from: observedAt)))"
    }
}

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version",
        abstract: "Show which commit the CLI and daemon were built from, and whether an update is available"
    )

    @Flag(name: .long, help: "Ask the daemon to check the remote now instead of showing its last observation")
    var check = false

    @Flag(name: .long, help: "Output JSON")
    var json = false

    mutating func run() async throws {
        let client = SocketClient()
        // A daemon that is not running is a normal answer here, not an error:
        // `tbd version` is the command someone runs when TBD looks wrong.
        let status = try? client.call(
            method: RPCMethod.daemonStatus, resultType: DaemonStatusResult.self)
        var update = status?.update
        if check {
            update = try client.call(
                method: RPCMethod.daemonCheckForUpdate, resultType: UpdateStatus.self)
        }
        let cli = CLIBuildIdentity.resolved()
        if json {
            printJSON(VersionJSON(
                cliVersion: TBDConstants.version,
                cli: cli,
                daemon: status?.buildIdentity,
                daemonExecutablePath: status?.executablePath,
                update: update))
        } else {
            print(VersionReport.render(cli: cli, daemon: status, update: update))
        }
    }
}

/// `tbd version --json`. A flat object rather than the raw `daemon.status`
/// payload: the CLI's own identity has no home in that result, and uptime and
/// client counts have no place in a version report.
struct VersionJSON: Codable {
    let cliVersion: String
    let cli: BuildIdentity?
    let daemon: BuildIdentity?
    let daemonExecutablePath: String?
    let update: UpdateStatus?
}

// MARK: - tbd update

/// Where `tbd update` looks for the procedure it runs.
enum UpdateScriptLocator {
    /// The outcome of the search, with the paths it tried, so a failure can
    /// tell the user where to look rather than only that it looked.
    enum Outcome: Equatable {
        case found(String)
        case missing(searched: [String])
    }

    /// Find `scripts/update.sh`.
    ///
    /// - Parameters:
    ///   - sourceWorktree: what the daemon reported as its build's source
    ///     worktree. The authoritative answer — the running daemon knows which
    ///     tree it came from, and this CLI may be a hard link installed
    ///     anywhere.
    ///   - executablePath: this binary's path, used only when the daemon said
    ///     nothing: the parent of `.build` is the tree a `.build`-relative CLI
    ///     was built in.
    ///   - fileExists: injection seam for the filesystem check.
    static func locate(
        sourceWorktree: String?,
        executablePath: String?,
        fileExists: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> Outcome {
        var searched: [String] = []
        for root in [sourceWorktree, BuildIdentityLoader.sourceWorktree(fromExecutablePath: executablePath)] {
            guard let root, !root.isEmpty else { continue }
            let candidate = URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent("scripts")
                .appendingPathComponent("update.sh").path
            if searched.contains(candidate) { continue }
            searched.append(candidate)
            if fileExists(candidate) { return .found(candidate) }
        }
        return .missing(searched: searched)
    }

    /// What the command prints when it cannot find the script. Pure so the
    /// wording is testable without a filesystem.
    static func missingMessage(searched: [String]) -> String {
        guard !searched.isEmpty else {
            return """
                tbd update: could not tell which worktree this installation was built from.
                Run scripts/update.sh from that worktree directly.
                """
        }
        let list = searched.map { "  \($0)" }.joined(separator: "\n")
        return """
            tbd update: no executable scripts/update.sh found. Looked in:
            \(list)
            """
    }
}

struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Build the latest main out of place and hand this installation over to it",
        discussion: """
            A thin wrapper: it asks the daemon which worktree this build came \
            from and then execs that worktree's scripts/update.sh, passing \
            through every argument and the environment you invoked it with. \
            The script is the procedure — read it there, and pass --help to it \
            for its own flags.
            """
    )

    @Argument(parsing: .captureForPassthrough, help: "Arguments forwarded verbatim to scripts/update.sh")
    var passthrough: [String] = []

    mutating func run() async throws {
        // The one and only daemon call this command makes. Everything after it
        // belongs to the script, which must work whether or not the daemon
        // survives the update it is about to perform.
        let status = try? SocketClient().call(
            method: RPCMethod.daemonStatus, resultType: DaemonStatusResult.self)
        let outcome = UpdateScriptLocator.locate(
            sourceWorktree: status?.buildIdentity?.sourceWorktree,
            executablePath: CLIBuildIdentity.executablePath)
        switch outcome {
        case .missing(let searched):
            print(UpdateScriptLocator.missingMessage(searched: searched))
            throw ExitCode(2)
        case .found(let script):
            // Replace this process rather than spawning a child: the script is
            // interactive, prints a running log, and may take minutes. An exec
            // hands it the terminal, the exit status and the signals directly.
            var argv: [UnsafeMutablePointer<CChar>?] = ([script] + passthrough).map { strdup($0) }
            argv.append(nil)
            execv(script, &argv)
            // execv only returns on failure.
            let reason = String(cString: strerror(errno))
            print("tbd update: could not exec \(script): \(reason)")
            throw ExitCode(1)
        }
    }
}
