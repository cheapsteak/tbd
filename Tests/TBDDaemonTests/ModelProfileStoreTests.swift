import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("ModelProfileStore")
struct ModelProfileStoreTests {
    @Test func createListGet() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        #expect(tok.name == "Personal")
        #expect(tok.kind == .oauth)

        let all = try await db.modelProfiles.list()
        #expect(all.count == 1)

        let fetched = try await db.modelProfiles.get(id: tok.id)
        #expect(fetched?.id == tok.id)
    }

    @Test func getByName() async throws {
        let db = try TBDDatabase(inMemory: true)
        _ = try await db.modelProfiles.create(name: "Work", kind: .apiKey)
        let found = try await db.modelProfiles.getByName("Work")
        #expect(found?.kind == .apiKey)
        let missing = try await db.modelProfiles.getByName("Nope")
        #expect(missing == nil)
    }

    @Test func renameAndDelete() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Old", kind: .oauth)
        try await db.modelProfiles.rename(id: tok.id, name: "New")
        let renamed = try await db.modelProfiles.get(id: tok.id)
        #expect(renamed?.name == "New")

        try await db.modelProfiles.delete(id: tok.id)
        #expect(try await db.modelProfiles.get(id: tok.id) == nil)
    }

    @Test func repoOverrideRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r", displayName: "r", defaultBranch: "main")
        #expect(repo.profileOverrideID == nil)

        try await db.repos.setProfileOverride(id: repo.id, profileID: tok.id)
        let fetched = try await db.repos.get(id: repo.id)
        #expect(fetched?.profileOverrideID == tok.id)

        try await db.repos.setProfileOverride(id: repo.id, profileID: nil)
        let cleared = try await db.repos.get(id: repo.id)
        #expect(cleared?.profileOverrideID == nil)
    }

    @Test func terminalTokenIDRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        let repo = try await db.repos.create(path: "/tmp/r2", displayName: "r2", defaultBranch: "main")
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "tbd/w",
            path: "/tmp/r2/.tbd/worktrees/w", tmuxServer: "tbd-test"
        )
        let term = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%0", label: "claude"
        )
        #expect(term.profileID == nil)

        try await db.terminals.setProfileID(id: term.id, profileID: tok.id)
        let fetched = try await db.terminals.get(id: term.id)
        #expect(fetched?.profileID == tok.id)

        try await db.terminals.setProfileID(id: term.id, profileID: nil)
        let cleared = try await db.terminals.get(id: term.id)
        #expect(cleared?.profileID == nil)
    }

    @Test func touchLastUsed() async throws {
        let db = try TBDDatabase(inMemory: true)
        let tok = try await db.modelProfiles.create(name: "Personal", kind: .oauth)
        #expect(tok.lastUsedAt == nil)
        try await db.modelProfiles.touchLastUsed(id: tok.id)
        let updated = try await db.modelProfiles.get(id: tok.id)
        #expect(updated?.lastUsedAt != nil)
    }

    @Test("store: bedrock fields round-trip through create + get")
    func bedrockRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let p = try await db.modelProfiles.create(
            name: "Bedrock prod",
            kind: .bedrock,
            baseURL: nil,
            model: "anthropic.claude-sonnet-4-5",
            awsRegion: "us-west-2",
            awsProfile: "acme-prod"
        )
        let fetched = try await db.modelProfiles.get(id: p.id)
        #expect(fetched?.kind == .bedrock)
        #expect(fetched?.awsRegion == "us-west-2")
        #expect(fetched?.awsProfile == "acme-prod")
        #expect(fetched?.model == "anthropic.claude-sonnet-4-5")
    }

    @Test("store: bedrock with nil awsProfile stays nil after round-trip")
    func bedrockNilAwsProfile() async throws {
        let db = try TBDDatabase(inMemory: true)
        let p = try await db.modelProfiles.create(
            name: "Bedrock minimal",
            kind: .bedrock,
            model: "anthropic.claude-sonnet-4-5",
            awsRegion: "us-east-1",
            awsProfile: nil
        )
        let fetched = try await db.modelProfiles.get(id: p.id)
        #expect(fetched?.awsProfile == nil)
    }

    @Test("store: updateBedrock round-trips all fields")
    func updateBedrockRoundTrip() async throws {
        let db = try TBDDatabase(inMemory: true)
        let p = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            baseURL: nil,
            model: "old-model",
            awsRegion: "us-west-2",
            awsProfile: "old-profile"
        )
        try await db.modelProfiles.updateBedrock(
            id: p.id,
            awsRegion: "us-east-1",
            awsProfile: "new-profile",
            model: "new-model"
        )
        let fetched = try await db.modelProfiles.get(id: p.id)
        #expect(fetched?.awsRegion == "us-east-1")
        #expect(fetched?.awsProfile == "new-profile")
        #expect(fetched?.model == "new-model")
    }

    @Test("store: updateBedrock with nil awsProfile clears the field")
    func updateBedrockClearsAwsProfile() async throws {
        let db = try TBDDatabase(inMemory: true)
        let p = try await db.modelProfiles.create(
            name: "Bedrock",
            kind: .bedrock,
            model: "m",
            awsRegion: "us-west-2",
            awsProfile: "acme-prod"
        )
        try await db.modelProfiles.updateBedrock(
            id: p.id,
            awsRegion: "us-west-2",
            awsProfile: nil,
            model: "m"
        )
        let fetched = try await db.modelProfiles.get(id: p.id)
        #expect(fetched?.awsProfile == nil)
    }
}
