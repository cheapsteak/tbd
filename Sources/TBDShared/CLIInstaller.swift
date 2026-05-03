import Foundation
import os

// CLIInstaller is currently only invoked from TBDApp; using com.tbd.app keeps
// the established subsystem taxonomy from docs/diagnostics-strategy.md intact.
private let logger = Logger(subsystem: "com.tbd.app", category: "cli-installer")

public enum CLIInstallState: Equatable {
    case notInstalled
    case installed(target: String)
    case stale(currentTarget: String)
    /// A non-symlink (regular file or directory) exists at `symlinkPath`.
    /// `install()` will overwrite it, but the UI should warn before doing so.
    case nonSymlink
}

public struct CLIInstallResult: Equatable, Sendable {
    public let symlinkPath: String
    public let target: String
    public let onPath: Bool
    public let suggestedShellRC: String?
    public let exportLine: String?

    public init(
        symlinkPath: String,
        target: String,
        onPath: Bool,
        suggestedShellRC: String?,
        exportLine: String?
    ) {
        self.symlinkPath = symlinkPath
        self.target = target
        self.onPath = onPath
        self.suggestedShellRC = suggestedShellRC
        self.exportLine = exportLine
    }
}

public enum CLIInstallerError: Error, Equatable {
    case daemonExecutablePathUnavailable
    case cliBinaryNotFound(searched: String)
    case symlinkCreationFailed(String)
}

public struct CLIInstaller: Sendable {
    public let symlinkPath: String
    public let pathProbe: @Sendable () async -> String?
    public let homeDir: String
    public let shellPath: String

    public init(
        symlinkPath: String? = nil,
        homeDir: String = NSHomeDirectory(),
        shellPath: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
        pathProbe: (@Sendable () async -> String?)? = nil
    ) {
        self.homeDir = homeDir
        self.symlinkPath = symlinkPath ?? (homeDir as NSString).appendingPathComponent(".local/bin/tbd")
        self.shellPath = shellPath
        self.pathProbe = pathProbe ?? { await Self.defaultLoginShellPathProbe(shellPath: shellPath) }
    }

    /// Compute the TBDCLI path given the daemon's executable path.
    public static func cliPath(forDaemonExecutable daemonPath: String) -> String {
        let dir = (daemonPath as NSString).deletingLastPathComponent
        return (dir as NSString).appendingPathComponent("TBDCLI")
    }

    /// Inspect the symlink. Pass the expected target (resolved daemon-sibling
    /// path) to determine staleness. If `expectedTarget` is nil, only checks
    /// that the symlink exists and points at a real file.
    public func currentState(expectedTarget: String?) -> CLIInstallState {
        let fm = FileManager.default
        let attrs = try? fm.attributesOfItem(atPath: symlinkPath)
        guard let attrs, attrs[.type] as? FileAttributeType == .typeSymbolicLink else {
            if (attrs?[.type] as? FileAttributeType) != nil {
                return .nonSymlink
            }
            return .notInstalled
        }
        let destination: String
        do {
            destination = try fm.destinationOfSymbolicLink(atPath: symlinkPath)
        } catch {
            return .notInstalled
        }

        let resolvedDest = Self.absolutize(
            destination,
            relativeTo: (symlinkPath as NSString).deletingLastPathComponent,
            homeDir: homeDir
        )

        if let expectedTarget {
            let expectedAbs = Self.absolutize(expectedTarget, relativeTo: homeDir, homeDir: homeDir)
            if resolvedDest == expectedAbs && fm.fileExists(atPath: resolvedDest) {
                return .installed(target: resolvedDest)
            }
            return .stale(currentTarget: resolvedDest)
        } else {
            if fm.fileExists(atPath: resolvedDest) {
                return .installed(target: resolvedDest)
            }
            return .stale(currentTarget: resolvedDest)
        }
    }

