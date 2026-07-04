import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#endif
import TBDShared

// MARK: - tbd profile

struct ProfileCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Manage model profiles (the accounts spawned Claude sessions run under)",
        subcommands: [
            ProfileList.self,
            ProfileSetDefault.self,
            ProfileLogin.self,
        ]
    )
}

// MARK: - Pure helpers (internal so TBDCLITests can exercise them)

/// Render the IDENTITY column for a profile row. OAuth profiles show the
/// logged-in account email, or "needs /login" when nobody has logged into
/// the profile's isolated config dir yet. Non-OAuth kinds (apiKey, bedrock)
/// have no login identity and render an em dash.
func profileIdentityCell(kind: CredentialKind, loginIdentity: String?) -> String {
    guard kind == .oauth else { return "—" }
    if let loginIdentity, !loginIdentity.isEmpty { return loginIdentity }
    return "needs /login"
}

/// First bucket in the snapshot matching `kind` (and, for scoped buckets,
/// the given model display name). nil when the snapshot is missing or the
/// account doesn't have that bucket.
func usageBucket(
    in snapshot: ProfileUsageSnapshot?,
    kind: String,
    modelDisplayName: String? = nil
) -> ClaudeUsageLimitBucket? {
    snapshot?.buckets.first {
        $0.kind == kind && (modelDisplayName == nil || $0.modelDisplayName == modelDisplayName)
    }
}

/// Union of model display names across all profiles' `weekly_scoped` buckets,
/// sorted for stable column order. Drives the dynamic per-model-family
/// weekly columns in `tbd profile list` (e.g. "Fable").
func scopedWeeklyModelNames(in profiles: [ModelProfileWithUsage]) -> [String] {
    var names: Set<String> = []
    for entry in profiles {
        for bucket in entry.usageSnapshot?.buckets ?? []
        where bucket.kind == "weekly_scoped" {
            if let name = bucket.modelDisplayName { names.insert(name) }
        }
    }
    return names.sorted()
}

/// Render a percent cell like "96%", or an em dash when the bucket is absent.
func usagePercentCell(_ bucket: ClaudeUsageLimitBucket?) -> String {
    guard let bucket else { return "—" }
    return "\(Int(bucket.percent.rounded()))%"
}

/// Render a reset timestamp in compact local time: "18:10" when it lands
/// within the next 24 h, otherwise "7/7 18:00". Em dash when absent.
func usageResetCell(_ date: Date?, now: Date = Date()) -> String {
    guard let date else { return "—" }
    let formatter = DateFormatter()
    formatter.dateFormat = date.timeIntervalSince(now) < 24 * 3600 ? "HH:mm" : "M/d HH:mm"
    return formatter.string(from: date)
}

/// Resolve a user-supplied profile reference against the daemon's profile
/// list. Accepts an exact name, a unique case-insensitive name, or a profile
/// UUID (escape hatch for scripting). Throws a `CLIError` with actionable
/// text when nothing (or more than one thing) matches.
func resolveProfile(
    named reference: String,
    in profiles: [ModelProfileWithUsage]
) throws -> ModelProfileWithUsage {
    if let id = UUID(uuidString: reference),
       let byID = profiles.first(where: { $0.profile.id == id }) {
        return byID
    }
    if let exact = profiles.first(where: { $0.profile.name == reference }) {
        return exact
    }
    let folded = profiles.filter {
        $0.profile.name.lowercased() == reference.lowercased()
    }
    if folded.count == 1 {
        return folded[0]
    }
    if folded.count > 1 {
        let names = folded.map(\.profile.name).sorted().joined(separator: ", ")
        throw CLIError.invalidArgument(
            "Profile name '\(reference)' is ambiguous (matches: \(names)). Use the exact name.")
    }
    guard !profiles.isEmpty else {
        throw CLIError.invalidArgument(
            "No model profiles exist yet. Create one in TBD Settings → Model Profiles.")
    }
    let available = profiles.map(\.profile.name).sorted().joined(separator: ", ")
    throw CLIError.invalidArgument("No profile named '\(reference)'. Available: \(available)")
}

