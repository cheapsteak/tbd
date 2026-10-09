import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Env-gated benchmark of what a sidebar refresh costs when many remote
/// sessions have ended, with the "Collapse ended remote sessions" option off
/// versus on (Ended collapsed). It mounts the real `SidebarView` in an
/// `OffscreenHost`, applies refresh-shaped updates, and reports main-thread CPU
/// per update with a no-mutation baseline subtracted.
///
/// Inert during normal runs: returns unless `TBD_PERF_BENCH=1`.
///
///     TBD_PERF_BENCH=1 scripts/test.sh --filter SidebarListUpdateBench
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
        let suite = "SidebarListUpdateBench.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppState.showScratchSectionKey)
        defaults.set(false, forKey: AppState.nightwatchExperimentalKey)
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
