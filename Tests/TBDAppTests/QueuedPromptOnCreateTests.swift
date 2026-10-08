import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// App-side tests for the queued prompt on worktree creation
/// (`docs/specs/2026-08-10-queued-prompt-on-create-design.md`, task 3).
///
/// Two properties are load-bearing and are asserted rather than arranged:
///
/// - The modal is gated on the DAEMON capability `queuedPromptEnabled`, not on
///   a UserDefaults twin. With it off, creation must behave exactly as it did
///   before — including arming rename-on-create via `editingWorktreeID`.
/// - Creation is not slowed. `worktree.create` is dispatched before
///   `worktree.setPendingPrompt` can possibly fire, and creation runs to
///   completion while the modal is still open and unsubmitted.
///
/// Every test constructs `AppState(userDefaults:)` against a unique throwaway
/// suite and tears it down — TBDApp ships as an unbundled SPM executable, so
/// `UserDefaults.standard` is the running developer's real `TBDApp.plist`
/// (mirrors `ReapRecordsStateTests.swift:17-22`).
@MainActor
@Suite("QueuedPromptOnCreate")
struct QueuedPromptOnCreateTests {

    // MARK: - Harness

    /// Records the order in which `AppState` dispatches its RPCs and lets a
    /// test hold `worktree.create` open, so "creation is already in flight
    /// while the operator types" is a real state the test can observe rather
    /// than a timing accident.
    @MainActor
    final class Harness {
        var calls: [String] = []
        var createGate: CheckedContinuation<Void, Never>?
        var parked: (worktreeID: UUID, text: String?, submit: Bool)?
        /// Every parking call, in order — the double-Cmd+N case parks twice and
        /// needs to see both.
        var parkedAll: [(worktreeID: UUID, text: String?, submit: Bool)] = []
        var parkResult: WorktreeSetPendingPromptResult = .parkedForSpawn
        /// Makes the parking RPC itself fail — a dropped socket rather than a
        /// refusal the daemon composed. Thrown after the call is recorded, so
        /// "the RPC went out and nothing came back parked" is what the test
        /// sees.
        var parkError: Error?
        var createError: Error?
        var flagWrites: [Bool] = []
        /// Everything written to the pasteboard. Stubbed on every state this
        /// suite builds, so no test can reach the developer's real one.
        var copied: [String] = []
        /// Every unsent first message handed to the file writer. Stubbed on
        /// every state this suite builds, so no test writes under `TBD_HOME`.
        var saved: [(repoID: UUID, worktreeName: String, text: String)] = []
        /// Makes the file write fail, to drive the clipboard-only fallback.
        var saveError: Error?
    }

    /// The path the stub writer reports, so assertions can name it.
    static let savedPath = "/tmp/fake-home/repos/r/unsent-prompts/20260101-000000-x.md"

    private struct StubError: Error {}

    private func withAppState(_ body: (AppState) async throws -> Void) async rethrows {
        let suiteName = "TBDAppTests.QueuedPromptOnCreate.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try await body(AppState(userDefaults: defaults))
    }

    private func capabilities(queuedPrompt: Bool) -> DaemonCapabilitiesResult {
        DaemonCapabilitiesResult(controlModeEnabled: false, queuedPromptEnabled: queuedPrompt)
    }

    private func daemonWorktree(repoID: UUID, name: String = "daemon-name") -> Worktree {
        Worktree(
            repoID: repoID,
            name: name,
            displayName: name,
            branch: "tbd/\(name)",
            path: "/tmp/wt",
            status: .creating,
            tmuxServer: "test-server"
        )
    }

    /// Drive the cooperative pool until `condition` holds. The creation path is
    /// a detached `Task`, so tests cannot simply `await` it; a bounded yield
    /// loop keeps them off wall-clock sleeps (repo rule: no raw `Task.sleep`).
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
    /// Used to prove a call did NOT happen, where a single yield would be a
    /// weak claim.
    private func drain() async {
        for _ in 0..<100 { await Task.yield() }
    }