/// Env vars that would poison an OAuth `/login` if inherited from the calling
/// shell: they force API-key auth, token auth, a proxy base URL, or Bedrock
/// routing onto the spawned `claude`, overriding the isolated config dir's
/// OAuth credentials.
let loginPoisonEnvVars = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_USE_BEDROCK",
]

/// Copy of `base` with every login-poisoning variable removed.
func sanitizedLoginEnvironment(base: [String: String]) -> [String: String] {
    var env = base
    for key in loginPoisonEnvVars {
        env.removeValue(forKey: key)
    }
    return env
}

/// Find an executable by name on a colon-separated search path
/// (defaults to the process's `PATH`). Returns its absolute path, or nil.
func findExecutable(named name: String, searchPath: String? = nil) -> String? {
    let path = searchPath ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
    for dir in path.split(separator: ":") where !dir.isEmpty {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
    }
    return nil
}

/// Replace the current process image with `executablePath` via `execve`,
/// handing the controlling TTY over cleanly (no wrapper process lingers).
/// Only returns by throwing, when exec itself fails.
func execReplacingCurrentProcess(
    executablePath: String,
    arguments: [String],
    environment: [String: String]
) throws -> Never {
    fflush(stdout)
    fflush(stderr)
    var argv: [UnsafeMutablePointer<CChar>?] = ([executablePath] + arguments).map { strdup($0) }
    argv.append(nil)
    var envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") }
    envp.append(nil)
    execve(executablePath, argv, envp)
    // execve only returns on failure — clean up and surface errno.
    let reason = String(cString: strerror(errno))
    for pointer in argv { free(pointer) }
    for pointer in envp { free(pointer) }
    throw CLIError.invalidArgument("Failed to exec \(executablePath): \(reason)")
}

// MARK: - profile list

struct ProfileList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List model profiles and their login state"
    )

    @Flag(name: .long, help: "Output JSON")
    var json = false

    @Flag(name: .long, help: "Force a fresh usage fetch for all logged-in OAuth profiles before listing")
    var refresh = false

    mutating func run() async throws {
        let client = SocketClient()

        if refresh {
            _ = try client.call(
                method: RPCMethod.modelProfileUsageRefresh,
                params: ModelProfileUsageRefreshParams(id: nil),
                resultType: ModelProfileUsageRefreshResult.self
            )
        }

        let result = try client.call(
            method: RPCMethod.modelProfileList,
            resultType: ModelProfileListResult.self
        )

        if json {
            printJSON(result)
            return
        }
        if result.profiles.isEmpty {
            print("No model profiles configured. Create one in TBD Settings → Model Profiles.")
            return
        }

        // Dynamic per-model-family weekly columns ("WK FABLE", ...) driven by
        // whatever scoped buckets the usage API actually returned.
        let scopedModels = scopedWeeklyModelNames(in: result.profiles)

        var header: [(String, Int)] = [
            ("NAME", 24), ("KIND", 6), ("IDENTITY", 26),
            ("5H", 4), ("RESET", 10), ("WK", 4),
        ]
        header.append(contentsOf: scopedModels.map { ("WK \($0.uppercased())", max($0.count + 3, 8)) })
        header.append(("", 0))
        print(tableRow(header))
        let width = header.reduce(0) { $0 + max($1.1, $1.0.count) + 2 }
        print(String(repeating: "-", count: max(width, 78)))

        var staleNotes: [String] = []
        for entry in result.profiles {
            let identity = profileIdentityCell(
                kind: entry.profile.kind,
                loginIdentity: entry.loginIdentity
            )
            let snapshot = entry.usageSnapshot
            let session = usageBucket(in: snapshot, kind: "session")
            let weeklyAll = usageBucket(in: snapshot, kind: "weekly_all")

            var cells: [(String, Int)] = [
                (entry.profile.name, 24),
                (entry.profile.kind.rawValue, 6),
                (identity, 26),
                (usagePercentCell(session), 4),
                (usageResetCell(session?.resetsAt), 10),
                (usagePercentCell(weeklyAll), 4),
            ]
            for model in scopedModels {
                let bucket = usageBucket(in: snapshot, kind: "weekly_scoped", modelDisplayName: model)
                cells.append((usagePercentCell(bucket), max(model.count + 3, 8)))
            }

            var trailing: [String] = []
            if entry.profile.id == result.defaultID { trailing.append("[default]") }
            if let snapshot, !snapshot.isOK {
                trailing.append("[stale*]")
                staleNotes.append("  * \(entry.profile.name): \(snapshot.status)")
            }
            cells.append((trailing.joined(separator: " "), 0))
            print(tableRow(cells))
        }
        for note in staleNotes { print(note) }
    }
}

