import AppKit
import Foundation
import SwiftUI
import Testing
@testable import TBDApp
import TBDShared

// Tier 1: deterministic, in-process state and bare AppKit objects. No
// subprocess, no network, no clock, no suspension point — every call here is
// synchronous, so unlike `RemoteAttachPagerWiringTests` this suite needs no
// bounded-time trait.

/// The diagnosis-tab lifecycle of `RemoteAttachPager` — the policy that decides
/// whether a mounted tab is a live terminal or a `RemoteAttachDiagnosisView`,
/// and what happens to a diagnosis tab on every later render.
///
/// **What this pins that nothing else does.** `RemoteAttachPreflightTests`
/// asserts the pure `resolve` function; `RemoteAttachPagerWiringTests` asserts
/// the mount-set diff with a stub `makeItem`. Neither reaches the policy that
/// joins them, and that policy carries the promise the diagnosis view makes to
/// the user — "TBD re-checks this automatically — no need to reopen the
/// session". Without it a failed preflight is a permanent dead pane: the tab is
/// created once per selection and kept, so what it concluded on first mount
/// would be what it showed forever. This suite goes red if the step-0
/// re-resolve is dropped, if the `makeItem` branch mounts the wrong kind of
/// tab, or if `Coordinator.diagnosed` stops tracking exactly the diagnosis tabs
/// that are on screen.
///
/// **Why it calls `RemoteAttachPager.update`.** `updateNSViewController` takes
/// a SwiftUI `Context`, which has no public initializer. `update` is its whole
/// body, with the two things it needs from the environment passed in: the
/// resolver (here the real `RemoteAttachPreflight.resolve` over a real
/// `AppState` registry, with only the filesystem probe stubbed) and the
/// terminal-controller factory (here a bare `NSViewController`, because the
/// production one needs `AppearanceSettings`, which would resolve
/// `UserDefaults.standard` — root `CLAUDE.md`, "Tests must not touch ~/tbd" —
/// and put a real provider `attach` spawn behind a tier-1 test).
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite, for the same reason as the neighbouring suite.
@MainActor
@Suite("Remote attach pager diagnosis tabs")
struct RemoteAttachPagerDiagnosisTests {
    private static let providerName = "acme"
    private static let providerConfig = RemoteProviderConfig(name: "acme", exec: "/opt/acme/bin/acme")

    private static let s1 = RemoteSessionSelection(provider: providerName, sessionID: "s1")
    private static let s2 = RemoteSessionSelection(provider: providerName, sessionID: "s2")

    /// What the preflight says about `providerConfig` when its executable
    /// cannot be found / run — spelled the way `resolve` builds it.
    private static var missing: RemoteAttachPreflight.Diagnosis {
        .executableMissing(
            provider: providerName,
            command: RemoteProviderIdentityPresentation.commandLine(providerConfig))
    }
    private static var notRunnable: RemoteAttachPreflight.Diagnosis {
        .executableNotRunnable(
            provider: providerName,
            command: RemoteProviderIdentityPresentation.commandLine(providerConfig))
    }

    private func key(_ selection: RemoteSessionSelection, _ generation: Int = 0) -> RemoteAttachMountKey {
        RemoteAttachMountKey(selection: selection, generation: generation)
    }

    /// One pager's worth of state: the tab view controller and coordinator that
    /// SwiftUI would keep alive across renders, plus the registry the resolver
    /// reads and the terminal controllers `update` asked to have built.
    @MainActor
    final class Harness {
        let state: AppState
        let vc: NSTabViewController
        let coordinator = RemoteAttachPager.Coordinator()

        /// What the filesystem probe reports for every provider's executable.
        /// The only part of `RemoteAttachPreflight.resolve` this suite stubs.
        var executable: RemoteAttachPreflight.ExecutableStatus = .runnable

        /// Every live terminal controller `update` built, in order.
        private(set) var builtTerminals: [(key: RemoteAttachMountKey, controller: NSViewController)] = []

