import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

// Tier 2: hosts real SwiftUI in an `NSHostingView` and pumps the run loop in
// bounded slices. No subprocesses, no `~/tbd`; every `AppState` and every
// `@AppStorage` store is a throwaway `UserDefaults` suite.
//
// WHAT THIS FILE PINS
//
// `AppState` is `@Observable`, so a view re-evaluates only when a property it
// actually read changes. Two things have to hold for that to be true in
// practice, and neither is visible to a model-layer assertion:
//
//   1. A write to a property a view does not read must not re-evaluate it.
//      Under `ObservableObject` this was false by construction —
//      `objectWillChange` was object-wide — so this file's first suite fails
//      against the pre-migration tree.
//   2. A view served from one of `AppState`'s memo caches must keep its
//      dependency on the cache's tracked source. SwiftUI rebuilds a view's
//      dependency set from what each `body` evaluation actually read, so a
//      body served entirely from a warm cache reads nothing tracked and drops
//      the dependency — after which a real change does not reach it. A naive
//      conversion has exactly this bug; `AppStateWarmCacheDependencySourceTests`
//      at the foot of this file fails against it.
//
// Counts are compared before-and-after, never against an exact number: SwiftUI
// may legitimately evaluate a body more than once for one change.

// MARK: - Instruments

/// Body evaluations of one probe view. A reference type so the count survives
/// the view struct being recreated.
@MainActor
final class BodyEvaluationCounter {
    private(set) var count = 0
    /// Returns a value so the call can sit in a `@ViewBuilder` as `let _ = `.
    @discardableResult
    func bump() -> Int {
        count += 1
        return count
    }
}

/// Reads exactly one `AppState` property, directly.
private struct DirectReadProbe: View {
    let counter: BodyEvaluationCounter
    @Environment(AppState.self) private var appState

    var body: some View {
        let _ = counter.bump()
        Text("repos: \(appState.repos.count)")
    }
}

/// Reads `AppState` only through a *method* backed by a memo cache, and
/// composes a child view from the result — the shape the sidebar actually has,
/// and the one a `withObservationTracking` assertion over the model cannot see.
private struct ComposedReadProbe: View {
    let parentID: UUID
    let counter: BodyEvaluationCounter
    @Environment(AppState.self) private var appState

    var body: some View {
        let _ = counter.bump()
        VStack(alignment: .leading, spacing: 0) {
            ForEach(appState.children(of: parentID)) { child in
                Text(child.displayName)
            }
        }
    }
}

/// Reads one tracked property directly AND one only through the memo-cached
/// `children(of:)`. The direct read is the lever: writing it forces a
/// re-evaluation whose `children(of:)` call is served from the warm cache, and
/// the counter proves that re-evaluation happened rather than assuming it.
private struct CacheTrapProbe: View {
    let parentID: UUID
    let counter: BodyEvaluationCounter
    @Environment(AppState.self) private var appState

    var body: some View {
        let _ = counter.bump()
        VStack(alignment: .leading, spacing: 0) {
            Text(appState.alertMessage ?? "-")
            ForEach(appState.children(of: parentID)) { child in
                Text(child.displayName)
            }
        }
    }
}

/// Reads only `@AppStorage`. Used as the vacuity guard in the cache suite: it
/// proves a defaults flip really did invalidate the views that read that key,
/// so a passing cache assertion cannot be one where nothing re-evaluated.
private struct AppStorageProbe: View {
    let counter: BodyEvaluationCounter
    @AppStorage(AppState.chevronBeforeProjectNameKey)
    private var chevronBeforeProjectName: Bool = AppState.chevronBeforeProjectNameDefault

    var body: some View {
        let _ = counter.bump()
        Text(chevronBeforeProjectName ? "before" : "after")
    }
}

// MARK: - Harness

@MainActor
private struct HostedProbe {
    let state: AppState
    let defaults: UserDefaults
    let host: NSHostingView<AnyView>
    private let window: NSWindow

