import Foundation
import Testing
@testable import TBDDaemonLib

@Test func testServerName() {
    let id = UUID()
    let name = TmuxManager.serverName(forRepoID: id)
    #expect(name.hasPrefix("tbd-"))
    #expect(name.count == 4 + 8) // "tbd-" + 8 hex chars
}

@Test func testServerNameDeterministic() {
    let id = UUID()
    let name1 = TmuxManager.serverName(forRepoID: id)
    let name2 = TmuxManager.serverName(forRepoID: id)
    #expect(name1 == name2)
}

@Test func testNewServerCommand() {
    let cmd = TmuxManager.newServerCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/repo"
    )
    #expect(cmd.contains("-L tbd-a1b2c3d4"))
    #expect(cmd.contains("new-session"))
    #expect(cmd.contains("-s main"))
    #expect(cmd.contains("-c /tmp/repo"))
}

@Test func testNewWindowCommand() {
    let cmd = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "claude --dangerously-skip-permissions"
    )
    #expect(cmd.contains("-L tbd-a1b2c3d4"))
    #expect(cmd.contains("-t main"))
    #expect(cmd.contains("-c /tmp/worktree"))
    #expect(cmd.contains("claude --dangerously-skip-permissions"))
}

@Test func testKillWindowCommand() {
    let cmd = TmuxManager.killWindowCommand(
        server: "tbd-a1b2c3d4",
        windowID: "@5"
    )
    #expect(cmd.contains("-L tbd-a1b2c3d4"))
    #expect(cmd.contains("kill-window"))
    #expect(cmd.contains("-t @5"))
}

@Test func testSendKeysCommand() {
    let cmd = TmuxManager.sendKeysCommand(
        server: "tbd-a1b2c3d4",
        paneID: "%3",
        text: "hello world"
    )
    #expect(cmd.contains("-L tbd-a1b2c3d4"))
    #expect(cmd.contains("send-keys"))
    #expect(cmd.contains("-l"))
    #expect(cmd.contains("-t %3"))
    #expect(cmd.contains("hello world"))
}

@Test func testListWindowsCommand() {
    let cmd = TmuxManager.listWindowsCommand(
        server: "tbd-a1b2c3d4",
        session: "main"
    )
    #expect(cmd.contains("-L tbd-a1b2c3d4"))
    #expect(cmd.contains("list-windows"))
    #expect(cmd.contains("-t main"))
}

@Test func testDryRunCreateWindow() async throws {
    let manager = TmuxManager(dryRun: true)
    let result1 = try await manager.createWindow(
        server: "tbd-test",
        session: "main",
        cwd: "/tmp",
        shellCommand: "echo hi"
    )
    #expect(result1.windowID == "@mock-0")
    #expect(result1.paneID == "%mock-0")

    let result2 = try await manager.createWindow(
        server: "tbd-test",
        session: "main",
        cwd: "/tmp",
        shellCommand: "echo hi"
    )
    #expect(result2.windowID == "@mock-1")
    #expect(result2.paneID == "%mock-1")
}

@Test func testDryRunListWindows() async throws {
    let manager = TmuxManager(dryRun: true)
    let windows = try await manager.listWindows(server: "tbd-test", session: "main")
    #expect(windows.isEmpty)
}

@Test func testDryRunEnsureServer() async throws {
    let manager = TmuxManager(dryRun: true)
    // Should not throw in dry run mode
    try await manager.ensureServer(server: "tbd-test", session: "main", cwd: "/tmp")
}

@Test func testDryRunKillWindow() async throws {
    let manager = TmuxManager(dryRun: true)
    // Should not throw in dry run mode
    try await manager.killWindow(server: "tbd-test", windowID: "@mock-0")
}

@Test func testDryRunSendKeys() async throws {
    let manager = TmuxManager(dryRun: true)
    // Should not throw in dry run mode
    try await manager.sendKeys(server: "tbd-test", paneID: "%mock-0", text: "hello")
}
