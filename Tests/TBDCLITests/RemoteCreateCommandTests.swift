import Foundation
import Testing
import TBDShared

@testable import TBDCLI

/// The pure halves of `tbd remote create`: the teleport precondition,
/// `--param` parsing, and the composed confirmation.
///
/// The commands themselves need a live daemon, so `run()` is out of reach; every
/// decision they make before the socket opens is not.
@Suite("tbd remote create")
struct RemoteCreateCommandTests {
    // MARK: - Teleport preconditions

    private func summary(
        uncommitted: Int = 0, unpushed: Int = 0, upstream: Bool = true
    ) -> TeleportWorkspaceSummary {
        TeleportWorkspaceSummary(
            uncommittedFiles: uncommitted, unpushedCommits: unpushed, hasUpstream: upstream)
    }

    @Test func aCleanPushedWorktreeTeleportsWithoutARefusal() {
        #expect(TeleportPrecondition.refusal(summary(), force: false) == nil)
    }

    /// The refusal has to say what would be left behind, in counts the user can
    /// check — "the worktree is dirty" tells them nothing about whether they
    /// mind.
    @Test func uncommittedFilesAreRefusedByCount() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(uncommitted: 3), force: false))
        #expect(refusal.contains("3 uncommitted files"))
        #expect(refusal.contains("stay on this machine"))
    }

    @Test func unpushedCommitsAreRefusedByCount() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(unpushed: 2), force: false))
        #expect(refusal.contains("2 unpushed commits"))
    }

    /// Both at once name both, in the sentence the design asks for.
    @Test func bothRefusalsAreNamedTogether() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(uncommitted: 3, unpushed: 2), force: false))
        #expect(refusal.contains("3 uncommitted files and 2 unpushed commits will stay on this machine"))
    }

    @Test func singularCountsReadAsSingular() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(uncommitted: 1, unpushed: 1), force: false))
        #expect(refusal.contains("1 uncommitted file and 1 unpushed commit will stay"))
    }

    /// A branch with no upstream is a different sentence from "you are two
    /// commits ahead": there is nothing on a remote for the new session to
    /// check out at all.
    @Test func aBranchWithNoUpstreamIsRefusedInItsOwnWords() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(unpushed: 0, upstream: false), force: false))
        #expect(refusal.contains("no upstream"))
    }

    /// Pushing is offered, not left to the reader to remember.
    @Test func theUnpushedRefusalOffersThePush() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(unpushed: 2), force: false))
        #expect(refusal.contains("git push"))
    }

    @Test func theUncommittedRefusalDoesNotOfferAPushForCommittedWork() throws {
        let refusal = try #require(
            TeleportPrecondition.refusal(summary(uncommitted: 2), force: false))
        #expect(refusal.contains("Commit or stash"))
    }

    @Test func forceOverridesEveryRefusal() {
        #expect(TeleportPrecondition.refusal(
            summary(uncommitted: 3, unpushed: 2, upstream: false), force: true) == nil)
        #expect(TeleportPrecondition.refusal(summary(uncommitted: 3), force: true) == nil)
        #expect(TeleportPrecondition.refusal(summary(unpushed: 2), force: true) == nil)
    }

    /// Every refusal says how to get through it. A gate with no stated override
    /// reads as a wall.
    @Test func everyRefusalNamesForce() throws {
        for candidate in [summary(uncommitted: 1), summary(unpushed: 1),
                          summary(upstream: false)] {
            let refusal = try #require(TeleportPrecondition.refusal(candidate, force: false))
            #expect(refusal.contains("--force"))
        }
    }

    // MARK: - --param parsing

    @Test func paramsBecomeAJSONObject() throws {
        let json = try remoteCreateParamsJSON(["repo=acme/api", "slug=probe"])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["repo"] as? String == "acme/api")
        #expect(decoded["slug"] as? String == "probe")
    }

    @Test func noParamsIsAnEmptyObject() throws {
        let json = try remoteCreateParamsJSON([])
        #expect(json == "{}")
    }

    /// A value may contain `=` — a prompt, a URL, a base64 blob — so the split
    /// is at the FIRST one only.
    @Test func aValueMayContainEqualsSigns() throws {
        let json = try remoteCreateParamsJSON(["prompt=a=b=c"])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["prompt"] as? String == "a=b=c")
    }

    /// Values stay strings. The field types belong to the provider, and a CLI
    /// that read `count=3` as a number would be inventing a type nobody wrote.
    @Test func valuesAreCarriedAsStrings() throws {
        let json = try remoteCreateParamsJSON(["count=3"])
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["count"] as? String == "3")
    }

    @Test func aParamWithNoEqualsIsRefused() {
        #expect(throws: (any Error).self) { try remoteCreateParamsJSON(["repo"]) }
    }

    @Test func aParamWithAnEmptyKeyIsRefused() {
        #expect(throws: (any Error).self) { try remoteCreateParamsJSON(["=acme/api"]) }
    }

    // MARK: - The create confirmation

    /// A session that silently began with somebody's whole conversation and one
    /// that began empty look identical from outside, so the line says which.
    @Test func aSeededCreateSaysSo() {
        let line = remoteCreateConfirmation(
            provider: "agentbox",
            session: RemoteSessionPayload(id: "probe", title: "fix flaky CI", state: .starting),
            seeded: true)
        #expect(line.contains("seeded"))
        #expect(line.contains("probe"))
    }

    @Test func anUnseededCreateDoesNotClaimASeed() {
        let line = remoteCreateConfirmation(
            provider: "agentbox",
            session: RemoteSessionPayload(id: "probe", state: .starting),
            seeded: false)
        #expect(line.contains("seeded") == false)
        #expect(line.contains("agentbox/probe"))
    }
}
