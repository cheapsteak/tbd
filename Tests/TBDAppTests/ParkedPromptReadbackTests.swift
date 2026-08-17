import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The recovery surface for a prompt the agent never received
/// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`, "Undeliverable
/// prompts": "the notification opens a read-back of the prompt with Copy and
/// Deliver-now").
///
/// The property that matters is that the text is *reachable*. The daemon leaves
/// it in `worktree.pending_prompt` and notifies, but a notification is
/// transient — so the read-back is reachable from the worktree row for as long
/// as the column holds anything, and both of its actions work off the same
/// snapshot the row advertises.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite and tears it down — TBDApp ships as an unbundled SPM executable, so
/// `UserDefaults.standard` is the running developer's real `TBDApp.plist`.
@MainActor
@Suite("ParkedPromptReadback")
struct ParkedPromptReadbackTests {

    // MARK: - Harness

    @MainActor
    final class Harness {
        var parked: [(worktreeID: UUID, text: String?, submit: Bool)] = []
        var parkResult: WorktreeSetPendingPromptResult = .awaitingReady
        var parkError: Error?
        var copied: [String] = []
        /// Holds every parking RPC open so "a second click while the first call
        /// is outstanding" is a real state rather than a timing accident.
        ///
        /// A list, not one slot: if the in-flight guard is ever removed, BOTH
        /// calls park here, and a single-slot gate would strand the first
        /// forever — the test would hang instead of failing, which is not a
        /// result. Releasing every waiter makes the mutation red rather than
        /// hung.
        var parkGates: [CheckedContinuation<Void, Never>] = []
        var gateParking = false

        func releaseParking() {
            let waiting = parkGates
            parkGates = []
            for continuation in waiting { continuation.resume() }
        }
    }

    private struct StubError: Error {
        var localizedDescription: String { "daemon went away" }
    }

