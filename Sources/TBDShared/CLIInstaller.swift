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
// older inode (an older version of TBDCLI, but still runs). `scripts/restart.sh`
// and `scripts/update.sh` re-link an existing hard link to the TBDCLI beside
// the daemon they start, so their builds never leave it behind. After any
// other rebuild the launch-time check (`CLILaunchCheck` in TBDApp) notices the
// inode mismatch. While the file at the install path is still the one TBD
// installed — its `CLIFileIdentity` matches the one TBD recorded — the check
// re-links it without asking. Any other file there may be the user's, so the
// check asks before replacing it.
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

/// A file's identity on disk: the device and inode `lstat` reports for it.
/// Two paths with equal identities are hard links to one file.
///
/// TBD records the identity of the `tbd` it installs. A rebuild gives the
/// daemon's TBDCLI a new inode, so the install goes stale, but while the file
/// at the install path keeps the recorded identity it is the one TBD put
/// there, and TBD may replace it without asking. An inode number can in
/// principle be reused once its file is deleted; that risk is accepted. The
/// change time is deliberately not part of the identity: a hard link's ctime
/// changes whenever its link count does, which every rebuild and every
/// worktree removal causes.
public struct CLIFileIdentity: Equatable, Sendable {
    public let device: Int64
    public let inode: UInt64

    public init(device: Int64, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// The identity of the regular file at `path`, or nil when nothing is
    /// there or the entry is a symlink, a directory or anything else that is
    /// not a regular file. `lstat`, so a symlink is never followed.
    public init?(regularFileAt path: String) {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            return nil
        }
        self.init(device: Int64(st.st_dev), inode: UInt64(st.st_ino))
    }

    /// `"<device>:<inode>"`, the form the identity is stored in. A string
    /// rather than a number, because an inode is a `UInt64` and a stored
    /// integer is an `Int`, which cannot hold every inode.
    public var storageString: String { "\(device):\(inode)" }

    /// Parse a ``storageString``. Nil for anything else.
    public init?(storageString: String) {
        let parts = storageString.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2,
              let device = Int64(parts[0]),
              let inode = UInt64(parts[1]) else {
            return nil
        }
        self.init(device: device, inode: inode)
    }
}

/// What a prompt about the CLI install should say.
public enum CLILaunchPromptKind: Equatable, Sendable {
    case missing
    /// The `tbd` at the install path is the one TBD installed — its identity
    /// matches the recorded one — and is now an older build than the
    /// daemon's. Only the menu asks about this; at launch it is refreshed
    /// without asking.
    case stale(current: String)
    /// Something TBD has no record of installing is at the install path: a
    /// regular file whose identity differs from the recorded one, any file
    /// when nothing is recorded, or a symlink. It may be the user's own, so
    /// nothing may call it an older version of TBD's CLI.
    case unrecognized(current: String)
    case unexpectedFileType
}

/// What the launch-time check should do about the CLI install.
public enum CLILaunchAction: Equatable, Sendable {
    case none
    /// Re-link the install path to the daemon's TBDCLI without asking.
    case refreshSilently
    case prompt(CLILaunchPromptKind)
}

public extension CLIInstallState {
    /// Decide what the launch-time check does.
    ///
    /// - Parameters:
    ///   - installedFile: the identity of the regular file at the install
    ///     path (``CLIInstaller/installedFileIdentity()``); nil when nothing
    ///     is there or the entry is not a regular file.
    ///   - recorded: the identity TBD recorded when it last installed the CLI
    ///     or saw a healthy install; nil when it has none.
    ///   - userPreviouslyDismissed: true if the user clicked "Not Now" on an
    ///     earlier `.missing` prompt. That suppresses the `.missing` prompt so
    ///     it does not nag; nothing else reads it.
    ///
    /// A stale install whose file still has the recorded identity is the one
    /// TBD installed, so it is refreshed without asking. Every other stale
    /// install — a different file, no record, or a symlink — is asked about,
    /// because TBD cannot tell it from the user's own. Recording the identity
    /// of an `.installed` file is the caller's job.
    func launchAction(
        installedFile: CLIFileIdentity?,
        recorded: CLIFileIdentity?,
        userPreviouslyDismissed: Bool
    ) -> CLILaunchAction {
        switch self {
        case .installed:
            return .none
        case .notInstalled:
            return userPreviouslyDismissed ? .none : .prompt(.missing)
        case .stale(let current):
            if let installedFile, installedFile == recorded {
                return .refreshSilently
            }
            return .prompt(.unrecognized(current: current))
        case .unexpectedFileType:
            return .prompt(.unexpectedFileType)
        }
    }

