import Foundation
import TBDShared
import Testing

@testable import TBDCLI

/// `tbd worktree archive` without `--force` refuses a worktree whose directory
/// holds uncommitted work — the contract its `--force` help text states. The
/// archive itself renames the directory into the deletion queue and unlinks
/// it, so these are the files a scripted "archive every idle worktree" sweep
/// would otherwise delete from under whoever is still editing them.
@Suite("worktree archive: uncommitted-work check")
struct WorktreeArchiveUncommittedCheckTests {

    private func makeDir() throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-archive-check-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private func row(path: String, repoID: UUID? = UUID()) -> Worktree {
        Worktree(
            id: UUID(), repoID: repoID, name: "helper", displayName: "helper",
            branch: "helper", path: path, status: .active, tmuxServer: "tbd-test"
        )
    }

    private func status(_ code: Int32, _ output: String) -> (String) -> ArchiveUncommittedCheck.StatusResult {
        { _ in ArchiveUncommittedCheck.StatusResult(exitCode: code, output: output) }
    }

    @Test func aCleanTreeIsArchived() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        #expect(ArchiveUncommittedCheck.refusal(for: row(path: dir), status: status(0, "")) == nil)
    }

    @Test func uncommittedAndUntrackedFilesRefuse() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let refusal = try #require(ArchiveUncommittedCheck.refusal(
            for: row(path: dir), status: status(0, " M Sources/a.swift\n?? notes.md\n")))
        #expect(refusal.contains("2 uncommitted change(s)"))
        #expect(refusal.contains("?? notes.md"))
        #expect(refusal.contains("--force"))
    }

    @Test func aStatusThatCannotRunRefusesRatherThanReadingClean() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let refusal = try #require(ArchiveUncommittedCheck.refusal(
            for: row(path: dir), status: status(128, "fatal: not a git repository")))
        #expect(refusal.contains("Could not check"))
        #expect(refusal.contains("--force"))
    }

    @Test func aScratchSpaceIsNotChecked() throws {
        // Its archive keeps the folder, so nothing in it is at risk.
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        var asked = false
        let refusal = ArchiveUncommittedCheck.refusal(
            for: row(path: dir, repoID: nil),
            status: { _ in asked = true; return .init(exitCode: 0, output: "?? x\n") })
        #expect(refusal == nil)
        #expect(!asked)
    }

    @Test func aMissingDirectoryHasNothingToLose() {
        let gone = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-archive-check-gone-\(UUID().uuidString)").path
        #expect(ArchiveUncommittedCheck.refusal(for: row(path: gone), status: status(128, "")) == nil)
    }

    @Test func realGitStatusSeesAnUntrackedFile() throws {
        let dir = try makeDir()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        try git(["init", "-q"], at: dir)
        #expect(ArchiveUncommittedCheck.refusal(for: row(path: dir)) == nil)

        try "draft\n".write(toFile: dir + "/draft.txt", atomically: true, encoding: .utf8)
        let refusal = try #require(ArchiveUncommittedCheck.refusal(for: row(path: dir)))
        #expect(refusal.contains("draft.txt"))
    }

    private func git(_ args: [String], at dir: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", dir] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
