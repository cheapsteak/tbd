import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// The stated contract of `tbd profile list --json` (schemaVersion 1) and the
/// `profileID` field of `tbd terminal list --json` — documented in
/// `docs/capacity-facts.md`. Every assertion here runs the SAME composition
/// path the commands use (`jsonString`, and the envelope for the versioned
/// one), then parses the resulting text, so the tests break if the printed
/// bytes change — not merely if a Swift model changes.
@Suite("CapacityContract")
struct CapacityContractTests {

    // MARK: - Fixtures

    /// 2026-07-07T18:00:00Z — the session bucket's reset instant.
    private static let sessionReset = Date(timeIntervalSince1970: 1_783_447_200)
    /// 2026-07-07T12:34:56Z — the last successful fetch.
    private static let fetchedAt = Date(timeIntervalSince1970: 1_783_427_696)
    /// 2026-07-01T00:00:00Z — profile creation, keeps encoded output stable.
    private static let createdAt = Date(timeIntervalSince1970: 1_782_864_000)

    private func healthyEntry(id: UUID) -> ModelProfileWithUsage {
        let snapshot = ProfileUsageSnapshot(
            buckets: [
                ClaudeUsageLimitBucket(
                    kind: "session", group: "session", percent: 42.5,
                    severity: "normal", resetsAt: Self.sessionReset, isActive: true
                ),
                ClaudeUsageLimitBucket(
                    kind: "weekly_all", group: "weekly", percent: 17,
                    severity: "normal", resetsAt: nil, isActive: false
                ),
                ClaudeUsageLimitBucket(
                    kind: "weekly_scoped", group: "weekly", percent: 3,
                    modelDisplayName: "Fable"
                ),
            ],
            fetchedAt: Self.fetchedAt,
            lastAttemptAt: Self.fetchedAt,
            status: "ok",
            statusKind: .ok
        )
        return ModelProfileWithUsage(
            profile: ModelProfile(id: id, name: "primary", kind: .oauth, createdAt: Self.createdAt),
            loginIdentity: "operator@example.com",
            usageSnapshot: snapshot
        )
    }

    /// A profile whose snapshot EXISTS but whose last fetch failed: no
    /// `fetchedAt` ever succeeded, and the failure is classified.
    private func failedFetchEntry(id: UUID) -> ModelProfileWithUsage {
        let snapshot = ProfileUsageSnapshot(
            buckets: [],
            fetchedAt: nil,
            lastAttemptAt: Self.fetchedAt,
            status: "fetch failed: HTTP 401",
            statusKind: .needsLogin
        )
        return ModelProfileWithUsage(
            profile: ModelProfile(id: id, name: "expired", kind: .oauth, createdAt: Self.createdAt),
            loginIdentity: "stale@example.com",
            usageSnapshot: snapshot
        )
    }

    /// A profile TBD tracks no usage for at all — non-OAuth kind, so the
    /// poller never even attempts a fetch.
    private func untrackedEntry(id: UUID) -> ModelProfileWithUsage {
        ModelProfileWithUsage(
            profile: ModelProfile(id: id, name: "bedrock-lane", kind: .bedrock, createdAt: Self.createdAt)
        )
    }

    // MARK: - Composition helpers (the real command path)

