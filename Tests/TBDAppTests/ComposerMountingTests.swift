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

    // MARK: - The sending hold's release condition

    /// The composer's own spawn reports in, and the hold releases.
    @Test func aMatchingIncarnationReleasesTheHold() async throws {
        let (state, suiteName) = makeState()
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let terminalID = UUID()
        let incarnation = UUID()

        async let started = state.awaitSessionStart(
            terminalID: terminalID, incarnationID: incarnation)
        await Task.yield()  // let the waiter register
        state.noteSessionStart(terminalID: terminalID, incarnationID: incarnation)
        #expect(await started)
        #expect(state.sessionStartWaiters[terminalID] == nil, "a released waiter is removed")
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
        await Task.yield()
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
        await Task.yield()
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
        await Task.yield()
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
}
