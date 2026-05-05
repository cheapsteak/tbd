import Foundation

/// Harnesses we can install the skill into. V1 ships only Claude Code; the
/// enum exists so adding `.codex` / `.gemini` later is mechanical.
public enum Harness: String, Sendable, Codable {
    case claudeCode
}

/// Result of a `status` call.
public enum SkillStatus: String, Sendable, Codable, Equatable {
    /// The harness's root config dir does not exist (e.g., `~/.claude/`).
    case harnessNotDetected
    /// The harness is detected but the skill file is not present.
    case notInstalled
    /// The skill file exists and matches the running daemon's content.
    case upToDate
    /// The skill file exists but differs from the running daemon's content.
    case outdated
}

/// Result of an `install` call.
public struct SkillInstallResult: Sendable, Codable, Equatable {
    public enum Action: String, Sendable, Codable, Equatable {
        case installed   // file did not exist before
        case updated     // file existed and differed; overwritten
        case noop        // file existed and already matched
    }
    public let action: Action
    public let path: String
}

public enum SkillInstallerError: Error, Equatable {
    case harnessNotDetected(Harness)
}

/// Minimal file-system abstraction so the installer can be unit-tested without
/// touching the real `~/`.
public protocol SkillFileSystem: Sendable {
    func fileExists(atPath path: String) -> Bool
    func readUTF8(atPath path: String) throws -> String
    func writeUTF8(_ contents: String, atPath path: String) throws
    func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws
    func isDirectory(atPath path: String) -> Bool
}

/// Real-FS implementation used in production.
public struct DefaultSkillFileSystem: SkillFileSystem {
    public init() {}

    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }

    public func readUTF8(atPath path: String) throws -> String {
        try String(contentsOfFile: path, encoding: .utf8)
    }

    public func writeUTF8(_ contents: String, atPath path: String) throws {
        try contents.write(toFile: path, atomically: true, encoding: .utf8)
    }

    public func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(
            atPath: path,
            withIntermediateDirectories: withIntermediateDirectories
        )
    }

    public func isDirectory(atPath path: String) -> Bool {
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }
}

/// Pure logic for installing the TBD skill. No daemon, no DB, no `os.Logger`.
public struct SkillInstaller: Sendable {
    private let fileSystem: SkillFileSystem
    private let claudeRoot: String

    /// Default home-relative path to the Claude Code root config dir.
    public static func defaultClaudeRoot() -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return home + "/.claude"
    }

    public init(
        fileSystem: SkillFileSystem = DefaultSkillFileSystem(),
        claudeRoot: String = SkillInstaller.defaultClaudeRoot()
    ) {
        self.fileSystem = fileSystem
        self.claudeRoot = claudeRoot
    }

    public func targetPath(for harness: Harness) -> String {
        switch harness {
        case .claudeCode:
            return claudeRoot + "/skills/tbd/SKILL.md"
        }
    }

    private func harnessRootPath(for harness: Harness) -> String {
        switch harness {
        case .claudeCode:
            return claudeRoot
        }
    }

    public func status(harness: Harness) -> SkillStatus {
        let root = harnessRootPath(for: harness)
        guard fileSystem.isDirectory(atPath: root) else {
            return .harnessNotDetected
        }
        let target = targetPath(for: harness)
        guard fileSystem.fileExists(atPath: target) else {
            return .notInstalled
        }
        let installed = (try? fileSystem.readUTF8(atPath: target)) ?? ""
        return installed == TBDSkillContent.body ? .upToDate : .outdated
    }

    @discardableResult
    public func install(harness: Harness) throws -> SkillInstallResult {
        let current = status(harness: harness)
        if current == .harnessNotDetected {
            throw SkillInstallerError.harnessNotDetected(harness)
        }
        let target = targetPath(for: harness)
        let parentDir = (target as NSString).deletingLastPathComponent
        try fileSystem.createDirectory(atPath: parentDir, withIntermediateDirectories: true)

        let action: SkillInstallResult.Action
        switch current {
        case .upToDate:
            action = .noop
        case .outdated:
            try fileSystem.writeUTF8(TBDSkillContent.body, atPath: target)
            action = .updated
        case .notInstalled:
            try fileSystem.writeUTF8(TBDSkillContent.body, atPath: target)
            action = .installed
        case .harnessNotDetected:
            // Already thrown above; keep exhaustive switch happy.
            throw SkillInstallerError.harnessNotDetected(harness)
        }
        return SkillInstallResult(action: action, path: target)
    }
}
