import Foundation
import Testing
@testable import TBDShared

@Test func testConstantsExist() {
    #expect(TBDConstants.version == "0.1.0")
}

@Test func testPrimaryAgentPreferenceDefault() {
    #expect(PrimaryAgentPreference.defaultValue == .claude)
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
        createdAt: Date(),
        activityState: .working,
        presentationActivityState: .idle
    )
    let data = try JSONEncoder().encode(terminal)
    let decoded = try JSONDecoder().decode(Terminal.self, from: data)
    #expect(terminal.id == decoded.id)
    #expect(decoded.tmuxWindowID == "@1")
    #expect(decoded.label == "editor")
    #expect(decoded.activityState == .working)
    #expect(decoded.presentationActivityState == .idle)
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

// MARK: - Parked-state decode compatibility (suspend/hibernate merge)

/// A legacy row parked by the pre-merge Suspend feature has ONLY `suspendedAt`
/// set (no `hibernatedAt`). It must still decode AND read as parked, so the UI
/// shows the moon and wake un-parks it.
@Test func testTerminalWithOnlySuspendedAtDecodesAsParked() throws {
    let json = """
    {
        "id": "\(UUID().uuidString)",
        "worktreeID": "\(UUID().uuidString)",
        "tmuxWindowID": "@1",
        "tmuxPaneID": "%1",
        "createdAt": 0,
        "suspendedAt": 12345,
        "activityState": "idle"
    }
    """
    let decoded = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    #expect(decoded.suspendedAt != nil)
    #expect(decoded.hibernatedAt == nil)
    #expect(decoded.isParked, "a legacy suspendedAt-only row must read as parked")
    #expect(decoded.isHibernated == false, "isHibernated is authoritative-only")
}

/// The authoritative case: a row with ONLY `hibernatedAt` set (no `suspendedAt`)
/// decodes and reads as parked (and hibernated).
@Test func testTerminalWithOnlyHibernatedAtDecodesAsParked() throws {
    let json = """
    {
        "id": "\(UUID().uuidString)",
        "worktreeID": "\(UUID().uuidString)",
        "tmuxWindowID": "@1",
        "tmuxPaneID": "%1",
        "createdAt": 0,
        "hibernatedAt": 12345,
        "activityState": "idle"
    }
    """
    let decoded = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    #expect(decoded.hibernatedAt != nil)
    #expect(decoded.suspendedAt == nil)
    #expect(decoded.isParked, "a hibernatedAt-only row must read as parked")
    #expect(decoded.isHibernated)
}

/// Neither column set → NOT parked.
@Test func testTerminalWithNeitherParkedTimestampIsNotParked() throws {
    let json = """
    {
        "id": "\(UUID().uuidString)",
        "worktreeID": "\(UUID().uuidString)",
        "tmuxWindowID": "@1",
        "tmuxPaneID": "%1",
        "createdAt": 0,
        "activityState": "idle"
    }
    """
    let decoded = try JSONDecoder().decode(Terminal.self, from: Data(json.utf8))
    #expect(!decoded.isParked)
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

@Test func modelProfileListResultDecodesWithoutPrimaryAgentPreference() throws {
    let json = """
    {
      "profiles": [],
      "defaultID": null
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ModelProfileListResult.self, from: json)
    #expect(decoded.primaryAgentPreference == .claude)
}

// MARK: - fallbackModels RPC param decode

@Test func modelProfileAddParamsDecodesWithFallbackModels() throws {
    let json = """
    {"name":"P","kind":"claudeDirect","fallbackModels":["claude-haiku-4-5-20251001","claude-sonnet-4-5"]}
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ModelProfileAddParams.self, from: json)
    #expect(decoded.fallbackModels == ["claude-haiku-4-5-20251001", "claude-sonnet-4-5"])
}

@Test func modelProfileAddParamsDecodesWithoutFallbackModels() throws {
    // Payload from an older client lacks the key — must still decode (nil).
    let json = #"{"name":"P","kind":"claudeDirect"}"#.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(ModelProfileAddParams.self, from: json)
    #expect(decoded.fallbackModels == nil)
    #expect(decoded.name == "P")
}

@Test func modelProfileUpdateEndpointParamsDecodesWithAndWithoutFallbackModels() throws {
    let id = "11111111-1111-1111-1111-111111111111"
    let withJSON = """
    {"id":"\(id)","baseURL":null,"model":"opus","fallbackModels":["claude-haiku-4-5-20251001"]}
    """.data(using: .utf8)!
    let withDecoded = try JSONDecoder().decode(ModelProfileUpdateEndpointParams.self, from: withJSON)
    #expect(withDecoded.fallbackModels == ["claude-haiku-4-5-20251001"])
    #expect(withDecoded.model == "opus")

    let withoutJSON = #"{"id":"\#(id)","baseURL":null,"model":null}"#.data(using: .utf8)!
    let withoutDecoded = try JSONDecoder().decode(ModelProfileUpdateEndpointParams.self, from: withoutJSON)
    #expect(withoutDecoded.fallbackModels == nil)
}

