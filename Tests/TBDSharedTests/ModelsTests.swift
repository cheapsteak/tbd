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

// MARK: - Backwards Compatibility (decode with missing fields)

/// Verifies that Worktree can decode from JSON that predates newer fields.
/// Every non-optional field added after v1 MUST have a property-level default
/// so old JSON (from DB, RPC, or disk) still decodes. If this test fails,
/// you added a field without a default — see CLAUDE.md "Database migrations".
@Test func testWorktreeDecodesWithoutOptionalFields() throws {
    // Minimal JSON: only the fields present since v1
    let json = """
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "repoID": "22222222-2222-2222-2222-222222222222",
        "name": "old-worktree",
        "displayName": "old-worktree",
        "branch": "tbd/old-worktree",
        "path": "/tmp/repo/.tbd/worktrees/old-worktree",
        "status": "active",
        "createdAt": 0,
        "tmuxServer": "tbd-test"
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Worktree.self, from: json)
    #expect(decoded.name == "old-worktree")
    #expect(decoded.hasConflicts == false)
    #expect(decoded.archivedAt == nil)
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
    let decodedParams = try JSONDecoder().decode(WorktreeCreateParams.self, from: decoded.paramsData)
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

@Test func conductorStatusRoundTrips() throws {
    let status = WorktreeStatus.conductor
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(WorktreeStatus.self, from: data)
    #expect(decoded == .conductor)
}

@Test func conductorModelRoundTrips() throws {
    let conductor = Conductor(
        id: UUID(),
        name: "test-conductor",
        repos: ["*"],
        heartbeatIntervalMinutes: 10,
        createdAt: Date()
    )
    let data = try JSONEncoder().encode(conductor)
    let decoded = try JSONDecoder().decode(Conductor.self, from: data)
    #expect(decoded.name == "test-conductor")
    #expect(decoded.repos == ["*"])
}

@Test func testResolvedPathResultRoundTrip() throws {
    let repoID = UUID()
    let result = ResolvedPathResult(repoID: repoID, worktreeID: nil)
    let data = try JSONEncoder().encode(result)
    let decoded = try JSONDecoder().decode(ResolvedPathResult.self, from: data)
    #expect(decoded.repoID == repoID)
    #expect(decoded.worktreeID == nil)
}

@Test func repoStatusRoundTrips() throws {
    let ok = RepoStatus.ok
    let missing = RepoStatus.missing
    #expect(ok.rawValue == "ok")
    #expect(missing.rawValue == "missing")
    #expect(RepoStatus(rawValue: "ok") == .ok)
    #expect(RepoStatus(rawValue: "missing") == .missing)
}

@Test func worktreeStatusHasFailedCase() {
    #expect(WorktreeStatus(rawValue: "failed") == .failed)
    #expect(WorktreeStatus.failed.rawValue == "failed")
}

@Test func testWorktreeCreateParamsRoundTripWithNewFields() throws {
    let repoID = UUID()
    let params = WorktreeCreateParams(
        repoID: repoID,
        folder: "my-folder",
        branch: "feat/my-branch",
        displayName: "My Display Name",
        prompt: "Build the thing"
    )
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(WorktreeCreateParams.self, from: data)
    #expect(decoded.repoID == repoID)
    #expect(decoded.folder == "my-folder")
    #expect(decoded.branch == "feat/my-branch")
    #expect(decoded.displayName == "My Display Name")
    #expect(decoded.prompt == "Build the thing")
}

@Test func testWorktreeCreateParamsRoundTripWithNilFields() throws {
    let repoID = UUID()
    let params = WorktreeCreateParams(repoID: repoID)
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(WorktreeCreateParams.self, from: data)
    #expect(decoded.repoID == repoID)
    #expect(decoded.folder == nil)
    #expect(decoded.branch == nil)
    #expect(decoded.displayName == nil)
    #expect(decoded.prompt == nil)
}

@Test func repoDecodesLegacyJSONWithoutNewFields() throws {
    let legacy = #"""
    {
      "id": "11111111-1111-1111-1111-111111111111",
      "path": "/tmp/r",
      "displayName": "r",
      "defaultBranch": "main",
      "createdAt": 0
    }
    """#
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .secondsSince1970
    let repo = try decoder.decode(Repo.self, from: Data(legacy.utf8))
    #expect(repo.worktreeSlot == nil)
    #expect(repo.worktreeRoot == nil)
    #expect(repo.status == .ok)
}

@Test func modelProfileUsageDecodesModernProfileIDKey() throws {
    let id = UUID()
    let json = """
    {
      "profileID": "\(id.uuidString)",
      "fiveHourPct": 0.42,
      "lastStatus": "ok"
    }
    """
    let decoded = try JSONDecoder().decode(ModelProfileUsage.self, from: Data(json.utf8))
    #expect(decoded.profileID == id)
    #expect(decoded.fiveHourPct == 0.42)
    #expect(decoded.lastStatus == "ok")
}

@Test func modelProfileUsageDecodesLegacyTokenIDKey() throws {
    let id = UUID()
    let json = """
    {
      "tokenID": "\(id.uuidString)",
      "sevenDayPct": 0.10
    }
    """
    let decoded = try JSONDecoder().decode(ModelProfileUsage.self, from: Data(json.utf8))
    #expect(decoded.profileID == id)
    #expect(decoded.sevenDayPct == 0.10)
}

@Test func repoEncodesNewFields() throws {
    var repo = Repo(path: "/tmp/r", displayName: "r")
    repo.worktreeSlot = "r"
    repo.status = .missing
    let data = try JSONEncoder().encode(repo)
    let s = String(decoding: data, as: UTF8.self)
    #expect(s.contains("\"worktreeSlot\":\"r\""))
    #expect(s.contains("\"status\":\"missing\""))
}
