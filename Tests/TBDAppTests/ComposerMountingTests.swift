import AppKit
import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The composer's registration and focus plumbing — the parts of mounting that
/// are not layout.
///
/// The registry is the `TerminalFocusTarget` shape: a weak reference keyed by
/// terminal, so a torn-down pane cannot keep a view alive and a stale entry
/// cannot steal focus from a live one.
@MainActor
@Suite("composer mounting")
struct ComposerMountingTests {

    private func makeState() -> (AppState, String) {
        let suiteName = "ComposerMountingTests-\(UUID().uuidString)"
        return (AppState(userDefaults: UserDefaults(suiteName: suiteName)!), suiteName)
    }

    /// Polls for a registered waiter instead of trusting a single
    /// `Task.yield()` to have been enough hops for the child task below to
    /// reach its registration point. A single yield that happens not to be
    /// enough doesn't redden these tests — it silently produces the same
    /// `false` outcome a *real* regression would (the `noteSessionStart` call
    /// below finds nothing to release, cancellation resolves the waiter
    /// `false`), so a registration bug and a passing test look identical.
    /// Bounding the poll and `#require`-ing it caught means a registration
    /// failure fails fast and says so, rather than either hanging or passing
    /// for the wrong reason.
    private func waiterRegistered(
        _ state: AppState, terminalID: UUID, maxYields: Int = 1000
    ) async -> Bool {
        for _ in 0..<maxYields {
            if state.sessionStartWaiters[terminalID] != nil { return true }
            await Task.yield()
        }
        return false
    }

    @Test func registrationIsKeyedByTerminal() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let view = NSView()

        state.registerComposerView(view, for: id)
        #expect(state.composerFocusTargets[id]?.view === view)

