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
/// The native sidebar cases (`SidebarListUpdateBench+Native` below) measure the
/// AppKit sidebar against the spec's "Responsiveness" budget with wall-clock
/// time: rebuild + diff + apply at 320 rows (8 ms) and at 800 remote sessions
/// (16 ms), `validateDrop` per call (1 ms), and a drop, `acceptDrop` through
/// the end-of-drag flush together. Each prints `BENCH native-...` lines with
/// p50, p95 and a `PASS`/`OVER` verdict. The `rebuild` and `apply` signpost
/// intervals on `com.tbd.app` / `native-sidebar` show the same split in
/// Instruments.
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
    private func makeSessions(n: Int, repoID: UUID) -> [RemoteSessionInfo] {
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

    private func cpuNanos() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    private func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }

    private func runCase(n: Int, collapse: Bool) async {
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
    }
}

// MARK: - Native sidebar budget

/// The native sidebar's responsiveness budget (spec: "Responsiveness"), in
/// milliseconds.
private enum NativeBudget {
    static let rowsRebuild = 8.0
    static let sessionsRebuild = 16.0
    static let validateDrop = 1.0
    /// The spec asks that a drop reach the screen on the next main-loop turn;
    /// it names no number, so a drop is held to the rebuild budget at 320 rows.
    static let drop = 8.0
    static let warmUp = 10
    static let iterations = 60
    static let validateIterations = 2000
}

extension SidebarListUpdateBench {
    @Test("native rebuild + diff + apply at 320 rows (gated by TBD_PERF_BENCH=1)")
    func nativeRebuildAtRows() async {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for structural in [false, true] {
            let h = OutlineHarness("bench.rows")
            defer { h.tearDown() }
            let fixture = Self.installRows(in: h)
            h.mount(size: NSSize(width: 320, height: 780))
            let rows = h.shownIDs.count
            var parked = false
            let samples = Self.measure(h) { step in
                if structural {
                    // Add, then remove, one leaf under a root: a structural diff.
                    var list = h.state.worktrees[fixture.repo.id] ?? []
                    if parked { list.removeLast() } else { list.append(fixture.extraLeaf) }
                    parked.toggle()
                    h.state.worktrees[fixture.repo.id] = list
                } else {
                    var list = h.state.worktrees[fixture.repo.id] ?? []
                    list[list.count / 2].displayName = "renamed \(step)"
                    h.state.worktrees[fixture.repo.id] = list
                }
            }
            Self.report("native-rebuild rows=\(rows) kind=\(structural ? "structure" : "content")",
                        samples, budget: NativeBudget.rowsRebuild)
        }
    }

    @Test("native rebuild + diff + apply at 800 remote sessions (gated by TBD_PERF_BENCH=1)")
    func nativeRebuildAtSessions() async {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        for collapse in [false, true] {
            let h = OutlineHarness("bench.sessions")
            defer { h.tearDown() }
            h.defaults.set(false, forKey: AppState.showScratchSectionKey)
            h.defaults.set(false, forKey: AppState.sidebarWorkflowGroupsKey)
            h.defaults.set(collapse, forKey: AppState.sidebarCollapseEndedSessionsKey)
            let repo = Repo(path: "/tmp/acme", displayName: "acme")
            h.state.repos = [repo]
            h.state.remoteProviders = [SidebarGroupFixtures.provider()]
            h.state.worktrees = [repo.id: [SidebarGroupFixtures.row("main", repoID: repo.id)]]
            h.state.remoteSessions = makeSessions(n: 800, repoID: repo.id)
            h.mount(size: NSSize(width: 320, height: 780))
            let rows = h.shownIDs.count
            let live = h.state.remoteSessions.indices.filter {
                !h.state.remoteSessions[$0].gone && h.state.remoteSessions[$0].payload.state == .running
            }
            let samples = Self.measure(h) { step in
                var sessions = h.state.remoteSessions
                let old = sessions[live[step % live.count]]
                sessions[live[step % live.count]] = RemoteSessionInfo(
                    provider: old.provider,
                    payload: .init(id: old.payload.id, createdAt: old.payload.createdAt, state: old.payload.state,
                                   agentState: old.payload.agentState == .working ? .idle : .working),
                    gone: old.gone, dismissed: old.dismissed,
                    lastSeen: old.lastSeen.addingTimeInterval(Double(step + 1)),
                    resolvedRepoID: old.resolvedRepoID)
                h.state.remoteSessions = sessions
            }
            Self.report("native-rebuild sessions=800 rows=\(rows) collapse_ended=\(collapse ? "on" : "off")",
                        samples, budget: NativeBudget.sessionsRebuild)
        }
    }

