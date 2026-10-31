#if TBD_HARNESSES
import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

/// Opt-in native SidebarView captures. No detail view or terminal is mounted.
///
/// Compiled only when the `TBD_HARNESSES` condition is set (see
/// `Tests/CLAUDE.md`), so a normal run neither builds nor schedules it, and
/// even then each test returns at once unless `TBD_SIDEBAR_SHOTS_DIR` names a
/// task-owned output directory:
///
///     TBD_SIDEBAR_SHOTS_DIR=/tmp/sidebar-shots scripts/test.sh \
///         -Xswiftc -DTBD_HARNESSES --filter SidebarRenderHarness
///
/// `renderSwiftUIAndNativeSideBySide` renders one fixture through the SwiftUI
/// sidebar and the native outline and writes both, plus a joined image.
///
/// Nothing in CI compiles this file, so a refactor elsewhere can leave it
/// failing to build; fix it when you next enable it.
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
        let suite = TestDefaultsSuite("SidebarRenderHarness")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        defaults.set(true, forKey: AppState.showScratchSectionKey)
        defaults.set(true, forKey: AppState.sidebarWorkflowGroupsKey)
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

    @Test func renderNestedRemoteGroups() async throws {
        guard let path = ProcessInfo.processInfo.environment["TBD_SIDEBAR_SHOTS_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [320, 240] {
            for dark in [false, true] {
                for expansion in 0...2 {
                    try await renderNested(width: width, dark: dark, expansion: expansion, into: directory)
                }
            }
        }
    }

    private func renderNested(width: Int, dark: Bool, expansion: Int, into directory: URL) async throws {
        let suite = TestDefaultsSuite("SidebarRenderHarness.Nested")
        let defaults = suite.defaults
        defer { suite.tearDown() }
        defaults.set(false, forKey: AppState.showScratchSectionKey)
        let state = AppState(userDefaults: defaults)
        let api = Repo(path: "/tmp/acme-api", displayName: "acme/api")
        let web = Repo(path: "/tmp/acme-web", displayName: "acme/web")
        state.repos = [api, web]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        var director = SidebarGroupFixtures.row("API director", repoID: api.id)
        director.pinnedAt = Date(timeIntervalSince1970: 1)
        let local = SidebarGroupFixtures.row("Local review", repoID: api.id, parent: director.id)
        let names = ["Index worker", "API tests worker", "Pagination worker", "Schema review", "Request trace"]
        let workers = names.enumerated().map {
            SidebarGroupFixtures.row($0.element, repoID: api.id, remote: "nested-\($0.offset)",
                                     parent: director.id, order: $0.offset + 1)
        }
        let activeChild = SidebarGroupFixtures.row("Running follow-up", repoID: api.id,
            remote: "follow-up", parent: workers[0].id)
        let crossRepoChild = SidebarGroupFixtures.row("Local web review", repoID: web.id, parent: workers[1].id)
        state.worktrees = [api.id: [director, local, activeChild] + workers, web.id: [crossRepoChild]]
        state.remoteSessions = names.indices.map {
            SidebarGroupFixtures.session("nested-\($0)", state: $0 == 0 || $0 >= 3 ? .exited : .running,
                                         repoID: api.id, agent: $0 == 1 ? .waitingInput : .idle)
        } + [SidebarGroupFixtures.session("follow-up", repoID: api.id)]
        if expansion > 0 {
            state.expandedSidebarGroups = [
                .init(owner: .parent(director.id), kind: .remote),
                .init(owner: .parent(workers[0].id), kind: .remote)
            ]
        }
        if expansion > 1 {
            state.expandedSidebarGroups.insert(.init(owner: .parent(director.id), kind: .exited))
        }
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let view = SidebarView().environment(state).defaultAppStorage(defaults)
            .environment(\.colorScheme, dark ? .dark : .light)
        let host = OffscreenHost(root: view, size: NSSize(width: width, height: 1000), appearance: appearance)
        defer { host.tearDown() }
        await host.pump(times: 40)
        let capture = try host.capture(scale: 2)
        try #require(capture.luminanceVariance() >= OffscreenHostDefaults.minLuminanceVariance,
                     "Nested sidebar capture was blank")
        let label = ["collapsed", "remote-expanded", "exited-expanded"][expansion]
        let name = "sidebar-nested-\(width)-\(dark ? "dark" : "light")-\(label).png"
        try capture.writePNG(to: directory.appendingPathComponent(name))
        #expect(state.recentlyAttachedRemoteSessions.isEmpty)
    }

    // MARK: SwiftUI and native side by side

    /// Renders one fixture through the SwiftUI `List` sidebar and through the
    /// native outline, as `sidebar-compare-<width>-<light|dark>-swiftui.png`
    /// and `...-native.png`, then a third file with the two next to each
    /// other (`...-side-by-side.png`, SwiftUI on the left).
    @Test func renderSwiftUIAndNativeSideBySide() async throws {
        guard let path = ProcessInfo.processInfo.environment["TBD_SIDEBAR_SHOTS_DIR"], !path.isEmpty else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for width in [320, 240] {
            for dark in [false, true] {
                try await renderComparison(width: width, dark: dark, into: directory)
            }
        }
    }

    /// The same rows for both paths: pinned and plain worktrees, children,
    /// and remote workers.
    private func populateComparison(_ state: AppState, defaults: UserDefaults) {
        defaults.set(false, forKey: AppState.showScratchSectionKey)
        let api = Repo(path: "/tmp/acme-api", displayName: "acme/api")
        let web = Repo(path: "/tmp/acme-web", displayName: "acme/web")
        state.repos = [api, web]
        state.remoteProviders = [SidebarGroupFixtures.provider()]
        let main = SidebarGroupFixtures.row("main", repoID: api.id, status: .main)
        var director = SidebarGroupFixtures.row("API director", repoID: api.id)
        director.pinnedAt = Date(timeIntervalSince1970: 1)
        let child = SidebarGroupFixtures.row("Local review", repoID: api.id, parent: director.id)
        let plain = SidebarGroupFixtures.row("Index tuning", repoID: api.id, order: 1)
        let names = ["Index worker", "API tests worker", "Pagination worker"]
        let workers = names.enumerated().map {
            SidebarGroupFixtures.row($0.element, repoID: api.id, remote: "cmp-\($0.offset)", order: $0.offset + 2)
        }
        let webMain = SidebarGroupFixtures.row("main", repoID: web.id, status: .main)
        let webRow = SidebarGroupFixtures.row("Response audit", repoID: web.id)
        state.worktrees = [api.id: [main, director, child, plain] + workers, web.id: [webMain, webRow]]
        state.remoteSessions = names.indices.map {
            SidebarGroupFixtures.session("cmp-\($0)", state: .running, repoID: api.id, agent: $0 == 1 ? .waitingInput : .idle)
        }
    }

    private func renderComparison(width: Int, dark: Bool, into directory: URL) async throws {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let label = "sidebar-compare-\(width)-\(dark ? "dark" : "light")"
        let size = NSSize(width: width, height: 780)

        // SwiftUI path.
        let swiftUIImage: NSBitmapImageRep
        do {
            let suite = TestDefaultsSuite("SidebarRenderHarness.Compare.SwiftUI")
            defer { suite.tearDown() }
            suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
            let state = AppState(userDefaults: suite.defaults)
            populateComparison(state, defaults: suite.defaults)
            let view = SidebarView().environment(state).defaultAppStorage(suite.defaults)
                .environment(\.colorScheme, dark ? .dark : .light)
            let host = OffscreenHost(root: view, size: size, appearance: appearance)
            defer { host.tearDown() }
            await host.pump(times: 40)
            let capture = try host.capture(scale: 2)
            try #require(capture.luminanceVariance() >= OffscreenHostDefaults.minLuminanceVariance,
                         "SwiftUI sidebar capture was blank")
            swiftUIImage = capture.rep
            try capture.writePNG(to: directory.appendingPathComponent("\(label)-swiftui.png"))
        }

        // Native path: the outline controller over the same fixture.
        let nativeImage: NSBitmapImageRep
        do {
            let suite = TestDefaultsSuite("SidebarRenderHarness.Compare.Native")
            defer { suite.tearDown() }
            let state = AppState(userDefaults: suite.defaults)
            populateComparison(state, defaults: suite.defaults)
            let controller = SidebarOutlineController(
                appState: state, defaults: suite.defaults, scratchDirectoryProbe: { _ in true })
            let host = OffscreenAppKitHost(controller: controller, size: size, appearance: appearance)
            defer { host.tearDown() }
            controller.flushPendingRebuild()
            host.layout()
            // Cells are made during layout; give the window a few turns to draw.
            for _ in 0..<5 {
                await Task.yield()
                host.layout()
            }
            nativeImage = try Self.bitmap(of: host.window, scale: 2)
            let name = "\(label)-native.png"
            try Self.writePNG(nativeImage, to: directory.appendingPathComponent(name))
        }

        try Self.writePNG(Self.joined(swiftUIImage, nativeImage), to: directory.appendingPathComponent("\(label)-side-by-side.png"))
    }

    /// The window's content drawn at `scale` pixels per point.
    private static func bitmap(of window: NSWindow, scale: CGFloat) throws -> NSBitmapImageRep {
        let view = try #require(window.contentView)
        view.layoutSubtreeIfNeeded()
        let bounds = view.bounds
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int((bounds.width * scale).rounded()),
            pixelsHigh: Int((bounds.height * scale).rounded()), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = bounds.size
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        view.displayIgnoringOpacity(bounds, in: context)
        return rep
    }

    /// `left` and `right` next to each other with a gap between.
    private static func joined(_ left: NSBitmapImageRep, _ right: NSBitmapImageRep) throws -> NSBitmapImageRep {
        let gap = 16
        let width = left.pixelsWide + gap + right.pixelsWide
        let height = max(left.pixelsHigh, right.pixelsHigh)
        let rep = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let context = try #require(NSGraphicsContext(bitmapImageRep: rep))
        let saved = NSGraphicsContext.current
        NSGraphicsContext.current = context
        defer { NSGraphicsContext.current = saved }
        NSColor.gray.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        left.draw(in: NSRect(x: 0, y: height - left.pixelsHigh, width: left.pixelsWide, height: left.pixelsHigh))
        right.draw(in: NSRect(x: left.pixelsWide + gap, y: height - right.pixelsHigh,
                              width: right.pixelsWide, height: right.pixelsHigh))
        return rep
    }

    private static func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
        let data = try #require(rep.representation(using: .png, properties: [:]))
        try data.write(to: url)
    }
}
#endif
