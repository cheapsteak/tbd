import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared
import TestSupport

// Tier 1 for the storage contract; the mount tests host `SidebarView`
// offscreen and wait on bounded pumps, never on elapsed time.

/// The default-off `useAppKitSidebar` flag: its three-state storage contract,
/// the branch `SidebarView` takes on it, and the reveal rule both branches
/// share. Spec: docs/specs/2026-10-31-native-sidebar-design.md, "Flag and
/// rollout".
@MainActor
@Suite("Native sidebar flag")
struct NativeSidebarFlagTests {
    // MARK: Storage

    @Test func flagUnsetReadsDefault() {
        let suite = TestDefaultsSuite("NativeSidebarFlagTests.unset")
        defer { suite.tearDown() }
        #expect(AppState.appKitSidebarDefault == false)
        #expect(suite.defaults.object(forKey: AppState.appKitSidebarKey) == nil)
        #expect(AppState.appKitSidebarEnabled(suite.defaults) == AppState.appKitSidebarDefault)
        #expect(AppState.appKitSidebarEnabled(suite.defaults) == false)
    }

    /// The graduation rehearsal: flip the shipped default to `true` and check
    /// that only the untouched state follows it.
    @Test func explicitFalseSurvivesDefaultChange() {
        #expect(!AppState.appKitSidebarEnabled(stored: false, shippedDefault: true))
        #expect(!AppState.appKitSidebarEnabled(stored: false, shippedDefault: false))
        #expect(AppState.appKitSidebarEnabled(stored: true, shippedDefault: false))
        #expect(AppState.appKitSidebarEnabled(stored: nil, shippedDefault: true))
        #expect(!AppState.appKitSidebarEnabled(stored: nil, shippedDefault: false))

        let suite = TestDefaultsSuite("NativeSidebarFlagTests.explicit")
        defer { suite.tearDown() }
        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        #expect(suite.defaults.object(forKey: AppState.appKitSidebarKey) as? Bool == false)
        #expect(!AppState.appKitSidebarEnabled(suite.defaults))
        suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        #expect(AppState.appKitSidebarEnabled(suite.defaults))
    }

    // MARK: The branch SidebarView takes

    @Test func flagOffMountsListPath() async throws {
        let suite = TestDefaultsSuite("NativeSidebarFlagTests.off")
        defer { suite.tearDown() }
        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        let state = Self.makeState(suite.defaults)
        let host = OffscreenHost(
            root: SidebarView().environment(state).defaultAppStorage(suite.defaults),
            size: NSSize(width: 320, height: 600))
        defer { host.tearDown() }

        // Positive control: the SwiftUI `List` is backed by an AppKit table,
        // and with no pins the dock mounts none, so a table here is the list.
        let listMounted = await host.settle { !host.descendants(NSTableView.self).isEmpty }
        try #require(listMounted, "The SwiftUI List never mounted; the negative below would be vacuous")
        #expect(Self.nativeRoots(host).isEmpty, "The native sidebar must not mount while the flag is off")
    }

    @Test func flagOnMountsNativePath() async throws {
        let suite = TestDefaultsSuite("NativeSidebarFlagTests.on")
        defer { suite.tearDown() }
        suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        let state = Self.makeState(suite.defaults)
        let host = OffscreenHost(
            root: SidebarView().environment(state).defaultAppStorage(suite.defaults),
            size: NSSize(width: 320, height: 600))
        defer { host.tearDown() }

        let nativeMounted = await host.settle { !Self.nativeRoots(host).isEmpty }
        try #require(nativeMounted, "The native sidebar never mounted with the flag on")
        let roots = Self.nativeRoots(host)
        #expect(roots.count == 1)
        // The SwiftUI List is not mounted: every table in the window belongs
        // to the native sidebar.
        let root = try #require(roots.first)
        #expect(host.descendants(NSTableView.self).allSatisfy { $0.isDescendant(of: root) })
    }

    /// The toggle swaps the sidebar without a restart: `SidebarView` binds the
    /// key through `@AppStorage`, so a write to the store re-renders it.
    @Test func flippingTheFlagSwapsThePathInPlace() async throws {
        let suite = TestDefaultsSuite("NativeSidebarFlagTests.flip")
        defer { suite.tearDown() }
        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        let state = Self.makeState(suite.defaults)
        let host = OffscreenHost(
            root: SidebarView().environment(state).defaultAppStorage(suite.defaults),
            size: NSSize(width: 320, height: 600))
        defer { host.tearDown() }

        let listMounted = await host.settle { !host.descendants(NSTableView.self).isEmpty }
        try #require(listMounted, "The SwiftUI List never mounted")

        suite.defaults.set(true, forKey: AppState.appKitSidebarKey)
        let swappedIn = await host.settle {
            !Self.nativeRoots(host).isEmpty && Self.tablesOutsideNativeRoot(host).isEmpty
        }
        #expect(swappedIn, "Turning the flag on must replace the List with the native sidebar")

        suite.defaults.set(false, forKey: AppState.appKitSidebarKey)
        let swappedBack = await host.settle {
            Self.nativeRoots(host).isEmpty && !host.descendants(NSTableView.self).isEmpty
        }
        #expect(swappedBack, "Turning the flag off must bring the List back")
    }

    // MARK: The shared reveal rule

    /// The cases `SidebarView.revealBaseline` answered, now asked of the
    /// shared function both sidebar paths call.
    @Test func revealBaselineUnchanged() {
        let repoID = UUID()
        let reveal = SidebarGroupReveal(
            generation: 2, worktreeIDs: [UUID()], remoteID: nil,
            groups: [SidebarGroupID(owner: .repository(repoID), kind: .remote)])
        let previous = SidebarGroupReveal(
            generation: 1, worktreeIDs: [UUID()], remoteID: nil, groups: [])

        // The initial mount reveals as navigation, whatever came before.
        #expect(SidebarReveal.baseline(previous: nil, reveal: reveal, hasRevealed: false) == nil)
        #expect(SidebarReveal.baseline(previous: previous, reveal: reveal, hasRevealed: false) == nil)
        // After it, a missing previous compares the reveal against itself…
        #expect(SidebarReveal.baseline(previous: nil, reveal: reveal, hasRevealed: true) == reveal)
        // …and a real previous is handed through unchanged.
        #expect(SidebarReveal.baseline(previous: previous, reveal: reveal, hasRevealed: true) == previous)
    }

    // MARK: Helpers

    private static func makeState(_ defaults: UserDefaults) -> AppState {
        let state = AppState(userDefaults: defaults)
        let repo = Repo(path: "/tmp/acme", displayName: "acme")
        state.repos = [repo]
        state.worktrees = [repo.id: [
            Worktree(repoID: repo.id, name: "main", displayName: "main", branch: "main",
                     path: "/tmp/acme", status: .main, tmuxServer: "acme"),
            Worktree(repoID: repo.id, name: "feature", displayName: "feature", branch: "feature",
                     path: "/tmp/acme-feature", tmuxServer: "acme"),
        ]]
        return state
    }

    private static func nativeRoots<Root: View>(_ host: OffscreenHost<Root>) -> [NSView] {
        host.descendants(NSView.self).filter { $0.identifier == NativeSidebarView.rootViewIdentifier }
    }

    private static func tablesOutsideNativeRoot<Root: View>(_ host: OffscreenHost<Root>) -> [NSTableView] {
        let roots = nativeRoots(host)
        return host.descendants(NSTableView.self).filter { table in
            !roots.contains { table.isDescendant(of: $0) }
        }
    }
}