    @Test("native validateDrop per call (gated by TBD_PERF_BENCH=1)")
    func nativeValidateDrop() throws {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        let h = OutlineHarness("bench.validate")
        defer { h.tearDown() }
        let fixture = Self.installRows(in: h)
        h.mount(size: NSSize(width: 320, height: 780))
        let info = BenchDraggingInfo(carrying: fixture.carried.id)
        defer { info.release() }
        h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), willBeginAt: .zero, forItems: [])
        defer { h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), endedAt: .zero, operation: .move) }
        let repoHeader = SidebarNodeID.repoHeader(fixture.repo.id)
        let proposals: [(SidebarNodeID, Int)] = [
            (.worktree(fixture.nestTarget.id), SidebarDropPolicy.dropOnItemIndex),
            (repoHeader, 3),
            (repoHeader, 0)
        ]
        let items = try proposals.map { try #require(h.controller.item(for: $0.0)) }
        info.draggingLocation = h.outline.convert(NSPoint(x: h.controller.dropDepthInset, y: 1), to: nil)
        var operations = 0
        var samples: [Double] = []
        let clock = ContinuousClock()
        for i in 0..<(NativeBudget.warmUp + NativeBudget.validateIterations) {
            let slot = i % proposals.count
            let start = clock.now
            let operation = h.controller.outlineView(
                h.outline, validateDrop: info, proposedItem: items[slot], proposedChildIndex: proposals[slot].1)
            let elapsed = Self.milliseconds(clock.now - start)
            if operation == .move { operations += 1 }
            if i >= NativeBudget.warmUp { samples.append(elapsed) }
        }
        Self.report("native-validateDrop accepted=\(operations)/\(NativeBudget.warmUp + NativeBudget.validateIterations)",
                    samples, budget: NativeBudget.validateDrop)
    }

    @Test("native drop: acceptDrop through the end-of-drag flush (gated by TBD_PERF_BENCH=1)")
    func nativeDrop() async throws {
        guard ProcessInfo.processInfo.environment["TBD_PERF_BENCH"] == "1" else { return }
        let h = OutlineHarness("bench.drop")
        defer { h.tearDown() }
        let fixture = Self.installRows(in: h)
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
            let info = BenchDraggingInfo(carrying: fixture.carried.id)
            defer { info.release() }
            let item = try #require(h.controller.item(for: target))
            h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), willBeginAt: .zero, forItems: [])
            info.draggingLocation = h.outline.convert(NSPoint(x: h.controller.dropDepthInset, y: 1), to: nil)
            let onto = SidebarDropPolicy.dropOnItemIndex
            _ = h.controller.outlineView(h.outline, validateDrop: info, proposedItem: item, proposedChildIndex: onto)
            let start = clock.now
            let ok = h.controller.outlineView(h.outline, acceptDrop: info, item: item, childIndex: onto)
            h.controller.outlineView(h.outline, draggingSession: NSDraggingSession(), endedAt: .zero, operation: .move)
            let elapsed = Self.milliseconds(clock.now - start)
            if ok { accepted += 1 }
            if i >= NativeBudget.warmUp { samples.append(elapsed) }
            // Let the move's RPC task settle before the next drop.
            await Task.yield()
        }
        Self.report("native-drop rows=\(h.shownIDs.count) accepted=\(accepted)/\(total)",
                    samples, budget: NativeBudget.drop)
    }

    // MARK: Fixture and measurement

    struct RowsFixture {
        let repo: Repo
        let carried: Worktree
        let nestTarget: Worktree
        let otherTarget: Worktree
        let extraLeaf: Worktree
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

    /// Runs `mutate` then a timed `flushPendingRebuild()`, after a warm-up.
    /// An iteration whose mutation scheduled no build measured nothing and is
    /// left out, and reported.
    static func measure(_ h: OutlineHarness, mutate: (Int) -> Void) -> [Double] {
        let clock = ContinuousClock()
        var samples: [Double] = []
        var skipped = 0
        for step in 0..<(NativeBudget.warmUp + NativeBudget.iterations) {
            mutate(step)
            let before = h.controller.buildCount
            let start = clock.now
            h.controller.flushPendingRebuild()
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

/// An `NSDraggingInfo` over a uniquely named pasteboard carrying one sidebar
/// row, for driving `validateDrop` and `acceptDrop` without a drag session.
/// Call `release()` once done with it.
@MainActor
private final class BenchDraggingInfo: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    var draggingLocation: NSPoint = .zero
    let draggingSequenceNumber = Int.random(in: 1...Int.max)
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0

    init(carrying id: UUID) {
        let pasteboard = NSPasteboard.withUniqueName()
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(id.uuidString, forType: .tbdSidebarWorktrees)
        _ = pasteboard.writeObjects([item])
        draggingPasteboard = pasteboard
        super.init()
    }

    func release() {
        draggingPasteboard.releaseGlobally()
    }

    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}

    nonisolated func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }

    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?,
                                classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any],
                                using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}

    func resetSpringLoading() {}
}