    private func withAppState(_ body: (AppState, Harness) async throws -> Void) async rethrows {
        let suiteName = "TBDAppTests.ParkedPromptReadback.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: defaults)
        let harness = Harness()
        state.pendingPromptSetter = { @MainActor worktreeID, text, submit in
            harness.parked.append((worktreeID, text, submit))
            if harness.gateParking {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    harness.parkGates.append(c)
                }
            }
            if let error = harness.parkError { throw error }
            return harness.parkResult
        }
        // Never the developer's real pasteboard.
        state.pasteboardWriter = { @MainActor text in harness.copied.append(text) }
        try await body(state, harness)
        state.dismissToast()
    }

    private func terminal(
        worktreeID: UUID, kind: TerminalKind?,
        transcriptPath: String? = nil,
        activityState: TerminalActivityState = .unknown
    ) -> Terminal {
        Terminal(
            worktreeID: worktreeID, tmuxWindowID: "@1", tmuxPaneID: "%1",
            transcriptPath: transcriptPath, kind: kind, activityState: activityState)
    }

    /// The single sheet slot both prompt surfaces share.
    private func slot(_ state: AppState) -> PromptSheet? {
        PromptSheet.presented(
            compose: state.queuedPromptTarget, readback: state.parkedPromptReadback)
    }

    private func isCompose(_ sheet: PromptSheet?) -> Bool {
        if case .compose = sheet { return true }
        return false
    }

    private func isReadback(_ sheet: PromptSheet?) -> Bool {
        if case .readback = sheet { return true }
        return false
    }

    /// Drive the cooperative pool until `condition` holds — the delivery call
    /// under test suspends inside a stubbed RPC, so there is nothing to await.
    private func waitUntil(
        _ label: String,
        _ condition: () -> Bool,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        for _ in 0..<500 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("timed out waiting for \(label)", sourceLocation: sourceLocation)
    }

    /// Give every already-enqueued main-actor task a generous chance to run.
    /// Used to prove a call did NOT reach the RPC, where a single yield would
    /// be a weak claim.
    private func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func worktree(
        repoID: UUID, prompt: String?, submit: Bool? = nil, name: String = "wt-name",
        status: WorktreeStatus = .active
    ) -> Worktree {
        Worktree(
            repoID: repoID,
            name: name,
            displayName: name,
            branch: "tbd/\(name)",
            path: "/tmp/wt",
            status: status,
            tmuxServer: "test-server",
            pendingPrompt: prompt,
            pendingPromptSubmit: submit
        )
    }

    // MARK: - The one visibility rule

    @Test("A row holding text yields a read-back; an empty column yields none")
    func readbackTracksTheColumn() {
        let repoID = UUID()
        let holding = worktree(repoID: repoID, prompt: "do the thing", submit: false)
        let readback = ParkedPromptReadback(worktree: holding)
        #expect(readback?.text == "do the thing")
        #expect(readback?.id == holding.id)
        #expect(readback?.worktreeName == "wt-name")
        #expect(readback?.submit == false)

        // Delivered: the daemon cleared the column, so the row advertises
        // nothing and the sheet has nothing to show.
        #expect(ParkedPromptReadback(worktree: worktree(repoID: repoID, prompt: nil)) == nil)
        // An empty string is not a parked prompt either.
        #expect(ParkedPromptReadback(worktree: worktree(repoID: repoID, prompt: "")) == nil)
        // A row with no submit bit recorded: the sheet must say what delivery
        // will actually do, and delivery stages without pressing Enter. Both
        // sides read `Worktree.pendingPromptSubmitResolved`, so this cannot
        // drift from the daemon — see `resolvedBitIsWhatTheSheetShows`.
        #expect(ParkedPromptReadback(
            worktree: worktree(repoID: repoID, prompt: "x", submit: nil))?.submit == false)
    }

    // MARK: - Reveal

    @Test("Revealing a parked prompt opens the read-back with the row's text")
    func revealOpensTheReadback() async throws {
        try await withAppState { state, _ in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "line one\nline two", submit: false)
            state.worktrees[repoID] = [wt]

            state.revealParkedPrompt(wt)

            let readback = try #require(state.parkedPromptReadback)
            #expect(readback.text == "line one\nline two")
            #expect(readback.submit == false)
            #expect(readback.worktreeName == "wt-name")
        }
    }

    @Test("Nothing parked: no sheet, and the operator is told why")
    func revealWithNothingParkedSaysSo() async {
        await withAppState { state, _ in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: nil)
            state.worktrees[repoID] = [wt]

            state.revealParkedPrompt(wt)

            #expect(state.parkedPromptReadback == nil)
            #expect(state.activeToast?.message.contains("already been delivered") == true)
        }
    }

    // MARK: - Copy

    @Test("Copy puts the parked text on the pasteboard, verbatim")
    func copyWritesThePasteboard() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "  keep my indentation\n\tand my tab")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)

            state.copyParkedPrompt(readback)

            #expect(harness.copied == ["  keep my indentation\n\tand my tab"])
            #expect(state.activeToast?.message.contains("copied") == true)
        }
    }

    // MARK: - Deliver now

    @Test("Deliver now re-parks the same text and submit bit, and closes the sheet")
    func deliverNowRepArksThroughTheSameRPC() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "second time lucky", submit: false)
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkResult = .awaitingReady

            await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit)

            // Re-parking IS re-arming: `PendingPromptCoordinator.park` re-enters
            // the worktree into the armed set and arms a paste against the live
            // agent. No new RPC is needed, and the staged (submit: false) bit
            // must survive the round trip or Deliver-now would start a turn the
            // operator declined.
            #expect(harness.parked.count == 1)
            #expect(harness.parked.first?.worktreeID == wt.id)
            #expect(harness.parked.first?.text == "second time lucky")
            #expect(harness.parked.first?.submit == false)
            #expect(state.parkedPromptReadback == nil)
            #expect(state.activeToast?.message.contains("Delivering") == true)
        }
    }

    @Test("Deliver now on a worktree with no agent yet says it waits for the spawn")
    func deliverNowBeforeSpawnSaysItWaits() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "before the agent exists")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkResult = .parkedForSpawn

            await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit)

            #expect(state.parkedPromptReadback == nil)
            #expect(state.activeToast?.message.contains("when the agent starts") == true)
        }
    }

    @Test("No agent to deliver to: nothing is parked, and the operator is told the truth")
    func shellPrimaryIsNotPromisedADelivery() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "nobody home")
            state.worktrees[repoID] = [wt]
            // The spawn already happened and produced a plain shell — one of
            // the spec's named undeliverable causes.
            state.terminals[wt.id] = [terminal(worktreeID: wt.id, kind: .shell)]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)

            await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit)

            // `park` would answer `.parkedForSpawn` here — the same answer it
            // gives before a spawn — so reporting it would promise a delivery
            // that can never happen and close the sheet on the only action
            // that works.
            #expect(harness.parked.isEmpty)
            #expect(state.parkedPromptReadback != nil)
            #expect(state.alertIsError)
            #expect(state.alertMessage?.contains("plain shell") == true)
        }
    }

    @Test("Whether an agent exists to deliver to")
    func agentPresenceRule() {
        let wtID = UUID()
        // Nothing spawned yet (or terminals not loaded): the prompt still
        // rides the next spawn, so delivery stays on offer.
        #expect(ParkedPromptReadback.primaryIsPlainShell(terminals: []) == false)
        #expect(ParkedPromptReadback.primaryIsPlainShell(
            terminals: [terminal(worktreeID: wtID, kind: .shell)]) == true)
        // An agent anywhere in the list is an agent to deliver to — the daemon
        // picks the first non-shell row, not row zero.
        #expect(ParkedPromptReadback.primaryIsPlainShell(terminals: [
            terminal(worktreeID: wtID, kind: .shell),
            terminal(worktreeID: wtID, kind: .claude)
        ]) == false)
        // A row with no kind at all reads as a shell, as it does in the daemon.
        #expect(ParkedPromptReadback.primaryIsPlainShell(
            terminals: [terminal(worktreeID: wtID, kind: nil)]) == true)
    }

    @Test("Deliver now is inert while its own RPC is outstanding")
    func doubleClickParksOnce() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "exactly once")
            state.worktrees[repoID] = [wt]
            state.terminals[wt.id] = [terminal(worktreeID: wt.id, kind: .claude)]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.gateParking = true

            let firstClick = Task { await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit) }
            await waitUntil("the parking RPC is in flight") { !harness.parkGates.isEmpty }

            // The second click, while the first call is still outstanding. It
            // runs in its own Task for the same reason the gate is a list: if
            // the guard is gone this call parks and SUSPENDS, and awaiting it
            // inline would deadlock the test against its own release.
            let secondClick = Task { await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit) }
            await drain()
            #expect(harness.parked.count == 1)

            harness.releaseParking()
            await firstClick.value
            await secondClick.value

            // Parking is not idempotent from the agent's side: a second park
            // is a second delivery of the operator's message.
            #expect(harness.parked.count == 1)
            // And the button is live again once the call has landed.
            #expect(state.parkedPromptDeliveryInFlight == false)
        }
    }

    // MARK: - Sending is opt-in

    @Test("Sending is opt-in: the shipped default is off")
    func sendingIsOptIn() {
        // Until an operator opts in, delivery types the message into the
        // composer and stops. Sending starts a turn nobody watched begin, and
        // is the one half TBD cannot report on afterwards — so it is the
        // operator's to ask for.
        #expect(QueuedPromptComposer.sendImmediatelyDefault == false)
    }

    @Test("An existing message shows the bit stored with it, not the default")
    func storedSubmitBitWins() {
        let repoID = UUID()
        // Someone ticked the box when they parked this; the composer must say
        // so rather than showing the default and misreporting what will happen.
        #expect(ParkedPromptReadback(
            worktree: worktree(repoID: repoID, prompt: "x", submit: true))?.submit == true)
        #expect(ParkedPromptReadback(
            worktree: worktree(repoID: repoID, prompt: "x", submit: false))?.submit == false)
    }

    /// The agreement itself. The sheet's whole job is to state what delivery
    /// will do, and delivery reads `Worktree.pendingPromptSubmitResolved`
    /// (`PendingPromptCoordinator.deliverParkedPrompt`). So both are asserted
    /// against the same *literal* per row shape, the absent bit included —
    /// comparing the sheet to the resolver instead would be an identity that
    /// stays green however the resolver is changed, and would pin nothing.
    @Test("The sheet seeds the same resolution delivery acts on")
    func resolvedBitIsWhatTheSheetShows() {
        let repoID = UUID()
        let contract: [(recorded: Bool?, pressesEnter: Bool)] =
            [(nil, false), (false, false), (true, true)]
        for (recorded, pressesEnter) in contract {
            let wt = worktree(repoID: repoID, prompt: "x", submit: recorded)
            // What delivery will do with this row.
            #expect(wt.pendingPromptSubmitResolved == pressesEnter)
            // And what the sheet tells the operator it will do.
            #expect(ParkedPromptReadback(worktree: wt)?.submit == pressesEnter)
        }
    }

    // MARK: - Where it surfaces

    @Test("One rule, two surfaces: pending is the banner's, undeliverable is the bar's")
    func phaseSplitsTheTwoSurfaces() {
        let repoID = UUID()
        let wt = worktree(repoID: repoID, prompt: "say this first")
        let agentID = wt.id

        // Nothing spawned yet — waiting, which is the common case and not a
        // problem.
        #expect(ParkedPromptReadback(worktree: wt, terminals: [])?.phase == .pending)
        // An agent exists. Whether it has announced itself is deliberately NOT
        // consulted: delivery clears the column the moment the paste succeeds,
        // so a lingering column after readiness is a timing window, not a
        // verdict, and the app no longer guesses at one.
        #expect(ParkedPromptReadback(worktree: wt, terminals: [
            terminal(worktreeID: agentID, kind: .claude,
                     transcriptPath: "/tmp/t.jsonl", activityState: .working)
        ])?.phase == .pending)
        // The two things the app can see for itself and be right about.
        #expect(ParkedPromptReadback(worktree: wt, terminals: [
            terminal(worktreeID: agentID, kind: .shell)
        ])?.phase == .undeliverable(.noAgent))
        #expect(ParkedPromptReadback(
            worktree: worktree(repoID: repoID, prompt: "x", status: .archived),
            terminals: [])?.phase == .undeliverable(.archived))
    }

    @Test("The two surfaces are complements — never both, never neither")
    func surfacesCannotBothShout() {
        let repoID = UUID()
        let wt = worktree(repoID: repoID, prompt: "one message")
        let cases: [[Terminal]] = [
            [],
            [terminal(worktreeID: wt.id, kind: .claude)],
            [terminal(worktreeID: wt.id, kind: .claude, activityState: .working)],
            [terminal(worktreeID: wt.id, kind: .shell)]
        ]
        for terminals in cases {
            let readback = ParkedPromptReadback(worktree: wt, terminals: terminals)
            let bar = StatusBarView.showsParkedPromptEntry(readback)
            let banner = QueuedPromptBannerModel.shows(phase: readback?.phase, footer: nil)
            #expect(bar != banner, "exactly one surface owns each phase")
        }
        // And with nothing parked, neither surface says anything.
        let empty = ParkedPromptReadback(worktree: worktree(repoID: repoID, prompt: nil))
        #expect(StatusBarView.showsParkedPromptEntry(empty) == false)
        #expect(QueuedPromptBannerModel.shows(phase: empty?.phase, footer: nil) == false)
    }

    @Test("The banner yields the footer slot to a parked or rate-limited pane")
    func bannerYieldsTheFooterSlot() {
        #expect(QueuedPromptBannerModel.shows(phase: .pending, footer: nil))
        // Nothing is running in these panes to receive a paste, so promising
        // one would be a promise the pane cannot keep.
        #expect(QueuedPromptBannerModel.shows(
            phase: .pending, footer: .hibernatedOverlay(message: "Hibernated")) == false)
        #expect(QueuedPromptBannerModel.shows(
            phase: .pending, footer: .scheduledResume(at: Date(), cancelTerminalID: UUID())) == false)
        // A message nothing will receive is the status bar's to report.
        #expect(QueuedPromptBannerModel.shows(
            phase: .undeliverable(.archived), footer: nil) == false)
    }

    @Test("The composer opens with what is true in this phase")
    func composerCopyFollowsThePhase() {
        let pendingSends = ParkedPromptPhase.pending.explanation(submit: true)
        let pendingWaits = ParkedPromptPhase.pending.explanation(submit: false)
        // A waiting message is described as waiting — never as a failure, and
        // never as already sent.
        #expect(pendingSends.contains("as soon as it is ready"))
        #expect(pendingWaits.contains("as soon as it is ready"))
        for copy in [pendingSends, pendingWaits] {
            #expect(copy.contains("confirm") == false)
            #expect(copy.contains("cannot be delivered") == false)
        }
        // The submit bit is what decides whether a turn starts, and the copy
        // says which — the default no longer sends.
        #expect(pendingSends.contains("then sends it"))
        #expect(pendingWaits.contains("leaves it for you to send"))
        // An undeliverable message says why, and points at Copy.
        #expect(ParkedPromptPhase.undeliverable(.archived).explanation(submit: false)
            .contains("archived"))
        #expect(ParkedPromptPhase.undeliverable(.noAgent).explanation(submit: false)
            .contains("copy it"))
    }

    // MARK: - Editing

    @Test("Sending an edited message parks the edit, not what was there before")
    func editedTextIsWhatGetsParked() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "original wording", submit: false)
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)

            // What the composer holds after the operator has amended it — the
            // common case being a note that the agent may already have this.
            await state.deliverParkedPromptNow(
                readback, text: "  amended wording  ", submit: true)

            #expect(harness.parked.count == 1)
            #expect(harness.parked.first?.text == "amended wording")
            // The composer's toggle wins over the bit parked earlier.
            #expect(harness.parked.first?.submit == true)
            #expect(state.parkedPromptReadback == nil)
        }
    }

    @Test("An emptied composer cannot be sent — that would unpark, not deliver")
    func blankEditIsNotADelivery() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "do not lose me")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)

            await state.deliverParkedPromptNow(readback, text: "   \n  ", submit: true)

            // Empty text is the daemon's UNPARK signal: sending it here would
            // silently destroy the message this surface exists to protect.
            #expect(harness.parked.isEmpty)
            #expect(state.parkedPromptReadback != nil)
        }
    }

    // MARK: - Discard

    @Test("Discard unparks the message and closes the composer")
    func discardClearsTheColumn() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "already answered, actually")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkResult = .refused(reason: "no prompt text — the worktree was unparked")

            await state.discardParkedPrompt(readback)

            // Unparking is `setPendingPrompt` with NO text; the daemon clears
            // the column and disarms any pending wait.
            #expect(harness.parked.count == 1)
            #expect(harness.parked.first?.text == nil)
            #expect(state.parkedPromptReadback == nil)
            #expect(state.activeToast?.message.contains("discarded") == true)
        }
    }

    @Test("A discard the daemon did not honour is not reported as done")
    func discardRefusalIsSurfaced() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "still here")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkResult = .refused(reason: "queued prompts are disabled")

            await state.discardParkedPrompt(readback)

            #expect(state.parkedPromptReadback != nil)
            #expect(state.alertIsError)
            #expect(state.alertMessage?.contains("queued prompts are disabled") == true)
        }
    }

    @Test("Reading the one status an unpark comes back as")
    func discardOutcomeMapping() {
        // `park` reports a successful unpark AS a refusal — nothing ended up
        // parked, which is exactly what was asked for.
        #expect(ParkedPromptReadback.discardRefusal(
            .refused(reason: "no prompt text — the worktree was unparked")) == nil)
        // Any other refusal means the column still holds the text.
        #expect(ParkedPromptReadback.discardRefusal(
            .refused(reason: "queued prompts are disabled")) == "queued prompts are disabled")
        // And a park in answer to a request carrying no text discarded nothing.
        #expect(ParkedPromptReadback.discardRefusal(.parkedForSpawn) != nil)
        #expect(ParkedPromptReadback.discardRefusal(.awaitingReady) != nil)
    }

    @Test("Discard is inert while another call is outstanding")
    func discardDoesNotDoubleFire() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "once is enough")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkResult = .refused(reason: "no prompt text — the worktree was unparked")
            harness.gateParking = true

            let firstClick = Task { await state.discardParkedPrompt(readback) }
            await waitUntil("the unpark RPC is in flight") { !harness.parkGates.isEmpty }
            let secondClick = Task { await state.discardParkedPrompt(readback) }
            await drain()
            #expect(harness.parked.count == 1)

            harness.releaseParking()
            await firstClick.value
            await secondClick.value
            #expect(harness.parked.count == 1)
        }
    }

    // MARK: - Archived worktrees

    @Test("An archived worktree still hands its text back, and says why it cannot be delivered")
    func archivedWorktreeKeepsItsTextReachable() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            // Archiving does not clear the column, and a revive will not
            // deliver a prompt parked before it — so this text can only ever
            // come back out through the read-back.
            let wt = worktree(
                repoID: repoID, prompt: "stranded but not lost", status: .archived)
            state.archivedWorktrees[repoID] = [wt]

            // The row's own value opens it: an archived row is in none of the
            // lists an ID lookup consults.
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            #expect(readback.text == "stranded but not lost")
            #expect(readback.worktreeIsArchived)
            #expect(state.parkedPromptUndeliverableReason(readback) == .archived)

            // Copy — the action that still means something — works.
            state.copyParkedPrompt(readback)
            #expect(harness.copied == ["stranded but not lost"])

            // Deliver-now does not claim success against a worktree nothing
            // will ever be delivered to.
            await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit)
            #expect(harness.parked.isEmpty)
            #expect(state.parkedPromptReadback != nil)
            #expect(state.alertMessage?.contains("archived") == true)
        }
    }

    @Test("Archived outranks the shell-primary reason")
    func archivedWinsTheReason() {
        let repoID = UUID()
        let live = worktree(repoID: repoID, prompt: "x")
        let archived = worktree(repoID: repoID, prompt: "x", status: .archived)
        let shell = [terminal(worktreeID: live.id, kind: .shell)]
        #expect(ParkedPromptReadback(worktree: live, terminals: [])?
            .phase.undeliverableReason == nil)
        #expect(ParkedPromptReadback(worktree: live, terminals: shell)?
            .phase.undeliverableReason == .noAgent)
        // An archived worktree with a live-looking terminal list still reads
        // archived: nothing will be delivered there whatever the row says.
        #expect(ParkedPromptReadback(worktree: archived, terminals: shell)?
            .phase.undeliverableReason == .archived)
    }

    // MARK: - One sheet slot

    @Test("Composing and reading back share one sheet slot, and close one at a time")
    func promptSheetsShareOneSlot() async {
        await withAppState { state, _ in
            #expect(slot(state) == nil)

            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "recoverable")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            #expect(isReadback(slot(state)))
            #expect(slot(state)?.id == wt.id)

            // Composing wins the slot — it is modal over the whole window.
            let target = QueuedPromptTarget(
                placeholderID: UUID(), repoID: repoID, worktreeName: "new-wt")
            state.queuedPromptTarget = target
            #expect(isCompose(slot(state)))

            // Closing the presented sheet clears exactly that one, so the
            // read-back behind it is not silently discarded.
            state.dismissPresentedPromptSheet()
            #expect(state.queuedPromptTarget == nil)
            #expect(isReadback(slot(state)))

            state.dismissPresentedPromptSheet()
            #expect(state.parkedPromptReadback == nil)
            #expect(slot(state) == nil)
        }
    }

    @Test("A refusal keeps the read-back open and names the reason")
    func refusalKeepsTheTextOnScreen() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "don't lose me")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkResult = .refused(reason: "queued prompts are disabled")

            await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit)

            // The whole point is recoverability: a refused delivery must leave
            // the text where the operator can still copy it.
            #expect(state.parkedPromptReadback != nil)
            #expect(state.alertIsError)
            #expect(state.alertMessage?.contains("queued prompts are disabled") == true)
        }
    }

    @Test("A thrown RPC error keeps the read-back open too")
    func rpcFailureKeepsTheTextOnScreen() async throws {
        try await withAppState { state, harness in
            let repoID = UUID()
            let wt = worktree(repoID: repoID, prompt: "don't lose me either")
            state.worktrees[repoID] = [wt]
            state.revealParkedPrompt(wt)
            let readback = try #require(state.parkedPromptReadback)
            harness.parkError = StubError()

            await state.deliverParkedPromptNow(readback, text: readback.text, submit: readback.submit)

            #expect(state.parkedPromptReadback != nil)
            #expect(state.alertIsError)
        }
    }
}