        init(state: AppState) {
            self.state = state
            let vc = NSTabViewController()
            vc.tabStyle = .unspecified
            vc.transitionOptions = []
            self.vc = vc
            registerProvider()
            for id in ["s1", "s2"] {
                state.remoteSessions.append(RemoteSessionInfo(
                    provider: RemoteAttachPagerDiagnosisTests.providerName,
                    payload: RemoteSessionPayload(id: id, state: .running),
                    gone: false, dismissed: false, lastSeen: Date()))
            }
        }

        /// `described: false` registers a provider whose `describe` has not
        /// succeeded yet, so what it supports is not known.
        func registerProvider(described: Bool = true) {
            unregisterProvider()
            state.remoteProviders.append(RemoteProviderStatus(
                config: RemoteAttachPagerDiagnosisTests.providerConfig,
                describe: described
                    ? ProviderDescribe(
                        name: RemoteAttachPagerDiagnosisTests.providerName, capabilities: ["attach", "log"])
                    : nil,
                health: described ? .ok : .error,
                errorMessage: nil, remediationLabel: nil, remediationCommand: nil))
        }

        func unregisterProvider() {
            state.remoteProviders.removeAll { $0.config.name == RemoteAttachPagerDiagnosisTests.providerName }
        }

        /// One render. `resolve` overrides the real preflight for the one test
        /// that has to script the answer.
        func update(
            mounts: [RemoteAttachMountKey],
            resolve override: ((RemoteSessionSelection) -> RemoteAttachPreflight.Diagnosis)? = nil
        ) {
            let resolver: (RemoteSessionSelection) -> RemoteAttachPreflight.Diagnosis = override ?? { selection in
                RemoteAttachPreflight.resolve(
                    selection: selection,
                    providers: self.state.remoteProviders,
                    sessions: self.state.remoteSessions,
                    probe: { _ in self.executable })
            }
            RemoteAttachPager.update(
                vc,
                coordinator: coordinator,
                mounts: mounts,
                activeSelection: nil,
                appState: state,
                resolve: resolver,
                makeTerminalController: { key, _ in
                    let controller = NSViewController()
                    controller.view = NSView(frame: .zero)
                    self.builtTerminals.append((key, controller))
                    return controller
                })
        }

        var tabs: [NSTabViewItem] { vc.tabViewItems }

        func tab(for selection: RemoteSessionSelection) -> NSTabViewItem? {
            tabs.first { ($0.identifier as? RemoteAttachMountKey)?.selection == selection }
        }

        /// The diagnosis a tab is showing, or nil when it is anything other
        /// than a diagnosis view (a live terminal).
        func shownDiagnosis(_ item: NSTabViewItem?) -> RemoteAttachPreflight.Diagnosis? {
            (item?.viewController as? NSHostingController<RemoteAttachDiagnosisView>)?.rootView.diagnosis
        }

        /// Whether a tab is the live terminal `update` built for `key`.
        func isLiveTerminal(_ item: NSTabViewItem?, for key: RemoteAttachMountKey) -> Bool {
            guard let item else { return false }
            return builtTerminals.contains { $0.key == key && $0.controller === item.viewController }
        }
    }

    private func withHarness(_ body: (Harness) -> Void) {
        let suiteName = "TBDAppTests.RemoteAttachPagerDiagnosis.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        body(Harness(state: AppState(userDefaults: defaults)))
    }

    // MARK: - Which kind of tab a key gets