    init(state: AppState, defaults: UserDefaults, content: AnyView) {
        self.state = state
        self.defaults = defaults
        self.host = NSHostingView(rootView: content)
        host.frame = NSRect(x: 0, y: 0, width: 420, height: 600)
        window = NSWindow(
            contentRect: host.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
    }

    /// Let SwiftUI's scheduled update land, then force layout so any pending
    /// body evaluation actually runs. Bounded slices — never an unbounded wait.
    func pump() {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        host.layoutSubtreeIfNeeded()
    }

    func tearDown() {
        window.contentView = nil
    }
}

/// One `AppState` and one `@AppStorage` store, both throwaway suites, hosting
/// `content` in a borderless window. `UserDefaults.standard` on this unbundled
/// executable is the developer's real `TBDApp.plist` — see the root `CLAUDE.md`
/// — so the `.defaultAppStorage` leg matters as much as the `AppState` one.
@MainActor
private func withHostedProbe(
    _ content: @MainActor (AppState) -> AnyView,
    _ body: (HostedProbe) -> Void
) {
    let suiteName = "TBDAppTests.AppStateObservation.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defer { defaults.removePersistentDomain(forName: suiteName) }
    let state = AppState(userDefaults: defaults)

    // `.defaultAppStorage` on the whole tree, not per view: an `@AppStorage`
    // that fell through to `UserDefaults.standard` would read — and a test
    // that flips one would write — the developer's real `TBDApp.plist`.
    let probe = HostedProbe(
        state: state,
        defaults: defaults,
        content: AnyView(content(state).defaultAppStorage(defaults))
    )
    defer { probe.tearDown() }
    probe.pump()
    body(probe)
}

@MainActor
private func makeWorktree(
    id: UUID = UUID(),
    repoID: UUID?,
    parentWorktreeID: UUID? = nil,
    name: String,
    sortOrder: Int = 0
) -> Worktree {
    Worktree(
        id: id,
        repoID: repoID,
        name: name,
        displayName: name,
        branch: "main",
        path: "/tmp/\(name)",
        status: .active,
        tmuxServer: "test-server",
        sortOrder: sortOrder,
        parentWorktreeID: parentWorktreeID
    )
}

// MARK: - Per-property tracking

@MainActor
@Suite("A write reaches only the views that read that property")
struct AppStatePerPropertyTrackingTests {

    /// The core discriminator. Under `ObservableObject` every write to any of
    /// `AppState`'s ~104 published properties re-ran the body of every view
    /// observing the object, so the first assertion below could not hold. It is
    /// what this migration is for.
    ///
    /// The second half is the positive control: without it, a harness that had
    /// simply stopped detecting re-evaluation at all would pass the first half.
    @Test("an unrelated write leaves the body alone; a read one does not")
    func unrelatedWriteDoesNotReEvaluate() {
        let counter = BodyEvaluationCounter()
        withHostedProbe({ state in
            AnyView(DirectReadProbe(counter: counter).environment(state))
        }, { probe in
            let baseline = counter.count
            #expect(baseline > 0, "the probe never evaluated; the harness is not measuring anything")

            // `isConnected` is not read by `DirectReadProbe`.
            probe.state.isConnected = !probe.state.isConnected
            probe.pump()
            #expect(counter.count == baseline,
                    "a write to a property this view does not read re-evaluated it")

            // `repos` is.
            probe.state.repos = [Repo(id: UUID(), path: "/tmp/acme", displayName: "acme")]
            probe.pump()
            #expect(counter.count > baseline,
                    "a write to a property this view DOES read did not re-evaluate it")
        })
    }

    /// Same claim, but for a view whose only `AppState` read is through a
    /// method backed by a memo cache and composed into a child `ForEach`. The
    /// read-set as actually composed is the thing per-property tracking has to
    /// get right, and it is not inspectable from the model side.
    @Test("a composed, cache-served read-set tracks the same way")
    func composedReadSetTracksTheSameWay() {
        let counter = BodyEvaluationCounter()
        let repoID = UUID()
        let parentID = UUID()

        withHostedProbe({ state in
            state.worktrees = [repoID: [
                makeWorktree(id: parentID, repoID: repoID, name: "parent")
            ]]
            return AnyView(
                ComposedReadProbe(parentID: parentID, counter: counter).environment(state)
            )
        }, { probe in
            let baseline = counter.count
            #expect(baseline > 0, "the probe never evaluated; the harness is not measuring anything")

            probe.state.isConnected = !probe.state.isConnected
            probe.pump()
            #expect(counter.count == baseline,
                    "a write to a property this view does not read re-evaluated it")

            probe.state.worktrees[repoID]?.append(
                makeWorktree(repoID: repoID, parentWorktreeID: parentID, name: "child")
            )
            probe.pump()
            #expect(counter.count > baseline,
                    "adding a child did not re-evaluate the view that renders children")
        })
    }
}

// MARK: - The production sidebar composition

@MainActor
@Suite("The real sidebar subtree renders through the memo cache")
struct AppStateCacheDependencyTests {

