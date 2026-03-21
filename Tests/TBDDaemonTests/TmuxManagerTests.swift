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
    let args = TmuxManager.newServerCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/repo"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("new-session"))
    #expect(args.contains("-s"))
    #expect(args.contains("main"))
    #expect(args.contains("-c"))
    #expect(args.contains("/tmp/repo"))
}

@Test func testHasSessionCommand() {
    let args = TmuxManager.hasSessionCommand(
        server: "tbd-a1b2c3d4",
        session: "main"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("has-session"))
    #expect(args.contains("-t"))
    #expect(args.contains("main"))
}

@Test func testNewWindowCommand() {
    let args = TmuxManager.newWindowCommand(
        server: "tbd-a1b2c3d4",
        session: "main",
        cwd: "/tmp/worktree",
        shellCommand: "claude --dangerously-skip-permissions"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("-t"))
    #expect(args.contains("main"))
    #expect(args.contains("-c"))
    #expect(args.contains("/tmp/worktree"))
    #expect(args.contains("claude --dangerously-skip-permissions"))
}

@Test func testKillWindowCommand() {
    let args = TmuxManager.killWindowCommand(
        server: "tbd-a1b2c3d4",
        windowID: "@5"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("kill-window"))
    #expect(args.contains("-t"))
    #expect(args.contains("@5"))
}

@Test func testSendKeysCommand() {
    let args = TmuxManager.sendKeysCommand(
        server: "tbd-a1b2c3d4",
        paneID: "%3",
        text: "hello world"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("send-keys"))
    #expect(args.contains("-l"))
    #expect(args.contains("-t"))
    #expect(args.contains("%3"))
    #expect(args.contains("hello world"))
}

@Test func testListWindowsCommand() {
    let args = TmuxManager.listWindowsCommand(
        server: "tbd-a1b2c3d4",
        session: "main"
    )
    #expect(args.contains("-L"))
    #expect(args.contains("tbd-a1b2c3d4"))
    #expect(args.contains("list-windows"))
    #expect(args.contains("-t"))
    #expect(args.contains("main"))
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