    /// The `makeItem` branch. Reddens if an unresolvable key returns no item
    /// again (a blank pane), or builds a terminal anyway, or mounts the
    /// diagnosis without recording it — an unrecorded diagnosis is never
    /// re-resolved, which is the permanent dead pane.
    @Test("a failing preflight mounts a diagnosis tab and records what it showed")
    func failingPreflightMountsADiagnosisTab() {
        withHarness { h in
            h.executable = .missing

            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.tabs.first?.identifier as? RemoteAttachMountKey == key(Self.s1))
            #expect(h.shownDiagnosis(h.tabs.first) == Self.missing)
            #expect(h.builtTerminals.isEmpty, "a diagnosed selection must not spawn anything")
            #expect(h.coordinator.diagnosed == [Self.s1: Self.missing])
        }
    }

    /// The other side of the same branch. Reddens if a resolvable key mounts
    /// a diagnosis view, and if it is recorded in `diagnosed` — which would
    /// subject a live PTY to the step-0 teardown.
    @Test("a passing preflight mounts a live terminal and records nothing")
    func passingPreflightMountsALiveTerminal() {
        withHarness { h in
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.isLiveTerminal(h.tabs.first, for: key(Self.s1)))
            #expect(h.shownDiagnosis(h.tabs.first) == nil)
            #expect(h.tabs.first?.identifier as? RemoteAttachMountKey == key(Self.s1))
            #expect(h.coordinator.diagnosed.isEmpty)
        }
    }

    // MARK: - Re-resolving a diagnosis tab

    /// The self-healing path: what keeps a failed attach from becoming a
    /// permanent dead pane. Reddens if step 0 is dropped (the diagnosis tab
    /// would survive the fix), or if it removes the tab without the add loop
    /// rebuilding it (the pane would go blank).
    @Test("a diagnosis tab is replaced by a live terminal once the preflight passes")
    func diagnosisTabIsReplacedByALiveTerminalWhenPreflightPasses() {
        withHarness { h in
            h.executable = .missing
            h.update(mounts: [key(Self.s1)])
            let diagnosisTab = h.tabs.first
            #expect(h.shownDiagnosis(diagnosisTab) == Self.missing)

            h.executable = .runnable
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.tabs.first !== diagnosisTab, "the diagnosis tab is torn down, not kept")
            #expect(h.isLiveTerminal(h.tabs.first, for: key(Self.s1)))
            #expect(h.tabs.first?.identifier as? RemoteAttachMountKey == key(Self.s1))
            #expect(h.builtTerminals.count == 1)
            #expect(h.coordinator.diagnosed.isEmpty, "a live terminal is not a diagnosis tab")
        }
    }

    /// The same path through the registry rather than the filesystem: the
    /// diagnosis text for an unregistered provider says to re-register it, and
    /// the claim "no need to reopen the session" has to hold for that fix too.
    @Test("registering the missing provider replaces its diagnosis tab with a live terminal")
    func registeringTheProviderReplacesTheDiagnosisTab() {
        withHarness { h in
            h.unregisterProvider()
            h.update(mounts: [key(Self.s1)])
            #expect(h.shownDiagnosis(h.tabs.first) == .providerNotRegistered(provider: Self.providerName))

            h.registerProvider()
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.isLiveTerminal(h.tabs.first, for: key(Self.s1)))
            #expect(h.coordinator.diagnosed.isEmpty)
        }
    }

    /// The third way a diagnosis heals, and the one where the first answer was
    /// never a refusal: a provider that has not been described yet is "not
    /// known", not "declined attach", and the tab it gets is replaced by the
    /// live terminal when `describe` lands, without reopening the session.
    @Test("a tab for a provider that has not been described yet becomes a terminal once it is")
    func unknownCapabilitiesHealWhenDescribeLands() {
        withHarness { h in
            h.registerProvider(described: false)
            h.update(mounts: [key(Self.s1)])

            #expect(h.shownDiagnosis(h.tabs.first) == .capabilitiesUnknown(provider: Self.providerName))
            #expect(h.builtTerminals.isEmpty)

            h.registerProvider(described: true)
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.isLiveTerminal(h.tabs.first, for: key(Self.s1)))
            #expect(h.coordinator.diagnosed.isEmpty)
        }
    }

    /// Reddens if step 0 stops comparing and tears every diagnosis tab down on
    /// every render: the tab would be rebuilt (a new instance) each time, and
    /// a SwiftUI view that is rebuilt per render flickers and loses selection
    /// and scroll state.
    @Test("a diagnosis tab is left alone while the preflight gives the same answer")
    func diagnosisTabStaysWhilePreflightStillFails() {
        withHarness { h in
            h.executable = .missing
            h.update(mounts: [key(Self.s1)])
            let first = h.tabs.first

            h.update(mounts: [key(Self.s1)])
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.tabs.first === first, "an unchanged diagnosis is not rebuilt")
            #expect(h.shownDiagnosis(h.tabs.first) == Self.missing)
            #expect(h.builtTerminals.isEmpty, "still failing: nothing may spawn")
            #expect(h.coordinator.diagnosed == [Self.s1: Self.missing])
        }
    }

    /// Still failing, but for a different reason: the pane must say the new
    /// reason (the old text would tell the user to fix something already
    /// fixed), and the record must follow, or the next render would compare
    /// against a diagnosis no longer on screen.
    @Test("a diagnosis tab is rebuilt when the preflight fails for a different reason")
    func diagnosisTabFollowsAChangedFailure() {
        withHarness { h in
            h.executable = .missing
            h.update(mounts: [key(Self.s1)])
            let first = h.tabs.first
            #expect(h.shownDiagnosis(first) == Self.missing)

            h.executable = .notExecutable
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.tabs.first !== first)
            #expect(h.shownDiagnosis(h.tabs.first) == Self.notRunnable)
            #expect(h.builtTerminals.isEmpty)
            #expect(h.coordinator.diagnosed == [Self.s1: Self.notRunnable])

            // And the record is the new one: another render with the same
            // answer leaves this rebuilt tab alone.
            let second = h.tabs.first
            h.update(mounts: [key(Self.s1)])
            #expect(h.tabs.first === second)
        }
    }

    /// The reason step 0 only looks at diagnosis tabs. A live terminal owns a
    /// PTY; if the provider's registration momentarily looks different the
    /// connection must survive it. Reddens if step 0 widens to every mounted
    /// tab, which would kill and respawn the session on a transient registry
    /// blip.
    @Test("a live terminal tab is never torn down because the preflight changed")
    func liveTerminalIsNotReResolved() {
        withHarness { h in
            h.update(mounts: [key(Self.s1)])
            let live = h.tabs.first
            #expect(h.isLiveTerminal(live, for: key(Self.s1)))

            h.executable = .missing
            h.unregisterProvider()
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.tabs.first === live)
            #expect(h.builtTerminals.count == 1, "the connection is kept, not respawned")
            #expect(h.coordinator.diagnosed.isEmpty)
        }
    }

    /// Both kinds side by side: only the failing selection is tracked, and
    /// fixing it replaces just that tab.
    @Test("only the failing selection is tracked and re-resolved among mixed tabs")
    func onlyTheDiagnosedSelectionIsTrackedAmongMixedTabs() {
        withHarness { h in
            // Same registration for both sessions, so give each its own
            // outcome by scripting the resolver: s1 resolves, s2 does not.
            let ready = RemoteAttachPreflight.Diagnosis.ready(Self.providerConfig)
            h.update(mounts: [key(Self.s1), key(Self.s2)], resolve: { $0 == Self.s1 ? ready : Self.missing })

            #expect(h.isLiveTerminal(h.tab(for: Self.s1), for: key(Self.s1)))
            #expect(h.shownDiagnosis(h.tab(for: Self.s2)) == Self.missing)
            #expect(h.coordinator.diagnosed == [Self.s2: Self.missing])
            let s1Tab = h.tab(for: Self.s1)

            h.update(mounts: [key(Self.s1), key(Self.s2)], resolve: { _ in ready })

            #expect(h.tabs.count == 2)
            #expect(h.tab(for: Self.s1) === s1Tab, "the other session's terminal is untouched")
            #expect(h.isLiveTerminal(h.tab(for: Self.s2), for: key(Self.s2)))
            #expect(h.builtTerminals.map(\.key) == [key(Self.s1), key(Self.s2)])
            #expect(h.coordinator.diagnosed.isEmpty)
        }
    }

    // MARK: - `diagnosed` bookkeeping

    /// The cleanup claim: an entry for a selection that left the mount set is
    /// dropped, one entry at a time, and the dictionary empties with the last.
    /// Reddens if the post-reconcile prune is dropped (the dictionary only
    /// ever grows) or prunes by something other than the selection (it would
    /// drop entries for tabs still on screen).
    @Test("diagnosed entries are dropped when their tabs leave the mount set")
    func diagnosedEntriesAreCleanedUpWhenTabsGoAway() {
        withHarness { h in
            h.executable = .missing
            h.update(mounts: [key(Self.s1), key(Self.s2)])
            #expect(h.tabs.count == 2)
            #expect(Set(h.coordinator.diagnosed.keys) == [Self.s1, Self.s2])

            h.update(mounts: [key(Self.s2)])

            #expect(h.tabs.count == 1)
            #expect(h.tab(for: Self.s1) == nil)
            #expect(h.tab(for: Self.s2) != nil)
            #expect(h.coordinator.diagnosed == [Self.s2: Self.missing])

            h.update(mounts: [])

            #expect(h.tabs.isEmpty)
            #expect(h.coordinator.diagnosed.isEmpty)
        }
    }

    /// A selection that is detached and later re-attached starts from
    /// nothing: no leftover record may suppress the fresh diagnosis tab it
    /// gets, and no stale one may make the first render tear it down.
    @Test("a selection re-mounted after leaving is diagnosed afresh")
    func aRemountedSelectionIsDiagnosedAfresh() {
        withHarness { h in
            h.executable = .missing
            h.update(mounts: [key(Self.s1)])
            h.update(mounts: [])
            #expect(h.coordinator.diagnosed.isEmpty)

            h.executable = .notExecutable
            h.update(mounts: [key(Self.s1)])

            #expect(h.tabs.count == 1)
            #expect(h.shownDiagnosis(h.tabs.first) == Self.notRunnable)
            #expect(h.coordinator.diagnosed == [Self.s1: Self.notRunnable])
        }
    }

    /// `diagnosed` names diagnosis tabs and nothing else. A reconnect swaps a
    /// selection's old key out and its replacement in within ONE update, and
    /// the preflight can change its mind between step 0's look and the
    /// replacement's own (it reads the filesystem). If the replacement then
    /// resolves, the record of the old diagnosis must not survive it: the next
    /// render would see the live terminal's selection "diagnosed", find the
    /// answer changed, and tear the fresh PTY down. The resolver is scripted
    /// because the interleaving cannot be produced deterministically with the
    /// real filesystem probe.
    @Test("a diagnosis record does not outlive the diagnosis tab it described")
    func staleDiagnosisRecordDoesNotKillALaterTerminal() {
        withHarness { h in
            h.executable = .missing
            h.update(mounts: [key(Self.s1, 0)])
            #expect(h.coordinator.diagnosed == [Self.s1: Self.missing])

            // Generation 0 -> 1. Step 0 still sees the old answer; the
            // replacement's own resolve sees the fix.
            var answers: [RemoteAttachPreflight.Diagnosis] = [Self.missing, .ready(Self.providerConfig)]
            h.update(mounts: [key(Self.s1, 1)], resolve: { _ in answers.removeFirst() })

            #expect(h.tabs.count == 1)
            #expect(h.isLiveTerminal(h.tabs.first, for: key(Self.s1, 1)))
            #expect(h.coordinator.diagnosed.isEmpty)

            // The very next render, answering ready as before: the terminal
            // that was just mounted is left alone.
            let live = h.tabs.first
            h.executable = .runnable
            h.update(mounts: [key(Self.s1, 1)])

            #expect(h.tabs.first === live)
            #expect(h.builtTerminals.count == 1, "the terminal is not torn down and respawned")
        }
    }
}
