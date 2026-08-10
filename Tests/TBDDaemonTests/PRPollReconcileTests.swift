import Foundation
import GRDB
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// What one `pr.list` poll reconciles: bindings a heal disproved, the branch
/// refs a refresh observed, and the single `Worktree.prStatus` column the
/// pre-binding readers still use.
///
/// Driven through the real `RPCRouter` handler with a scripted `gh`, because
/// every finding here is about the *order* things happen in within one pass —
/// which no unit of the pieces can show.
///
/// Tier 1 — in-memory DB, injected `gh`, no git subprocess (the branch facts
/// are primed into the router's own TTL cache), no clock.
@Suite("PR poll reconciliation")
struct PRPollReconcileTests {

    // MARK: - Scripted `gh`

    /// Answers the four query shapes a poll issues: `repo view`, the viewer
    /// batch, the aliased by-number lookup, and the per-PR check query. Nodes
    /// are green (`SUCCESS`), so the check query is never reached.
    ///
    /// Mutable between polls, which is the whole point: a heal is a *later*
    /// pass contradicting an earlier one.
    private actor ScriptedGH {
        var nameWithOwner = "acme/acme-prod"
        var viewerNodes: [String] = []
        var nodesByNumber: [Int: String] = [:]

        func set(viewerNodes: [String]) { self.viewerNodes = viewerNodes }
        func set(nodesByNumber: [Int: String]) { self.nodesByNumber = nodesByNumber }

        func run(args: [String], repoPath: String) -> GHCommandResult? {
            if args.first == "repo" { return GHCommandResult(stdout: nameWithOwner + "\n") }
            guard let query = args.first(where: { $0.hasPrefix("query=") }) else { return nil }
            if query.contains("commits(last: 1)") { return nil }
            if query.contains("viewer {") {
                return GHCommandResult(
                    stdout: "{\"data\":{\"viewer\":{\"pullRequests\":{\"nodes\":["
                        + viewerNodes.joined(separator: ",") + "]}}}}")
            }
            if query.contains("pullRequest(number:") {
                let fields = Self.aliasedNumbers(inQuery: query).map { alias, number in
                    "\"" + alias + "\": " + (nodesByNumber[number] ?? "null")
                }
                return GHCommandResult(
                    stdout: "{\"data\":{\"repository\":{" + fields.joined(separator: ",") + "}}}")
            }
            return nil
        }

        /// Parse `pr0: pullRequest(number: 88) { … }` lines back into (alias, number).
        private static func aliasedNumbers(inQuery query: String) -> [(alias: String, number: Int)] {
            query.split(separator: "\n").compactMap { line in
                guard let colon = line.firstIndex(of: ":"),
                      let open = line.range(of: "pullRequest(number: "),
                      let close = line[open.upperBound...].firstIndex(of: ")"),
                      let number = Int(line[open.upperBound..<close]) else { return nil }
                return (String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces),
                        number)
            }
        }
    }

    /// One PR node in the shape `prNodeFieldSelection` requests. Plain `"""`
    /// with interpolation — no backslash escapes — so a mis-escaped fixture
    /// cannot silently exercise a parse-failure path.
    private static func nodeJSON(
        number: Int, owner: String = "acme", repo: String = "acme-prod",
        head: String, base: String = "main", state: String = "OPEN"
    ) -> String {
        """
        {"number": \(number), "url": "https://github.com/\(owner)/\(repo)/pull/\(number)",
         "state": "\(state)", "mergeStateStatus": "CLEAN", "reviewDecision": "APPROVED",
         "headRefName": "\(head)", "baseRefName": "\(base)",
         "createdAt": "2026-08-01T00:00:00Z", "isDraft": false,
         "statusCheckRollup": {"state": "SUCCESS"}}
        """
    }

    // MARK: - Harness

    private struct Harness {
        let db: TBDDatabase
        let router: RPCRouter
        let gh: ScriptedGH
        let prManager: PRStatusManager
        let repoID: UUID
        /// The merged-transition fan-out, replaced by a recorder: these tests
        /// assert *whether the poll fired*, never that anything was archived.
        let fired: FiredTransitionRecorder

        init() async throws {
            let db = try TBDDatabase(inMemory: true)
            self.db = db
            let gh = ScriptedGH()
            self.gh = gh
            let manager = PRStatusManager(ghRunner: { args, path in
                await gh.run(args: args, repoPath: path)
            })
            prManager = manager
            // Production wires this in `Daemon.swift`. Without it the poll's
            // worktree-column write never happens, and the stale-snapshot bug
            // this suite exists for is unreachable.
            await manager.setOnStatusPersist { [db] worktreeID, status in
                try? await db.worktrees.setPRStatus(id: worktreeID, status: status)
            }
            let created = try await db.repos.create(
                path: "/tmp/prpoll-repo-\(UUID().uuidString)",
                displayName: "acme-prod", defaultBranch: "main")
            repoID = created.id
            router = RPCRouter(
                db: db,
                lifecycle: WorktreeLifecycle(
                    db: db, git: GitManager(),
                    tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
                tmux: TmuxManager(dryRun: true),
                startTime: Date(),
                prManager: manager,
                prBindingRepoResolver: { _ in ("acme", "acme-prod") },
                actuationLog: makeTestActuationLog())
            // Production wires this in `Daemon.swift` too. Without it the poll
            // judges no merge rule at all, and the two ordering findings below
            // — when a re-attach re-arms, and which head ref the rule is judged
            // on — are unreachable.
            let recorder = FiredTransitionRecorder()
            fired = recorder
            router.mergeTrigger = AllResolvedMergeTrigger { worktreeID, prNumber in
                await recorder.record(worktreeID: worktreeID, prNumber: prNumber)
            }
        }

        /// A worktree plus the branch facts the poll would otherwise shell out
        /// to git for. Primed into the router's own TTL cache, so the poll
        /// spawns no subprocess and the head-ref heal has the evidence it needs:
        /// the worktree tracks `main`, which is also the repo default.
        func newWorktree(branch: String = "tbd/feature") async throws -> UUID {
            let suffix = UUID().uuidString
            let path = "/tmp/prpoll-wt-\(suffix)"
            let worktree = try await db.worktrees.create(
                repoID: repoID, name: "wt-\(suffix)", branch: branch,
                path: path, tmuxServer: "tbd-prpoll")
            _ = await router.branchTrackingCache.upstreamBranchName(
                worktreePath: path, branch: branch) { "main" }
            _ = await router.branchTrackingCache.pushBranch(
                worktreePath: path, branch: branch) { .noPushDestination }
            return worktree.id
        }

        @discardableResult
        func poll() async -> Bool {
            await router.handle(RPCRequest(method: RPCMethod.prList)).success
        }

        func seedBinding(_ number: Int, worktreeID: UUID, source: PRBindingSource,
                         owner: String = "acme", repo: String = "acme-prod",
                         state: PRMergeableState? = nil) async throws {
            let url = "https://github.com/\(owner)/\(repo)/pull/\(number)"
            _ = try await db.prBindings.upsert(PRBinding(
                worktreeID: worktreeID, owner: owner, repo: repo, number: number, url: url,
                status: state.map { PRStatus(number: number, url: url, state: $0) },
                source: source))
        }

        /// The cached worktree-keyed status an earlier pass would have left.
        func seedCachedStatus(_ number: Int, worktreeID: UUID, owner: String = "acme",
                              repo: String = "acme-prod",
                              state: PRMergeableState = .mergeable) async {
            await prManager.seedForTesting(
                worktreeID: worktreeID,
                status: PRStatus(number: number,
                                 url: "https://github.com/\(owner)/\(repo)/pull/\(number)",
                                 state: state))
        }

        func bindings(_ worktreeID: UUID) async throws -> [PRBinding] {
            try await db.prBindings.list(worktreeID: worktreeID, includeDetached: true)
        }

        /// `tbd pr detach` / `tbd pr attach` — a tombstone written and cleared,
        /// the way the CLI's RPC handlers do it.
        func setDetached(_ number: Int, worktreeID: UUID, _ detached: Bool) async throws {
            let key = PRBinding(
                worktreeID: worktreeID, owner: "acme", repo: "acme-prod", number: number,
                url: "https://github.com/acme/acme-prod/pull/\(number)",
                source: .manual).identityKey
            _ = try await db.prBindings.setDetached(
                worktreeID: worktreeID, identityKey: key, detached: detached)
        }

        func firedWorktreeIDs() async -> [UUID] { await fired.fired.map(\.worktreeID) }

        func columnStatus(_ worktreeID: UUID) async throws -> PRStatus? {
            try await db.worktrees.get(id: worktreeID)?.prStatus
        }

        /// Rows changed on the writer connection so far. An idle poll must not
        /// move it — `UPDATE` counts a row even when the value is identical.
        func totalChanges() async throws -> Int {
            try await db.writerForTests.write { conn in
                try Int.fetchOne(conn, sql: "SELECT total_changes()") ?? 0
            }
        }
    }

    // MARK: - Finding A: a heal must reach the binding, not just the cache

    @Test("a branch binding written by one poll is removed when a later poll's head-ref heal fires")
    func headRefHealRemovesTheBranchBindingItDisproved() async throws {
        let harness = try await Harness()
        let wt = try await harness.newWorktree()

        // Poll 1: the viewer batch matches the worktree's own branch, so the
        // branch matcher binds PR #90.
        await harness.gh.set(viewerNodes: [Self.nodeJSON(number: 90, head: "tbd/feature")])
        #expect(await harness.poll())
        let afterFirst = try await harness.bindings(wt)
        #expect(afterFirst.map(\.number) == [90])
        #expect(afterFirst.first?.source == .branch)

        // Poll 2: `@{push}` now resolves and the batch no longer offers the PR,
        // so the cached number is re-resolved — and its head turns out to be the
        // branch this worktree merely TRACKS, which is the repo default. The
        // heal clears the cache; without this fix the binding row survived,
        // kept driving the icon, and on merge auto-archived the worktree.
        await harness.gh.set(viewerNodes: [])
        await harness.gh.set(nodesByNumber: [90: Self.nodeJSON(number: 90, head: "main")])
        #expect(await harness.poll())

        #expect(try await harness.bindings(wt).isEmpty)
        #expect(try await harness.columnStatus(wt) == nil)
    }

    @Test("the same heal leaves a hook or manual binding standing")
    func healSparesHookAndManualBindings() async throws {
        for source in PRBindingSource.allCases {
            let harness = try await Harness()
            let wt = try await harness.newWorktree()
            try await harness.seedBinding(90, worktreeID: wt, source: source, state: .mergeable)
            await harness.seedCachedStatus(90, worktreeID: wt)

            await harness.gh.set(nodesByNumber: [90: Self.nodeJSON(number: 90, head: "main")])
            #expect(await harness.poll())

            let remaining = try await harness.bindings(wt).map(\.number)
            #expect(remaining == (source == .branch ? [] : [90]), "source \(source.rawValue)")
        }
    }

    @Test("a cross-repo poisoned binding is removed, not just its cache entry")
    func crossRepoHealRemovesTheBinding() async throws {
        // The repo's remote was re-pointed after the binding was written, so the
        // coordinator's bind-time repo check can no longer help: a binding is
        // re-queried by (owner, repo, number) and never re-validated.
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(7, worktreeID: wt, source: .branch, repo: "other-repo",
                                      state: .mergeable)
        await harness.seedCachedStatus(7, worktreeID: wt, repo: "other-repo")

        #expect(await harness.poll())

        #expect(try await harness.bindings(wt).isEmpty)
        #expect(try await harness.columnStatus(wt) == nil)
    }

    @Test("a poll that heals nothing leaves every binding alone")
    func healthyPollRemovesNothing() async throws {
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(90, worktreeID: wt, source: .branch, state: .mergeable)
        await harness.seedCachedStatus(90, worktreeID: wt)

        // The PR's head IS this worktree's own branch — nothing is disproved.
        await harness.gh.set(nodesByNumber: [90: Self.nodeJSON(number: 90, head: "tbd/feature")])
        #expect(await harness.poll())

        #expect(try await harness.bindings(wt).map(\.number) == [90])
    }

    // MARK: - Finding B: the worktree column is compared against what it holds now

    @Test("a worst status equal to the pre-poll snapshot is still written when the pass moved the column")
    func worktreeStatusComparesAgainstTheCurrentValue() async throws {
        // Worktree bound to #1 (mergeable) and #2 (checks failing); the column
        // already holds checksFailed(#2). Mid-pass, `fetchAll` branch-matches #1
        // and persists mergeable(#1). The worst of the bindings is still
        // checksFailed(#2) — which equals the PRE-poll snapshot, so the write
        // was skipped and the column stayed green over a failing PR, every poll.
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook, state: .mergeable)
        try await harness.seedBinding(2, worktreeID: wt, source: .hook, state: .checksFailed)
        // Byte-for-byte what binding #2 carries, so the pre-poll snapshot and
        // the worst-of-bindings verdict really do compare equal — that equality
        // is the whole bug.
        let failing = PRStatus(number: 2, url: "https://github.com/acme/acme-prod/pull/2",
                               state: .checksFailed)
        try await harness.db.worktrees.setPRStatus(id: wt, status: failing)

        // #1 resolves green by branch match and by number; #2 does not resolve,
        // so it keeps its previous failing status.
        await harness.gh.set(viewerNodes: [Self.nodeJSON(number: 1, head: "tbd/feature")])
        await harness.gh.set(nodesByNumber: [1: Self.nodeJSON(number: 1, head: "tbd/feature")])
        #expect(await harness.poll())

        let column = try await harness.columnStatus(wt)
        #expect(column?.state == .checksFailed)
        #expect(column?.number == 2)
    }

    @Test("an idle poll issues no write at all")
    func idlePollWritesNothing() async throws {
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook, state: .mergeable)
        await harness.gh.set(nodesByNumber: [1: Self.nodeJSON(number: 1, head: "tbd/feature")])

        // First poll settles everything (status, refs, worktree column).
        #expect(await harness.poll())
        let before = try await harness.totalChanges()

        #expect(await harness.poll())

        // The skip-when-unchanged optimisation is preserved: re-reading the
        // current column costs a SELECT, never an UPDATE.
        #expect(try await harness.totalChanges() == before)
    }

    @Test("a merged worst status is still never written to the worktree column")
    func mergedIsNeverPersistedToTheColumn() async throws {
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook, state: .mergeable)
        let previous = PRStatus(number: 1, url: "https://github.com/acme/acme-prod/pull/1",
                                state: .mergeable, reason: "Ready to merge")
        try await harness.db.worktrees.setPRStatus(id: wt, status: previous)

        await harness.gh.set(nodesByNumber: [
            1: Self.nodeJSON(number: 1, head: "tbd/feature", state: "MERGED")
        ])
        #expect(await harness.poll())

        // The binding records the merge; the column keeps its previous value so
        // a restart re-observes the merge as a transition.
        #expect(try await harness.bindings(wt).first?.status?.state == .merged)
        #expect(try await harness.columnStatus(wt) == previous)
    }

    // MARK: - Finding C: head and base refs are actually written

    @Test("a refresh populates the binding's head and base branch")
    func refreshPopulatesBranchRefs() async throws {
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook)
        #expect(try await harness.bindings(wt).first?.headBranch == nil)

        await harness.gh.set(nodesByNumber: [
            1: Self.nodeJSON(number: 1, head: "tbd/fix-login-timeout", base: "release/2026-08")
        ])
        #expect(await harness.poll())

        let bound = try await harness.bindings(wt).first
        #expect(bound?.headBranch == "tbd/fix-login-timeout")
        #expect(bound?.baseRef == "release/2026-08")
    }

    @Test("a poll that resolves nothing leaves an already-known branch in place")
    func transientFailureKeepsKnownRefs() async throws {
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook)
        await harness.gh.set(nodesByNumber: [1: Self.nodeJSON(number: 1, head: "tbd/feature")])
        #expect(await harness.poll())
        #expect(try await harness.bindings(wt).first?.headBranch == "tbd/feature")

        // The PR stops resolving (deleted, inaccessible, rate-limited).
        await harness.gh.set(nodesByNumber: [:])
        #expect(await harness.poll())

        #expect(try await harness.bindings(wt).first?.headBranch == "tbd/feature")
        #expect(try await harness.bindings(wt).first?.baseRef == "main")
    }

    // MARK: - Finding D: the merge rule judges the refs this pass observed

    @Test("a head ref observed for the first time fires the merge rule in that same pass")
    func firstObservedHeadRefFiresInTheSamePass() async throws {
        // A hook binding carries no head ref until a refresh observes one, and
        // the ownership arm holds the gate shut while it is unknown. So the
        // pass that first resolves the PR observes BOTH the merge and the proof
        // of ownership — and must fire on it. Folding only the status onto the
        // in-memory binding would judge against the nil it just replaced and
        // defer the fan-out by a whole poll.
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook)
        #expect(try await harness.bindings(wt).first?.headBranch == nil)

        await harness.gh.set(nodesByNumber: [
            1: Self.nodeJSON(number: 1, head: "tbd/feature", state: "MERGED")
        ])
        #expect(await harness.poll())

        #expect(await harness.firedWorktreeIDs() == [wt])
    }

    // MARK: - Finding E: a re-attach re-arms the once-only guard

    @Test("re-attaching the only binding lets a later poll fire again")
    func reattachAfterDetachFiresAgain() async throws {
        // Detaching the only binding takes the worktree out of the poll's
        // binding grouping, so `evaluate` is never called for it again and its
        // own re-arm cannot run. The pass reports the whole polled population
        // BEFORE the no-bindings early return, so an explicit `tbd pr attach`
        // is a fresh rising edge — which is what a user retrying an archive
        // that was blocked by active children is asking for.
        let harness = try await Harness()
        let wt = try await harness.newWorktree()
        try await harness.seedBinding(1, worktreeID: wt, source: .hook)
        await harness.gh.set(nodesByNumber: [
            1: Self.nodeJSON(number: 1, head: "tbd/feature", state: "MERGED")
        ])
        #expect(await harness.poll())
        #expect(await harness.firedWorktreeIDs() == [wt])

        try await harness.setDetached(1, worktreeID: wt, true)
        #expect(await harness.poll())
        #expect(await harness.firedWorktreeIDs() == [wt])

        try await harness.setDetached(1, worktreeID: wt, false)
        #expect(await harness.poll())
        #expect(await harness.firedWorktreeIDs() == [wt, wt])
    }
}