    /// The prompt the menu item shows. The menu always asks, because the user
    /// opened it. Nil for `.installed`, which gets the "already installed"
    /// alert instead. A stale install with the recorded identity really is an
    /// older version of TBD's CLI and is described as one; any other stale
    /// install is `.unrecognized`, as at launch.
    func menuPromptKind(
        installedFile: CLIFileIdentity?,
        recorded: CLIFileIdentity?
    ) -> CLILaunchPromptKind? {
        switch self {
        case .installed:
            return nil
        case .notInstalled:
            return .missing
        case .stale(let current):
            if let installedFile, installedFile == recorded {
                return .stale(current: current)
            }
            return .unrecognized(current: current)
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

public enum CLIInstallerError: LocalizedError, Equatable {
    case linkCreationFailed(String)
    /// link(2) returned EXDEV — source and install path are on different
    /// filesystems. Hard links can't span volumes, so the only fixes are
    /// moving the project or changing the install location.
    case crossDeviceLink(target: String, installPath: String)

    // Without this, error.localizedDescription returns the NSError bridge
    // string ("The operation couldn't be completed…") and the actual reason
    // (e.g. "create parent: …", "remove existing: …") is lost in both the
    // user-facing alert and the os.Logger error line.
    public var errorDescription: String? {
        switch self {
        case .linkCreationFailed(let reason):
            return "Link creation failed: \(reason)"
        case .crossDeviceLink(let target, let installPath):
            return "Can't hard-link \(installPath) → \(target): they're on different filesystems. TBD installs the CLI as a hard link, which only works within a single volume. Move your project to the same volume as your home directory, or pick a different install location on the same volume as your project."
        }
    }
}

public struct CLIInstaller: Sendable {
    public let installPath: String
    public let pathProbe: @Sendable () async -> String?
    public let homeDir: String
    public let shellPath: String
    /// Injectable hook around link(2). Returns 0 on success, or the errno
    /// value on failure — lets tests simulate EXDEV / EACCES without touching
    /// real filesystems on different volumes.
    public let linkFunc: @Sendable (String, String) -> Int32

    public init(
        installPath: String? = nil,
        homeDir: String = NSHomeDirectory(),
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        pathProbe: (@Sendable () async -> String?)? = nil,
        linkFunc: (@Sendable (String, String) -> Int32)? = nil
    ) {
        self.homeDir = homeDir
        self.installPath = installPath ?? (homeDir as NSString).appendingPathComponent(".local/bin/tbd")
        self.shellPath = shellPath
        self.pathProbe = pathProbe ?? { await Self.defaultLoginShellPathProbe(shellPath: shellPath) }
        self.linkFunc = linkFunc ?? { src, dst in
            link(src, dst) == 0 ? 0 : errno
        }
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
    /// Legacy symlinks (installed by versions of TBD before the hard-link
    /// scheme) are reported as `.stale`. A symlink has no recorded identity,
    /// so the launch-time check asks before replacing it with a hard link.
    public func currentState(expectedTarget: String?) -> CLIInstallState {
        var st = stat()
        guard lstat(installPath, &st) == 0 else {
            return .notInstalled
        }

        let mode = st.st_mode & S_IFMT
        if mode == S_IFLNK {
            // Legacy install from before hard-link migration (or someone
            // replaced our hard link). Surface as stale so the launch-time
            // check offers to re-install it as a hard link — the upgrade
            // path for users crossing the migration.
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

    /// The identity of the regular file at the install path, or nil when
    /// nothing is there or the entry is a symlink, a directory or anything
    /// else that is not a regular file.
    public func installedFileIdentity() -> CLIFileIdentity? {
        CLIFileIdentity(regularFileAt: installPath)
    }

    /// The hidden sibling `install(target:)` links to before renaming it over
    /// `installPath`: `.<name>.tbd-install` in the same directory, so the
    /// rename never crosses a filesystem.
    static func stagingPath(forInstallPath installPath: String) -> String {
        let directory = (installPath as NSString).deletingLastPathComponent
        let name = (installPath as NSString).lastPathComponent
        return (directory as NSString).appendingPathComponent(".\(name).tbd-install")
    }

    /// Create or replace the install path as a hard link to `target`.
    /// Idempotent. A failure leaves whatever was at the install path as it
    /// was.
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

        // Refuse a directory at the install path. rename(2) below would
        // refuse it too, but with a bare EISDIR; this names the fix. A
        // directory here is improbable in practice, and the "Replace the
        // file at …" alert doesn't signal that a whole directory is at stake.
        var st = stat()
        if lstat(installPath, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR {
            throw CLIInstallerError.linkCreationFailed(
                "a directory exists at \(installPath); remove it manually before installing"
            )
        }

        // Link to a hidden sibling, then rename(2) it over the install path.
        // rename replaces a regular file or a symlink in one step and does not
        // follow a symlink, so when either step fails the `tbd` already there
        // is untouched. That matters because the launch check refreshes
        // without asking: a failed refresh must not delete a working `tbd`.
        // The sibling's name is fixed rather than unique, so a crash between
        // the two steps leaves at most one leftover, and the next install
        // removes it here first.
        let stagingPath = Self.stagingPath(forInstallPath: installPath)
        if unlink(stagingPath) != 0, errno != ENOENT {
            let msg = String(cString: strerror(errno))
            throw CLIInstallerError.linkCreationFailed(
                "remove the leftover \(stagingPath) beside \(installPath): \(msg)"
            )
        }

        // Direct link(2) instead of FileManager.linkItem so we can read errno
        // cleanly and distinguish EXDEV (cross-filesystem) from generic
        // failures. Argument order matches link(2): first is the **existing**
        // source, second is the new name. The sibling is on the install
        // path's filesystem, so EXDEV still means target and install path
        // are on different volumes, and the error names the install path.
        let linkErr = linkFunc(target, stagingPath)
        if linkErr != 0 {
            if linkErr == EXDEV {
                throw CLIInstallerError.crossDeviceLink(target: target, installPath: installPath)
            }
            let msg = String(cString: strerror(linkErr))
            throw CLIInstallerError.linkCreationFailed(msg)
        }

        if rename(stagingPath, installPath) != 0 {
            let msg = String(cString: strerror(errno))
            unlink(stagingPath)
            throw CLIInstallerError.linkCreationFailed("replace \(installPath): \(msg)")
        }
        // When the install path was already a link to `target` (a reinstall
        // of a current install), the two names are one file, and rename(2)
        // may succeed without removing the sibling. Remove it; after a real
        // rename this finds nothing.
        unlink(stagingPath)

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
