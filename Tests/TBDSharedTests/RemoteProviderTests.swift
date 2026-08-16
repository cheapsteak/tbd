import Testing
import Foundation
@testable import TBDShared

@Suite("RemoteProvider contract types")
struct RemoteProviderTests {
    @Test func sessionPayloadDecodesSnakeCaseAndTolerantEnums() throws {
        let json = """
        {"id": "fix-ci", "title": "fix CI", "created_at": "2026-07-24T18:02:11Z",
         "state": "running", "agent_state": "waiting_input",
         "agent_state_reason": "permission_prompt", "agent_state_at": "2026-07-24T18:40:00Z",
         "meta": {"repo": "acme/api"}, "some_future_field": 42}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.id == "fix-ci")
        #expect(s.state == .running)
        #expect(s.agentState == .waitingInput)
        #expect(s.agentStateReason == "permission_prompt")
        #expect(s.meta?["repo"] == "acme/api")
    }

    @Test func unknownEnumValuesDecodeAsUnknown() throws {
        let json = #"{"id": "x", "state": "hibernating", "agent_state": "pondering"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.state == .unknown)
        #expect(s.agentState == .unknown)
    }

    @Test func missingAgentStateDecodesAsUnknown() throws {
        let json = #"{"id": "x", "state": "running"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.agentState == .unknown)
    }

    // MARK: - RemoteSessionPayload — archived field (nil vs. false vs. true)
    //
    // The filing-sync authority rule (docs/specs/2026-08-16-remote-lane-archive-design.md
    // §"Whose report counts") depends on distinguishing an absent `archived`
    // (no claim made) from an explicit `false` (a claim). These tests would
    // pass on a collapsed `archived: Bool = false` EXCEPT for
    // `archivedFieldRoundTripsAllThreeStatesDistinctly`, which fails outright
    // if `archived` is not `Bool?` — that is the one load-bearing case.

    @Test func archivedAbsentDecodesAsNilAndIsArchivedReadsFalse() throws {
        let json = #"{"id": "x", "state": "running"}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.archived == nil)
        #expect(s.isArchived == false)
    }

    @Test func archivedExplicitFalseDecodesAsSomeFalse() throws {
        let json = #"{"id": "x", "state": "running", "archived": false}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.archived == .some(false))
        #expect(s.isArchived == false)
    }

    @Test func archivedTrueDecodesAsSomeTrue() throws {
        let json = #"{"id": "x", "state": "running", "archived": true}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.archived == .some(true))
        #expect(s.isArchived == true)
    }

    /// The load-bearing case: if `archived` were collapsed to a non-optional
    /// `Bool` defaulting to `false`, the absent and explicit-`false` states
    /// would decode and re-encode identically and this test would fail to
    /// distinguish them on round-trip.
    @Test func archivedFieldRoundTripsAllThreeStatesDistinctly() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        let absent = RemoteSessionPayload(id: "x", state: .running)
        let explicitFalse = RemoteSessionPayload(id: "x", state: .running, archived: false)
        let explicitTrue = RemoteSessionPayload(id: "x", state: .running, archived: true)

        let decodedAbsent = try decoder.decode(RemoteSessionPayload.self, from: try encoder.encode(absent))
        let decodedFalse = try decoder.decode(RemoteSessionPayload.self, from: try encoder.encode(explicitFalse))
        let decodedTrue = try decoder.decode(RemoteSessionPayload.self, from: try encoder.encode(explicitTrue))

        #expect(decodedAbsent.archived == nil)
        #expect(decodedFalse.archived == .some(false))
        #expect(decodedTrue.archived == .some(true))
        // All three must be pairwise distinguishable — a collapsed `Bool`
        // would make the first two equal.
        #expect(decodedAbsent.archived != decodedFalse.archived)
        #expect(decodedFalse.archived != decodedTrue.archived)

        #expect(decodedAbsent.isArchived == false)
        #expect(decodedFalse.isArchived == false)
        #expect(decodedTrue.isArchived == true)
    }

    /// A realistic payload fixture that predates the `archived` field (same
    /// shape as `sessionPayloadDecodesSnakeCaseAndTolerantEnums` above) must
    /// still decode — the field is additive.
    @Test func realisticFixtureWithoutArchivedStillDecodes() throws {
        let json = """
        {"id": "fix-ci", "title": "fix CI", "created_at": "2026-07-24T18:02:11Z",
         "state": "running", "agent_state": "waiting_input",
         "agent_state_reason": "permission_prompt", "agent_state_at": "2026-07-24T18:40:00Z",
         "meta": {"repo": "acme/api"}}
        """.data(using: .utf8)!
        let s = try JSONDecoder().decode(RemoteSessionPayload.self, from: json)
        #expect(s.id == "fix-ci")
        #expect(s.archived == nil)
        #expect(s.isArchived == false)
    }

    @Test func staleProjectionDemotesActiveStateWithoutMutatingTheSnapshot() {
        let original = RemoteSessionPayload(
            id: "x", title: "worker", state: .running,
            agentState: .working, agentStateReason: "tool")
        let projected = original.projectedForStaleSnapshot()

        #expect(projected.state == .unknown)
        #expect(projected.agentState == .unknown)
        #expect(projected.agentStateReason == nil)
        #expect(original.state == .running)
        #expect(original.agentState == .working)
    }

    @Test func staleProjectionPreservesAConfirmedExit() {
        let exited = RemoteSessionPayload(
            id: "x", state: .exited, exitCode: 0, agentState: .exited)
        #expect(exited.projectedForStaleSnapshot() == exited)
    }

    @Test func providerStatusWithoutNewTimestampStillDecodes() throws {
        let json = #"{"config":{"name":"acme","exec":"/x"},"health":"ok"}"#.data(using: .utf8)!
        let status = try JSONDecoder().decode(RemoteProviderStatus.self, from: json)
        #expect(status.lastSuccessfulSnapshotAt == nil)
        #expect(status.hasStaleSnapshot == false)
    }

    @Test func describeDecodesCreateParams() throws {
        let json = """
        {"contract_versions": [1], "name": "example", "provider_version": "0.1.0",
         "capabilities": ["log", "attach"],
         "create_params": [
           {"name": "repo", "type": "string", "label": "Repository", "required": true},
           {"name": "size", "type": "enum", "label": "Size", "values": ["small","large"], "default": "small"}]}
        """.data(using: .utf8)!
        let d = try JSONDecoder().decode(ProviderDescribe.self, from: json)
        #expect(d.contractVersions == [1])
        #expect(d.capabilities.contains("log"))
        #expect(d.createParams[0].required == true)
        #expect(d.createParams[1].values == ["small", "large"])
        #expect(d.createParams[1].defaultValue == "small")
    }

    @Test func errorEnvelopeDecodes() throws {
        let json = """
        {"error": {"code": "auth_expired", "message": "token expired", "retryable": false,
                   "remediation": {"label": "Run login", "command": "aws sso login --profile acme"}}}
        """.data(using: .utf8)!
        let e = try JSONDecoder().decode(ProviderErrorEnvelope.self, from: json)
        #expect(e.error.code == "auth_expired")
        #expect(e.error.remediation?.command == "aws sso login --profile acme")
    }

    @Test func registryLoadsAndValidates() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "example", "exec": "/usr/local/bin/example", "args": ["provider"]}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        let configs = try RemoteProviderRegistry.load(from: file)
        #expect(configs.count == 1)
        #expect(configs[0].name == "example")
        // Missing file → empty list, not an error.
        #expect(try RemoteProviderRegistry.load(from: dir.appendingPathComponent("nope.json")).isEmpty)
        // Duplicate names → throws.
        try #"[{"name": "a", "exec": "/x"}, {"name": "a", "exec": "/y"}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try RemoteProviderRegistry.load(from: file) }
    }

    @Test func registryRejectsEmptyExec() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "example", "exec": ""}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: RemoteProviderRegistry.RegistryError.invalidEntry("example")) {
            try RemoteProviderRegistry.load(from: file)
        }
    }

    @Test func registryRejectsEmptyName() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"[{"name": "", "exec": "/usr/local/bin/example"}]"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: RemoteProviderRegistry.RegistryError.invalidEntry("")) {
            try RemoteProviderRegistry.load(from: file)
        }
    }

    @Test func registryRejectsNonArrayJSON() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("remote-provider-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("agent-providers.json")
        try #"{"name": "x"}"#
            .write(to: file, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try RemoteProviderRegistry.load(from: file) }
    }

    @Test func agentProvidersPathHonorsTBDHome() {
        let path = TBDConstants.agentProvidersPath(environment: ["TBD_HOME": "/tmp/tbd-test-home"])
        #expect(path == "/tmp/tbd-test-home/agent-providers.json")
    }

    // MARK: - RemoteSessionInfo — id derivation + resolvedRepoID wire defaults

    @Test func sessionInfoIDMatchesDeterministicDerivation() {
        let info = RemoteSessionInfo(
            provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
            gone: false, dismissed: false, lastSeen: Date())
        #expect(info.id == RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1"))
    }

    /// A payload from an OLDER daemon that never sent `id`/`resolvedRepoID`
    /// on the wire must still decode: `id` is recomputed (never trusted off
    /// the wire regardless), and `resolvedRepoID` defaults to nil.
    @Test func sessionInfoDecodesWhenIDAndResolvedRepoIDAreAbsent() throws {
        let json = """
        {"provider": "acme", "payload": {"id": "s1", "state": "running"},
         "gone": false, "dismissed": false, "lastSeen": \(Date().timeIntervalSinceReferenceDate)}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let info = try decoder.decode(RemoteSessionInfo.self, from: json)
        #expect(info.id == RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1"))
        #expect(info.resolvedRepoID == nil)
    }