    /// Create or replace the symlink to point at `target`. Idempotent.
    public func install(target: String) async throws -> CLIInstallResult {
        let fm = FileManager.default
        let parent = (symlinkPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: parent) {
            do {
                try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)
            } catch {
                throw CLIInstallerError.symlinkCreationFailed("create parent: \(error.localizedDescription)")
            }
        }

        // Remove any existing entry (symlink or file). Use lstat so we don't
        // follow a broken symlink and miss the removal.
        var st = stat()
        if lstat(symlinkPath, &st) == 0 {
            do {
                try fm.removeItem(atPath: symlinkPath)
            } catch {
                throw CLIInstallerError.symlinkCreationFailed("remove existing: \(error.localizedDescription)")
            }
        }

        do {
            try fm.createSymbolicLink(atPath: symlinkPath, withDestinationPath: target)
        } catch {
            throw CLIInstallerError.symlinkCreationFailed(error.localizedDescription)
        }

        let pathInfo = await pathStatus()
        return CLIInstallResult(
            symlinkPath: symlinkPath,
            target: target,
            onPath: pathInfo.onPath,
            suggestedShellRC: pathInfo.onPath ? nil : pathInfo.shellRC,
            exportLine: pathInfo.onPath ? nil : pathInfo.exportLine
        )
    }

    /// Compute current path status (whether the symlink's parent dir is on the
    /// user's login-shell PATH, plus suggested rc / export line if not).
    public func pathStatus() async -> (onPath: Bool, shellRC: String, exportLine: String) {
        let binDir = (symlinkPath as NSString).deletingLastPathComponent
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
        let displayBinDir = displayPath(binDir, homeDir: homeDir)
        switch shellName {
        case "fish":
            let rc = "~/.config/fish/config.fish"
            let line: String
            if displayBinDir == "~/.local/bin" {
                line = "set -gx PATH $HOME/.local/bin $PATH"
            } else {
                // Single-quote so paths with spaces don't word-split.
                line = "set -gx PATH '\(displayBinDir)' $PATH"
            }
            return (rc, line)
        case "bash":
            let rc = "~/.bash_profile"
            let line: String
            if displayBinDir == "~/.local/bin" {
                line = "export PATH=\"$HOME/.local/bin:$PATH\""
            } else {
                line = "export PATH=\"\(displayBinDir):$PATH\""
            }
            return (rc, line)
        default:
            let rc = "~/.zshrc"
            let line: String
            if displayBinDir == "~/.local/bin" {
                line = "export PATH=\"$HOME/.local/bin:$PATH\""
            } else {
                line = "export PATH=\"\(displayBinDir):$PATH\""
            }
            return (rc, line)
        }
    }

    /// Render a path as `~/...` if it's under the home dir, else the absolute path.
    static func displayPath(_ path: String, homeDir: String) -> String {
        let abs = absolutize(path, relativeTo: homeDir, homeDir: homeDir)
        if abs == homeDir { return "~" }
        if abs.hasPrefix(homeDir + "/") {
            return "~" + abs.dropFirst(homeDir.count)
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

    static func absolutize(_ path: String, relativeTo base: String, homeDir: String = NSHomeDirectory()) -> String {
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
            let resumed = ManagedAtomicBool()
            let resume: @Sendable (String?) -> Void = { value in
                if resumed.exchange(true) { return }
                cont.resume(returning: value)
            }

            process.terminationHandler = { _ in
                guard let data = try? pipe.fileHandleForReading.readToEnd(),
                      let output = String(data: data, encoding: .utf8) else {
                    resume(nil); return
                }
                let firstLine = output.split(whereSeparator: { $0 == "\n" || $0 == "\r" }).first.map(String.init) ?? ""
                let trimmed = firstLine.trimmingCharacters(in: .whitespaces)
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

/// Lock-protected bool used to gate single-resume semantics on the probe
/// continuation. `swift-atomics` is not in this package's deps, so a tiny
/// `NSLock`-backed flag does the job.
private final class ManagedAtomicBool: @unchecked Sendable {
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

