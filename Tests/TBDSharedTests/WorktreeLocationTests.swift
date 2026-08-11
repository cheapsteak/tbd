import Testing
import Foundation
@testable import TBDShared

@Suite struct WorktreeLocationTests {

    private func makeWorktree(location: WorktreeLocation = .local) -> Worktree {
        Worktree(repoID: UUID(), name: "n", displayName: "n", branch: "b",
                 path: "/tmp/n", tmuxServer: "s", location: location)
    }

    @Test func defaultsToLocal() {
        #expect(makeWorktree().location == .local)
    }

    @Test func remoteCarriesProviderAndSessionID() {
        let wt = makeWorktree(location: .remote(provider: "agentbox", sessionID: "s-1"))
        #expect(wt.location == .remote(provider: "agentbox", sessionID: "s-1"))
        let binding = try? #require(wt.providerBinding)
        #expect(binding?.provider == "agentbox")
        #expect(binding?.sessionID == "s-1")
    }

    @Test func localHasNoProviderBinding() {
        #expect(makeWorktree().providerBinding == nil)
    }

    /// A payload written by a daemon predating v70 must still decode, as
    /// local — the field is absent, not null.
    @Test func decodesLegacyPayloadAsLocal() throws {
        let json = """
        {"id":"\(UUID().uuidString)","repoID":"\(UUID().uuidString)","name":"n",
         "displayName":"n","branch":"b","path":"/tmp/n","status":"active",
         "createdAt":0,"tmuxServer":"s"}
        """
        let decoded = try JSONDecoder().decode(Worktree.self, from: Data(json.utf8))
        #expect(decoded.location == .local)
    }

    @Test func roundTripsRemoteThroughCodable() throws {
        let wt = makeWorktree(location: .remote(provider: "agentbox", sessionID: "s-1"))
        let data = try JSONEncoder().encode(wt)
        let decoded = try JSONDecoder().decode(Worktree.self, from: data)
        #expect(decoded.location == wt.location)
    }

    /// `Worktree` hand-writes `encode(to:)`, so a property added to the struct
    /// but forgotten in the encoder would silently vanish off the wire between
    /// daemon and app. Populating every field and comparing the whole decoded
    /// value catches that, where a per-field test only catches the fields
    /// someone remembered to write a test for.
    @Test func roundTripsAFullyPopulatedWorktree() throws {
        let wt = Worktree(
            id: UUID(),
            repoID: UUID(),
            name: "20260810-domestic-ferret",
            displayName: "domestic-ferret",
            branch: "tbd/20260810-domestic-ferret",
            path: "/tmp/wt",
            status: .archived,
            hasConflicts: true,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            archivedAt: Date(timeIntervalSince1970: 1_700_000_500),
            tmuxServer: "tbd-a1b2c3d4",
            archivedClaudeSessions: ["sess-a", "sess-b"],
            sortOrder: 7,
            archivedHeadSHA: "deadbeef",
            liveClaudeSessionCount: 3,
            parentWorktreeID: UUID(),
            autoArchiveOnMerge: true,
            autoHibernateOnMerge: false,
            promotedToRepoID: UUID(),
            prStatus: PRStatus(number: 42, url: "https://example.invalid/pr/42",
                               state: .mergeable, reason: "why", files: ["a.swift"],
                               commits: 3, authorWorktreeID: UUID(),
                               mergeQueuePosition: 1),
            prNumber: 42,
            foreignHead: true,
            pinnedAt: Date(timeIntervalSince1970: 1_700_000_200),
            pinSortOrder: 2,
            location: .remote(provider: "agentbox", sessionID: "s-1")
        )
        let decoded = try JSONDecoder().decode(Worktree.self, from: JSONEncoder().encode(wt))
        #expect(decoded == wt)
    }

    /// The stored path is named `localPath` in Swift but must not change the
    /// wire format: the JSON key stays `path`, so a daemon and an app at
    /// different versions still agree.
    @Test func encodesLocalPathUnderThePathKey() throws {
        let wt = makeWorktree()
        let object = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(wt)) as? [String: Any]
        #expect(object?["path"] as? String == "/tmp/n")
        #expect(object?["localPath"] == nil)
    }
}
