import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

/// Opt-in native SidebarView captures. No detail view or terminal is mounted.
/// Set TBD_SIDEBAR_SHOTS_DIR to a task-owned output directory to enable.
@MainActor
@Suite("Sidebar render harness")
struct SidebarRenderHarness {
    @Test func renderCollapsedAndExpandedGroups() async throws {
        guard let path = ProcessInfo.processInfo.environment["TBD_SIDEBAR_SHOTS_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [320, 240] {
            for dark in [false, true] {
                for expanded in [false, true] {
                    try await render(width: width, dark: dark, expanded: expanded, into: directory)
                }
            }
        }
    }

    private func render(width: Int, dark: Bool, expanded: Bool, into directory: URL) async throws {
        let suite = "SidebarRenderHarness.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppState.showScratchSectionKey)
        defaults.set(false, forKey: AppState.nightwatchExperimentalKey)
        let state = AppState(userDefaults: defaults)
        let api = Repo(path: "/tmp/acme-api", displayName: "acme/api")
        let web = Repo(path: "/tmp/acme-web", displayName: "acme/web")
        state.repos = [api, web]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        var director = SidebarGroupFixtures.row("API director", repoID: api.id)
        director.pinnedAt = Date(timeIntervalSince1970: 1)
        var webDirector = SidebarGroupFixtures.row("Web director", repoID: web.id)
        webDirector.pinnedAt = Date(timeIntervalSince1970: 2)
        let names = ["Index worker", "API tests worker", "Pagination worker", "Schema review", "Request trace"]
        let workers = names.enumerated().map {
            SidebarGroupFixtures.row($0.element, repoID: api.id, remote: "worker-\($0.offset)", order: $0.offset + 1)
        }
        let parked = SidebarGroupFixtures.row("Queue investigation", repoID: api.id)
        let parkedChild = SidebarGroupFixtures.row("Response audit", repoID: web.id, parent: parked.id)
        let mixed = SidebarGroupFixtures.row("Mixed worktree", repoID: api.id)
        let scratch = Worktree(repoID: nil, name: "scratch", displayName: "Layout exploration",
                               branch: "", path: "/tmp/acme-scratch", tmuxServer: "acme")
        state.worktrees = [api.id: [director, parked, mixed] + workers, web.id: [webDirector, parkedChild]]
        state.scratchWorktrees = [scratch]
        let parkedAt = Date(timeIntervalSince1970: 1_800_000_000)
        for worktree in [parked, parkedChild, mixed, scratch] {
            state.terminals[worktree.id] = [Terminal(
                worktreeID: worktree.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
                kind: .claude, hibernatedAt: parkedAt)]
        }
        state.terminals[mixed.id]?.append(Terminal(
            worktreeID: mixed.id, tmuxWindowID: "@2", tmuxPaneID: "%2", kind: .shell))
        state.remoteSessions = names.indices.map {
            SidebarGroupFixtures.session("worker-\($0)", state: $0 < 3 ? .running : .exited,
                                         repoID: api.id, agent: $0 == 1 ? .waitingInput : .idle)
        } + [SidebarGroupFixtures.session("Unmatched worker")]
        if expanded {
            state.expandedSidebarGroups = [
                .init(owner: .repository(api.id), kind: .remote),
                .init(owner: .repository(api.id), kind: .exited),
                .init(owner: .provider("acme"), kind: .remote),
                .init(owner: .repository(api.id), kind: .hibernated),
                .init(owner: .scratch, kind: .hibernated)
            ]
        }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = SidebarView().environment(state).defaultAppStorage(defaults)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = OffscreenHost(root: view, size: NSSize(width: width, height: 780), appearance: appearance)
        defer { host.tearDown() }
        await host.pump(times: 40)
        let capture = try host.capture(scale: 2)
        try #require(capture.luminanceVariance() >= OffscreenHostDefaults.minLuminanceVariance,
                     "Sidebar capture was blank")
        let name = "sidebar-\(width)-\(dark ? "dark" : "light")-\(expanded ? "expanded" : "collapsed").png"
        try capture.writePNG(to: directory.appendingPathComponent(name))
        #expect(state.recentlyAttachedRemoteSessions.isEmpty)
    }
}
