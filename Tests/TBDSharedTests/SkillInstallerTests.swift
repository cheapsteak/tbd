import Testing
import Foundation
@testable import TBDShared

/// In-memory file system for testing.
final class FakeFileSystem: SkillFileSystem, @unchecked Sendable {
    var files: [String: String] = [:]
    var directories: Set<String> = []

    func fileExists(atPath path: String) -> Bool {
        files[path] != nil || directories.contains(path)
    }

    func readUTF8(atPath path: String) throws -> String {
        guard let s = files[path] else {
            throw NSError(domain: "FakeFS", code: 1)
        }
        return s
    }

    func writeUTF8(_ contents: String, atPath path: String) throws {
        files[path] = contents
    }

    func createDirectory(atPath path: String, withIntermediateDirectories: Bool) throws {
        directories.insert(path)
    }

    func isDirectory(atPath path: String) -> Bool {
        directories.contains(path)
    }
}

private func make(installed claudeRoot: Bool = true) -> (SkillInstaller, FakeFileSystem) {
    let fs = FakeFileSystem()
    if claudeRoot {
        fs.directories.insert("/home/u/.claude")
    }
    let installer = SkillInstaller(
        fileSystem: fs,
        claudeSkillsRoot: "/home/u/.claude/skills"
    )
    return (installer, fs)
}

@Test func statusReportsHarnessNotDetectedWhenClaudeRootMissing() {
    let (installer, _) = make(installed: false)
    let status = installer.status(harness: .claudeCode)
    #expect(status == .harnessNotDetected)
}

@Test func statusReportsNotInstalledWhenFileAbsent() {
    let (installer, _) = make()
    let status = installer.status(harness: .claudeCode)
    #expect(status == .notInstalled)
}

@Test func statusReportsUpToDateWhenContentMatches() {
    let (installer, fs) = make()
    fs.files["/home/u/.claude/skills/tbd/SKILL.md"] = TBDSkillContent.body
    let status = installer.status(harness: .claudeCode)
    #expect(status == .upToDate)
}

@Test func statusReportsOutdatedWhenContentDiffers() {
    let (installer, fs) = make()
    fs.files["/home/u/.claude/skills/tbd/SKILL.md"] = "different"
    let status = installer.status(harness: .claudeCode)
    #expect(status == .outdated)
}

@Test func installWritesFileWhenNotInstalled() throws {
    let (installer, fs) = make()
    let result = try installer.install(harness: .claudeCode)
    #expect(result.action == .installed)
    #expect(result.path == "/home/u/.claude/skills/tbd/SKILL.md")
    #expect(fs.files["/home/u/.claude/skills/tbd/SKILL.md"] == TBDSkillContent.body)
}

@Test func installCreatesParentDirectoryIfMissing() throws {
    let (installer, fs) = make()
    _ = try installer.install(harness: .claudeCode)
    #expect(fs.directories.contains("/home/u/.claude/skills/tbd"))
}

@Test func installOverwritesWhenOutdated() throws {
    let (installer, fs) = make()
    fs.files["/home/u/.claude/skills/tbd/SKILL.md"] = "stale content"
    let result = try installer.install(harness: .claudeCode)
    #expect(result.action == .updated)
    #expect(fs.files["/home/u/.claude/skills/tbd/SKILL.md"] == TBDSkillContent.body)
}

@Test func installIsNoopWhenAlreadyUpToDate() throws {
    let (installer, fs) = make()
    fs.files["/home/u/.claude/skills/tbd/SKILL.md"] = TBDSkillContent.body
    let result = try installer.install(harness: .claudeCode)
    #expect(result.action == .noop)
}

@Test func installThrowsWhenHarnessNotDetected() {
    let (installer, _) = make(installed: false)
    #expect(throws: SkillInstallerError.self) {
        _ = try installer.install(harness: .claudeCode)
    }
}

@Test func harnessTargetPathIsExpected() {
    let (installer, _) = make()
    #expect(installer.targetPath(for: .claudeCode) == "/home/u/.claude/skills/tbd/SKILL.md")
}
