import Foundation

public enum TBDConstants {
    public static let version = "0.1.0"

    /// Base config directory resolved from the given environment dictionary.
    /// Honors `TBD_HOME`; falls back to `~/tbd` when the key is absent or empty.
    public static func configDir(environment: [String: String]) -> URL {
        if let override = environment["TBD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("tbd")
    }

    /// Base config directory. Resolves `TBD_HOME` env var on every access so a
    /// process that sets the env after first read (e.g. a SwiftTesting suite
    /// trait) gets the new value. Falls back to `~/tbd` when the env is unset
    /// or empty, preserving production behavior.
    public static var configDir: URL { configDir(environment: ProcessInfo.processInfo.environment) }

    /// File containing the user-selected tmux executable fallback. Honors
    /// `TBD_HOME` so the app and daemon share the same configured value.
    public static func tmuxExecutablePathFile(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("tmux-executable-path")
    }

    public static var tmuxExecutablePathFile: URL {
        tmuxExecutablePathFile(environment: ProcessInfo.processInfo.environment)
    }

    /// Unix socket path resolved from the given environment dictionary.
    /// Honors `TBD_SOCKET_PATH` independently of `TBD_HOME` — darwin caps
    /// `sun_path` at ~104 bytes, so a deep `TBD_HOME` can overflow even though
    /// `$configDir/sock` would fit a shallow override.
    public static func socketPath(environment: [String: String]) -> String {
        if let override = environment["TBD_SOCKET_PATH"], !override.isEmpty {
            return override
        }
        return configDir(environment: environment).appendingPathComponent("sock").path
    }

    /// Unix socket path. Honors `TBD_SOCKET_PATH` independently of `TBD_HOME`
    /// — darwin caps `sun_path` at ~104 bytes, so a deep `TBD_HOME` can
    /// overflow even though `$configDir/sock` would fit a shallow override.
    public static var socketPath: String { socketPath(environment: ProcessInfo.processInfo.environment) }

    /// Sidecar Unix socket over which the daemon vends file descriptors to
    /// the app (SCM_RIGHTS). Sibling of `socketPath`.
    public static func vendSocketPath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("vend.sock").path
    }

    /// Sidecar Unix socket over which the daemon vends file descriptors to
    /// the app (SCM_RIGHTS). Sibling of `socketPath`.
    public static var vendSocketPath: String { vendSocketPath(environment: ProcessInfo.processInfo.environment) }

    /// Directory holding one socket and one lock file per live pty holder:
    /// `~/tbd/holders`. Honors TBD_HOME.
    ///
    /// Deliberately shallow and directly under the config dir: every holder
    /// socket path must fit Darwin's ~104-byte `sun_path`, and nesting is the
    /// thing that breaks that budget first. `HolderRendezvous` composes the
    /// per-session names inside it and enforces the budget.
    public static func holdersDir(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        configDir(environment: environment).appendingPathComponent("holders")
    }

