import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite("PRPollLegs", .serialized)
struct PRPollLegsTests {
    @Test func keyLowercasesAndOrders() {
        let key = PRPollKey(host: "GitHub.com", owner: "Acme", repo: "Acme-Prod", number: 2)
        #expect(key == PRPollKey(host: "github.com", owner: "acme", repo: "acme-prod", number: 2))
        #expect(PRPollKey(host: "h", owner: "o", repo: "r", number: 1) < PRPollKey(host: "h", owner: "o", repo: "r", number: 2))
    }

    @Test func keyFromBindingMatchesItsRepoGroup() {
        let binding = PRBinding(worktreeID: UUID(), host: "GitHub.com", owner: "Acme", repo: "Acme-Prod",
                                number: 5, url: "https://github.com/Acme/Acme-Prod/pull/5", source: .manual)
        #expect(PRPollKey(binding) == PRPollKey(host: "github.com", owner: "acme", repo: "acme-prod", number: 5))
    }

    @Test func onlyKeysQueriesDueKeysOnceAndFansOutToEveryOwner() async throws {
        // Two worktrees bound to PR 7, one bound to merged PR 9, one bound to PR 8.
        // onlyKeys = {7}: the numbered query names 7 exactly once, never 8 or 9,
        // and both PR-7 bindings get the fresh status.
        let harness = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending), (wt: 1, number: 7, state: .pending),
                       (wt: 2, number: 9, state: .merged), (wt: 3, number: 8, state: .blocked)],
            responses: [7: "MERGEABLE_CLEAN"])
        await harness.router.refreshBindingStatusesForTests(onlyKeys: [harness.key(7)])
        let queries = await harness.gh.numberedQueries()
        #expect(queries.count == 1)
        #expect(queries.first.map { $0.components(separatedBy: "pullRequest(number: 7)").count - 1 } == 1)
        #expect(queries.first?.contains("pullRequest(number: 9)") == false)
        #expect(queries.first?.contains("pullRequest(number: 8)") == false)
        #expect(try await harness.bindingState(wt: 0, number: 7) == .mergeable)
        #expect(try await harness.bindingState(wt: 1, number: 7) == .mergeable)
        #expect(try await harness.bindingState(wt: 2, number: 9) == .merged)
        #expect(try await harness.bindingState(wt: 3, number: 8) == .blocked)
    }

    @Test func emptyOnlyKeysQueriesNothing() async throws {
        let harness = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending)],
            responses: [7: "MERGEABLE_CLEAN"])
        await harness.router.refreshBindingStatusesForTests(onlyKeys: [])
        #expect(await harness.gh.numberedQueries().isEmpty)
        #expect(try await harness.bindingState(wt: 0, number: 7) == .pending)
    }

    @Test func nilOnlyKeysKeepsTodaysBehaviour() async throws {
        let harness = try await PRPollLegsHarness.make(
            bindings: [(wt: 0, number: 7, state: .pending), (wt: 1, number: 9, state: .merged)],
            responses: [7: "MERGEABLE_CLEAN", 9: "MERGED"])
        await harness.router.refreshBindingStatusesForTests(onlyKeys: nil)
        let text = (await harness.gh.numberedQueries()).joined()
        #expect(text.contains("pullRequest(number: 7)"))
        #expect(text.contains("pullRequest(number: 9)"))   // today re-queries merged bindings
        #expect(try await harness.bindingState(wt: 0, number: 7) == .mergeable)
    }

    @Test func hasPollableBranchNeedsADirectoryAndABranch() {
        let repoID = UUID()
        let local = Worktree(repoID: repoID, name: "l", displayName: "l", branch: "tbd/l",
                             path: "/tmp/acme-l", tmuxServer: "tbd-l")
        let pathless = Worktree(repoID: repoID, name: "p", displayName: "p", branch: "tbd/p",
                                path: "", tmuxServer: "tbd-p")
        // A remote row with no mirror sighting has no live branch: bindings only.
        let remote = Worktree(repoID: repoID, name: "r", displayName: "r", branch: "tbd/r",
                              path: WorktreeLocation.remote(provider: "agentbox", sessionID: "s-1")
                                .storagePath ?? "",
                              tmuxServer: "",
                              location: .remote(provider: "agentbox", sessionID: "s-1"))
        func pollable(_ wt: Worktree) -> Bool {
            RPCRouter.hasPollableBranch(wt, repoPathByID: [repoID: "/tmp/acme"],
                                        mirrorMeta: [:], defaultBranchByRepo: [repoID: "main"])
        }
        #expect(pollable(local))
        #expect(!pollable(pathless))
        #expect(!pollable(remote))
    }
}
