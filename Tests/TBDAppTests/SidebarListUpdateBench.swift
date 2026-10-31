import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Env-gated benchmark of what a sidebar refresh costs when many remote
/// sessions have ended, with the "Collapse ended remote sessions" option off
/// versus on (Ended collapsed). It mounts the real `SidebarView` in an
/// `OffscreenHost`, applies refresh-shaped updates, and reports main-thread CPU
/// per update with a no-mutation baseline subtracted.
///
/// Inert during normal runs: returns unless `TBD_PERF_BENCH=1`.
///
///     TBD_PERF_BENCH=1 scripts/test.sh --filter SidebarListUpdateBench
///
/// The native sidebar cases below the struct, compiled only under
/// `TBD_HARNESSES` (`Tests/CLAUDE.md`), measure the AppKit sidebar against the
/// spec's "Responsiveness" budget with wall-clock time: rebuild + diff + apply
/// + the layout pass that makes cell views, at 320 rows (8 ms) and at 800
/// remote sessions (16 ms); `validateDrop` per call (1 ms); and a drop,
/// `acceptDrop` through the end-of-drag flush and layout together. The last
/// case compares the native path with the `List` path at 800 sessions on one
/// metric (graduation criterion 4). Each prints `BENCH native-...` lines with
/// p50, p95 and a `PASS`/`OVER` verdict. The `rebuild` and `apply` signpost
/// intervals on `com.tbd.app` / `native-sidebar` show the same split in
/// Instruments.
///
///     TBD_PERF_BENCH=1 scripts/test.sh -Xswiftc -DTBD_HARNESSES --filter SidebarListUpdateBench
@Suite("Sidebar list update bench")
@MainActor
struct SidebarListUpdateBench {
    private static let updates = 15

    @Test("refresh cost with many ended sessions (gated by TBD_PERF_BENCH=1)")
    func refreshCost() async {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for n in [208, 800] {
            for collapse in [false, true] {
                await runCase(n: n, collapse: collapse)
            }
        }
    }

    /// 2% running, 12% exited, the rest gone, all resolved to one repo.
    fileprivate func makeSessions(n: Int, repoID: UUID) -> [RemoteSessionInfo] {
        let running = max(4, n * 2 / 100), exited = n * 12 / 100
        let epoch = Date(timeIntervalSince1970: 1_800_000_000)
        return (0..<n).map { i in
            let created = ISO8601DateFormatter().string(from: epoch.addingTimeInterval(Double(i) * 60))
            let state: RemoteProcessState = i < running ? .running : (i < running + exited ? .exited : .running)
            return RemoteSessionInfo(
                provider: "acme",
                payload: .init(id: "s\(i)", createdAt: created, state: state, agentState: .idle),
                gone: i >= running + exited, dismissed: false, lastSeen: epoch, resolvedRepoID: repoID)
        }
    }

    fileprivate func cpuNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    fileprivate func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    @discardableResult
    private func runCase(n: Int, collapse: Bool) async -> [Double] {
        let suite = TestDefaultsSuite("SidebarListUpdateBench")
        defer { suite.tearDown() }
        let defaults = suite.defaults
        defaults.set(true, forKey: AppState.showScratchSectionKey)
        defaults.set(false, forKey: AppState.sidebarWorkflowGroupsKey)
        defaults.set(collapse, forKey: AppState.sidebarCollapseEndedSessionsKey)
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        state.worktrees = [repo.id: [SidebarGroupFixtures.row("main", repoID: repo.id)]]
        state.remoteSessions = makeSessions(n: n, repoID: repo.id)

        let view = SidebarView().environment(state).defaultAppStorage(defaults)
        let host = OffscreenHost(root: view, size: NSSize(width: 320, height: 780))
        defer { host.tearDown() }
        await host.pump(times: 40)

        let layout = state.sidebarRepositoryLayout(
            repoID: repo.id, grouped: false, collapseEnded: collapse,
            matchedSessions: state.sidebarMatchedRemoteSessions(repoID: repo.id))
        // Ended stays collapsed, so only the inline sessions exist as rows.
        let sessionRowsInList = layout.inlineSessions.count

        func timed(_ body: () -> Void) -> Double {
            let start = cpuNanos()
            body()
            host.pumpSynchronously(times: 4)
            return Double(cpuNanos() - start) / 1_000_000
        }

        let baseline = median((0..<Self.updates).map { _ in timed {} })

        let liveIndices = state.remoteSessions.indices.filter { !state.remoteSessions[$0].gone
            && state.remoteSessions[$0].payload.state == .running }
        var deltas: [Double] = []
        for step in 0..<Self.updates {
            let index = liveIndices[step % liveIndices.count]
            deltas.append(timed {
                var sessions = state.remoteSessions
                let old = sessions[index]
                let working = old.payload.agentState != .working
                sessions[index] = RemoteSessionInfo(
                    provider: old.provider,
                    payload: .init(id: old.payload.id, createdAt: old.payload.createdAt, state: old.payload.state,
                                   agentState: working ? .working : .idle),
                    gone: old.gone, dismissed: old.dismissed,
                    lastSeen: old.lastSeen.addingTimeInterval(Double(step + 1)),
                    resolvedRepoID: old.resolvedRepoID)
                state.remoteSessions = sessions
            } - baseline)
        }
        let p90 = deltas.sorted()[min(deltas.count - 1, Int(Double(deltas.count) * 0.9))]
        print(String(
            format: "BENCH sidebar-update n=%d collapse=%@ session_rows_in_list=%d median_ms=%.2f p90_ms=%.2f",
            n, collapse ? "on" : "off", sessionRowsInList, median(deltas), p90))
        fflush(stdout)
        return deltas
    }
}

