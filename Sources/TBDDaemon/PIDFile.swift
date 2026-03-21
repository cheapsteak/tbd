import Foundation
import TBDShared

public struct PIDFile: Sendable {
    let path: String

    public init(path: String = TBDConstants.pidFilePath) {
        self.path = path
    }

    public func write() throws {
        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)".write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func read() -> pid_t? {
        guard let content = try? String(contentsOfFile: path, encoding: .utf8),
              let pid = pid_t(content.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return nil
        }
        return pid
    }

    public func isStale() -> Bool {
        guard let pid = read() else { return false }
        return kill(pid, 0) != 0
    }

    public func remove() {
        try? FileManager.default.removeItem(atPath: path)
    }

    public func cleanupIfStale() {
        if isStale() {
            remove()
            try? FileManager.default.removeItem(atPath: TBDConstants.socketPath)
        }
    }
}