    /// A mismatched `id` on the wire (e.g. a future/foreign producer) must
    /// be ignored — the type always recomputes rather than trusting it, so
    /// Swift-side correctness never depends on the wire's `id` field.
    @Test func sessionInfoIgnoresAWireIDThatDisagreesWithDerivation() throws {
        let bogus = UUID().uuidString
        let json = """
        {"id": "\(bogus)", "provider": "acme", "payload": {"id": "s1", "state": "running"},
         "gone": false, "dismissed": false, "lastSeen": \(Date().timeIntervalSinceReferenceDate)}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let info = try decoder.decode(RemoteSessionInfo.self, from: json)
        #expect(info.id.uuidString != bogus)
        #expect(info.id == RemoteSessionIdentity.uuid(provider: "acme", sessionID: "s1"))
    }

    @Test func sessionInfoRoundTripsResolvedRepoID() throws {
        let repoID = UUID()
        let info = RemoteSessionInfo(
            provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
            gone: false, dismissed: false, lastSeen: Date(), resolvedRepoID: repoID)
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(RemoteSessionInfo.self, from: try encoder.encode(info))
        #expect(decoded.resolvedRepoID == repoID)
    }

    // MARK: - RemoteSessionInfo — pinnedAt wire defaults

    /// A payload from a daemon predating the dock pin must decode with the
    /// session simply unpinned, not fail.
    @Test func sessionInfoDecodesWhenPinnedAtIsAbsent() throws {
        let json = """
        {"provider": "acme", "payload": {"id": "s1", "state": "running"},
         "gone": false, "dismissed": false, "lastSeen": \(Date().timeIntervalSinceReferenceDate)}
        """.data(using: .utf8)!
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        let info = try decoder.decode(RemoteSessionInfo.self, from: json)
        #expect(info.pinnedAt == nil)
    }

    @Test func sessionInfoRoundTripsPinnedAt() throws {
        let pinnedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let info = RemoteSessionInfo(
            provider: "acme", payload: RemoteSessionPayload(id: "s1", state: .running),
            gone: false, dismissed: false, lastSeen: Date(), pinnedAt: pinnedAt)
        let decoded = try JSONDecoder().decode(
            RemoteSessionInfo.self, from: try JSONEncoder().encode(info))
        #expect(decoded.pinnedAt == pinnedAt)
    }

    // MARK: - RemoteProviderStatus — freshnessUnreadable wire defaults

    /// A status payload from a daemon predating the field must decode as
    /// "readable", not fail. `RemoteProviderStatus` hand-writes `init(from:)`
    /// precisely because Swift's synthesized one ignores property defaults.
    @Test func providerStatusDecodesWhenFreshnessUnreadableIsAbsent() throws {
        let json = """
        {"config": {"name": "acme", "exec": "/x"}, "health": "stale",
         "errorMessage": "inventory unavailable"}
        """.data(using: .utf8)!
        let status = try JSONDecoder().decode(RemoteProviderStatus.self, from: json)
        #expect(status.freshnessUnreadable == false)
        // No snapshot on file and not unreadable — nothing cached to
        // misrepresent, so this must not gate.
        #expect(status.hasStaleSnapshot == false)
    }

    @Test func providerStatusRoundTripsFreshnessUnreadable() throws {
        let status = RemoteProviderStatus(
            config: RemoteProviderConfig(name: "acme", exec: "/x"), describe: nil,
            health: .stale, errorMessage: nil, remediationLabel: nil, remediationCommand: nil,
            lastSuccessfulSnapshotAt: nil, freshnessUnreadable: true)
        let decoded = try JSONDecoder().decode(
            RemoteProviderStatus.self, from: try JSONEncoder().encode(status))
        #expect(decoded.freshnessUnreadable)
        // An unreadable freshness row gates even with no timestamp on file.
        #expect(decoded.hasStaleSnapshot)
    }

    /// The gate is about cached rows being misrepresented, so a HEALTHY
    /// provider never gates regardless of how the freshness row read.
    @Test func providerStatusHealthyNeverCountsAsStaleSnapshot() throws {
        #expect(
            RemoteProviderStatus.isStaleSnapshot(
                health: .ok, lastSuccessfulSnapshotAt: Date(), freshnessUnreadable: true) == false)
    }

    @Test func setPinParamsRoundTrip() throws {
        let params = RemoteSetPinParams(provider: "acme", sessionID: "s1", pinned: true)
        let decoded = try JSONDecoder().decode(
            RemoteSetPinParams.self, from: try JSONEncoder().encode(params))
        #expect(decoded.provider == "acme")
        #expect(decoded.sessionID == "s1")
        #expect(decoded.pinned)
    }
}