// MARK: - profile set-default

struct ProfileSetDefault: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "set-default",
        abstract: "Set (or clear) the global default profile for new sessions"
    )

    @Argument(help: "Profile name or UUID (omit with --clear)")
    var name: String?

    @Flag(name: .long, help: "Clear the global default instead of setting one")
    var clear = false

    mutating func run() async throws {
        let client = SocketClient()

        if clear {
            guard name == nil else {
                throw CLIError.invalidArgument("Cannot combine a profile name with --clear")
            }
            try client.callVoid(
                method: RPCMethod.modelProfileSetGlobalDefault,
                params: ModelProfileSetGlobalDefaultParams(id: nil)
            )
            print("Cleared the global default profile.")
            print("New sessions will use ambient credentials unless a repo-level override applies.")
            return
        }

        guard let name else {
            throw CLIError.invalidArgument(
                "Provide a profile name, or pass --clear to unset the default.")
        }

        let list = try client.call(
            method: RPCMethod.modelProfileList,
            resultType: ModelProfileListResult.self
        )
        let entry = try resolveProfile(named: name, in: list.profiles)
        try client.callVoid(
            method: RPCMethod.modelProfileSetGlobalDefault,
            params: ModelProfileSetGlobalDefaultParams(id: entry.profile.id)
        )
        let identity = profileIdentityCell(
            kind: entry.profile.kind,
            loginIdentity: entry.loginIdentity
        )
        print("Global default profile is now '\(entry.profile.name)' (\(entry.profile.kind.rawValue), \(identity)).")
        print("New sessions will use it unless a repo-level override applies.")
    }
}

// MARK: - profile login

struct ProfileLogin: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "login",
        abstract: "Open claude inside a profile's isolated config dir so /login lands on the right account",
        discussion: """
            Replaces this process with `claude` running under the profile's \
            CLAUDE_CONFIG_DIR, so the OAuth credential written by /login is \
            stored for that profile — not for whatever account your shell \
            happens to be logged into.
            """
    )

    @Argument(help: "OAuth profile name or UUID")
    var name: String

    mutating func run() async throws {
        let client = SocketClient()
        let list = try client.call(
            method: RPCMethod.modelProfileList,
            resultType: ModelProfileListResult.self
        )
        let entry = try resolveProfile(named: name, in: list.profiles)

        guard entry.profile.kind == .oauth else {
            let detail = entry.profile.kind == .bedrock
                ? "Bedrock profiles authenticate with AWS credentials"
                : "API-key profiles carry their own key"
            throw CLIError.invalidArgument(
                "Profile '\(entry.profile.name)' is a \(entry.profile.kind.rawValue) profile. "
                    + "Only OAuth profiles log in via /login — \(detail), so there is nothing to log into.")
        }

        // Provision (or re-verify) the isolated config dir daemon-side.
        let prepared = try client.call(
            method: RPCMethod.modelProfilePrepareConfigDir,
            params: ModelProfilePrepareConfigDirParams(id: entry.profile.id),
            resultType: ModelProfilePrepareConfigDirResult.self
        )

        guard let claudePath = findExecutable(named: "claude") else {
            throw CLIError.invalidArgument(
                "Could not find `claude` on PATH. Install Claude Code first (https://claude.com/claude-code).")
        }

        let current = entry.loginIdentity.map { "currently logged in as \($0)" }
            ?? "not logged in yet"
        print("Opening claude for profile '\(entry.profile.name)' (\(current)) — "
            + "run /login inside this session, then /status to verify, then exit.")

        var env = sanitizedLoginEnvironment(base: ProcessInfo.processInfo.environment)
        env["CLAUDE_CONFIG_DIR"] = prepared.configDirPath
        try execReplacingCurrentProcess(
            executablePath: claudePath,
            arguments: [],
            environment: env
        )
    }
}
