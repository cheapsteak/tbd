import Foundation
import os

// MARK: - Why hard links, not symlinks
//
// `~/.local/bin/tbd` is installed as a **hard link** to the daemon's sibling
// TBDCLI binary. The TBDCLI binary lives inside an ephemeral worktree's
// `.build/.../TBDCLI` — when that worktree is archived (`git worktree remove`)
// or pruned (`git worktree prune`), a *symlink* installed at `~/.local/bin/tbd`
// would dangle and the user's `tbd` command would 404 until the next TBDApp
// launch re-installed it.
//
// A hard link shares the inode with `.build/.../TBDCLI`. When the worktree's
// `.build` dir is removed, the file's link count drops by 1 but
// `~/.local/bin/tbd` keeps a reference, so the on-disk binary stays alive and
// `tbd` keeps working.
//
// Trade-off: a subsequent `swift build` in any worktree writes a *new* inode
// at its `.build/.../TBDCLI`. Our existing install path still points at the
// older inode (an older version of TBDCLI, but still runs). The launch-time
// `CLIInstallerCoordinator` notices the inode mismatch and offers to
// "Refresh" — same UX the symlink-staleness check already provided.
//
// This is the same trick `scripts/restart.sh` applies to the `.app` bundle
// binary (see lines 57–67 of that file) for the same fragility reason:
// worktrees come and go but the kernel-reported exec path must stay stable.
// Precedent: PR #195 ("Fix: Make macOS notification banners actually fire").

// CLIInstaller is currently only invoked from TBDApp; using com.tbd.app keeps
// the established subsystem taxonomy from docs/diagnostics-strategy.md intact.
private let logger = Logger(subsystem: "com.tbd.app", category: "cli-installer")

public enum CLIInstallState: Equatable, Sendable {
    case notInstalled
    case installed(target: String)
    case stale(currentTarget: String)
    /// A directory (or other non-regular-file) occupies `installPath`.
    /// `install()` will refuse to overwrite a directory; the UI surfaces a
    /// manual-removal prompt instead.
    case unexpectedFileType
}

/// What the launch-time check should prompt the user about, if anything.
public enum CLILaunchPromptKind: Equatable, Sendable {
    case missing
    case stale(current: String)
    case unexpectedFileType
}

public extension CLIInstallState {
    /// Decide whether the launch-time check should surface a prompt.
    ///
    /// `userPreviouslyDismissed` should be true if the user clicked "Not Now"
    /// on a previous `.notInstalled` prompt — in which case we suppress the
    /// re-prompt to avoid nagging. `.stale` and `.unexpectedFileType` are
    /// always surfaced because they represent a broken install the user
    /// likely wants fixed (and they explicitly opted in by installing once
    /// before).
    func launchPromptKind(userPreviouslyDismissed: Bool) -> CLILaunchPromptKind? {
        switch self {
        case .installed:
            return nil
        case .notInstalled:
            return userPreviouslyDismissed ? nil : .missing
        case .stale(let current):
            return .stale(current: current)
        case .unexpectedFileType:
            return .unexpectedFileType
        }
    }
}

public struct CLIInstallResult: Equatable, Sendable {
    public let installPath: String
    public let target: String
    public let onPath: Bool
    public let suggestedShellRC: String?
    public let exportLine: String?

    public init(
        installPath: String,
        target: String,
        onPath: Bool,
        suggestedShellRC: String?,
        exportLine: String?
    ) {
        self.installPath = installPath
        self.target = target
        self.onPath = onPath
        self.suggestedShellRC = suggestedShellRC
        self.exportLine = exportLine
    }
}

public enum CLIInstallerError: Error, Equatable {
    case linkCreationFailed(String)
}

extension CLIInstallerError: LocalizedError {
    // Without this, error.localizedDescription returns the NSError bridge
    // string ("The operation couldn't be completed…") and the actual reason
    // (e.g. "create parent: …", "remove existing: …") is lost in both the
    // user-facing alert and the os.Logger error line.
    public var errorDescription: String? {
        switch self {
        case .linkCreationFailed(let reason):
            return "Link creation failed: \(reason)"
        }
    }
}

public struct CLIInstaller: Sendable {
    public let installPath: String
    public let pathProbe: @Sendable () async -> String?
    public let homeDir: String
    public let shellPath: String

    public init(
        installPath: String? = nil,
        homeDir: String = NSHomeDirectory(),
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        pathProbe: (@Sendable () async -> String?)? = nil
    ) {
        self.homeDir = homeDir
        self.installPath = installPath ?? (homeDir as NSString).appendingPathComponent(".local/bin/tbd")
        self.shellPath = shellPath
        self.pathProbe = pathProbe ?? { await Self.defaultLoginShellPathProbe(shellPath: shellPath) }
    }