    /// End-to-end shape: the production sidebar composition —
    /// `WorktreeSubtreeView`, which renders `WorktreeRowView` and recurses
    /// through `AppState.children(of:)` — grows a row when a child is added
    /// through the memo cache. Asserted on rendered height, because the bug
    /// class this guards against is stale UI and height is what a user sees.
    ///
    /// `WorktreeSubtreeView` is the interesting subject because `children(of:)`
    /// is its *only* route to `worktrees`; `RepoSectionView`, by contrast,
    /// indexes `appState.worktrees` directly in four computed properties, so it
    /// re-registers that dependency whatever the cache does.
    ///
    /// It does NOT discriminate against the missing `_ = worktrees` touch: the
    /// `@AppStorage` flip below is included as the unrelated re-evaluation the
    /// trap needs, and measurably does not force one on this view — the test
    /// passes either way. The discriminating assertion lives in
    /// ``AppStateWarmCacheDependencySourceTests``, which forces the
    /// re-evaluation through a tracked property and proves it happened.
    @Test("the real sidebar subtree renders a child added after its cache was warmed")
    func realSidebarSubtreeRendersAChildAddedThroughTheCache() {
        let storageCounter = BodyEvaluationCounter()
        let repoID = UUID()
        let parentID = UUID()

        withHostedProbe({ state in
            state.worktrees = [repoID: [
                makeWorktree(id: parentID, repoID: repoID, name: "parent")
            ]]
            return AnyView(
                VStack(alignment: .leading, spacing: 0) {
                    WorktreeSubtreeView(worktree: state.worktrees[repoID]![0],
                                        depth: 0,
                                        sectionRepoID: repoID)
                    AppStorageProbe(counter: storageCounter)
                }
                .frame(width: 420, alignment: .leading)
                .environment(state)
            )
        }, { probe in
            let coldHeight = probe.host.fittingSize.height
            #expect(coldHeight > 0, "the subtree never laid out; the harness is not measuring anything")

            // (2) Re-evaluate while the cache is warm, for a reason that has
            // nothing to do with `worktrees`.
            let beforeFlip = storageCounter.count
            probe.defaults.set(
                !AppState.chevronBeforeProjectNameDefault,
                forKey: AppState.chevronBeforeProjectNameKey
            )
            probe.pump()
            #expect(storageCounter.count > beforeFlip,
                    "the defaults flip invalidated nothing, so the cache was never re-served")

            // (3) A real change to the source the cache is derived from.
            probe.state.worktrees[repoID]?.append(
                makeWorktree(repoID: repoID, parentWorktreeID: parentID, name: "child")
            )
            probe.pump()

            #expect(probe.host.fittingSize.height > coldHeight,
                    "the new child row never appeared: the warm cache severed the worktrees dependency")
        })
    }
}

// MARK: - The warm-cache dependency trap, measured

@MainActor
@Suite("A cache-served evaluation would sever the worktrees dependency")
struct AppStateWarmCacheDependencySourceTests {