@Test func modelProfileUpdateBedrockParamsDecodesWithAndWithoutFallbackModels() throws {
    let id = "11111111-1111-1111-1111-111111111111"
    let withJSON = """
    {"id":"\(id)","awsRegion":"us-west-2","awsProfile":null,"model":"m","fallbackModels":["a","b"]}
    """.data(using: .utf8)!
    let withDecoded = try JSONDecoder().decode(ModelProfileUpdateBedrockParams.self, from: withJSON)
    #expect(withDecoded.fallbackModels == ["a", "b"])

    let withoutJSON = """
    {"id":"\(id)","awsRegion":"us-west-2","awsProfile":null,"model":"m"}
    """.data(using: .utf8)!
    let withoutDecoded = try JSONDecoder().decode(ModelProfileUpdateBedrockParams.self, from: withoutJSON)
    #expect(withoutDecoded.fallbackModels == nil)
    #expect(withoutDecoded.awsRegion == "us-west-2")
}

@Test func testTerminalDecodesWithoutActivityState() throws {
    let json = """
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "worktreeID": "22222222-2222-2222-2222-222222222222",
        "tmuxWindowID": "@1",
        "tmuxPaneID": "%1",
        "label": "Codex",
        "createdAt": 0
    }
    """.data(using: .utf8)!

    let decoded = try JSONDecoder().decode(Terminal.self, from: json)
    #expect(decoded.activityState == .unknown)
    #expect(decoded.presentationActivityState == nil)
}

// MARK: - Hibernation fields + gating helpers

@Test func testTerminalDecodesWithoutHibernationFields() throws {
    // Pre-v39 JSON (no hibernatedAt/keepWarm) must decode with safe defaults.
    let json = """
    {
        "id": "11111111-1111-1111-1111-111111111111",
        "worktreeID": "22222222-2222-2222-2222-222222222222",
        "tmuxWindowID": "@1",
        "tmuxPaneID": "%1",
        "createdAt": 0
    }
    """.data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Terminal.self, from: json)
    #expect(decoded.hibernatedAt == nil)
    #expect(decoded.keepWarm == false)
    #expect(decoded.isHibernated == false)
}

@Test func testTerminalHibernationFieldsRoundTrip() throws {
    let t = Terminal(
        worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
        claudeSessionID: "s", kind: .claude,
        hibernatedAt: Date(timeIntervalSince1970: 100), keepWarm: true)
    let data = try JSONEncoder().encode(t)
    let decoded = try JSONDecoder().decode(Terminal.self, from: data)
    #expect(decoded.hibernatedAt == Date(timeIntervalSince1970: 100))
    #expect(decoded.keepWarm == true)
    #expect(decoded.isHibernated == true)
}

@Test func testManuallyHibernatableGating() {
    func t(_ state: TerminalActivityState, session: String? = "s", kind: TerminalKind? = .claude,
           hibernatedAt: Date? = nil, suspendedAt: Date? = nil, keepWarm: Bool = false) -> Terminal {
        Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                 claudeSessionID: session, suspendedAt: suspendedAt, kind: kind,
                 activityState: state, hibernatedAt: hibernatedAt, keepWarm: keepWarm)
    }
    // Manual-hibernatable: idle/unknown resumable Claude, not running/waiting/
    // hibernated/suspended. keep-warm does NOT block manual.
    #expect(t(.idle).isManuallyHibernatable)
    #expect(t(.unknown).isManuallyHibernatable)
    #expect(t(.idle, keepWarm: true).isManuallyHibernatable)          // manual bypasses keep-warm
    #expect(!t(.working).isManuallyHibernatable)                      // running rail
    #expect(!t(.waitingForUser).isManuallyHibernatable)              // permission rail
    #expect(!t(.idle, session: nil, kind: .shell).isManuallyHibernatable)  // not Claude
    #expect(!t(.idle, kind: .codex).isManuallyHibernatable)          // Codex excluded
    #expect(!t(.idle, hibernatedAt: Date()).isManuallyHibernatable)  // already hibernated
    #expect(!t(.idle, suspendedAt: Date()).isManuallyHibernatable)   // suspended
}

@Test func testAutoHibernationEligibilityAddsKeepWarmRail() {
    let base = Terminal(worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
                        claudeSessionID: "s", kind: .claude, activityState: .idle)
    #expect(base.isAutoHibernationEligible)
    var warm = base; warm.keepWarm = true
    // Auto adds the keep-warm rail that manual bypasses.
    #expect(!warm.isAutoHibernationEligible)
    #expect(warm.isManuallyHibernatable)
}