    /// Compose exactly what `ProfileList.run()` prints for `--json`, then
    /// parse it back into untyped JSON.
    private func composedProfileListJSON(
        _ result: ModelProfileListResult
    ) throws -> [String: Any] {
        let text = try #require(jsonString(VersionedJSONEnvelope(
            schemaVersion: profileListSchemaVersion,
            payload: result
        )))
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Compose exactly what `TerminalList.run()` prints for `--json` (a bare
    /// top-level array), then parse it back.
    private func composedTerminalListJSON(_ terminals: [Terminal]) throws -> [[String: Any]] {
        let text = try #require(jsonString(terminals))
        let data = try #require(text.data(using: .utf8))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
    }

    // MARK: - Envelope

    @Test func profileListJSON_stampsSchemaVersionOnTheEnvelope() throws {
        let defaultID = UUID()
        let object = try composedProfileListJSON(ModelProfileListResult(
            profiles: [healthyEntry(id: defaultID)],
            defaultID: defaultID
        ))

        #expect(object["schemaVersion"] as? Int == 1)
        // The payload's own fields survive alongside the stamped key —
        // the envelope adds, it does not wrap or displace.
        #expect(object["defaultID"] as? String == defaultID.uuidString)
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.count == 1)
        let profile = try #require(profiles[0]["profile"] as? [String: Any])
        #expect(profile["id"] as? String == defaultID.uuidString)
        #expect(profile["name"] as? String == "primary")
        #expect(profile["kind"] as? String == "oauth")
        #expect(profiles[0]["loginIdentity"] as? String == "operator@example.com")
    }

    @Test func profileListJSON_carriesUnknownPayloadFieldsThrough() throws {
        // Fields the capacity contract does not interpret still ship inside the
        // same versioned object — the envelope mirrors nothing by hand, so a
        // field added to the RPC result appears without an envelope change.
        let object = try composedProfileListJSON(ModelProfileListResult(
            profiles: [],
            defaultID: nil,
            primaryAgentPreference: .defaultValue
        ))
        #expect(object["schemaVersion"] as? Int == 1)
        #expect(object["profiles"] as? [Any] != nil)
        #expect(object["primaryAgentPreference"] != nil)
        #expect(object["gcEnabled"] as? Bool == true)
        // `defaultID` is absent (not null) when no global default is configured.
        #expect(object["defaultID"] == nil)
    }

    // MARK: - Buckets and units

    @Test func profileListJSON_bucketFieldsCarryValuesAndUnits() throws {
        let id = UUID()
        let object = try composedProfileListJSON(ModelProfileListResult(
            profiles: [healthyEntry(id: id)], defaultID: id
        ))
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        let snapshot = try #require(profiles[0]["usageSnapshot"] as? [String: Any])

        #expect(snapshot["status"] as? String == "ok")
        #expect(snapshot["statusKind"] as? String == "ok")
        #expect(snapshot["fetchedAt"] as? String == "2026-07-07T12:34:56Z")
        #expect(snapshot["lastAttemptAt"] as? String == "2026-07-07T12:34:56Z")

        let buckets = try #require(snapshot["buckets"] as? [[String: Any]])
        #expect(buckets.count == 3)

        let session = try #require(buckets.first { $0["kind"] as? String == "session" })
        #expect(session["group"] as? String == "session")
        // percent is a JSON number on a 0-100 scale, not a formatted string.
        #expect(session["percent"] as? Double == 42.5)
        #expect(session["severity"] as? String == "normal")
        #expect(session["isActive"] as? Bool == true)
        // resetsAt is ISO 8601 in UTC.
        #expect(session["resetsAt"] as? String == "2026-07-07T18:00:00Z")

        let weeklyAll = try #require(buckets.first { $0["kind"] as? String == "weekly_all" })
        #expect(weeklyAll["percent"] as? Double == 17)
        // The API sent null for this window — the key is omitted, not null.
        #expect(weeklyAll["resetsAt"] == nil)

        let scoped = try #require(buckets.first { $0["kind"] as? String == "weekly_scoped" })
        #expect(scoped["modelDisplayName"] as? String == "Fable")
        #expect(scoped["percent"] as? Double == 3)
    }

    // MARK: - Absence vs failure

    @Test func profileListJSON_absentSnapshotDiffersFromFailedFetch() throws {
        let trackedID = UUID()
        let untrackedID = UUID()
        let object = try composedProfileListJSON(ModelProfileListResult(
            profiles: [failedFetchEntry(id: trackedID), untrackedEntry(id: untrackedID)],
            defaultID: nil
        ))
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        #expect(profiles.count == 2)

        // Untracked: TBD has no usage tracking for this profile at all — the
        // key is absent entirely.
        let untracked = try #require(profiles.first {
            (($0["profile"] as? [String: Any])?["id"] as? String) == untrackedID.uuidString
        })
        #expect(untracked["usageSnapshot"] == nil)
        let untrackedProfile = try #require(untracked["profile"] as? [String: Any])
        #expect(untrackedProfile["kind"] as? String == "bedrock")

        // Tracked but failing: the snapshot IS present, classified, and says
        // no fetch has ever succeeded (`fetchedAt` absent).
        let failing = try #require(profiles.first {
            (($0["profile"] as? [String: Any])?["id"] as? String) == trackedID.uuidString
        })
        let snapshot = try #require(failing["usageSnapshot"] as? [String: Any])
        #expect(snapshot["statusKind"] as? String == "needsLogin")
        #expect(snapshot["status"] as? String == "fetch failed: HTTP 401")
        #expect(snapshot["lastAttemptAt"] as? String == "2026-07-07T12:34:56Z")
        #expect(snapshot["buckets"] as? [Any] != nil)
        #expect(snapshot["fetchedAt"] == nil)
    }

    @Test func profileListJSON_failedFetchCanStillCarryStaleBuckets() throws {
        // A failure does not empty `buckets`: they are the last SUCCESSFUL
        // fetch's numbers, and staleness is read off `fetchedAt`.
        let id = UUID()
        let snapshot = ProfileUsageSnapshot(
            buckets: [ClaudeUsageLimitBucket(kind: "session", percent: 99)],
            fetchedAt: Self.fetchedAt,
            lastAttemptAt: Self.sessionReset,
            status: "stale since 2026-07-07T12:34:56Z; fetch failed: offline",
            statusKind: .networkError
        )
        let entry = ModelProfileWithUsage(
            profile: ModelProfile(id: id, name: "offline", kind: .oauth, createdAt: Self.createdAt),
            usageSnapshot: snapshot
        )
        let object = try composedProfileListJSON(
            ModelProfileListResult(profiles: [entry], defaultID: nil))
        let profiles = try #require(object["profiles"] as? [[String: Any]])
        let composed = try #require(profiles[0]["usageSnapshot"] as? [String: Any])

        #expect(composed["statusKind"] as? String == "networkError")
        #expect(composed["fetchedAt"] as? String == "2026-07-07T12:34:56Z")
        #expect(composed["lastAttemptAt"] as? String == "2026-07-07T18:00:00Z")
        let buckets = try #require(composed["buckets"] as? [[String: Any]])
        #expect(buckets.count == 1)
        #expect(buckets[0]["percent"] as? Double == 99)
    }

    // MARK: - The terminal to profile join

    @Test func terminalListJSON_emitsProfileIDWhenResolved() throws {
        let profileID = UUID()
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            createdAt: Self.createdAt, profileID: profileID, kind: .claude
        )
        let rows = try composedTerminalListJSON([terminal])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as? String == terminal.id.uuidString)
        #expect(rows[0]["kind"] as? String == "claude")
        #expect(rows[0]["profileID"] as? String == profileID.uuidString)
    }

    @Test func terminalListJSON_omitsProfileIDWhenAmbient() throws {
        // No profile resolved at spawn time: the session runs on ambient
        // machine credentials TBD does not track. The key is omitted — a
        // consumer must read that as "capacity facts unknown", never resolve
        // it against `defaultID`.
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@2", tmuxPaneID: "%2",
            createdAt: Self.createdAt, kind: .shell
        )
        let rows = try composedTerminalListJSON([terminal])
        #expect(rows.count == 1)
        #expect(rows[0]["id"] as? String == terminal.id.uuidString)
        #expect(rows[0]["kind"] as? String == "shell")
        #expect(rows[0]["worktreeID"] as? String == terminal.worktreeID.uuidString)
        #expect(rows[0]["profileID"] == nil)
    }
}
