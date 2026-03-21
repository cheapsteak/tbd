import Foundation
import Testing
@testable import TBDShared

@Test func testConstantsExist() {
    #expect(TBDConstants.version == "0.1.0")
}

// MARK: - Model Codable Round-Trips

@Test func testRepoRoundTrip() throws {
    let repo = Repo(
        id: UUID(),
        path: "/Users/test/project",
        remoteURL: "git@github.com:test/project.git",
        displayName: "project",
        defaultBranch: "main",
        createdAt: Date()
    )
    let data = try JSONEncoder().encode(repo)
    let decoded = try JSONDecoder().decode(Repo.self, from: data)
    #expect(repo.id == decoded.id)
    #expect(repo.path == decoded.path)
    #expect(repo.remoteURL == decoded.remoteURL)
    #expect(repo.displayName == decoded.displayName)
    #expect(repo.defaultBranch == decoded.defaultBranch)
}

@Test func testWorktreeRoundTrip() throws {
    let wt = Worktree(
        id: UUID(),
        repoID: UUID(),
        name: "20260321-fuzzy-penguin",
        displayName: "fuzzy-penguin",
        branch: "tbd/20260321-fuzzy-penguin",
        path: "/Users/test/project/.tbd/worktrees/20260321-fuzzy-penguin",
        status: .active,
        createdAt: Date(),
        archivedAt: nil,
        tmuxServer: "tbd-a1b2c3d4"
    )
    let data = try JSONEncoder().encode(wt)
    let decoded = try JSONDecoder().decode(Worktree.self, from: data)
    #expect(wt.id == decoded.id)
    #expect(decoded.status == .active)
    #expect(decoded.name == "20260321-fuzzy-penguin")
    #expect(decoded.archivedAt == nil)
}

@Test func testTerminalRoundTrip() throws {
    let terminal = Terminal(
        id: UUID(),
        worktreeID: UUID(),
        tmuxWindowID: "@1",
        tmuxPaneID: "%3",
        label: "editor",
        createdAt: Date()
    )
    let data = try JSONEncoder().encode(terminal)
    let decoded = try JSONDecoder().decode(Terminal.self, from: data)
    #expect(terminal.id == decoded.id)
    #expect(decoded.tmuxWindowID == "@1")
    #expect(decoded.label == "editor")
}

@Test func testNotificationRoundTrip() throws {
    let notification = TBDNotification(
        id: UUID(),
        worktreeID: UUID(),
        type: .error,
        message: "build failed",
        read: false,
        createdAt: Date()
    )
    let data = try JSONEncoder().encode(notification)
    let decoded = try JSONDecoder().decode(TBDNotification.self, from: data)
    #expect(notification.id == decoded.id)
    #expect(decoded.type == .error)
    #expect(decoded.message == "build failed")
    #expect(decoded.read == false)
}

// MARK: - NotificationType Severity Ordering

@Test func testNotificationTypeSeverityOrdering() {
    #expect(NotificationType.error.severity > NotificationType.attentionNeeded.severity)
    #expect(NotificationType.attentionNeeded.severity > NotificationType.taskComplete.severity)
    #expect(NotificationType.taskComplete.severity > NotificationType.responseComplete.severity)
}

// MARK: - RPC Protocol Round-Trips

@Test func testRPCRequestRoundTrip() throws {
    let params = WorktreeCreateParams(repoID: UUID())
    let request = try RPCRequest(method: RPCMethod.worktreeCreate, params: params)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(RPCRequest.self, from: data)
    #expect(decoded.method == "worktree.create")
    // Verify we can decode the params back
    let decodedParams = try JSONDecoder().decode(WorktreeCreateParams.self, from: decoded.params)
    #expect(decodedParams.repoID == params.repoID)
}

@Test func testRPCResponseSuccessRoundTrip() throws {
    let repo = Repo(path: "/tmp/test", displayName: "test")
    let response = try RPCResponse(result: repo)
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(RPCResponse.self, from: data)
    #expect(decoded.success == true)
    #expect(decoded.error == nil)
    let decodedRepo = try decoded.decodeResult(Repo.self)
    #expect(decodedRepo.displayName == "test")
}

@Test func testRPCResponseErrorRoundTrip() throws {
    let response = RPCResponse(error: "not found")
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(RPCResponse.self, from: data)
    #expect(decoded.success == false)
    #expect(decoded.error == "not found")
    #expect(decoded.result == nil)
}

@Test func testRPCResponseOk() throws {
    let response = RPCResponse.ok()
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(RPCResponse.self, from: data)
    #expect(decoded.success == true)
    #expect(decoded.result == nil)
    #expect(decoded.error == nil)
}

// MARK: - Param Structs Codable Round-Trips

@Test func testRepoAddParamsRoundTrip() throws {
    let params = RepoAddParams(path: "/tmp/repo")
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(RepoAddParams.self, from: data)
    #expect(decoded.path == "/tmp/repo")
}

@Test func testRepoRemoveParamsRoundTrip() throws {
    let id = UUID()
    let params = RepoRemoveParams(repoID: id, force: true)
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(RepoRemoveParams.self, from: data)
    #expect(decoded.repoID == id)
    #expect(decoded.force == true)
}

@Test func testWorktreeListParamsRoundTrip() throws {
    let params = WorktreeListParams(repoID: UUID(), status: .archived)
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(WorktreeListParams.self, from: data)
    #expect(decoded.status == .archived)
}

@Test func testNotifyParamsRoundTrip() throws {
    let params = NotifyParams(worktreeID: UUID(), type: .taskComplete, message: "done")
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(NotifyParams.self, from: data)
    #expect(decoded.type == .taskComplete)
    #expect(decoded.message == "done")
}

@Test func testDaemonStatusResultRoundTrip() throws {
    let result = DaemonStatusResult(version: "0.1.0", uptime: 3600.5, connectedClients: 2)
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(DaemonStatusResult.self, from: data)
    #expect(decoded.version == "0.1.0")
    #expect(decoded.uptime == 3600.5)
    #expect(decoded.connectedClients == 2)
}

@Test func testResolvedPathResultRoundTrip() throws {
    let repoID = UUID()
    let result = ResolvedPathResult(repoID: repoID, worktreeID: nil)
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(ResolvedPathResult.self, from: data)
    #expect(decoded.repoID == repoID)
    #expect(decoded.worktreeID == nil)
}