@Test func testConfigDecodesWithoutHibernationFields() throws {
    // Config JSON with no hibernation fields must decode with the idle sweep
    // OFF (opt-in) and 30 min.
    let json = "{}".data(using: .utf8)!
    let decoded = try JSONDecoder().decode(Config.self, from: json)
    #expect(decoded.autoHibernateEnabled == false)
    #expect(decoded.hibernateIdleMinutes == Config.defaultHibernateIdleMinutes)
}

@Test func testConfigHibernationRoundTrip() throws {
    let config = Config(autoHibernateEnabled: false, hibernateIdleMinutes: 42)
    let data = try JSONEncoder().encode(config)
    let decoded = try JSONDecoder().decode(Config.self, from: data)
    #expect(decoded.autoHibernateEnabled == false)
    #expect(decoded.hibernateIdleMinutes == 42)
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
        prompt: "Build the thing",
        model: "claude-fable-5",
        primaryAgentPreference: .codex
    )
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(WorktreeCreateParams.self, from: data)
    #expect(decoded.repoID == repoID)
    #expect(decoded.folder == "my-folder")
    #expect(decoded.branch == "feat/my-branch")
    #expect(decoded.displayName == "My Display Name")
    #expect(decoded.prompt == "Build the thing")
    #expect(decoded.model == "claude-fable-5")
    #expect(decoded.primaryAgentPreference == .codex)
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
    #expect(decoded.model == nil)
    #expect(decoded.primaryAgentPreference == nil)
}