    private func arm(_ state: AppState, _ harness: Harness, created: Worktree) {
        state.worktreeCreator = { @MainActor _ in
            harness.calls.append(RPCMethod.worktreeCreate)
            if let error = harness.createError { throw error }
            return created
        }
        state.pendingPromptSetter = { @MainActor worktreeID, text, submit in
            harness.calls.append(RPCMethod.worktreeSetPendingPrompt)
            if let parkError = harness.parkError { throw parkError }
            harness.parked = (worktreeID, text, submit)
            harness.parkedAll.append((worktreeID, text, submit))
            return harness.parkResult
        }
        state.queuedPromptFlagSetter = { @MainActor enabled in
            harness.flagWrites.append(enabled)
        }
        state.pasteboardWriter = { @MainActor text in harness.copied.append(text) }
        state.unsentPromptWriter = { @MainActor repoID, worktreeName, text in
            if let saveError = harness.saveError { throw saveError }
            harness.saved.append((repoID, worktreeName, text))
            return Self.savedPath
        }
    }

    // MARK: - The gate, both branches

    @Test("Capability OFF: no modal, and rename-on-create still arms")
    func capabilityOffPreservesRenameOnCreate() async {
        await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: false)

            state.createWorktree(repoID: repoID)

            // The optimistic placeholder arms rename immediately, as today.
            #expect(state.queuedPromptTarget == nil)
            #expect(state.editingWorktreeID != nil)

            await waitUntil("placeholder swap") { state.selectedWorktreeIDs == [created.id] }
            await drain()