    /// The discriminating test for the `_ = worktrees` touch in
    /// `AppState.childrenIndex()`. Remove that line and this fails.
    ///
    /// Sequence, with every step proved rather than assumed: evaluate cold
    /// (fills `childrenIndexCache` and reads `worktrees`); write a property the
    /// probe reads *directly*, asserting the body count moved — so an
    /// evaluation demonstrably ran while the cache was warm, and its
    /// `children(of:)` call read nothing tracked; then write `worktrees`.
    ///
    /// Without the touch, that last write does not arrive: SwiftUI rebuilt the
    /// view's dependency set from the cache-served evaluation, which registered
    /// nothing. The view keeps rendering the old subtree — stale sidebar, no
    /// error anywhere.
    ///
    /// The lever matters. A re-evaluation forced through `@AppStorage` instead
    /// of through a tracked `AppState` property does *not* reproduce this, which
    /// is why the probe below reads `alertMessage` directly rather than relying
    /// on a defaults flip.
    @Test("a cache-warm re-evaluation costs the view its worktrees dependency without the fix")
    func warmReEvaluationKeepsTheDependency() {
        let counter = BodyEvaluationCounter()
        let repoID = UUID()
        let parentID = UUID()

        withHostedProbe({ state in
            state.worktrees = [repoID: [
                makeWorktree(id: parentID, repoID: repoID, name: "parent")
            ]]
            return AnyView(
                CacheTrapProbe(parentID: parentID, counter: counter).environment(state)
            )
        }, { probe in
            let cold = counter.count
            #expect(cold > 0, "the probe never evaluated; the harness is not measuring anything")

            probe.state.alertMessage = "forced"
            probe.pump()
            let warm = counter.count
            #expect(warm > cold,
                    "the forced re-evaluation did not happen, so the cache was never re-served")

            probe.state.worktrees[repoID]?.append(
                makeWorktree(repoID: repoID, parentWorktreeID: parentID, name: "child")
            )
            probe.pump()
            #expect(counter.count > warm,
                    "a worktrees write did not reach a view whose last evaluation was cache-served")
        })
    }

    /// The same claim at the primitive level, with no SwiftUI involved:
    /// `withObservationTracking` replaces its access list per call, so a
    /// cache-served read leaves it with nothing registered. Asserted separately
    /// from the hosted test so a future failure says which layer moved.
    @Test("withObservationTracking registers the dependency on a warm cache too")
    func rawTrackingKeepsTheDependencyOnAWarmCache() {
        withEmissionState { state in
            let repoID = UUID()
            let parentID = UUID()
            state.worktrees = [repoID: [
                makeWorktree(id: parentID, repoID: repoID, name: "parent")
            ]]

            // Cold: the fill reads `worktrees`, so the tracker fires.
            // `onChange` is `@Sendable`, so the flag lives in a reference box.
            let coldFired = BodyEvaluationCounter()
            withObservationTracking {
                _ = state.children(of: parentID)
            } onChange: {
                MainActor.assumeIsolated { _ = coldFired.bump() }
            }
            state.worktrees[repoID]?.append(
                makeWorktree(repoID: repoID, parentWorktreeID: parentID, name: "a")
            )
            #expect(coldFired.count > 0, "a cold-cache read did not register a dependency on worktrees")

            // Warm: re-read to refill, then arm again against the warm cache.
            _ = state.children(of: parentID)
            let warmFired = BodyEvaluationCounter()
            withObservationTracking {
                _ = state.children(of: parentID)
            } onChange: {
                MainActor.assumeIsolated { _ = warmFired.bump() }
            }
            state.worktrees[repoID]?.append(
                makeWorktree(repoID: repoID, parentWorktreeID: parentID, name: "b")
            )
            #expect(warmFired.count > 0,
                    "a warm-cache read registered no dependency on worktrees")
        }
    }

    /// `allWorktrees` is the other memoized getter and carries the same touch,
    /// over both of its sources. Asserted separately because its cache is
    /// invalidated by two `didSet`s, and a touch that covered only one of them
    /// would leave scratch-space churn silently undeliverable.
    @Test("allWorktrees keeps both dependencies on a warm cache")
    func allWorktreesKeepsBothDependenciesWarm() {
        withEmissionState { state in
            let repoID = UUID()
            state.worktrees = [repoID: [makeWorktree(repoID: repoID, name: "parent")]]
            state.scratchWorktrees = []

            for (label, mutate) in [
                ("worktrees", { state.worktrees[repoID]?.append(makeWorktree(repoID: repoID, name: "w")) }),
                ("scratchWorktrees", { state.scratchWorktrees.append(makeWorktree(repoID: nil, name: "s")) })
            ] as [(String, () -> Void)] {
                _ = state.allWorktrees  // warm the cache
                let fired = BodyEvaluationCounter()
                withObservationTracking {
                    _ = state.allWorktrees
                } onChange: {
                    MainActor.assumeIsolated { _ = fired.bump() }
                }
                mutate()
                #expect(fired.count > 0,
                        "a warm allWorktrees read registered no dependency on \(label)")
            }
        }
    }
}

// MARK: - Untracked bookkeeping behind a tracked question

@MainActor
@Suite("canCloseFocusedTab tracks the property that moves when focus does")
struct AppStateFocusedTabTrackingTests {

    /// `resolvedFocusedTabCloseContext()` answers "which tab would ⌘W close?"
    /// from three things Observation cannot see: `terminalFocusTargets` and
    /// `terminalTabCloseContexts` (both `@ObservationIgnored`) and
    /// `NSApp.keyWindow?.firstResponder` (not observable at all). Its one
    /// observable input is `focusedTabCloseContext`, which `TerminalPanelView`
    /// writes on every focus in and out — so that property is the proxy for a
    /// first-responder change, and the function has to read it on every path
    /// or the File ▸ Close Tab item registers no dependency on focus moving.
    ///
    /// The discriminator is a NON-EMPTY `terminalFocusTargets`: on the empty
    /// path the function returns `focusedTabCloseContext` anyway, so a test
    /// that left it empty would pass with the read removed. Remove the
    /// `let lastFocused = focusedTabCloseContext` line and this fails.
    @Test("a focus change still reaches canCloseFocusedTab once a terminal view has registered")
    func focusChangeReachesTheMenuItemWithRegisteredTerminals() {
        let suiteName = "TBDAppTests.FocusedTabTracking.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)

        let view = TBDTerminalView(
            frame: CGRect(x: 0, y: 0, width: 320, height: 240),
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: defaults)
        )
        view.resize(cols: 10, rows: 5)
        let terminalID = UUID()
        state.registerTerminalView(view, for: terminalID)
        #expect(!state.terminalFocusTargets.isEmpty,
                "the discriminating path needs a registered terminal view")

        let fired = BodyEvaluationCounter()
        withObservationTracking {
            _ = state.canCloseFocusedTab
        } onChange: {
            MainActor.assumeIsolated { _ = fired.bump() }
        }

        // What TerminalPanelView does when a terminal takes focus.
        state.focusedTabCloseContext = TabCloseContext(worktreeID: UUID(), tabID: UUID())

        #expect(fired.count > 0,
                "a focus change did not reach canCloseFocusedTab, so Close Tab can stay stale")
    }
}