#if TBD_HARNESSES
// MARK: - Native sidebar budget

/// The native sidebar's responsiveness budget (spec: "Responsiveness"), in
/// milliseconds.
private enum NativeBudget {
    static let rowsRebuild = 8.0
    static let sessionsRebuild = 16.0
    static let validateDrop = 1.0
    /// The spec asks that a drop reach the screen on the next main-loop turn;
    /// it names no number, so a drop is held to the rebuild budget at 320 rows
    /// and to the 800-session budget on that tree.
    static let drop = 8.0
    static let dropSessions = 16.0
    static let warmUp = 10
    static let iterations = 60
    static let validateIterations = 2000
}

extension SidebarListUpdateBench {
    @Test("native rebuild + diff + apply at 320 rows (gated by TBD_PERF_BENCH=1)")
    func nativeRebuildAtRows() {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for structural in [false, true] {
            let h = OutlineHarness("bench.rows")
            defer { h.tearDown() }
            let fixture = Self.installRows(in: h)
            h.mount(size: NSSize(width: 320, height: 780))
            let rows = h.shownIDs.count
            var parked = false
            let samples = Self.measure(h) { step in
                var list = h.state.worktrees[fixture.repo.id] ?? []
                if structural {
                    // Add, then remove, one leaf under a root: a structural diff.
                    if parked { list.removeLast() } else { list.append(fixture.extraLeaf) }
                    parked.toggle()
                } else {
                    list[list.count / 2].displayName = "renamed \(step)"
                }
                h.state.worktrees[fixture.repo.id] = list
            }
            Self.report("native-rebuild rows=\(rows) kind=\(structural ? "structure" : "content")",
                        samples, budget: NativeBudget.rowsRebuild)
        }
    }

    @Test("native rebuild + diff + apply at 800 remote sessions (gated by TBD_PERF_BENCH=1)")
    func nativeRebuildAtSessions() {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for collapse in [false, true] {
            let h = OutlineHarness("bench.sessions")
            defer { h.tearDown() }
            let (_, live) = installSessions(in: h, collapse: collapse)
            h.mount(size: NSSize(width: 320, height: 780))
            let rows = h.shownIDs.count
            let samples = Self.measure(h) { step in Self.flipSession(in: h, live: live, step: step) }
            Self.report("native-rebuild sessions=800 rows=\(rows) collapse_ended=\(collapse ? "on" : "off")",
                        samples, budget: NativeBudget.sessionsRebuild)
        }
    }