    public static func databasePath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("state.db").path
    }
    public static var databasePath: String { databasePath(environment: ProcessInfo.processInfo.environment) }

    public static func pidFilePath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("tbdd.pid").path
    }
    public static var pidFilePath: String { pidFilePath(environment: ProcessInfo.processInfo.environment) }

    public static func portFilePath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("port").path
    }
    public static var portFilePath: String { portFilePath(environment: ProcessInfo.processInfo.environment) }

    public static func reposDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("repos")
    }
    public static var reposDir: URL { reposDir(environment: ProcessInfo.processInfo.environment) }

    /// Base directory holding all scratch spaces: `~/tbd/scratch`. Honors TBD_HOME.
    public static func scratchDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("scratch")
    }
    public static var scratchDir: URL { scratchDir(environment: ProcessInfo.processInfo.environment) }

    /// Base directory for Claude Code scratchpads resolved from the given environment dictionary.
    /// Honors `TBD_CLAUDE_SCRATCH_BASE`; falls back to `/private/tmp/claude-<uid>` when the key
    /// is absent or empty.
    public static func claudeScratchpadBase(environment: [String: String]) -> URL {
        if let override = environment["TBD_CLAUDE_SCRATCH_BASE"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let uid = getuid()
        return URL(fileURLWithPath: "/private/tmp/claude-\(uid)", isDirectory: true)
    }

    /// Base directory for Claude Code scratchpads. Resolves `TBD_CLAUDE_SCRATCH_BASE` env var
    /// on every access so a process that sets the env after first read (e.g. a SwiftTesting
    /// suite trait) gets the new value. Falls back to `/private/tmp/claude-<uid>` when the env
    /// is unset or empty, preserving production behavior.
    public static var claudeScratchpadBase: URL { claudeScratchpadBase(environment: ProcessInfo.processInfo.environment) }

    /// The host Claude store — `TBD_CLAUDE_HOST_HOME` when set, `~/.claude`
    /// otherwise — resolved from the given environment dictionary.
    ///
    /// **The single resolution point for that override, package-wide.** It
    /// lives in `TBDShared` rather than beside its daemon-side caller because
    /// `TBDApp` needs it too and does not link `TBDDaemonLib`:
    /// `LegacyHookSettingsPath` hand-built `homeDirectoryForCurrentUser/.claude`
    /// for a dialog body, which is display-only today but shows the wrong path
    /// under any override and is the exact shape of the leak
    /// `LegacyHookScanner.globalSettingsPath` had.
    /// `ClaudeProfileConfigDirManager.resolveHostBaseDirectory` delegates here.
    public static func claudeHostHome(environment: [String: String]) -> URL {
        if let override = environment["TBD_CLAUDE_HOST_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude", isDirectory: true)
    }

    /// The host Claude store. Resolves `TBD_CLAUDE_HOST_HOME` on every access,
    /// like the other overrides here, so a process that sets it after first
    /// read gets the new value.
    public static var claudeHostHome: URL { claudeHostHome(environment: ProcessInfo.processInfo.environment) }

    public static func hookPath(repoID: UUID, eventName: String, environment: [String: String]) -> String {
        reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("hooks")
            .appendingPathComponent(eventName)
            .path
    }

    public static func hookPath(repoID: UUID, eventName: String) -> String {
        hookPath(repoID: repoID, eventName: eventName, environment: ProcessInfo.processInfo.environment)
    }

    /// Base directory holding per-worktree config (e.g. scratch-worktree
    /// notepads): `~/tbd/worktrees`. Honors TBD_HOME.
    public static func worktreesDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("worktrees")
    }
    public static var worktreesDir: URL { worktreesDir(environment: ProcessInfo.processInfo.environment) }

    /// Path to a repo's shared notepad file: `~/tbd/repos/<repoID>/notes.md`.
    /// Shared by every worktree of the repo. Honors TBD_HOME.
    public static func notesPath(repoID: UUID, environment: [String: String]) -> String {
        reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("notes.md")
            .path
    }
    public static func notesPath(repoID: UUID) -> String {
        notesPath(repoID: repoID, environment: ProcessInfo.processInfo.environment)
    }

    /// Path to a repo's Claude settings overlay fragment file:
    /// `~/tbd/repos/<repoID>/claude-settings.json`. A user-authored JSON
    /// object deep-merged into TBD's `--settings` overlay at Claude spawn
    /// time. Honors TBD_HOME.
    public static func claudeSettingsOverlayPath(repoID: UUID, environment: [String: String]) -> String {
        reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent("claude-settings.json")
            .path
    }
    public static func claudeSettingsOverlayPath(repoID: UUID) -> String {
        claudeSettingsOverlayPath(repoID: repoID, environment: ProcessInfo.processInfo.environment)
    }

    /// Directory holding user-authored markdown stylesheets for the file
    /// viewer: `~/tbd/markdown-themes`. The selected theme is the file
    /// `<themeID>.css` inside it, where `themeID` comes from the
    /// `markdown.viewer.theme` user default. A user-authored editable blob, so
    /// it is file-backed rather than a DB column. Honors TBD_HOME.
    public static func markdownThemesDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("markdown-themes")
    }
    public static var markdownThemesDir: URL {
        markdownThemesDir(environment: ProcessInfo.processInfo.environment)
    }

    /// Base directory for per-note (tab) content files. Honors TBD_HOME.
    public static func noteContentDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("notes")
    }
    public static var noteContentDir: URL { noteContentDir(environment: ProcessInfo.processInfo.environment) }

    /// Path to one note tab's content file:
    /// `~/tbd/notes/<worktreeID>/<noteID>.md`. Note content is file-backed
    /// (the DB `content` column is a dormant legacy fallback); the DB note
    /// row keeps tab identity + title. Honors TBD_HOME.
    public static func noteContentPath(worktreeID: UUID, noteID: UUID, environment: [String: String]) -> String {
        noteContentDir(environment: environment)
            .appendingPathComponent(worktreeID.uuidString)
            .appendingPathComponent("\(noteID.uuidString).md")
            .path
    }
    public static func noteContentPath(worktreeID: UUID, noteID: UUID) -> String {
        noteContentPath(worktreeID: worktreeID, noteID: noteID, environment: ProcessInfo.processInfo.environment)
    }

    /// Base directory for captured scrollback of closed terminals. Honors TBD_HOME.
    public static func terminalHistoryDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("terminal-history")
    }
    public static var terminalHistoryDir: URL { terminalHistoryDir(environment: ProcessInfo.processInfo.environment) }

    /// Path to one closed terminal's captured scrollback:
    /// `~/tbd/terminal-history/<worktreeID>/<terminalID>.txt`. Content is
    /// file-backed (the `terminal_history` DB row keeps metadata only); the
    /// app reads this file directly. Honors TBD_HOME.
    public static func terminalHistoryPath(worktreeID: UUID, terminalID: UUID, environment: [String: String]) -> String {
        terminalHistoryDir(environment: environment)
            .appendingPathComponent(worktreeID.uuidString)
            .appendingPathComponent("\(terminalID.uuidString).txt")
            .path
    }
    public static func terminalHistoryPath(worktreeID: UUID, terminalID: UUID) -> String {
        terminalHistoryPath(worktreeID: worktreeID, terminalID: terminalID, environment: ProcessInfo.processInfo.environment)
    }

    /// Path to a scratch worktree's notepad file:
    /// `~/tbd/worktrees/<worktreeID>/notes.md`. Honors TBD_HOME.
    public static func notesPath(worktreeID: UUID, environment: [String: String]) -> String {
        worktreesDir(environment: environment)
            .appendingPathComponent(worktreeID.uuidString)
            .appendingPathComponent("notes.md")
            .path
    }
    public static func notesPath(worktreeID: UUID) -> String {
        notesPath(worktreeID: worktreeID, environment: ProcessInfo.processInfo.environment)
    }

    /// Path to the remote-provider registry file: `~/tbd/agent-providers.json`.
    /// User-authored JSON array of `{name, exec, args?}`. Honors TBD_HOME.
    public static func agentProvidersPath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("agent-providers.json").path
    }
    public static var agentProvidersPath: String {
        agentProvidersPath(environment: ProcessInfo.processInfo.environment)
    }

    /// Path to the append-only actuation record: `~/tbd/actuations.jsonl`.
    /// The daemon is its only writer; rotated day segments
    /// (`actuations-<YYYY-MM-DD>.jsonl`) sit beside it in the same directory.
    /// Honors `TBD_HOME` like every other derived path — never hand-build it
    /// from `$HOME`.
    public static func actuationLogPath(environment: [String: String]) -> String {
        configDir(environment: environment).appendingPathComponent("actuations.jsonl").path
    }
    public static var actuationLogPath: String {
        actuationLogPath(environment: ProcessInfo.processInfo.environment)
    }

    /// Directory holding daemon-managed runtime files — the Claude settings
    /// overlays, the statusline tee and its captures: `~/tbd/runtime`.
    public static func runtimeDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("runtime")
    }
    public static var runtimeDir: URL { runtimeDir(environment: ProcessInfo.processInfo.environment) }

    /// The one shared statusline tee script: `~/tbd/runtime/statusline-tee.sh`.
    ///
    /// One file for the whole fleet rather than one per session — the script
    /// takes its capture path and its delegate command as arguments, so nothing
    /// session-specific is baked into it.
    public static func statuslineTeeScriptPath(environment: [String: String]) -> String {
        runtimeDir(environment: environment)
            .appendingPathComponent("statusline-tee.sh")
            .path
    }
    public static var statuslineTeeScriptPath: String {
        statuslineTeeScriptPath(environment: ProcessInfo.processInfo.environment)
    }

    /// Filename prefix/suffix for a session's statusline capture file. Shared
    /// between the path builder and the orphan-prune sweep so the two can't
    /// drift, exactly as the per-session overlay's pair is.
    public static let statuslineCapturePrefix = "statusline-capture-"
    public static let statuslineCaptureSuffix = ".json"

    /// Where the tee publishes one session's statusline stdin JSON:
    /// `~/tbd/runtime/statusline-capture-<sessionKey>.json`.
    ///
    /// The payload carries the session's cwd and repo paths, so the tee writes
    /// it under a restrictive umask; the path itself is only an opaque terminal
    /// id.
    public static func statuslineCapturePath(
        sessionKey: String,
        environment: [String: String]
    ) -> String {
        runtimeDir(environment: environment)
            .appendingPathComponent(
                "\(statuslineCapturePrefix)\(sanitizedSessionKey(sessionKey))\(statuslineCaptureSuffix)")
            .path
    }
    public static func statuslineCapturePath(sessionKey: String) -> String {
        statuslineCapturePath(sessionKey: sessionKey, environment: ProcessInfo.processInfo.environment)
    }

    /// Filesystem-safe rendering of a session key (non-`[A-Za-z0-9_-]` → `_`).
    ///
    /// Callers MUST pass a unique opaque id (the terminal UUID): the mapping is
    /// only collision-safe for such inputs, since two distinct human-readable
    /// strings could sanitize to the same filename while distinct UUIDs never
    /// do. Lives here so the overlay files and the capture files sanitize
    /// identically — a second implementation is how the prune sweep and the
    /// path builder drift apart.
    public static func sanitizedSessionKey(_ sessionKey: String) -> String {
        String(sessionKey.unicodeScalars.map { scalar -> Character in
            let isSafe = scalar == "-" || scalar == "_"
                || (scalar >= "0" && scalar <= "9")
                || (scalar >= "a" && scalar <= "z")
                || (scalar >= "A" && scalar <= "Z")
            return isSafe ? Character(scalar) : "_"
        })
    }

    /// Directory holding everything fleet supervision persists outside the DB:
    /// the operator's `supervision.json`, the continuous `ledger.jsonl`, the
    /// out-of-band `status.json` heartbeat, and one directory per declared
    /// project. Honors `TBD_HOME` like every other derived path — never
    /// hand-build it from `$HOME`.
    public static func supervisionDir(environment: [String: String]) -> URL {
        configDir(environment: environment).appendingPathComponent("supervision")
    }
    public static var supervisionDir: URL {
        supervisionDir(environment: ProcessInfo.processInfo.environment)
    }

    /// The operator's supervision file: `~/tbd/supervision/supervision.json`.
    /// Project topology, per-project marks, mode declarations and selections,
    /// supervisor bindings, sweep selection. Hand-editable; the daemon is its
    /// only programmatic writer.
    public static func supervisionFilePath(environment: [String: String]) -> String {
        supervisionDir(environment: environment).appendingPathComponent("supervision.json").path
    }
    public static var supervisionFilePath: String {
        supervisionFilePath(environment: ProcessInfo.processInfo.environment)
    }

    /// The continuous supervision record: `~/tbd/supervision/ledger.jsonl`.
    /// Append-only, one JSON object per line, whole-line writes.
    public static func supervisionLedgerPath(environment: [String: String]) -> String {
        supervisionDir(environment: environment).appendingPathComponent("ledger.jsonl").path
    }
    public static var supervisionLedgerPath: String {
        supervisionLedgerPath(environment: ProcessInfo.processInfo.environment)
    }

    /// The out-of-band heartbeat: `~/tbd/supervision/status.json`, rewritten
    /// atomically at boot, at every brake edge, and on a fixed cadence while
    /// the brake is released — so a watchdog that cannot reach the socket or
    /// the DB can still tell whether the daemon is alive. See
    /// `SupervisionStatusFile` for the full contract, including why staleness
    /// under an engaged brake is expected rather than a liveness signal.
    public static func supervisionStatusPath(environment: [String: String]) -> String {
        supervisionDir(environment: environment).appendingPathComponent("status.json").path
    }
    public static var supervisionStatusPath: String {
        supervisionStatusPath(environment: ProcessInfo.processInfo.environment)
    }

    /// A project's own directory: `~/tbd/supervision/projects/<name>`. Holds
    /// the operator-level playbook, the journal, the proposals doc, and any
    /// customized sweep or transition program.
    ///
    /// **Returns nil when the name is not one safe path component, and the
    /// optional return is the guarantee — do not make it non-optional.** A
    /// helper that accepts an unvalidated name and hands back a path outside
    /// its own directory *is* the vulnerability; refusing to compose one is how
    /// this closes, and it closes for every caller at once, including callers
    /// not yet written.
    ///
    /// Validating at the call site instead would be the same bug with more
    /// steps: not every project name arrives through `supervision.json`, where
    /// `SupervisionFile.validate()` already refuses an unusable name. A
    /// singleton project is named by its repo's **display name**, which an
    /// operator may edit to anything at all — `acme/web` yields
    /// `…/supervision/projects/acme/web`, and `..` walks straight out of the
    /// supervision directory. Those names never pass through the file's
    /// validation, so the only place that can be relied on to check them is
    /// here.
    ///
    /// A nil is not an error condition to escalate: the project is supervised
    /// normally and only its directory is unavailable
    /// (`SupervisionProject.hasUsableDirectory`,
    /// `SupervisionWarningCode.unusableProjectName`). The operator's fix is to
    /// rename the repo.
    public static func supervisionProjectDir(
        project: String, environment: [String: String]
    ) -> URL? {
        guard SupervisionFile.isSafeProjectName(project) else { return nil }
        return supervisionDir(environment: environment)
            .appendingPathComponent("projects")
            .appendingPathComponent(project)
    }
    public static func supervisionProjectDir(project: String) -> URL? {
        supervisionProjectDir(project: project, environment: ProcessInfo.processInfo.environment)
    }

    /// A declared project's operator-level playbook:
    /// `~/tbd/supervision/projects/<name>/supervision.md`.
    ///
    /// Nil for the same reason `supervisionProjectDir` is nil — a name that is
    /// not one safe path component has no directory to hold it, so there is no
    /// path to compose and the operator level is simply unavailable for that
    /// project until the repo is renamed.
    public static func supervisionPlaybookPath(
        project: String, environment: [String: String]
    ) -> String? {
        supervisionProjectDir(project: project, environment: environment)?
            .appendingPathComponent(supervisionPlaybookFileName).path
    }
    public static func supervisionPlaybookPath(project: String) -> String? {
        supervisionPlaybookPath(project: project, environment: ProcessInfo.processInfo.environment)
    }

    /// A singleton project's operator-level playbook:
    /// `~/tbd/repos/<repoID>/supervision.md`.
    ///
    /// Keyed by repo id rather than by the project's name, which is the repo's
    /// **display name** and may be anything at all — so unlike the declared
    /// case this path always composes. Same file-backed per-repo pattern as
    /// `hookPath` and `notesPath`: a user-authored editable blob lives in a
    /// file, never in a DB column.
    public static func repoPlaybookPath(repoID: UUID, environment: [String: String]) -> String {
        reposDir(environment: environment)
            .appendingPathComponent(repoID.uuidString)
            .appendingPathComponent(supervisionPlaybookFileName)
            .path
    }
    public static func repoPlaybookPath(repoID: UUID) -> String {
        repoPlaybookPath(repoID: repoID, environment: ProcessInfo.processInfo.environment)
    }

    /// The one filename a playbook has, at every level. Named once so the
    /// operator levels and the in-repo level cannot drift apart.
    public static let supervisionPlaybookFileName = "supervision.md"

    /// The in-repo playbook, relative to a repo's main checkout:
    /// `.agents/supervision.md`. The directory name describes its audience —
    /// local process guidance for any tool that drives agents — and TBD owns
    /// particular filenames inside it, never the directory.
    public static func repoAgentsPlaybookPath(checkout: String) -> String {
        URL(fileURLWithPath: checkout, isDirectory: true)
            .appendingPathComponent(agentsDirectoryName)
            .appendingPathComponent(supervisionPlaybookFileName)
            .path
    }

    /// The in-repo directory holding local process guidance for agent-driving
    /// tools.
    public static let agentsDirectoryName = ".agents"
}
