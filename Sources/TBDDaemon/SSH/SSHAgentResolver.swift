import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SSHAgent")

public struct SSHAgentResolver: Sendable {
    public static let defaultSymlinkPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ssh/tbd-agent.sock"
    }()

    public let symlinkPath: String
    private let candidatePaths: [String]?

    public init(
        symlinkPath: String = SSHAgentResolver.defaultSymlinkPath,
        candidatePaths: [String]? = nil
    ) {
        self.symlinkPath = symlinkPath
        self.candidatePaths = candidatePaths
    }

    public func resolve() async -> Bool {
        if isValid() {
            logger.debug("SSH agent symlink is valid")
            return true
        }

        let candidates: [String]
        if let injected = candidatePaths {
            candidates = injected
            logger.info("SSH agent stale, probing \(candidates.count) injected candidates")
            for path in candidates {
                if canConnect(to: path) {
                    return applySymlink(to: path)
                }
            }
        } else {
            candidates = discoverCandidates()
            logger.info("SSH agent stale, probing \(candidates.count) candidates")
            for path in candidates {
                if await probeWithSSHAdd(socketPath: path) {
                    return applySymlink(to: path)
                }
            }
        }

        logger.warning("No live SSH agent found among \(candidates.count) candidates")
        return false
    }

    public func isValid() -> Bool {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else {
            return false
        }
        return canConnect(to: target)
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

        return await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                do {
                    try process.run()
                    process.waitUntilExit()
                    return process.terminationStatus != 2
                } catch {
                    return false
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                if process.isRunning {
                    process.terminate()
                    logger.debug("SSH probe timed out for \(socketPath)")
                }
                return false
            }

            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    private func discoverCandidates() -> [String] {
        let fm = FileManager.default
        let baseDir = "/private/tmp"
        guard let entries = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

        var candidates: [(path: String, mtime: Date)] = []
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

        return candidates
            .sorted { $0.mtime > $1.mtime }
            .prefix(10)
            .map(\.path)
    }

    private func applySymlink(to target: String) -> Bool {
        do {
            try updateSymlink(to: target)
            return true
        } catch {
            logger.error("Failed to update symlink: \(error)")
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

        logger.info("SSH agent symlink updated: \(old) → \(target)")
    }
}