    /// Compute the TBDCLI path given the daemon's executable path.
    public static func cliPath(forDaemonExecutable daemonPath: String) -> String {
        let dir = (daemonPath as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("TBDCLI")
    }

    /// Inspect the install path. Pass the expected target (resolved
    /// daemon-sibling path) to determine staleness by **inode comparison** —
    /// our install is a hard link, so two paths sharing the same `(st_dev,
    /// st_ino)` mean the kernel sees them as the same file.
    ///
    /// Legacy symlinks (installed by versions of TBD before this PR) are
    /// reported as `.stale` so the launch-time `CLIInstallerCoordinator`
    /// prompt re-installs them as hard links on the next refresh.
    public func currentState(expectedTarget: String?) -> CLIInstallState {
        var st = stat()
        guard lstat(installPath, &st) == 0 else {
            return .notInstalled
        }

        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK {
            // Legacy install from before hard-link migration (or someone
            // replaced our hard link). Surface as stale so the launch-time
            // prompt re-installs as a hard link on the next refresh —
            // intentional upgrade path for users crossing the migration.
            let dest = (try? FileManager.default.destinationOfSymbolicLink(atPath: installPath)) ?? installPath
            let resolved = Self.absolutize(
                dest,
                relativeTo: (installPath as NSString).deletingLastPathComponent,
                homeDir: homeDir
            )
            return .stale(currentTarget: resolved)
        }
        if mode == S_IFDIR {
            return .unexpectedFileType
        }
        guard mode == S_IFREG else {
            return .unexpectedFileType
        }

        guard let expectedTarget else {
            // Without a reference target we can only confirm "something is
            // here". Treat as installed-pointing-at-self.
            return .installed(target: installPath)
        }

        var expectedStat = stat()
        guard stat(expectedTarget, &expectedStat) == 0 else {
            // Expected target gone — our install path still works (hard
            // link keeps the inode alive) but it's structurally stale.
            return .stale(currentTarget: installPath)
        }
        if st.st_dev == expectedStat.st_dev && st.st_ino == expectedStat.st_ino {
            return .installed(target: expectedTarget)
        }
        return .stale(currentTarget: installPath)
    }

    /// Create or replace the install path as a hard link to `target`.
    /// Idempotent.
    public func install(target: String) async throws -> CLIInstallResult {
        let fm = FileManager.default
        let parent = (installPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            do {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                throw CLIInstallerError.linkCreationFailed("create parent: \(error.localizedDescription)")
            }
        }

        // Remove any existing entry (symlink, hard link, or file). Use lstat
        // so we don't follow a broken symlink and miss the removal. Refuse
        // to recurse into a directory: FileManager.removeItem deletes
        // directories recursively, and the "Replace the file at …" alert
        // doesn't signal that scope. A directory at this path is improbable
        // in practice, but the safer behavior is to surface the situation to
        // the user.
        var st = stat()
        if lstat(installPath, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFDIR {
                throw CLIInstallerError.linkCreationFailed(
                    "a directory exists at \(installPath); remove it manually before installing"
                )
            }
            do {
                try fm.removeItem(atPath: installPath)
            } catch {
                throw CLIInstallerError.linkCreationFailed("remove existing: \(error.localizedDescription)")
            }
        }

        do {
            // FileManager.linkItem(atPath:toPath:) wraps link(2): first
            // argument is the **existing** source, second is the new name.
            try fm.linkItem(atPath: target, toPath: installPath)
        } catch {
            throw CLIInstallerError.linkCreationFailed(error.localizedDescription)
        }

        let pathInfo = await pathStatus()
        return CLIInstallResult(
            installPath: installPath,
            target: target,
            onPath: pathInfo.onPath,
            suggestedShellRC: pathInfo.onPath ? nil : pathInfo.shellRC,
            exportLine: pathInfo.onPath ? nil : pathInfo.exportLine
        )
    }

    /// Compute current path status (whether the install path's parent dir is
    /// on the user's login-shell PATH, plus suggested rc / export line if
    /// not).
    public func pathStatus() async -> (onPath: Bool, shellRC: String, exportLine: String) {
        let binDir = (installPath as NSString).deletingLastPathComponent
        let probed = await pathProbe()
        let onPath = Self.directoryIsOnPath(binDir, pathString: probed, homeDir: homeDir)
        let (rc, line) = Self.shellRCAndExport(forShellPath: shellPath, binDir: binDir, homeDir: homeDir)
        return (onPath, rc, line)
    }

    // MARK: - Helpers

    static func directoryIsOnPath(_ dir: String, pathString: String?, homeDir: String) -> Bool {
        guard let pathString, !pathString.isEmpty else { return false }
        let entries = pathString.split(separator: ":").map(String.init)
        let normalizedDir = absolutize(dir, relativeTo: homeDir, homeDir: homeDir)
        for entry in entries {
            let normalized = absolutize(entry, relativeTo: homeDir, homeDir: homeDir)
            if normalized == normalizedDir { return true }
        }
        return false
    }

    static func shellRCAndExport(forShellPath shellPath: String, binDir: String, homeDir: String) -> (rc: String, exportLine: String) {
        let shellName = (shellPath as NSString).lastPathComponent.lowercased()
        // Use $HOME (not ~) so the path expands inside quoted strings —
        // bash/zsh don't expand ~ inside double quotes; fish doesn't expand
        // anything inside single quotes. Double-quoting keeps space-safety.
        let exportPath = shellExpandable(binDir, homeDir: homeDir)
        switch shellName {
        case "fish":
            return ("~/.config/fish/config.fish", "set -gx PATH \"\(exportPath)\" $PATH")
        case "bash":
            return ("~/.bash_profile", "export PATH=\"\(exportPath):$PATH\"")
        default:
            return ("~/.zshrc", "export PATH=\"\(exportPath):$PATH\"")
        }
    }

    /// Render a path as `$HOME/...` if it's under the home dir, else the
    /// absolute path. Suitable for embedding inside double-quoted strings
    /// in bash/zsh and fish, where `~` would NOT be expanded.
    static func shellExpandable(_ path: String, homeDir: String) -> String {
        let abs = absolutize(path, relativeTo: homeDir, homeDir: homeDir)
        if abs == homeDir { return "$HOME" }
        if abs.hasPrefix(homeDir + "/") {
            return "$HOME" + abs.dropFirst(homeDir.count)
        }
        return abs
    }

    static func expandTilde(_ path: String, homeDir: String) -> String {
        if path == "~" { return homeDir }
        if path.hasPrefix("~/") {
            return homeDir + String(path.dropFirst(1))
        }
        return path
    }

    static func absolutize(_ path: String, relativeTo base: String, homeDir: String) -> String {
        let expanded = expandTilde(path, homeDir: homeDir)
        let nsPath = expanded as NSString
        if nsPath.isAbsolutePath {
            return nsPath.standardizingPath
        }
        let combined = (base as NSString).appendingPathComponent(expanded)
        return (combined as NSString).standardizingPath
    }

    /// Spawn the user's login shell to print PATH. Returns nil on any failure.
    /// Bridges `Process.terminationHandler` and a 2-second `DispatchQueue` timer
    /// into a continuation so the awaiting task yields its cooperative-pool
    /// thread instead of blocking on `Thread.sleep`.
    public static func defaultLoginShellPathProbe(shellPath: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shellPath)
        process.arguments = ["-ilc", "echo $PATH"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()  // discard

        return await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            // Guard against double-resume (terminationHandler vs timeout race).
            let resumed = OnceFlag()
            let resume: @Sendable (String?) -> Void = { value in
                if resumed.exchange(true) { return }
                cont.resume(returning: value)
            }

            process.terminationHandler = { _ in
                guard let data = try? pipe.fileHandleForReading.readToEnd(),
                      let output = String(data: data, encoding: .utf8) else {
                    resume(nil); return
                }
                // Interactive shells (-i) source rc files that may print
                // banners (nvm/rbenv version notices, welcome messages) to
                // stdout *before* our `echo $PATH`, so PATH is always the
                // last non-empty line.
                let lastLine = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).last.map(String.init) ?? ""
                let trimmed = lastLine.trimmingCharacters(in: .whitespaces)
                resume(trimmed.isEmpty ? nil : trimmed)
            }

            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                if process.isRunning {
                    process.terminate()
                    logger.warning("Login-shell PATH probe timed out")
                }
                resume(nil)
            }

            do {
                try process.run()
            } catch {
                logger.warning("Login-shell PATH probe failed to launch \(shellPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
                resume(nil)
            }
        }
    }
}

/// One-shot flag used to gate single-resume semantics on the probe
/// continuation when terminationHandler and the timeout race. `swift-atomics`
/// is not in this package's deps, so a tiny `NSLock`-backed flag does the job.
private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    /// Sets the flag to true and returns the *previous* value.
    func exchange(_ newValue: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let old = value
        value = newValue
        return old
    }
}