@Test func worktreeCreateParamsDecodesWithoutPrimaryAgentOverride() throws {
    let data = Data(#"{"repoID":"11111111-1111-1111-1111-111111111111"}"#.utf8)
    let decoded = try JSONDecoder().decode(WorktreeCreateParams.self, from: data)
    #expect(decoded.primaryAgentPreference == nil)
}

@Test func codexUsageResultDecodesWithoutOptionalMetadata() throws {
    let data = Data(#"{"rateLimits":[]}"#.utf8)
    let decoded = try JSONDecoder().decode(CodexUsageResult.self, from: data)
    #expect(decoded.account == nil)
    #expect(decoded.unavailableReason == nil)
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
    // swiftlint:disable:next optional_data_string_conversion
    let s = String(decoding: data, as: UTF8.self)
    #expect(s.contains("\"worktreeSlot\":\"r\""))
    #expect(s.contains("\"status\":\"missing\""))
}

// MARK: - PRStatus persisted-JSON compatibility

/// PRStatus rides in the single `worktree.prStatus` TEXT column (migration
/// v34) as JSON. `mergeQueuePosition` was added as an OPTIONAL field with no
/// new migration, so a blob written before the field existed (no
/// `mergeQueuePosition` key) must still decode — yielding nil.
@Test func prStatusDecodesLegacyJSONWithoutMergeQueuePosition() throws {
    let legacy = """
    {"number":123,"url":"https://github.com/acme/acme-prod/pull/123","state":"pending","reason":"Checks pending"}
    """
    let decoded = try JSONDecoder().decode(PRStatus.self, from: Data(legacy.utf8))
    #expect(decoded.number == 123)
    #expect(decoded.state == .pending)
    #expect(decoded.mergeQueuePosition == nil)
}

@Test func prStatusRoundTripsMergeQueuePosition() throws {
    let status = PRStatus(number: 7, url: "https://github.com/acme/acme-prod/pull/7",
                          state: .pending, reason: "Checks pending", mergeQueuePosition: 2)
    let data = try JSONEncoder().encode(status)
    let decoded = try JSONDecoder().decode(PRStatus.self, from: data)
    #expect(decoded.mergeQueuePosition == 2)
}

// MARK: - `sameValue(as:)` — change detection without the freshness stamp

/// The rule this method exists to enforce: a fact *about* a reading may never
/// decide whether the reading changed. `observedAt` advances every poll, so an
/// "on change" test built on `==` fires every poll — which is exactly how
/// persist-on-change became persist-every-poll on a forty-worktree fleet.
@Test func prStatusSameValueIgnoresOnlyTheObservedAtStamp() {
    let base = PRStatus(number: 7, url: "https://github.com/acme/acme-prod/pull/7",
                        state: .mergeable, reason: "Ready to merge",
                        mergeQueuePosition: nil,
                        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let reRead = PRStatus(number: 7, url: "https://github.com/acme/acme-prod/pull/7",
                          state: .mergeable, reason: "Ready to merge",
                          mergeQueuePosition: nil,
                          observedAt: Date(timeIntervalSince1970: 1_700_000_600))

    #expect(base != reRead, "Equatable deliberately keeps the stamp")
    #expect(base.sameValue(as: reRead))
}

@Test func prStatusSameValueSeesEveryValueField() {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let base = PRStatus(number: 7, url: "https://github.com/acme/acme-prod/pull/7",
                        state: .mergeable, reason: "Ready to merge",
                        files: ["a.swift"], commits: 3,
                        authorWorktreeID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
                        mergeQueuePosition: 1, observedAt: stamp)
    // Each field, one at a time — a `sameValue` that forgot one would let a
    // real change go unpersisted, which is the opposite and worse failure.
    let variants: [PRStatus] = [
        PRStatus(number: 8, url: base.url, state: base.state, reason: base.reason,
                 files: base.files, commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: "https://github.com/acme/acme-prod/pull/8",
                 state: base.state, reason: base.reason, files: base.files,
                 commits: base.commits, authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: .closed, reason: base.reason,
                 files: base.files, commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: base.state, reason: "Blocked",
                 files: base.files, commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: base.state, reason: base.reason,
                 files: ["b.swift"], commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: base.state, reason: base.reason,
                 files: base.files, commits: 4, authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: base.state, reason: base.reason,
                 files: base.files, commits: base.commits, authorWorktreeID: UUID(),
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: base.state, reason: base.reason,
                 files: base.files, commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: 2, observedAt: stamp)
    ]
    for variant in variants {
        #expect(!base.sameValue(as: variant), "sameValue missed a changed field: \(variant)")
    }
}

// MARK: - The structural half: a ninth field cannot be forgotten

/// `sameValue` must not be a hand-written field list, because a list has to be
/// remembered. This pins the two halves that together make it structural.
///
/// **Half one — `sameValue` is exactly `==` modulo the stamp.** Asserted as an
/// equivalence over a matrix, so a `sameValue` rewritten as a hand list that
/// omits any field disagrees with `==` on the pair that differs in it, and this
/// reds naming the pair.
@Test func prStatusSameValueAgreesWithEqualityOnStampStrippedValues() {
    let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    let later = Date(timeIntervalSince1970: 1_700_000_600)
    let base = PRStatus(number: 7, url: "https://github.com/acme/acme-prod/pull/7",
                        state: .mergeable, reason: "Ready to merge",
                        files: ["a.swift"], commits: 3,
                        authorWorktreeID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
                        mergeQueuePosition: 1, observedAt: stamp)
    let matrix: [PRStatus] = [
        base,
        base.withObservedAt(later),
        base.withObservedAt(nil),
        PRStatus(number: 8, url: base.url, state: base.state, reason: base.reason,
                 files: base.files, commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: base.mergeQueuePosition, observedAt: later),
        PRStatus(number: base.number, url: base.url, state: .closed, reason: nil,
                 files: nil, commits: nil, authorWorktreeID: nil,
                 mergeQueuePosition: nil, observedAt: stamp),
        PRStatus(number: base.number, url: base.url, state: base.state, reason: base.reason,
                 files: base.files, commits: base.commits,
                 authorWorktreeID: base.authorWorktreeID,
                 mergeQueuePosition: 2, observedAt: stamp)
    ]
    for a in matrix {
        for b in matrix {
            #expect(a.sameValue(as: b) == (a.withObservedAt(nil) == b.withObservedAt(nil)),
                    "sameValue disagreed with stamp-stripped equality for \(a) vs \(b)")
        }
    }
}

/// **Half two — `withObservedAt` carries every field.** A copy written with the
/// memberwise initializer would compile with a new field omitted (every
/// parameter past `reason` has a default) and silently drop it, which would put
/// the hole straight back. Asserted against the type's own encoding, so the
/// field roster comes from `PRStatus` rather than from this test.
@Test func prStatusWithObservedAtChangesTheStampAndNothingElse() throws {
    let base = PRStatus(number: 7, url: "https://github.com/acme/acme-prod/pull/7",
                        state: .mergeable, reason: "Ready to merge",
                        files: ["a.swift"], commits: 3,
                        authorWorktreeID: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA"),
                        mergeQueuePosition: 1,
                        observedAt: Date(timeIntervalSince1970: 1_700_000_000))
    let restamped = base.withObservedAt(Date(timeIntervalSince1970: 1_700_000_600))

    func fields(_ status: PRStatus) throws -> [String: String] {
        let data = try JSONEncoder().encode(status)
        let object = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        return object
            .filter { $0.key != "observedAt" }
            .mapValues { String(describing: $0) }
    }

    let before = try fields(base)
    #expect(!before.isEmpty)
    #expect(before == (try fields(restamped)),
            "withObservedAt dropped or altered a field other than the stamp")
    #expect(restamped.observedAt == Date(timeIntervalSince1970: 1_700_000_600))
    // …and putting the original stamp back yields the original value, whole.
    #expect(restamped.withObservedAt(base.observedAt) == base)
}
