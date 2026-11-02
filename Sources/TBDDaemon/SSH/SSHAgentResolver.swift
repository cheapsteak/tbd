import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SSHAgent")

/// Keeps `~/.ssh/tbd-agent.sock` pointing at a live SSH agent.
///
/// When the symlink is stale, `resolve()` probes candidate sockets with
/// `ssh-add -l` and repoints the symlink at the first one that answers. The
/// candidates come from three sources, in this order (`discoverCandidates()`):
///
/// 1. `launchctl getenv SSH_AUTH_SOCK`, launchd's own answer. It names the
///    login session's agent socket wherever the OS keeps it.
/// 2. The `SSH_AUTH_SOCK` this process was started with, captured when the
///    resolver is constructed, which the daemon does before it overwrites the
///    variable with the symlink path.
/// 3. `com.apple.launchd.*/Listeners` sockets under `/private/tmp` and
///    `/private/var/run`, newest first. Earlier macOS releases keep the socket
///    under the first; macOS 27 keeps it under the second.
public struct SSHAgentResolver: Sendable {
    public static let defaultSymlinkPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ssh/tbd-agent.sock"
    }()

    /// Where launchd creates `com.apple.launchd.*/Listeners` sockets.
    public static let defaultGlobBaseDirectories = ["/private/tmp", "/private/var/run"]

    /// Bounds each `ssh-add -l` probe and the `launchctl getenv` lookup.
    static let processTimeout: Duration = .seconds(2)

    /// The most glob matches probed, so a directory full of dead sessions
    /// cannot stretch a refresh past a few probes' worth of timeouts.
    static let globCandidateLimit = 10

    /// darwin's `MAXSYMLINKS`: the most links followed when checking whether a
    /// candidate leads back to the symlink.
    static let maxSymlinkHops = 32

    public let symlinkPath: String
    private let candidatePaths: [String]?
    private let launchdLookup: @Sendable () async -> String?
    private let inheritedSocketPath: String?
    private let globBaseDirectories: [String]
    private let clock: any Clock<Duration>

    /// - Parameters:
    ///   - symlinkPath: The stable symlink to maintain.
    ///   - candidatePaths: Replaces discovery outright and checks each path
    ///     with `connect(2)` rather than `ssh-add -l`, so a test can use a
    ///     plain bound socket.
    ///   - launchdLookup: Returns launchd's `SSH_AUTH_SOCK`, or nil. Left nil,
    ///     it runs `launchctl getenv SSH_AUTH_SOCK`, bounded by `clock`; pass
    ///     `{ nil }` for no launchd answer.
    ///   - inheritedSocketPath: The `SSH_AUTH_SOCK` this process was started
    ///     with. The default reads the environment at construction, so build
    ///     the resolver before anything overwrites the variable.
    ///   - globBaseDirectories: The directories searched for
    ///     `com.apple.launchd.*/Listeners` sockets.
    ///   - clock: Bounds the `launchctl` lookup and each `ssh-add` probe.
    public init(
        symlinkPath: String = SSHAgentResolver.defaultSymlinkPath,
        candidatePaths: [String]? = nil,
        launchdLookup: (@Sendable () async -> String?)? = nil,
        inheritedSocketPath: String? = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"],
        globBaseDirectories: [String] = SSHAgentResolver.defaultGlobBaseDirectories,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.symlinkPath = symlinkPath
        self.candidatePaths = candidatePaths
        if let launchdLookup {
            self.launchdLookup = launchdLookup
        } else {
            self.launchdLookup = { await SSHAgentResolver.launchctlGetenv(clock: clock) }
        }
        self.inheritedSocketPath = inheritedSocketPath
        self.globBaseDirectories = globBaseDirectories
        self.clock = clock
    }

    public func resolve() async -> Bool {
        if await isValid() {
            logger.debug("SSH agent symlink is valid")
            return true
        }

        if let injected = candidatePaths {
            logger.info("SSH agent stale, probing \(injected.count, privacy: .public) injected candidates")
            for path in injected where canConnect(to: path) {
                return applySymlink(to: path)
            }
            logger.warning("No live SSH agent found among \(injected.count, privacy: .public) injected candidates")
            return false
        }

        let candidates = await discoverCandidates()
        logger.info("SSH agent stale, probing \(candidates.count, privacy: .public) candidates")
        for path in candidates {
            if await probeWithSSHAdd(socketPath: path) {
                return applySymlink(to: path)
            }
        }

        logger.warning(
            "No live SSH agent found among \(candidates.count, privacy: .public) candidates: \(candidates.joined(separator: ", "), privacy: .public)")
        return false
    }

    public func isValid() async -> Bool {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else {
            return false
        }
        guard canConnect(to: target) else { return false }
        // A stale launchd socket can still accept connect(2) without speaking the
        // SSH agent protocol — probe with ssh-add -l to confirm a real agent answers.
        return await probeWithSSHAdd(socketPath: symlinkPath)
    }

    /// The sockets `resolve()` probes when no `candidatePaths` were injected:
    /// launchd's answer, then the inherited `SSH_AUTH_SOCK`, then the glob
    /// matches. A socket named twice keeps its first position and spelling.
    /// Empty and relative values are dropped, and so is any path that is the
    /// symlink or leads to it, since pointing the symlink there makes a loop.
    func discoverCandidates() async -> [String] {
        var sources: [String] = []
        if let launchd = await launchdLookup() { sources.append(launchd) }
        if let inheritedSocketPath { sources.append(inheritedSocketPath) }
        sources.append(contentsOf: globCandidates())

        var seen: Set<String> = []
        var candidates: [String] = []
        for raw in sources {
            let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard path.hasPrefix("/"), !leadsToSymlink(path) else { continue }
            if seen.insert(Self.canonicalLocation(of: path)).inserted {
                candidates.append(path)
            }
        }
        return candidates
    }

    /// launchd's `SSH_AUTH_SOCK`, from `launchctl getenv`. Nil when it prints
    /// nothing, fails, or is still running after `processTimeout`.
    static func launchctlGetenv(clock: any Clock<Duration>) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = ["getenv", "SSH_AUTH_SOCK"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        guard await runBounded(process, label: "launchctl getenv SSH_AUTH_SOCK", clock: clock) == 0 else {
            return nil
        }
        // The child has exited, and its few bytes of output sit in the pipe.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard let text = String(bytes: data, encoding: .utf8) else { return nil }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    // MARK: - Private

    private func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
                rawPathPtr.copyMemory(from: ptr, byteCount: min(strlen(ptr) + 1, sunPathSize))
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    private func probeWithSSHAdd(socketPath: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
        process.arguments = ["-l"]
        process.environment = ["SSH_AUTH_SOCK": socketPath]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // ssh-add exits 2 when no agent answers; 0 (keys listed) and 1 (no
        // keys) both mean one did.
        guard let status = await Self.runBounded(process, label: "SSH probe of \(socketPath)", clock: clock) else {
            return false
        }
        return status != 2
    }

    /// Runs `process` and returns its exit status. Nil when it cannot start,
    /// is killed by a signal, or is still running after `processTimeout`, in
    /// which case it is terminated.
    private static func runBounded(
        _ process: Process,
        label: String,
        clock: any Clock<Duration>
    ) async -> Int32? {
        return await withTaskGroup(of: Int32?.self) { group in
            group.addTask {
                do {
                    try process.run()
                    process.waitUntilExit()
                    // A process terminated at the deadline can finish first;
                    // its signal status is not an answer.
                    return process.terminationReason == .exit ? process.terminationStatus : nil
                } catch {
                    return nil
                }
            }

            group.addTask {
                try? await clock.sleep(for: SSHAgentResolver.processTimeout)
                if process.isRunning {
                    process.terminate()
                    logger.debug("\(label, privacy: .public) timed out")
                }
                return nil
            }

            let first = await group.next()
            group.cancelAll()
            return first ?? nil
        }
    }

    /// `com.apple.launchd.*/Listeners` sockets under every glob base
    /// directory, newest first, at most `globCandidateLimit` of them.
    private func globCandidates() -> [String] {
        let fm = FileManager.default
        var candidates: [(path: String, mtime: Date)] = []
        for baseDir in globBaseDirectories {
            guard let entries = try? fm.contentsOfDirectory(atPath: baseDir) else { continue }
            for dir in entries where dir.hasPrefix("com.apple.launchd.") {
                let path = "\(baseDir)/\(dir)/Listeners"
                var statBuf = stat()
                guard stat(path, &statBuf) == 0,
                      (statBuf.st_mode & S_IFMT) == S_IFSOCK else {
                    continue
                }
                let mtime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec))
                candidates.append((path: path, mtime: mtime))
            }
        }

        return candidates
            .sorted { $0.mtime > $1.mtime }
            .prefix(Self.globCandidateLimit)
            .map(\.path)
    }

    /// Whether `path` names the symlink, directly or through a chain of
    /// symlinks. A daemon restarted from a TBD shell inherits `SSH_AUTH_SOCK`
    /// set to the symlink itself.
    private func leadsToSymlink(_ path: String) -> Bool {
        let symlink = Self.canonicalLocation(of: symlinkPath)
        var current = path
        for _ in 0..<Self.maxSymlinkHops {
            if Self.canonicalLocation(of: current) == symlink { return true }
            guard let next = try? FileManager.default.destinationOfSymbolicLink(atPath: current) else {
                return false
            }
            if next.hasPrefix("/") {
                current = next
            } else {
                let linkDirectory = (current as NSString).deletingLastPathComponent
                current = (linkDirectory as NSString).appendingPathComponent(next)
            }
        }
        return false
    }

    /// `path` with its directory resolved by `realpath(3)` and its last
    /// component kept as written, so a symlink is named rather than followed:
    /// `/tmp/x` and `/private/tmp/x` compare equal. Unchanged when the
    /// directory does not exist.
    private static func canonicalLocation(of path: String) -> String {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard !directory.isEmpty, let resolved = realpath(directory, nil) else { return path }
        defer { free(resolved) }
        return (String(cString: resolved) as NSString).appendingPathComponent(name)
    }

    private func applySymlink(to target: String) -> Bool {
        do {
            try updateSymlink(to: target)
            return true
        } catch {
            logger.error("Failed to update symlink: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    private func updateSymlink(to target: String) throws {
        let fm = FileManager.default

        let sshDir = (symlinkPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: sshDir) {
            try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let old = (try? fm.destinationOfSymbolicLink(atPath: symlinkPath)) ?? "(none)"

        // Remove existing non-symlink file/directory at the path
        var pathStat = stat()
        if lstat(symlinkPath, &pathStat) == 0 {
            let fileType = pathStat.st_mode & S_IFMT
            if fileType != S_IFLNK {
                try fm.removeItem(atPath: symlinkPath)
            }
        }

        let tempPath = symlinkPath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        unlink(tempPath)
        guard symlink(target, tempPath) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.rename(tempPath, symlinkPath) == 0 else {
            unlink(tempPath)
            throw CocoaError(.fileWriteUnknown)
        }

        logger.info("SSH agent symlink updated: \(old, privacy: .public) → \(target, privacy: .public)")
    }
}