            #expect(state.queuedPromptTarget == nil)
            #expect(state.editingWorktreeID == created.id)
            #expect(harness.calls == [RPCMethod.worktreeCreate])
        }
    }

    @Test("Capability ON: modal presented, editingWorktreeID untouched")
    func capabilityOnPresentsModalAndSkipsRename() async {
        await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)

            #expect(state.queuedPromptTarget != nil)
            #expect(state.editingWorktreeID == nil)

            await waitUntil("placeholder swap") { state.selectedWorktreeIDs == [created.id] }
            await drain()

            // Rename-on-create must stay off through the swap too: the modal
            // and the inline rename field cannot both own focus.
            #expect(state.editingWorktreeID == nil)
            #expect(state.queuedPromptTarget?.id != nil)
        }
    }

    // MARK: - Creation is not slowed

    @Test("worktree.create is dispatched before worktree.setPendingPrompt")
    func createIsDispatchedBeforeTheParkingRPC() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            // Hold `worktree.create` open so the submit below lands while
            // creation is genuinely in flight: the stub parks its continuation
            // instead of returning, and resumes only when the test says so.
            state.worktreeCreator = { @MainActor _ in
                harness.calls.append(RPCMethod.worktreeCreate)
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    harness.createGate = c
                }
                return created
            }

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)

            state.submitQueuedPrompt(target, text: "do the thing", submit: true)

            await waitUntil("create entered") { harness.createGate != nil }
            await drain()

            // The parking RPC cannot precede the create RPC, and cannot fire
            // at all while creation is unfinished — there is no worktree ID yet.
            #expect(harness.calls == [RPCMethod.worktreeCreate])
            #expect(harness.parked == nil)

            harness.createGate?.resume()
            await waitUntil("prompt parked") { harness.parked != nil }

            #expect(harness.calls == [RPCMethod.worktreeCreate, RPCMethod.worktreeSetPendingPrompt])
            #expect(harness.parked?.worktreeID == created.id)
            #expect(harness.parked?.text == "do the thing")
            #expect(harness.parked?.submit == true)
        }
    }

    @Test("Creation completes while the modal is still open and unsubmitted")
    func creationDoesNotAwaitTheModal() async {
        await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)

            await waitUntil("placeholder swap") { state.selectedWorktreeIDs == [created.id] }
            #expect(state.pendingWorktreeIDs.isEmpty)
            // Still waiting on the operator — and creation finished anyway.
            #expect(state.queuedPromptTarget != nil)
            #expect(harness.parked == nil)
        }
    }

    // MARK: - Submission

    @Test("Dismissing without submitting parks nothing")
    func dismissParksNothing() async {
        await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            await waitUntil("placeholder swap") { state.selectedWorktreeIDs == [created.id] }

            // What `.sheet(item:)` does on Escape.
            state.queuedPromptTarget = nil
            await drain()

            #expect(harness.calls == [RPCMethod.worktreeCreate])
            #expect(harness.parked == nil)
        }
    }

    @Test("Whitespace-only text parks nothing")
    func blankPromptParksNothing() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "   \n  ", submit: true)
            await waitUntil("placeholder swap") { state.selectedWorktreeIDs == [created.id] }
            await drain()

            #expect(harness.parked == nil)
        }
    }

    @Test("submit:false rides through to the parking RPC")
    func unsubmittedPromptCarriesTheFlag() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "line one\nline two", submit: false)

            await waitUntil("prompt parked") { harness.parked != nil }
            #expect(harness.parked?.submit == false)
            // Multi-line text reaches the RPC verbatim.
            #expect(harness.parked?.text == "line one\nline two")
        }
    }

    @Test("Creation failure surfaces instead of parking into nothing")
    func creationFailureDoesNotPark() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            harness.createError = StubError()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "never lands", submit: true)

            await waitUntil("alert") { state.alertMessage != nil }
            #expect(harness.parked == nil)
            #expect(state.alertIsError)
            // The row never existed, so the file is the only copy; the
            // pasteboard is left alone once the file is written.
            #expect(harness.saved.map(\.text) == ["never lands"])
            #expect(harness.copied.isEmpty)
        }
    }

    @Test("A refusal from the daemon is surfaced, not swallowed")
    func refusalSurfaces() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            harness.parkResult = .refused(reason: "queued prompts are disabled")
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "hello", submit: true)

            await waitUntil("alert") { state.alertMessage != nil }
            #expect(state.alertMessage?.contains("queued prompts are disabled") == true)
        }
    }

    /// The modal is dismissed by the time a refusal comes back and there is no
    /// draft store behind it, so an alert on its own would leave the operator's
    /// message existing nowhere at all.
    @Test("A refused first message is handed back in a file")
    func refusalKeepsTheComposedTextRecoverable() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            harness.parkResult = .refused(
                reason: "this worktree's primary terminal is not an agent")
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "  the thing I typed  ", submit: true)

            await waitUntil("alert") { state.alertMessage != nil }
            // Trimmed exactly as the parking RPC would have carried it.
            #expect(harness.saved.map(\.text) == ["the thing I typed"])
            // The alert names the reason AND where the text went, so neither
            // fact can arrive without the other.
            #expect(state.alertMessage?.contains("not an agent") == true)
            #expect(state.alertMessage?.contains("saved to \(Self.savedPath)") == true)
            #expect(state.alertIsError)
        }
    }

    /// The third way parking can end without the text in the column, and the
    /// likeliest one in the field: the RPC never completed. A refusal at least
    /// proves the daemon read the message; a dropped socket does not, so the
    /// hand-back matters here most.
    @Test("A parking RPC that throws hands the composed text back too")
    func transportFailureKeepsTheComposedTextRecoverable() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            harness.parkError = StubError()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "the socket died", submit: true)

            await waitUntil("alert") { state.alertMessage != nil }
            #expect(harness.calls.contains(RPCMethod.worktreeSetPendingPrompt))
            #expect(harness.parked == nil)
            #expect(harness.saved.map(\.text) == ["the socket died"])
            #expect(state.alertMessage?.contains("saved to \(Self.savedPath)") == true)
            #expect(state.alertIsError)
        }
    }

    // MARK: - Unsent first messages are written to a file

    @Test("A submitted message whose creation failed is saved to a file the alert names")
    func creationFailureSavesTheSubmittedMessage() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let harness = Harness()
            harness.createError = StubError()
            arm(state, harness, created: daemonWorktree(repoID: repoID))
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "  keep me  ", submit: true)

            await waitUntil("alert") { state.alertMessage != nil }
            #expect(harness.saved.count == 1)
            #expect(harness.saved.first?.repoID == repoID)
            #expect(harness.saved.first?.worktreeName == target.worktreeName)
            #expect(harness.saved.first?.text == "keep me")
            #expect(state.alertRevealPath == Self.savedPath)
            #expect(state.alertMessage?.contains(Self.savedPath) == true)
            // The file holds the text, so the pasteboard is not touched — a
            // Copy Path from the alert would overwrite it anyway.
            #expect(harness.copied.isEmpty)
        }
    }

    @Test("A refusal also saves the message to a file")
    func refusalSavesTheMessage() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let harness = Harness()
            harness.parkResult = .refused(reason: "nope")
            arm(state, harness, created: daemonWorktree(repoID: repoID))
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "refused text", submit: false)

            await waitUntil("alert") { state.alertMessage != nil }
            #expect(harness.saved.map(\.text) == ["refused text"])
            #expect(state.alertRevealPath == Self.savedPath)
        }
    }

    @Test("A file write that fails falls back to the clipboard and says so")
    func failedFileWriteFallsBackToClipboardOnly() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let harness = Harness()
            harness.createError = StubError()
            harness.saveError = StubError()
            arm(state, harness, created: daemonWorktree(repoID: repoID))
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "clipboard only", submit: true)

            await waitUntil("alert") { state.alertMessage != nil }
            #expect(harness.saved.isEmpty)
            #expect(harness.copied == ["clipboard only"])
            #expect(state.alertRevealPath == nil)
            #expect(state.alertMessage?.contains("could not be saved to a file") == true)
            #expect(state.alertMessage?.contains("copied to your clipboard instead") == true)
            #expect(state.alertIsError)
        }
    }

    @Test("An unsent draft in the open modal is saved when creation fails")
    func unsentDraftIsSavedOnFailure() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let harness = Harness()
            arm(state, harness, created: daemonWorktree(repoID: repoID))
            let target = QueuedPromptTarget(
                placeholderID: UUID(), repoID: repoID, worktreeName: "brave-otter")
            target.resolve(.failed)

            state.keepUnsentDraftAfterFailedCreation(target, draft: "\n half-typed thought \n")
            // Deferred a turn, so the alert lands after the sheet has gone.
            #expect(state.alertMessage == nil)
            await waitUntil("alert") { state.alertMessage != nil }

            #expect(harness.saved.count == 1)
            #expect(harness.saved.first?.repoID == repoID)
            #expect(harness.saved.first?.worktreeName == "brave-otter")
            #expect(harness.saved.first?.text == "half-typed thought")
            #expect(harness.copied.isEmpty)
            #expect(state.alertRevealPath == Self.savedPath)
            #expect(state.alertMessage?.contains("Worktree creation failed") == true)
            #expect(state.alertIsError)
        }
    }

    @Test("A blank draft in the open modal saves nothing and raises no alert")
    func blankUnsentDraftSavesNothing() async {
        await withAppState { state in
            let harness = Harness()
            arm(state, harness, created: daemonWorktree(repoID: UUID()))
            let target = QueuedPromptTarget(
                placeholderID: UUID(), repoID: UUID(), worktreeName: "brave-otter")
            target.resolve(.failed)

            state.keepUnsentDraftAfterFailedCreation(target, draft: "  \n\t ")
            await drain()

            #expect(harness.saved.isEmpty)
            #expect(harness.copied.isEmpty)
            #expect(state.alertMessage == nil)
        }
    }

    // MARK: - Creation that fails after the daemon row existed

    /// Drive a creation to the point the daemon row exists and the target has
    /// resolved `.created` — where `git worktree add` has yet to run.
    private func createdAndAwaitingGit(
        _ state: AppState, _ harness: Harness, repoID: UUID
    ) async throws -> (QueuedPromptTarget, Worktree) {
        let created = daemonWorktree(repoID: repoID, name: "late-fail")
        arm(state, harness, created: created)
        state.daemonCapabilities = capabilities(queuedPrompt: true)
        state.createWorktree(repoID: repoID)
        let target = try #require(state.queuedPromptTarget)
        await waitUntil("created") { target.resolution == .created(created.id) }
        await waitUntil("swap") { state.findWorktree(id: created.id) != nil }
        return (target, created)
    }

    private func archive(
        _ state: AppState, _ id: UUID, creationFailed: Bool = true,
        unsentPromptPath: String? = nil, unsentPromptLost: Bool = false
    ) {
        state.handleDelta(.worktreeArchived(WorktreeIDDelta(
            worktreeID: id, creationFailed: creationFailed,
            unsentPromptPath: unsentPromptPath, unsentPromptLost: unsentPromptLost)))
    }

    @Test("The failure alert names the file the daemon saved a parked message to")
    func failureAlertNamesTheDaemonsFile() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            state.submitQueuedPrompt(target, text: "parked then lost", submit: true)
            await waitUntil("parked") { harness.parked != nil }
            let daemonPath = "/tmp/fake-home/repos/r/unsent-prompts/20260101-000000-late-fail.md"

            archive(state, created.id, unsentPromptPath: daemonPath)

            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
            #expect(state.alertMessage?.contains("saved to \(daemonPath)") == true)
            #expect(state.alertRevealPath == daemonPath)
            // The daemon saved it; the app writes nothing of its own.
            #expect(harness.saved.isEmpty)
        }
    }

    @Test("The failure alert says when the daemon could not save the parked message")
    func failureAlertSaysTheMessageWasLost() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())

            // Stands even with the composer open: this alert is the only
            // place the loss is named.
            archive(state, created.id, unsentPromptLost: true)

            #expect(target.hasFailed)
            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
            #expect(state.alertMessage?.contains("could not be saved") == true)
            #expect(state.alertRevealPath == nil)
        }
    }

    @Test("A lost message is reported even for a worktree the app never knew")
    func lostMessageAlertsForAnUnknownWorktree() async {
        await withAppState { state in
            archive(state, UUID(), unsentPromptLost: true)

            #expect(state.alertMessage?.contains("Worktree creation failed.") == true)
            #expect(state.alertMessage?.contains("could not be saved") == true)
            #expect(state.alertRevealPath == nil)
        }
    }

    @Test("A creation failure for an unknown worktree with nothing parked stays silent")
    func unknownWorktreeFailureWithNothingParkedStaysSilent() async {
        await withAppState { state in
            archive(state, UUID())
            #expect(state.alertMessage == nil)
        }
    }

    @Test("Without a daemon path the failure alert offers no file")
    func failureAlertWithoutAPathOffersNoFile() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (_, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            state.dismissPresentedPromptSheet()

            archive(state, created.id)

            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
            #expect(state.alertRevealPath == nil)
        }
    }

    @Test("An open composer is told when git worktree add fails, and its draft is saved")
    func openDraftIsSavedOnLateCreationFailure() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: repoID)
            #expect(state.composerTargetsByWorktreeID[created.id] === target)

            archive(state, created.id)

            // The open composer raises the one alert itself, so the delta
            // raises none — replacing an alert on screen is unreliable.
            #expect(target.hasFailed)
            #expect(target.failureAfterCreate?.contains("Couldn't create worktree") == true)
            #expect(state.alertMessage == nil)
            #expect(state.composerTargetsByWorktreeID.isEmpty)

            // What the sheet does on seeing `hasFailed`.
            #expect(QueuedPromptModal.shouldHandOffDraft(creationFailed: target.hasFailed, submitted: false))
            state.keepUnsentDraftAfterFailedCreation(target, draft: "half typed")
            await waitUntil("draft alert") { state.alertRevealPath != nil }

            #expect(harness.saved.map(\.text) == ["half typed"])
            #expect(harness.saved.first?.repoID == repoID)
            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
            #expect(state.alertMessage?.contains("saved to \(Self.savedPath)") == true)
            #expect(state.alertRevealPath == Self.savedPath)
        }
    }

    @Test("An open composer with a blank draft still raises the failure alert")
    func blankOpenDraftStillRaisesTheFailureAlert() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())

            archive(state, created.id)
            #expect(state.alertMessage == nil)
            state.keepUnsentDraftAfterFailedCreation(target, draft: "  \n ")
            await waitUntil("alert") { state.alertMessage != nil }

            #expect(harness.saved.isEmpty)
            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
            #expect(state.alertRevealPath == nil)
        }
    }

    @Test("A submitted composer leaves the failure alert to the delta")
    func submittedComposerDoesNotSuppressTheAlert() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            // Send, with the sheet not yet torn down when the delta lands.
            state.submitQueuedPrompt(target, text: "sent", submit: true)
            #expect(state.queuedPromptTarget === target)
            #expect(state.composerTargetsByWorktreeID.isEmpty)

            archive(state, created.id)

            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
        }
    }

    @Test("A cancelled composer leaves the failure alert to the delta")
    func cancelledComposerDoesNotSuppressTheAlert() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            // Cancel or Escape, with the sheet not yet torn down.
            state.withdrawComposer(target)
            #expect(state.queuedPromptTarget === target)
            #expect(state.composerTargetsByWorktreeID.isEmpty)

            archive(state, created.id)

            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
            #expect(harness.saved.isEmpty)
        }
    }

    @Test("A daemon-saved path is named even with an open composer")
    func daemonPathAlertStandsWithAnOpenComposer() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            let daemonPath = "/tmp/fake-home/repos/r/unsent-prompts/x.md"

            archive(state, created.id, unsentPromptPath: daemonPath)

            #expect(target.hasFailed)
            #expect(state.alertRevealPath == daemonPath)
        }
    }

    @Test("A deliberate archive of a creating row does nothing to its composer")
    func deliberateArchiveDoesNothing() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())

            archive(state, created.id, creationFailed: false)

            #expect(state.alertMessage == nil)
            #expect(target.hasFailed == false)
            #expect(harness.saved.isEmpty)
            // Released all the same, so nothing leaks.
            #expect(state.composerTargetsByWorktreeID.isEmpty)
        }
    }

    @Test("A queued composer whose creation fails late is dropped, and the failure alert shows")
    func backloggedTargetIsDroppedOnLateFailure() async throws {
        try await withAppState { state in
            let harness = Harness()
            let blocker = QueuedPromptTarget(placeholderID: UUID(), repoID: UUID(), worktreeName: "x")
            state.presentQueuedPrompt(blocker)
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID, name: "late-fail")
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)
            state.createWorktree(repoID: repoID)
            let queued = try #require(state.queuedPromptBacklog.first)
            await waitUntil("created") { queued.resolution == .created(created.id) }
            #expect(state.composerTargetsByWorktreeID[created.id] === queued)

            archive(state, created.id)

            #expect(state.queuedPromptBacklog.isEmpty)
            #expect(queued.hasFailed)
            #expect(state.alertMessage?.contains("creat") == true)
            #expect(harness.saved.isEmpty)
        }
    }

    @Test("Closing the composer stops tracking it")
    func closingTheComposerReleasesItsEntry() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            #expect(state.composerTargetsByWorktreeID[created.id] === target)

            state.dismissPresentedPromptSheet()
            #expect(state.composerTargetsByWorktreeID.isEmpty)

            // Cancel discards by design: the failure alert still shows, and
            // the closed composer is not told.
            archive(state, created.id)
            #expect(target.hasFailed == false)
            #expect(state.alertMessage?.contains("Couldn't create worktree") == true)
        }
    }

    @Test("A park that races the failed creation's delete is saved once, by the app")
    func parkRacingTheDeleteIsSavedOnce() async throws {
        try await withAppState { state in
            let harness = Harness()
            let (target, created) = try await createdAndAwaitingGit(state, harness, repoID: UUID())
            var parkGate: CheckedContinuation<Void, Never>?
            state.pendingPromptSetter = { @MainActor _, _, _ in
                await withCheckedContinuation { parkGate = $0 }
                // The row was deleted before the park reached it.
                return .refused(reason: "no such worktree")
            }
            state.submitQueuedPrompt(target, text: "raced", submit: true)
            await waitUntil("parking entered") { parkGate != nil }

            // Nothing was parked, so the daemon saved nothing.
            archive(state, created.id)
            #expect(harness.saved.isEmpty)

            parkGate?.resume()
            await waitUntil("saved") { !harness.saved.isEmpty }
            await drain()

            #expect(harness.saved.map(\.text) == ["raced"])
            #expect(state.alertRevealPath == Self.savedPath)
        }
    }

    @Test("The composer hands its draft off only on failure, and never after a submit")
    func shouldHandOffDraftBranches() {
        #expect(QueuedPromptModal.shouldHandOffDraft(creationFailed: true, submitted: false))
        #expect(!QueuedPromptModal.shouldHandOffDraft(creationFailed: true, submitted: true))
        #expect(!QueuedPromptModal.shouldHandOffDraft(creationFailed: false, submitted: false))
        #expect(!QueuedPromptModal.shouldHandOffDraft(creationFailed: false, submitted: true))
    }

    @Test("Closing an alert clears its file, and a plain alert carries none")
    func alertRevealPathDoesNotOutliveItsAlert() async {
        await withAppState { state in
            state.showAlert("saved", isError: true, revealPath: "/tmp/x.md")
            #expect(state.alertRevealPath == "/tmp/x.md")

            state.alertMessage = nil
            #expect(state.alertRevealPath == nil)

            state.showAlert("saved", isError: true, revealPath: "/tmp/x.md")
            state.showAlert("something else")
            #expect(state.alertRevealPath == nil)
        }
    }

    @Test("A queued modal whose creation already failed is never presented")
    func failedTargetsAreDroppedFromTheBacklog() async {
        await withAppState { state in
            let open = QueuedPromptTarget(placeholderID: UUID(), repoID: UUID(), worktreeName: "a")
            let failed = QueuedPromptTarget(placeholderID: UUID(), repoID: UUID(), worktreeName: "b")
            let pending = QueuedPromptTarget(placeholderID: UUID(), repoID: UUID(), worktreeName: "c")
            state.presentQueuedPrompt(open)
            state.presentQueuedPrompt(failed)
            state.presentQueuedPrompt(pending)
            failed.resolve(.failed)

            state.dismissPresentedPromptSheet()
            await waitUntil("next modal") { state.queuedPromptTarget != nil }

            #expect(state.queuedPromptTarget === pending)
            #expect(state.queuedPromptBacklog.isEmpty)
        }
    }

    // MARK: - Two creations in flight at once

    @Test("Two rapid Cmd+N presses: the second modal queues, and both prompts land")
    func rapidDoubleCreateQueuesTheSecondModal() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let firstWT = daemonWorktree(repoID: repoID, name: "first-wt")
            let secondWT = daemonWorktree(repoID: repoID, name: "second-wt")
            let harness = Harness()
            arm(state, harness, created: firstWT)
            var queue = [firstWT, secondWT]
            state.worktreeCreator = { @MainActor _ in
                harness.calls.append(RPCMethod.worktreeCreate)
                return queue.removeFirst()
            }
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            let firstTarget = try #require(state.queuedPromptTarget)
            state.createWorktree(repoID: repoID)

            // The modal the operator is typing in is NOT swapped out from
            // under them: `.sheet(item:)` handed a replacement item can keep
            // presenting the old one, which would park the second worktree's
            // message against the first.
            #expect(state.queuedPromptTarget === firstTarget)
            #expect(state.queuedPromptBacklog.count == 1)

            state.submitQueuedPrompt(firstTarget, text: "alpha", submit: true)
            // What `.sheet(item:)` does when the first sheet closes.
            state.queuedPromptTarget = nil

            await waitUntil("second modal presented") {
                state.queuedPromptTarget != nil && state.queuedPromptTarget !== firstTarget
            }
            let secondTarget = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(secondTarget, text: "beta", submit: false)

            await waitUntil("both prompts parked") { harness.parkedAll.count == 2 }
            await drain()

            // Each message reached its OWN worktree.
            #expect(harness.parkedAll.contains {
                $0.worktreeID == firstWT.id && $0.text == "alpha" && $0.submit
            })
            #expect(harness.parkedAll.contains {
                $0.worktreeID == secondWT.id && $0.text == "beta" && !$0.submit
            })
            #expect(state.queuedPromptBacklog.isEmpty)
        }
    }

    @Test("A daemon row the local list lost still receives its prompt")
    func promptParksEvenWhenThePlaceholderSwapFindsNothing() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            // Hold creation open so the local rows can vanish mid-create — the
            // repo-removed-while-creating case `replaceCreationPlaceholder`
            // returns nil for.
            state.worktreeCreator = { @MainActor _ in
                harness.calls.append(RPCMethod.worktreeCreate)
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    harness.createGate = c
                }
                return created
            }

            state.createWorktree(repoID: repoID)
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "still mine", submit: true)
            await waitUntil("create entered") { harness.createGate != nil }

            state.worktrees[repoID] = nil
            harness.createGate?.resume()

            // The daemon row exists, so the prompt has somewhere to go. Telling
            // the operator "creation failed" and dropping their text would be a
            // lie about a worktree that is sitting in the daemon.
            await waitUntil("prompt parked") { harness.parked != nil }
            #expect(harness.parked?.worktreeID == created.id)
            #expect(harness.parked?.text == "still mine")
            #expect(state.alertMessage == nil)
        }
    }

    /// A worktree row holding an undelivered first message, so a read-back can
    /// be opened over it.
    private func parkedWorktree(repoID: UUID) -> Worktree {
        Worktree(
            repoID: repoID,
            name: "holding",
            displayName: "holding",
            branch: "tbd/holding",
            path: "/tmp/wt",
            status: .active,
            tmuxServer: "test-server",
            pendingPrompt: "recover me"
        )
    }

    @Test("Cmd+N over an open read-back queues instead of swapping the sheet")
    func creationQueuesBehindAnOpenReadback() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            let holding = parkedWorktree(repoID: repoID)
            state.worktrees[repoID] = [holding]
            state.revealParkedPrompt(holding)
            #expect(state.parkedPromptReadback != nil)

            // Menu-bar commands still fire with a sheet on screen.
            state.createWorktree(repoID: repoID)

            // Presenting the modal now would flip the bound sheet item from the
            // read-back to the new target WITHOUT passing through nil — the
            // same non-nil→non-nil swap the creation queue exists to avoid,
            // entered by the other door.
            #expect(state.queuedPromptTarget == nil)
            #expect(state.queuedPromptBacklog.count == 1)
            #expect(state.parkedPromptReadback != nil)

            // Closing the read-back frees the slot; the queued modal opens.
            state.parkedPromptReadback = nil
            await waitUntil("queued modal presented") { state.queuedPromptTarget != nil }
            #expect(state.queuedPromptBacklog.isEmpty)

            // And it is still the target for the worktree that was created.
            let target = try #require(state.queuedPromptTarget)
            state.submitQueuedPrompt(target, text: "for the new one", submit: true)
            await waitUntil("prompt parked") { harness.parked != nil }
            #expect(harness.parked?.worktreeID == created.id)
        }
    }

    @Test("A read-back opened in the gap does not get presented over")
    func deferredPresentationYieldsToAReadback() async throws {
        try await withAppState { state in
            let repoID = UUID()
            let created = daemonWorktree(repoID: repoID)
            let harness = Harness()
            arm(state, harness, created: created)
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            let holding = parkedWorktree(repoID: repoID)
            state.worktrees[repoID] = [holding]
            state.revealParkedPrompt(holding)
            state.createWorktree(repoID: repoID)
            #expect(state.queuedPromptBacklog.count == 1)

            // The backlog opens on a LATER main-actor turn, and the sidebar is
            // clickable the moment the sheet closes — so the slot can be taken
            // inside that gap.
            state.parkedPromptReadback = nil
            state.revealParkedPrompt(holding)
            await drain()

            #expect(state.parkedPromptReadback != nil)
            #expect(state.queuedPromptTarget == nil)
            // Put back at the HEAD of the queue, not dropped.
            #expect(state.queuedPromptBacklog.count == 1)

            // It opens once the slot is genuinely free.
            state.parkedPromptReadback = nil
            await waitUntil("queued modal presented") { state.queuedPromptTarget != nil }
        }
    }

    @Test("A read-back cannot open over a compose modal")
    func readbackDeclinesWhileComposing() async {
        await withAppState { state in
            let repoID = UUID()
            let harness = Harness()
            arm(state, harness, created: daemonWorktree(repoID: repoID))
            state.daemonCapabilities = capabilities(queuedPrompt: true)

            state.createWorktree(repoID: repoID)
            #expect(state.queuedPromptTarget != nil)

            let holding = parkedWorktree(repoID: repoID)
            state.worktrees[repoID] = [holding]
            state.revealParkedPrompt(holding)

            // Unreachable by pointer — the modal covers the row — and refused
            // anyway, so the sheet slot is never held by both.
            #expect(state.parkedPromptReadback == nil)
        }
    }

    // MARK: - Settings toggle

    @Test("Settings toggle writes the daemon flag and re-reads capabilities")
    func settingsToggleDrivesTheRPC() async {
        await withAppState { state in
            let harness = Harness()
            arm(state, harness, created: daemonWorktree(repoID: UUID()))
            state.daemonCapabilitiesFetcher = { self.capabilities(queuedPrompt: true) }

            await state.setQueuedPromptEnabled(true)

            #expect(harness.flagWrites == [true])
            #expect(state.daemonCapabilities?.queuedPromptEnabled == true)
        }
    }
}