    /// Graduation criterion 4: the native path no slower than the `List` path
    /// at 800 sessions. Both are measured as main-thread CPU per refresh with
    /// an idle baseline subtracted, which is what `runCase` measures, and
    /// both include the layout pass that makes the rows.
    @Test("native versus List at 800 remote sessions (gated by TBD_PERF_BENCH=1)")
    func nativeVersusList() async {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for collapse in [false, true] {
            let list = await runCase(n: 800, collapse: collapse)
            let native = nativeCPUDeltas(collapse: collapse)
            let listSorted = list.sorted(), nativeSorted = native.sorted()
            let listP50 = Self.percentile(listSorted, 0.5), nativeP50 = Self.percentile(nativeSorted, 0.5)
            let nativeP95 = Self.percentile(nativeSorted, 0.95), listP95 = Self.percentile(listSorted, 0.95)
            let verdict = nativeSorted.isEmpty || listSorted.isEmpty ? "NO-DATA" : (nativeP50 <= listP50 ? "PASS" : "OVER")
            let line = String(
                format: "BENCH native-vs-list sessions=800 collapse_ended=%@ metric=main_thread_cpu_ms list_p50=%.3f list_p95=%.3f native_p50=%.3f native_p95=%.3f verdict=%@",
                collapse ? "on" : "off", listP50, listP95, nativeP50, nativeP95, verdict)
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
    }

    /// Main-thread CPU per refresh of the native sidebar at 800 sessions
    /// (mutation, rebuild + apply, layout), idle baseline subtracted.
    private func nativeCPUDeltas(collapse: Bool) -> [Double] {
        let h = OutlineHarness("bench.vs")
        defer { h.tearDown() }
        let (_, live) = installSessions(in: h, collapse: collapse)
        h.mount(size: NSSize(width: 320, height: 780))
        var idle: [Double] = []
        for _ in 0..<15 {
            let start = cpuNanos()
            h.controller.flushPendingRebuild()
            h.host?.layout()
            idle.append(Double(cpuNanos() - start) / 1_000_000)
        }
        let baseline = median(idle)
        var deltas: [Double] = []
        for step in 0..<(NativeBudget.warmUp + NativeBudget.iterations) {
            Self.flipSession(in: h, live: live, step: step)
            let start = cpuNanos()
            h.controller.flushPendingRebuild()
            h.host?.layout()
            let elapsed = Double(cpuNanos() - start) / 1_000_000 - baseline
            if step >= NativeBudget.warmUp { deltas.append(max(0, elapsed)) }
        }
        return deltas
    }

    @Test("native validateDrop per call (gated by TBD_PERF_BENCH=1)")
    func nativeValidateDrop() throws {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for scenario in Scenario.allCases {
            let h = OutlineHarness("bench.validate")
            defer { h.tearDown() }
            let fixture = installScenario(scenario, in: h)
            h.mount(size: NSSize(width: 320, height: 780))
            let info = StubDraggingInfo(carrying: fixture.carried.id)
            defer { info.release() }
            h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), willBeginAt: .zero, forItems: [])
            defer { h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), endedAt: .zero, operation: .move) }
            let repoHeader = SidebarNodeID.repoHeader(fixture.repo.id)
            let proposals: [(SidebarNodeID, Int)] = [
                (.worktree(fixture.nestTarget.id), SidebarDropPolicy.dropOnItemIndex),
                (repoHeader, 3),
                (repoHeader, 0)
            ]
            var items: [SidebarItem] = []
            for proposal in proposals {
                items.append(try #require(h.controller.item(for: proposal.0)))
            }
            info.draggingLocation = h.outline.convert(NSPoint(x: h.controller.dropDepthInset, y: 1), to: nil)
            var operations = 0
            var samples: [Double] = []
            let clock = ContinuousClock()
            let total = NativeBudget.warmUp + NativeBudget.validateIterations
            for i in 0..<total {
                let slot = i % proposals.count
                let start = clock.now
                let operation = h.controller.outlineView(
                    h.outline, validateDrop: info, proposedItem: items[slot], proposedChildIndex: proposals[slot].1)
                let elapsed = Self.milliseconds(clock.now - start)
                if operation == .move { operations += 1 }
                if i >= NativeBudget.warmUp { samples.append(elapsed) }
            }
            Self.report("native-validateDrop tree=\(scenario.rawValue) rows=\(h.shownIDs.count) accepted=\(operations)/\(total)",
                        samples, budget: NativeBudget.validateDrop)
        }
    }

    @Test("native drop: acceptDrop through the end-of-drag flush (gated by TBD_PERF_BENCH=1)")
    func nativeDrop() async throws {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for scenario in Scenario.allCases {
            let h = OutlineHarness("bench.drop")
            defer { h.tearDown() }
            let fixture = installScenario(scenario, in: h)
            h.state.worktreeMoveManySender = { _ in }
            h.mount(size: NSSize(width: 320, height: 780))
            let targets = [fixture.nestTarget.id, fixture.otherTarget.id]
            let clock = ContinuousClock()
            var samples: [Double] = []
            var accepted = 0
            let total = NativeBudget.warmUp + NativeBudget.iterations
            for i in 0..<total {
                // Alternate targets so every drop is a real move.
                let target = SidebarNodeID.worktree(targets[i % 2])
                let info = StubDraggingInfo(carrying: fixture.carried.id)
                defer { info.release() }
                let item = try #require(h.controller.item(for: target))
                h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), willBeginAt: .zero, forItems: [])
                info.draggingLocation = h.outline.convert(NSPoint(x: h.controller.dropDepthInset, y: 1), to: nil)
                let onto = SidebarDropPolicy.dropOnItemIndex
                _ = h.controller.outlineView(h.outline, validateDrop: info, proposedItem: item, proposedChildIndex: onto)
                let start = clock.now
                let ok = h.controller.outlineView(h.outline, acceptDrop: info, item: item, childIndex: onto)
                h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), endedAt: .zero, operation: .move)
                h.host?.layout()
                let elapsed = Self.milliseconds(clock.now - start)
                if ok { accepted += 1 }
                if i >= NativeBudget.warmUp { samples.append(elapsed) }
                await Self.settleMoves(on: h.state)
            }
            Self.report(
                "native-drop tree=\(scenario.rawValue) rows=\(h.shownIDs.count) accepted=\(accepted)/\(total) pending_moves=\(h.state.pendingWorktreeMoves.count)",
                samples, budget: scenario == .rows ? NativeBudget.drop : NativeBudget.dropSessions)
        }
    }

    // MARK: Fixtures

    enum Scenario: String, CaseIterable {
        case rows = "320rows"
        case sessions = "800sessions"
    }

    struct RowsFixture {
        let repo: Repo
        let carried: Worktree
        let nestTarget: Worktree
        let otherTarget: Worktree
        let extraLeaf: Worktree
    }

    func installScenario(_ scenario: Scenario, in h: OutlineHarness) -> RowsFixture {
        switch scenario {
        case .rows: Self.installRows(in: h)
        case .sessions: installSessions(in: h, collapse: false).fixture
        }
    }

    /// One repo with 800 remote sessions (the `runCase` mix) and a local
    /// main, ten roots and a child under the first root, so a drop has rows
    /// to carry. Returns the fixture and the indices of the live sessions.
    func installSessions(in h: OutlineHarness, collapse: Bool) -> (fixture: RowsFixture, live: [Int]) {
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        h.defaults.set(false, forKey: AppState.sidebarWorkflowGroupsKey)
        h.defaults.set(collapse, forKey: AppState.sidebarCollapseEndedSessionsKey)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        let roots = (0..<10).map { SidebarGroupFixtures.row("root \($0)", repoID: repo.id, order: $0) }
        let child = SidebarGroupFixtures.row("child", repoID: repo.id, parent: roots[0].id)
        h.state.repos = [repo]
        h.state.remoteProviders = [SidebarGroupFixtures.provider()]
        h.state.worktrees = [repo.id: [SidebarGroupFixtures.row("main", repoID: repo.id, status: .main)] + roots + [child]]
        h.state.remoteSessions = makeSessions(n: 800, repoID: repo.id)
        let live = h.state.remoteSessions.indices.filter {
            !h.state.remoteSessions[$0].gone && h.state.remoteSessions[$0].payload.state == .running
        }
        let fixture = RowsFixture(
            repo: repo, carried: child, nestTarget: roots[4], otherTarget: roots[6],
            extraLeaf: SidebarGroupFixtures.row("extra", repoID: repo.id, parent: roots[3].id, order: 9))
        return (fixture, live)
    }

    /// Flips one live session's agent state: a refresh-shaped content change.
    static func flipSession(in h: OutlineHarness, live: [Int], step: Int) {
        var sessions = h.state.remoteSessions
        let index = live[step % live.count]
        let old = sessions[index]
        sessions[index] = RemoteSessionInfo(
            provider: old.provider,
            payload: .init(id: old.payload.id, createdAt: old.payload.createdAt, state: old.payload.state,
                           agentState: old.payload.agentState == .working ? .idle : .working),
            gone: old.gone, dismissed: old.dismissed,
            lastSeen: old.lastSeen.addingTimeInterval(Double(step + 1)),
            resolvedRepoID: old.resolvedRepoID)
        h.state.remoteSessions = sessions
    }

    /// Four repos of one main row, 13 roots and 5 children under each root:
    /// 79 worktrees and a header each, 320 rows when everything is expanded.
    /// The returned repo is the first; its first root's first child is the row
    /// a drop carries.
    static func installRows(in h: OutlineHarness) -> RowsFixture {
        h.defaults.set(false, forKey: AppState.showScratchSectionKey)
        h.defaults.set(false, forKey: AppState.sidebarWorkflowGroupsKey)
        var repos: [Repo] = []
        var lists: [UUID: [Worktree]] = [:]
        var first: RowsFixture?
        for r in 0..<4 {
            let repo = Repo(path: "/tmp/acme-\(r)", displayName: "acme-\(r)")
            repos.append(repo)
            var list = [SidebarGroupFixtures.row("main", repoID: repo.id, status: .main)]
            var roots: [Worktree] = []
            for i in 0..<13 {
                let root = SidebarGroupFixtures.row("root \(i)", repoID: repo.id, order: i)
                roots.append(root)
                list.append(root)
                for j in 0..<5 {
                    list.append(SidebarGroupFixtures.row("child \(i).\(j)", repoID: repo.id, parent: root.id, order: j))
                }
            }
            lists[repo.id] = list
            if r == 0 {
                first = RowsFixture(
                    repo: repo, carried: list[2], nestTarget: roots[6], otherTarget: roots[8],
                    extraLeaf: SidebarGroupFixtures.row("extra", repoID: repo.id, parent: roots[3].id, order: 9))
            }
        }
        h.state.repos = repos
        h.state.worktrees = lists
        return first!
    }

    // MARK: Measurement

    /// Retires every pending move: the daemon's delta for each (carrying its
    /// `moveID`), then a few turns for the RPC task to report success, so
    /// pending moves cannot accumulate and make later drops dearer.
    static func settleMoves(on state: AppState) async {
        for move in state.pendingWorktreeMoves {
            state.handleDelta(.worktreeSiblingsReordered(WorktreeSiblingsReorderedDelta(moveID: move.moveID, entries: [])))
        }
        for _ in 0..<10 where !state.pendingWorktreeMoves.isEmpty {
            await Task.yield()
        }
    }

    /// Runs `mutate`, then times `flushPendingRebuild()` and the layout pass
    /// that makes the cell views, after a warm-up. An iteration whose mutation
    /// scheduled no build measured nothing and is left out, and reported.
    static func measure(_ h: OutlineHarness, mutate: (Int) -> Void) -> [Double] {
        let clock = ContinuousClock()
        var samples: [Double] = []
        var skipped = 0
        for step in 0..<(NativeBudget.warmUp + NativeBudget.iterations) {
            mutate(step)
            let before = h.controller.buildCount
            let start = clock.now
            h.controller.flushPendingRebuild()
            h.host?.layout()
            let elapsed = milliseconds(clock.now - start)
            guard h.controller.buildCount > before else { skipped += 1; continue }
            if step >= NativeBudget.warmUp { samples.append(elapsed) }
        }
        if skipped > 0 {
            FileHandle.standardOutput.write(Data("BENCH native-warning \(skipped) iteration(s) scheduled no rebuild\n".utf8))
        }
        return samples
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) * 1000 + Double(parts.attoseconds) / 1e15
    }

    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
    }

    static func report(_ label: String, _ samples: [Double], budget: Double) {
        let sorted = samples.sorted()
        let p50 = percentile(sorted, 0.5), p95 = percentile(sorted, 0.95)
        let verdict = sorted.isEmpty ? "NO-DATA" : (p95 <= budget ? "PASS" : "OVER")
        let line = String(
            format: "BENCH %@ n=%d p50_ms=%.3f p95_ms=%.3f budget_ms=%.1f verdict=%@",
            label, sorted.count, p50, p95, budget, verdict)
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }
}
#endif