        state.unregisterComposerView(view, for: id)
        #expect(state.composerFocusTargets[id] == nil)
    }

    /// A LATER registration wins, and an earlier view's teardown must not
    /// unregister it — the pane can be rebuilt while the old view is still
    /// deallocating.
    @Test func aStaleUnregisterDoesNotEvictTheLiveView() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let old = NSView(), new = NSView()

        state.registerComposerView(old, for: id)
        state.registerComposerView(new, for: id)
        state.unregisterComposerView(old, for: id)

        #expect(state.composerFocusTargets[id]?.view === new)
    }

    /// Unregistering a terminal that never registered is a no-op, not a crash:
    /// the composer's `onDisappear` runs for a view whose registration a later
    /// pane may already have replaced, or that never happened at all.
    @Test func unregisteringSomethingNeverRegisteredIsANoOp() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        state.unregisterComposerView(NSView(), for: UUID())
        #expect(state.composerFocusTargets.isEmpty)
    }

    /// The reference is weak: a pane that went away leaves no view behind.
    @Test func theRegistryHoldsTheViewWeakly() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        do {
            let view = NSView()
            state.registerComposerView(view, for: id)
            #expect(state.composerFocusTargets[id]?.view != nil)
        }
        #expect(state.composerFocusTargets[id]?.view == nil)
    }

    /// Focusing a terminal with no registered composer is a no-op, not a crash —
    /// Cmd+/ can be pressed with the transcript pane closed.
    @Test func focusingAnUnregisteredComposerIsANoOp() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        state.focusComposer(terminalID: UUID())
        #expect(state.composerFocusTargets.isEmpty)
    }

    /// `focusTranscript`'s fallback branch: no transcript table has registered
    /// for this terminal (Task 13 hasn't wired one in yet), so it resigns first
    /// responder instead of crashing on a nil lookup. A composer view with no
    /// window makes `view.window?.makeFirstResponder(nil)` a no-op through the
    /// optional chain, so the discriminating check is that the composer's own
    /// registration survives the call untouched.
    @Test func focusTranscriptFallsBackToResigningFirstResponderWhenNoneIsRegistered() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let composerView = NSView()
        state.registerComposerView(composerView, for: id)

        state.focusTranscript(terminalID: id)

        #expect(state.composerFocusTargets[id]?.view === composerView)
    }

    /// The Reveal Terminal action moves AppKit's first responder to the
    /// registered terminal view — the observable effect `revealTerminal`
    /// actually mutates (it touches no `AppState` property; the registry read
    /// is the only state involved).
    @Test func revealTerminalMakesTheTerminalViewFirstResponder() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        _ = NSApplication.shared
        let id = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: true)
        let view = TBDTerminalView(
            frame: window.contentLayoutRect,
            font: TBDTerminalView.defaultMonospaceFont,
            appearance: AppearanceSettings(defaults: UserDefaults(suiteName: suiteName)!))
        window.contentView?.addSubview(view)
        state.registerTerminalView(view, for: id)

        state.revealTerminal(terminalID: id)

        #expect(window.firstResponder === view)
    }

    // MARK: - The sending hold's release condition

    /// The composer's own spawn reports in, and the hold releases.
    @Test func aMatchingIncarnationReleasesTheHold() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let terminalID = UUID()
        let incarnation = UUID()

        async let started = state.awaitSessionStart(
            terminalID: terminalID, incarnationID: incarnation)
        try #require(await waiterRegistered(state, terminalID: terminalID))
        state.noteSessionStart(terminalID: terminalID, incarnationID: incarnation)
        #expect(await started)
        #expect(state.sessionStartWaiters[terminalID] == nil, "a released waiter is removed")
    }

    /// **The other half of the fix.** `wakeTerminalForComposer` mints its
    /// incarnation and returns before the daemon's refresh round trip
    /// completes, so a `SessionStart` can be accepted before the caller ever
    /// calls `awaitSessionStart`. Without a latch, that start reaches
    /// `noteSessionStart` with no waiter registered and is dropped — the
    /// later `awaitSessionStart` call then waits to its timeout for a start
    /// that already happened. `noteSessionStart` latches the incarnation
    /// regardless of whether anyone is waiting, and `awaitSessionStart`
    /// checks that latch before registering.
    @Test func aSessionStartBeforeTheWaiterStillReleases() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let terminalID = UUID()
        let incarnation = UUID()

        state.noteSessionStart(terminalID: terminalID, incarnationID: incarnation)
        let started = await state.awaitSessionStart(
            terminalID: terminalID, incarnationID: incarnation)

        #expect(started)
        #expect(state.sessionStartWaiters[terminalID] == nil, "no waiter was ever registered")
    }

    /// **The negative pair.** A latch holding a DIFFERENT incarnation must not
    /// short-circuit a later waiter for this one — the latch is scoped by
    /// exact incarnation, not "something started recently".
    @Test func aLatchedDifferentIncarnationDoesNotReleaseALaterWaiter() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let terminalID = UUID()
        let mine = UUID()

        state.noteSessionStart(terminalID: terminalID, incarnationID: UUID())

        let task = Task { @MainActor in
            await state.awaitSessionStart(terminalID: terminalID, incarnationID: mine)
        }
        try #require(await waiterRegistered(state, terminalID: terminalID))
        #expect(state.sessionStartWaiters[terminalID]?.count == 1, "still waiting")

        task.cancel()
        #expect(await task.value == false)
    }

    /// **The load-bearing negative.** Another spawn's SessionStart on the same
    /// terminal — a competing wake, a recapture, a person typing
    /// `claude --resume` in the pane — leaves the hold held.
    @Test func anotherIncarnationDoesNotRelease() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let terminalID = UUID()
        let mine = UUID()

        let task = Task { @MainActor in
            await state.awaitSessionStart(terminalID: terminalID, incarnationID: mine)
        }
        try #require(await waiterRegistered(state, terminalID: terminalID))
        state.noteSessionStart(terminalID: terminalID, incarnationID: UUID())
        #expect(state.sessionStartWaiters[terminalID]?.count == 1, "still waiting")

        // Cancellation is the only other way out, and it must answer false
        // rather than hang — the coordinator's task group awaits this child.
        task.cancel()
        #expect(await task.value == false)
    }

    /// A SessionStart carrying NO incarnation releases nobody. A worktree's
    /// first spawn and an archive restore both produce one.
    @Test func anIncarnationlessSessionStartReleasesNobody() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let terminalID = UUID()
        let mine = UUID()

        let task = Task { @MainActor in
            await state.awaitSessionStart(terminalID: terminalID, incarnationID: mine)
        }
        try #require(await waiterRegistered(state, terminalID: terminalID))
        state.noteSessionStart(terminalID: terminalID, incarnationID: nil)
        #expect(state.sessionStartWaiters[terminalID]?.count == 1)
        task.cancel()
        #expect(await task.value == false)
    }

    /// Another terminal's SessionStart is not this terminal's business.
    @Test func anotherTerminalsSessionStartReleasesNobody() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let mine = UUID(), incarnation = UUID()

        let task = Task { @MainActor in
            await state.awaitSessionStart(terminalID: mine, incarnationID: incarnation)
        }
        try #require(await waiterRegistered(state, terminalID: mine))
        state.noteSessionStart(terminalID: UUID(), incarnationID: incarnation)
        #expect(state.sessionStartWaiters[mine]?.count == 1)
        task.cancel()
        #expect(await task.value == false)
    }

    // MARK: - What the wake reports

    private func stateWakingWith(
        _ result: Result<TerminalWakeResult, any Error>
    ) -> (AppState, String) {
        let (state, suiteName) = makeState()
        state.composerWakeSender = { _, _, _, _ in try result.get() }
        return (state, suiteName)
    }

    @Test func aWokenWakeReportsItsIncarnation() async throws {
        let incarnation = UUID()
        let (state, suiteName) = stateWakingWith(
            .success(TerminalWakeResult(woken: true, sessionIncarnationID: incarnation)))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let reply = await state.wakeTerminalForComposer(
            terminalID: UUID(), worktreeID: UUID(), prompt: "hi")
        #expect(reply == .woken(incarnationID: incarnation))
    }

    /// `woken: false` is a no-op, never a success: the prompt went nowhere.
    @Test func aNoOpWakeIsReportedAsSuch() async throws {
        let (state, suiteName) = stateWakingWith(.success(TerminalWakeResult(woken: false)))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let reply = await state.wakeTerminalForComposer(
            terminalID: UUID(), worktreeID: UUID(), prompt: "hi")
        #expect(reply == .noOp)
    }

    @Test func aFailedWakeCarriesItsMessage() async throws {
        let (state, suiteName) = stateWakingWith(
            .failure(DaemonClientError.rpcError("session gone", code: nil)))
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let reply = await state.wakeTerminalForComposer(
            terminalID: UUID(), worktreeID: UUID(), prompt: "hi")
        guard case .failed(let message) = reply else {
            Issue.record("expected a failure, got \(reply)")
            return
        }
        #expect(message.contains("session gone"))
    }

    // MARK: - The mount decision

    private func terminal(
        worktreeID: UUID,
        id: UUID = UUID(),
        kind: TerminalKind? = .claude,
        hibernatedAt: Date? = nil
    ) -> Terminal {
        Terminal(
            id: id, worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            kind: kind, hibernatedAt: hibernatedAt,
            hibernateReason: hibernatedAt == nil ? nil : .manual)
    }

    private func worktree(id: UUID = UUID(), remote: Bool = false) -> Worktree {
        let location: WorktreeLocation =
            remote ? .remote(provider: "test", sessionID: "s1") : .local
        return Worktree(
            id: id, repoID: UUID(), name: "wt", displayName: "WT", branch: "main",
            path: location.storagePath ?? "/tmp/wt", status: .active,
            tmuxServer: "test-server", location: location)
    }

    private func mount(
        terminal: Terminal?, worktree: Worktree?, enabled: Bool = true
    ) -> TableTranscriptPaneView.ComposerMount? {
        TableTranscriptPaneView.composerMount(
            terminal: terminal, worktree: worktree, composerEnabled: enabled)
    }

    /// **The flag-off branch.** With the daemon capability off the pane renders
    /// exactly as it did before: no composer is built at all, so
    /// `MessageComposerView` — which reads `AppState` non-optionally from the
    /// environment — is never evaluated.
    @Test func theFlagOffMountsNoComposer() {
        let wt = worktree()
        #expect(mount(terminal: terminal(worktreeID: wt.id), worktree: wt, enabled: false) == nil)
    }

    /// **The flag-on branch.** A live Claude terminal on a local worktree gets a
    /// running composer, and the mount carries the `LocalWorktree` the view's
    /// initializer takes.
    @Test func aLiveClaudeTerminalOnALocalWorktreeMounts() throws {
        let wt = worktree()
        let decision = try #require(mount(terminal: terminal(worktreeID: wt.id), worktree: wt))
        #expect(decision.state == .running)
        #expect(decision.worktree.id == wt.id)
    }

    /// A remote worktree has no composer, and it cannot even produce the
    /// `LocalWorktree` the view requires — the two facts agree.
    @Test func aRemoteWorktreeMountsNoComposer() {
        let wt = worktree(remote: true)
        #expect(mount(terminal: terminal(worktreeID: wt.id), worktree: wt) == nil)
    }

    @Test func aNonClaudeTerminalMountsNoComposer() {
        let wt = worktree()
        #expect(mount(terminal: terminal(worktreeID: wt.id, kind: .codex), worktree: wt) == nil)
        #expect(mount(terminal: terminal(worktreeID: wt.id, kind: .shell), worktree: wt) == nil)
        #expect(mount(terminal: terminal(worktreeID: wt.id, kind: nil), worktree: wt) == nil)
    }

    /// The pane can render before either row is cached — the transcript comes
    /// from the daemon, the rows from their own RPCs — so both absences are
    /// real states rather than impossible ones.
    @Test func aMissingRowMountsNoComposer() {
        let wt = worktree()
        #expect(mount(terminal: nil, worktree: wt) == nil)
        #expect(mount(terminal: terminal(worktreeID: wt.id), worktree: nil) == nil)
    }

    /// A parked session still gets a composer: sending resumes it. This is the
    /// case a `state != .hidden` gate must keep and an `isEnabled` gate would
    /// have dropped.
    @Test func aHibernatedClaudeTerminalStillMounts() throws {
        let wt = worktree()
        let decision = try #require(mount(
            terminal: terminal(worktreeID: wt.id, hibernatedAt: Date()), worktree: wt))
        #expect(decision.state == .notRunning(exited: false))
    }

    // MARK: - The transcript as a focus target

    @Test func transcriptRegistrationIsKeyedByTerminal() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let table = NSTableView()

        state.registerTranscriptView(table, for: id)
        #expect(state.transcriptFocusTargets[id]?.view === table)

        state.unregisterTranscriptView(table, for: id)
        #expect(state.transcriptFocusTargets[id] == nil)
    }

    /// Same newer-wins rule as the composer registry, and for the same reason:
    /// a session rollover rebuilds the table while the old one is still
    /// deallocating.
    @Test func aStaleTranscriptUnregisterDoesNotEvictTheLiveView() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let id = UUID()
        let old = NSTableView(), new = NSTableView()

        state.registerTranscriptView(old, for: id)
        state.registerTranscriptView(new, for: id)
        state.unregisterTranscriptView(old, for: id)

        #expect(state.transcriptFocusTargets[id]?.view === new)
    }

    /// **Escape's destination.** With a transcript table registered,
    /// `focusTranscript` moves AppKit's first responder onto it rather than
    /// taking the resign-first-responder fallback the earlier test pins.
    @Test func focusTranscriptMakesTheRegisteredTableFirstResponder() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        _ = NSApplication.shared
        let id = UUID()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled], backing: .buffered, defer: true)
        // A column-less NSTableView refuses first responder outright, so the
        // fixture has to be shaped like the real one — `TableTranscriptView`
        // adds exactly one column before the table is ever shown.
        let table = NSTableView(frame: window.contentLayoutRect)
        table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c")))
        window.contentView?.addSubview(table)
        state.registerTranscriptView(table, for: id)

        state.focusTranscript(terminalID: id)

        #expect(
            window.firstResponder === table,
            "focus went to \(String(describing: window.firstResponder)) instead")
    }

    // MARK: - Which terminal the menu commands act on

    private func liveTranscriptTab(terminalID: UUID) -> TBDShared.Tab {
        let tabID = UUID()
        return TBDShared.Tab(
            id: tabID,
            content: .liveTranscript(id: tabID, terminalID: terminalID),
            label: "Transcript")
    }

    private func terminalTab(terminalID: UUID) -> TBDShared.Tab {
        TBDShared.Tab(
            id: UUID(), content: .terminal(terminalID: terminalID), label: "Agent")
    }

    /// **⌘/ from where somebody actually presses it.** Driven through the
    /// production state only: a selected worktree, a `.liveTranscript` tab that
    /// `resolvedActiveTab` resolves to, and a composer registered the way the
    /// pane's mount registers one.
    ///
    /// Nothing writes `focusedTabCloseContext` for a transcript tab — only
    /// terminal views do — and `resolvedFocusedTabCloseContext()` answers nil
    /// for any first responder that is not a `TBDTerminalView`, which is every
    /// responder in this pane. Resolving through those two alone therefore named
    /// no terminal at all here.
    @Test func theComposerCommandNamesTheSelectedWorktreesActiveTranscriptTerminal() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), terminalID = UUID()
        state.tabs[worktreeID] = [liveTranscriptTab(terminalID: terminalID)]
        state.selectedWorktreeIDs = [worktreeID]
        let composerView = NSView()
        state.registerComposerView(composerView, for: terminalID)

        #expect(state.composerCommandTerminalID == terminalID)
    }

    /// **The worse half of the same bug.** A stale last-focused context naming a
    /// BACKGROUND terminal tab must not win over the transcript the person is
    /// looking at — ⌘/ there moved the caret in a tab that is not on screen.
    /// The registration is what decides: the terminal tab has no composer.
    @Test func aStaleTerminalTabContextDoesNotStealTheComposerCommand() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), background = UUID(), transcript = UUID()
        let backgroundTab = terminalTab(terminalID: background)
        state.tabs[worktreeID] = [
            liveTranscriptTab(terminalID: transcript), backgroundTab
        ]
        state.selectedWorktreeIDs = [worktreeID]
        state.focusedTabCloseContext = TabCloseContext(
            worktreeID: worktreeID, tabID: backgroundTab.id)
        let composerView = NSView()
        state.registerComposerView(composerView, for: transcript)

        #expect(state.composerCommandTerminalID == transcript)
    }

    /// **The negative.** No composer registered anywhere — the flag is off, or
    /// the pane has not mounted one — and the accessor answers nil, which is
    /// what the two menu items' `.disabled(…)` reads. `focusComposer` on a
    /// terminal with no registered composer is a no-op, so an enabled item there
    /// would be an offer of nothing.
    @Test func withNoComposerRegisteredTheComposerCommandNamesNothing() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), terminalID = UUID()
        state.tabs[worktreeID] = [liveTranscriptTab(terminalID: terminalID)]
        state.selectedWorktreeIDs = [worktreeID]

        #expect(state.composerCommandTerminalID == nil)
    }

    /// Nothing selected and nothing focused — nothing to act on either.
    @Test func withNoFocusedTabTheComposerCommandNamesNothing() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        #expect(state.composerCommandTerminalID == nil)
    }

    // MARK: - A dead terminal takes its composer state with it

    @Test func closingATabDiscardsItsComposerDraft() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), terminalID = UUID()
        let tab = liveTranscriptTab(terminalID: terminalID)
        state.tabs[worktreeID] = [tab]
        state.composerDraft(for: terminalID).text = "half a sentence"

        state.closeTab(worktreeID: worktreeID, index: 0)

        #expect(state.composerDrafts[terminalID] == nil)
    }

    /// The focus registries hold their views weakly, so nothing leaks — but an
    /// empty box per dead terminal accumulates for the app's lifetime. A closed
    /// tab leaves neither entry behind, nor the incarnation latch.
    @Test func closingATabLeavesNoComposerRegistryEntry() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), terminalID = UUID()
        let tab = liveTranscriptTab(terminalID: terminalID)
        state.tabs[worktreeID] = [tab]
        let composerView = NSView(), transcriptView = NSView()
        state.registerComposerView(composerView, for: terminalID)
        state.registerTranscriptView(transcriptView, for: terminalID)
        state.lastStartedIncarnation[terminalID] = UUID()

        state.closeTab(worktreeID: worktreeID, index: 0)

        #expect(state.composerFocusTargets[terminalID] == nil)
        #expect(state.transcriptFocusTargets[terminalID] == nil)
        #expect(state.lastStartedIncarnation[terminalID] == nil)
    }

    /// **The common death.** A tab close is the rarer one; every pane close,
    /// archive and daemon-reported removal funnels through
    /// `removeDeletedTerminalFromState`, which left the draft — and a send
    /// finishing after the row was gone then minted a fresh empty one through
    /// `composerDraft(for:)`.
    @Test func removingADeletedTerminalForgetsItsComposerState() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), terminalID = UUID()
        state.composerDraft(for: terminalID).text = "half a sentence"
        let composerView = NSView(), transcriptView = NSView()
        state.registerComposerView(composerView, for: terminalID)
        state.registerTranscriptView(transcriptView, for: terminalID)
        state.lastStartedIncarnation[terminalID] = UUID()

        state.removeDeletedTerminalFromState(
            terminalID: terminalID, worktreeID: worktreeID)

        #expect(state.composerDrafts[terminalID] == nil)
        #expect(state.composerFocusTargets[terminalID] == nil)
        #expect(state.transcriptFocusTargets[terminalID] == nil)
        #expect(state.lastStartedIncarnation[terminalID] == nil)
    }

    /// A waiter on a terminal that stops existing is RESUMED false, never
    /// dropped: it is a suspended continuation, and one nobody resumes hangs its
    /// send for the life of the app instead of timing out.
    @Test func removingADeletedTerminalFailsItsPendingSessionStartWait() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), terminalID = UUID()

        let task = Task { @MainActor in
            await state.awaitSessionStart(terminalID: terminalID, incarnationID: UUID())
        }
        try #require(await waiterRegistered(state, terminalID: terminalID))

        state.removeDeletedTerminalFromState(
            terminalID: terminalID, worktreeID: worktreeID)

        #expect(await task.value == false)
        #expect(state.sessionStartWaiters[terminalID] == nil)
    }

    /// The prune is scoped to the dead terminal. A live sibling's registrations
    /// and latch survive.
    @Test func forgettingOneTerminalLeavesAnothersRegistrationsAlone() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let dying = UUID(), surviving = UUID()
        let dyingView = NSView(), survivingView = NSView()
        state.registerComposerView(dyingView, for: dying)
        state.registerComposerView(survivingView, for: surviving)
        state.registerTranscriptView(survivingView, for: surviving)
        let incarnation = UUID()
        state.lastStartedIncarnation[surviving] = incarnation

        state.forgetComposerState(for: dying)

        #expect(state.composerFocusTargets[dying] == nil)
        #expect(state.composerFocusTargets[surviving]?.view === survivingView)
        #expect(state.transcriptFocusTargets[surviving]?.view === survivingView)
        #expect(state.lastStartedIncarnation[surviving] == incarnation)
    }

    /// The discard is scoped to the closed tab's own terminals. A sibling tab's
    /// half-written message survives.
    @Test func closingATabLeavesAnotherTabsDraftAlone() {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let worktreeID = UUID(), closing = UUID(), surviving = UUID()
        state.tabs[worktreeID] = [
            liveTranscriptTab(terminalID: closing),
            liveTranscriptTab(terminalID: surviving)
        ]
        state.composerDraft(for: closing).text = "going away"
        state.composerDraft(for: surviving).text = "staying"

        state.closeTab(worktreeID: worktreeID, index: 0)

        #expect(state.composerDrafts[closing] == nil)
        #expect(state.composerDrafts[surviving]?.text == "staying")
    }
}
