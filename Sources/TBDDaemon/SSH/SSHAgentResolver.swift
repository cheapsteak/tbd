import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SSHAgent")

public struct SSHAgentResolver: Sendable {
    /// The stable symlink path: ~/.ssh/tbd-agent.sock
    public static let defaultSymlinkPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ssh/tbd-agent.sock"
    }()

    public let symlinkPath: String

    public init(symlinkPath: String = SSHAgentResolver.defaultSymlinkPath) {
        self.symlinkPath = symlinkPath
    }

    /// Check if the current symlink target is reachable via connect(2).
    public func isValid() -> Bool {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else {
            return false
        }
        return canConnect(to: target)
    }

    /// Attempt a connect(2) on a Unix domain socket path.
    /// Returns true if the connection succeeds (agent is alive).
    func canConnect(to path: String) -> Bool {
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
}
