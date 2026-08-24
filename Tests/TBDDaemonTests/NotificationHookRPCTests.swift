import Foundation
import Testing
@testable import TBDDaemonLib
@testable import TBDShared
import TestSupport

/// Tier 1. `terminal.notificationEvent` records one fact, and for a
/// prompt-on-screen classification raises the attention notification the
/// sidebar renders. Two properties carry most of the weight here:
///
/// 1. Every classification branch records the message verbatim beside the label
///    TBD put on it, and an unrecognized type stays unrecognized.
/// 2. **`activityState` is untouched by all of them.** It gates parking, so a
///    hook that could move it would silently change which sessions hibernate.
///    Every branch test asserts the activity triple is byte-identical
///    afterward, and the hibernation gate's own decision is asserted alongside
///    it rather than inferred from that.
@Suite struct NotificationHookRPCTests {
    let db: TBDDatabase
    let router: RPCRouter
    let terminalID: UUID
    let worktreeID: UUID
    let worktreePath: String
    /// Every delta the handler broadcasts, captured through a real subscriber
    /// on the router's own `StateSubscriptionManager` (`broadcast` fans out
    /// synchronously, so the capture is complete once the handler returns).
    fileprivate let broadcasts: BroadcastDeltas
    /// Shared with `activityRouter` so the retraction broadcast the activity
    /// rail emits lands in the same collector as the notification's.
    private let subscriptions: StateSubscriptionManager

    /// Pinned through the router's date seam, so the stored observed-at is an
    /// exact assertion rather than a freshness window.
    static let observedAt = Date(timeIntervalSince1970: 1_780_000_000)

    init() async throws {
        let db = try TBDDatabase(inMemory: true)
        self.db = db
        let broadcasts = BroadcastDeltas()
        self.broadcasts = broadcasts
        let subscriptions = StateSubscriptionManager()
        self.subscriptions = subscriptions
        subscriptions.addSubscriber { data in
            if let delta = try? JSONDecoder().decode(StateDelta.self, from: data) {
                broadcasts.append(delta)
            }
            return true
        }
        self.router = RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subscriptions,
            now: { Self.observedAt },
            actuationLog: makeTestActuationLog())
        let repo = try await db.repos.create(
            path: "/tmp/notif-repo-\(UUID().uuidString)", displayName: "N", defaultBranch: "main")
        worktreePath = "/tmp/notif-wt-\(UUID().uuidString)"
        let wt = try await db.worktrees.create(
            repoID: repo.id, name: "w", branch: "b",
            path: worktreePath, tmuxServer: "tbd-notif")
        worktreeID = wt.id
        let terminal = try await db.terminals.create(
            worktreeID: wt.id, tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: "claude", claudeSessionID: "s-1", kind: .claude)
        terminalID = terminal.id
        // A resting, park-eligible session with a full activity triple, so the
        // "unchanged" assertions have something specific to be unchanged.
        try await db.terminals.setActivityState(
            id: terminal.id, activityState: .idle,
            source: .hookEvent("Stop"), observedAt: Self.baselineActivityAt)
    }

    static let baselineActivityAt = Date(timeIntervalSince1970: 1_779_000_000)

    private func notify(
        type: String?,
        message: String = "Claude needs your permission to use Bash",
        title: String? = nil,
        rawPayload: String? = nil,
        cwd: String? = nil,
        terminalID: UUID? = nil
    ) async -> RPCResponse {
        let request = try! RPCRequest(
            method: RPCMethod.terminalNotificationEvent,
            params: TerminalNotificationEventParams(
                terminalID: terminalID ?? self.terminalID,
                notificationType: type,
                message: message,
                title: title,
                rawPayload: rawPayload,
                cwd: cwd))
        return await router.handle(request)
    }

    private func terminal() async throws -> Terminal {
        try #require(try await db.terminals.get(id: terminalID))
    }

    private func activityRouter(observedAt: Date) -> RPCRouter {
        RPCRouter(
            db: db,
            lifecycle: WorktreeLifecycle(
                db: db, git: GitManager(),
                tmux: TmuxManager(dryRun: true), hooks: HookResolver()),
            tmux: TmuxManager(dryRun: true),
            startTime: Date(),
            subscriptions: subscriptions,
            now: { observedAt },
            actuationLog: makeTestActuationLog())
    }

    /// Every awaiting-input delta the collector saw, in order.
    private func awaitingInputDeltas() -> [TerminalAwaitingInputDelta] {
        broadcasts.snapshot().compactMap { delta in
            if case .terminalAwaitingInputChanged(let d) = delta { return d }
            return nil
        }
    }

    private func sendActivity(
        _ activityState: TerminalActivityState, at observedAt: Date
    ) async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminalID, activityState: activityState))
        #expect(await activityRouter(observedAt: observedAt).handle(request).success)
    }

    /// The park decision for the current row, plus the raw activity triple —
    /// the two things this slice must leave alone.
    private func parkDecision(_ terminal: Terminal) -> HibernationGate.Decision {
        HibernationGate.decide(
            terminal: terminal,
            autoHibernateEnabled: true,
            idleTimeout: 60,
            idleSince: Self.baselineActivityAt,
            now: Self.baselineActivityAt.addingTimeInterval(3600))
    }

    // MARK: - Classification branches

    struct Branch: Sendable, CustomStringConvertible {
        let type: String?
        let expected: AwaitingInputClass
        var description: String { "\(type ?? "<absent>") → \(expected.rawValue)" }
    }

    /// Every documented `notification_type`, plus an absent one and one this
    /// build has never seen. One case per branch of the classifier.
    static let classifications: [Branch] = [
        Branch(type: "permission_prompt", expected: .promptOnScreen),
        Branch(type: "elicitation_dialog", expected: .promptOnScreen),
        Branch(type: "agent_needs_input", expected: .promptOnScreen),
        Branch(type: "idle_prompt", expected: .doneWaiting),
        Branch(type: "auth_success", expected: .informational),
        Branch(type: "elicitation_complete", expected: .informational),
        Branch(type: "elicitation_response", expected: .informational),
        Branch(type: "agent_completed", expected: .informational),
        Branch(type: "some_future_type", expected: .unrecognized),
        Branch(type: nil, expected: .unrecognized)
    ]

    @Test(arguments: classifications)
    func recordsTheReasonWithItsClassAndLeavesActivityAlone(branch: Branch) async throws {
        let before = try await terminal()
        let message = "Claude needs your permission to use Bash"

        let response = await notify(type: branch.type, message: message, title: "Permission needed")
        #expect(response.success)

        let after = try await terminal()
        let reason = try #require(after.awaitingInputReason)
        #expect(reason.message == message)
        #expect(reason.notificationType == branch.type)
        #expect(reason.classification == branch.expected)
        #expect(reason.hookEventName == "Notification")
        #expect(after.awaitingInputObservedAt == Self.observedAt)

        // The composed output — what any surface that reports this fact must
        // print — carries the message, the class, the source and the age.
        let fact = try #require(after.observedAwaitingInput)
        #expect(fact.source == .hookEvent("Notification"))
        #expect(fact.observedAt == Self.observedAt)
        let summary = fact.summary
        #expect(summary.contains(message))
        #expect(summary.contains(branch.expected.rawValue))
        #expect(summary.contains("source: hook:Notification"))
        #expect(summary.contains(FactTimestamp.string(from: Self.observedAt)))

        // …and the activity fact is byte-identical: same value, same source,
        // same observed-at. Nothing here may move a gating field.
        #expect(after.activityState == before.activityState)
        #expect(after.activityStateSource == before.activityStateSource)
        #expect(after.activityStateObservedAt == before.activityStateObservedAt)
        #expect(after.observedActivity == before.observedActivity)

        // Hibernation eligibility follows from that, but is asserted directly
        // rather than assumed.
        #expect(parkDecision(after) == parkDecision(before))
        #expect(parkDecision(after) == .eligible)
        #expect(HibernationGate.blockingRail(terminal: after) == nil)

        // A prompt on screen is the one class a human has to act on now, so
        // it, and only it, raises the attention notification behind the macOS
        // banner. Every other class leaves the notification ledger untouched.
        // (The awaiting-input delta is broadcast for every class that is
        // written — the app mirrors the columns — and is asserted separately.)
        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        let received = broadcasts.snapshot().filter {
            if case .notificationReceived = $0 { return true }
            return false
        }
        if branch.expected == .promptOnScreen {
            #expect(unread.count == 1)
            #expect(unread.first?.type == .attentionNeeded)
            #expect(received.count == 1)
        } else {
            #expect(unread.isEmpty)
            #expect(received.isEmpty)
        }
    }

    /// The delta the app renders from: it must carry the created row's own
    /// identity and message, so the sidebar's unread state and the row agree.
    @Test func aPromptOnScreenBroadcastsTheNotificationItCreated() async throws {
        let message = "Claude needs your permission to use Bash"
        #expect(await notify(type: "permission_prompt", message: message).success)

        let unread = try await db.notifications.unread(worktreeID: worktreeID)
        let row = try #require(unread.first)
        #expect(unread.count == 1)
        #expect(row.type == .attentionNeeded)
        #expect(row.worktreeID == worktreeID)
        #expect(row.message == message)

        let delta = try #require(broadcasts.snapshot().compactMap { delta -> NotificationDelta? in
            if case .notificationReceived(let d) = delta { return d }
            return nil
        }.first)
        #expect(delta.notificationID == row.id)
        #expect(delta.worktreeID == worktreeID)
        #expect(delta.type == .attentionNeeded)
        #expect(delta.message == message)
    }

    /// A notification hook can arrive with an empty message; the banner still
    /// has to say something a human can act on.
    @Test func anEmptyMessageFallsBackToTheGenericBanner() async throws {
        #expect(await notify(type: "permission_prompt", message: "").success)

        let row = try #require(try await db.notifications.unread(worktreeID: worktreeID).first)
        #expect(row.message == "Claude needs your input")

        let delta = try #require(broadcasts.snapshot().compactMap { delta -> NotificationDelta? in
            if case .notificationReceived(let d) = delta { return d }
            return nil
        }.first)
        #expect(delta.message == "Claude needs your input")
    }

    /// A near-miss spelling of a known type is the case a "helpful" matcher
    /// would fold into `promptOnScreen`. It must not be.
    @Test(arguments: ["permission_prompt_v2", "PERMISSION_PROMPT", " permission_prompt", "prompt", ""])
    func lookalikeTypesAreNeverFoldedIntoAKnownClass(type: String) async throws {
        #expect(await notify(type: type).success)
        let reason = try #require(try await terminal().awaitingInputReason)
        #expect(reason.notificationType == type, "the type is recorded verbatim")
        #expect(reason.classification == .unrecognized)
    }

    // MARK: - The verbatim payload

    @Test func rawPayloadSurvivesTheRoundTripUnmodified() async throws {
        // Includes a field this build does not model (`permission_mode`) and
        // unicode, because the point of carrying it verbatim is that a later
        // consumer can read what TBD never parsed.
        let raw = #"""
        {"session_id":"abc123","cwd":"/x","hook_event_name":"Notification",\#
        "message":"Claude needs your permission — “Bash”","title":"Permission needed",\#
        "notification_type":"permission_prompt","permission_mode":"default","prompt_id":"p-1"}
        """#
        #expect(await notify(type: "permission_prompt", rawPayload: raw).success)

        let reason = try #require(try await terminal().awaitingInputReason)
        #expect(reason.raw == raw)
        // Still parseable as the JSON it was — nothing re-encoded it.
        let storedRaw = try #require(reason.raw)
        let object = try JSONSerialization.jsonObject(with: Data(storedRaw.utf8))
        #expect((object as? [String: Any])?["permission_mode"] as? String == "default")
    }

    @Test func absentRawPayloadIsCarriedAsAnAbsence() async throws {
        #expect(await notify(type: "idle_prompt", rawPayload: nil).success)
        let reason = try #require(try await terminal().awaitingInputReason)
        #expect(reason.raw == nil)
        #expect(reason.classification == .doneWaiting)
    }

    // MARK: - Guards

    @Test func unknownTerminalIsASoftNoOp() async throws {
        let response = await notify(type: "permission_prompt", terminalID: UUID())
        #expect(response.success, "an unknown terminal must not throw at a fire-and-forget hook")
        // …and nothing was written to the real terminal.
        #expect(try await terminal().awaitingInputReason == nil)
    }

    @Test func aForeignSessionsCWDIsRejected() async throws {
        // A hook fired by a session living in another worktree — the shape
        // `TBD_TERMINAL_ID` inheritance makes possible — must not write here.
        let otherRepo = try await db.repos.create(
            path: "/tmp/notif-other-repo-\(UUID().uuidString)", displayName: "O",
            defaultBranch: "main")
        let otherPath = "/tmp/notif-other-wt-\(UUID().uuidString)"
        _ = try await db.worktrees.create(
            repoID: otherRepo.id, name: "o", branch: "ob",
            path: otherPath, tmuxServer: "tbd-notif")

        let response = await notify(type: "permission_prompt", cwd: otherPath)
        #expect(response.success)
        #expect(try await terminal().awaitingInputReason == nil)
    }

    @Test func theOwningWorktreesCWDIsAccepted() async throws {
        #expect(await notify(type: "permission_prompt", cwd: worktreePath).success)
        #expect(try await terminal().awaitingInputReason != nil)
    }

    @Test func anAbsentCWDCannotBeValidatedSoTheEventIsAccepted() async throws {
        // Backward compatibility with a CLI that doesn't send it — the same
        // fallback `terminal.sessionEvent` makes.
        #expect(await notify(type: "permission_prompt", cwd: nil).success)
        #expect(try await terminal().awaitingInputReason != nil)
    }

    // MARK: - Superseding

    /// The rail that keeps a recorded reason honest: the next newer activity
    /// observation clears it, so a "needs your permission" cannot outlive the
    /// prompt it described.
    @Test func theNextActivityObservationSupersedesTheRecordedReason() async throws {
        #expect(await notify(type: "permission_prompt").success)
        #expect(try await terminal().awaitingInputReason != nil)

        // The user answered and the turn resumed — UserPromptSubmit arrives as
        // activity=working through the ordinary bridge.
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminalID, activityState: .working))
        #expect(await activityRouter(
            observedAt: Self.observedAt.addingTimeInterval(1)).handle(request).success)

        let after = try await terminal()
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        #expect(after.observedAwaitingInput == nil)
        #expect(after.activityState == .working)
    }

    /// A second notification replaces the first rather than accumulating —
    /// the stored reason always describes the most recent one.
    @Test func aLaterNotificationReplacesTheRecordedReason() async throws {
        #expect(await notify(type: "permission_prompt", message: "first").success)
        #expect(await notify(type: "idle_prompt", message: "second").success)
        let reason = try #require(try await terminal().awaitingInputReason)
        #expect(reason.message == "second")
        #expect(reason.classification == .doneWaiting)
    }

    // MARK: - What may and may not clear a standing prompt

    /// The overlay registers `Notification` with **no matcher**, so every type
    /// arrives here — including the ones that fire while a permission prompt is
    /// still on screen. A subagent finishing sends `agent_completed`, which is
    /// `informational`: it observed nothing about the prompt, and letting it
    /// overwrite the reason columns would erase a live prompt and leave the
    /// session reading as un-blocked.
    @Test(arguments: ["agent_completed", "auth_success", "elicitation_complete",
                      "elicitation_response", "some_future_type", nil])
    func aClassThatEstablishesNothingCannotClearAStandingPrompt(type: String?) async throws {
        #expect(await notify(type: "permission_prompt", message: "needs your permission").success)

        #expect(await notify(type: type, message: "a subagent finished").success)

        let after = try await terminal()
        let reason = try #require(after.awaitingInputReason)
        #expect(reason.message == "needs your permission")
        #expect(reason.classification == .promptOnScreen)
        #expect(reason.notificationType == "permission_prompt")
        // The stamp stays the prompt's own, so the resolver's ordering
        // comparison still describes the moment the prompt was reported.
        #expect(after.awaitingInputObservedAt == Self.observedAt)
    }

    /// The other half of the same rule, so the guard is a refusal and not a
    /// freeze: a newer prompt, and the agent reporting it is back at its own
    /// prompt, both write.
    @Test(arguments: [("permission_prompt", AwaitingInputClass.promptOnScreen),
                      ("idle_prompt", AwaitingInputClass.doneWaiting)])
    func aClassThatDoesSpeakStillSupersedesAStandingPrompt(
        type: String, expected: AwaitingInputClass
    ) async throws {
        #expect(await notify(type: "permission_prompt", message: "first prompt").success)

        #expect(await notify(type: type, message: "the newer report").success)

        let reason = try #require(try await terminal().awaitingInputReason)
        #expect(reason.message == "the newer report")
        #expect(reason.classification == expected)
    }

    /// And the activity rail is untouched by the guard: a genuine observation
    /// that the session moved on still retracts the prompt, exactly as before.
    @Test func theActivityRailStillClearsAStandingPrompt() async throws {
        #expect(await notify(type: "permission_prompt").success)
        #expect(await notify(type: "agent_completed", message: "subagent done").success)
        #expect(try await terminal().awaitingInputReason?.classification == .promptOnScreen)

        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminalID, activityState: .working))
        #expect(await activityRouter(
            observedAt: Self.observedAt.addingTimeInterval(1)).handle(request).success)

        #expect(try await terminal().awaitingInputReason == nil)
    }

    // MARK: - The awaiting-input delta

    /// The sidebar reads the reason columns, not the notification row, so the
    /// record has to reach the app by push. The notification is unread mail —
    /// selecting a worktree marks it read, which is why the row the user was
    /// looking at kept animating the thinking dots at a session sitting on a
    /// permission prompt.
    @Test func aRecordedPromptIsBroadcastAlongsideTheNotification() async throws {
        let message = "Claude needs your permission to use Bash"
        #expect(await notify(type: "permission_prompt", message: message).success)

        let delta = try #require(awaitingInputDeltas().first)
        #expect(awaitingInputDeltas().count == 1)
        #expect(delta.terminalID == terminalID)
        #expect(delta.worktreeID == worktreeID)
        #expect(delta.observedAt == Self.observedAt)
        #expect(delta.reason?.message == message)
        #expect(delta.reason?.notificationType == "permission_prompt")
        #expect(delta.reason?.classification == .promptOnScreen)
    }

    /// Every class is broadcast, not only the one the sidebar renders: the app
    /// mirrors the columns rather than deriving them, so a `doneWaiting` that
    /// replaces a standing prompt has to reach it too.
    @Test func aNonPromptClassIsBroadcastToo() async throws {
        #expect(await notify(type: "idle_prompt", message: "back at the prompt").success)

        let delta = try #require(awaitingInputDeltas().first)
        #expect(delta.reason?.classification == .doneWaiting)
    }

    /// The mirror of the write guard: a report that establishes nothing does
    /// not change the record, so there is nothing to announce.
    @Test func aRefusedReportBroadcastsNothing() async throws {
        #expect(await notify(type: "permission_prompt", message: "needs permission").success)
        #expect(awaitingInputDeltas().count == 1)

        #expect(await notify(type: "agent_completed", message: "a subagent finished").success)

        #expect(awaitingInputDeltas().count == 1, "the standing prompt is unchanged")
    }

    /// **The staleness case, and the reason the retraction cannot ride the
    /// activity delta.** A permission prompt is raised in the MIDDLE of a turn,
    /// so the session already reads `working`; the hook that fires once the
    /// human answers reports `working` again. The handler's unchanged-state
    /// guard drops that observation, so a reason retracted only on a *changed*
    /// state would stay pinned to the row until the turn ended — minutes of
    /// attention indicator for a prompt nobody is looking at.
    @Test func aSameStateActivityObservationStillRetractsAStandingPrompt() async throws {
        try await sendActivity(.working, at: Self.observedAt.addingTimeInterval(-1))
        #expect(await notify(type: "permission_prompt").success)
        #expect(try await terminal().awaitingInputReason != nil)

        try await sendActivity(.working, at: Self.observedAt.addingTimeInterval(1))

        let after = try await terminal()
        #expect(after.awaitingInputReason == nil)
        #expect(after.awaitingInputObservedAt == nil)
        #expect(after.activityState == .working, "activityState is left exactly as it was")

        let retraction = try #require(awaitingInputDeltas().last)
        #expect(retraction.reason == nil)
        #expect(retraction.observedAt == nil)
        #expect(retraction.terminalID == terminalID)
        #expect(retraction.worktreeID == worktreeID)
    }

    /// The changed-state path announces its retraction as well — the app must
    /// not need a `terminal.list` refresh to stop showing the indicator.
    @Test func aChangedStateActivityObservationBroadcastsTheRetraction() async throws {
        #expect(await notify(type: "permission_prompt").success)

        try await sendActivity(.working, at: Self.observedAt.addingTimeInterval(1))

        #expect(try await terminal().awaitingInputReason == nil)
        let retraction = try #require(awaitingInputDeltas().last)
        #expect(retraction.reason == nil)
    }

    /// No standing reason means no retraction to announce, so an ordinary turn
    /// boundary does not add a delta per hook event.
    @Test func anActivityObservationWithNoStandingReasonBroadcastsNothing() async throws {
        try await sendActivity(.working, at: Self.observedAt.addingTimeInterval(1))
        try await sendActivity(.idle, at: Self.observedAt.addingTimeInterval(2))

        #expect(awaitingInputDeltas().isEmpty)
    }

    /// The ordering rule survives the move onto the same-state path: a reason
    /// recorded AFTER the activity event was stamped is newer than the
    /// observation superseding it, so it stands.
    ///
    /// Paired with its control, because the refusal on its own is satisfied by
    /// simply never running the retraction at all — the shape this test had
    /// before the control was added, which passed against a tree with no
    /// same-state retraction in it.
    @Test(arguments: [(-1.0, true), (1.0, false)])
    func aSameStateObservationRetractsOnlyANotNewerReason(
        offset: Double, survives: Bool
    ) async throws {
        try await sendActivity(.working, at: Self.observedAt.addingTimeInterval(-2))
        #expect(await notify(type: "permission_prompt").success)
        #expect(awaitingInputDeltas().count == 1)

        try await sendActivity(.working, at: Self.observedAt.addingTimeInterval(offset))

        let reason = try await terminal().awaitingInputReason
        #expect((reason?.classification == .promptOnScreen) == survives)
        // The retraction is announced exactly when it happened, so a tree that
        // stopped retracting on the same-state path fails the control half
        // rather than passing both.
        let retractions = awaitingInputDeltas().filter { $0.reason == nil }
        #expect(retractions.count == (survives ? 0 : 1))
    }

    /// The Codex rail retracts through `applyActivityObservation` rather than
    /// the same-state branch, and owes the app the same announcement.
    @Test func theCodexRailAlsoAnnouncesItsRetraction() async throws {
        let codex = try await db.terminals.create(
            worktreeID: worktreeID, tmuxWindowID: "@2", tmuxPaneID: "%2",
            label: "codex", claudeSessionID: "s-2", kind: .codex)
        #expect(await notify(type: "permission_prompt", terminalID: codex.id).success)
        #expect(try await db.terminals.get(id: codex.id)?.awaitingInputReason != nil)

        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: codex.id, activityState: .working, sessionID: "s-2"))
        #expect(await activityRouter(
            observedAt: Self.observedAt.addingTimeInterval(1)).handle(request).success)

        #expect(try await db.terminals.get(id: codex.id)?.awaitingInputReason == nil)
        let retraction = try #require(awaitingInputDeltas().last)
        #expect(retraction.reason == nil)
        #expect(retraction.terminalID == codex.id)
    }

    /// A `/clear`, a resume, or a hand relaunch replaces the process the prompt
    /// was raised on. The store retracts the reason; the app has to be told, or
    /// its cached row keeps the indicator up on a session that no longer holds
    /// the prompt.
    @Test func aSessionStartAnnouncesItsRetraction() async throws {
        #expect(await notify(type: "permission_prompt").success)
        #expect(try await terminal().awaitingInputReason != nil)

        let request = try RPCRequest(
            method: RPCMethod.terminalSessionEvent,
            params: TerminalSessionEventParams(
                terminalID: terminalID, sessionID: "s-2",
                transcriptPath: nil, source: "clear"))
        #expect(await router.handle(request).success)

        #expect(try await terminal().awaitingInputReason == nil)
        let retraction = try #require(awaitingInputDeltas().last)
        #expect(retraction.reason == nil)
        #expect(retraction.terminalID == terminalID)
    }

    /// The router's date seam reaches BOTH stamps the resolver's rung-4 decision
    /// compares. `setActivityState` defaults `observedAt` to a bare `Date()` at
    /// the store, so a handler that omitted it would leave one end of that
    /// ordering un-pinnable by any test.
    @Test func theActivityObservationIsStampedFromTheRoutersDateSeam() async throws {
        let request = try RPCRequest(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(terminalID: terminalID, activityState: .working))
        #expect(await router.handle(request).success)

        let after = try await terminal()
        #expect(after.activityStateObservedAt == Self.observedAt)
        #expect(after.observedActivity?.observedAt == Self.observedAt)
    }
}

/// Thread-safe collector for broadcast StateDeltas (same shape as the one in
/// `RPCRouterWorktreeCreateBroadcastTests`).
private final class BroadcastDeltas: @unchecked Sendable {
    private let lock = NSLock()
    private var deltas: [StateDelta] = []

    func append(_ delta: StateDelta) {
        lock.lock(); defer { lock.unlock() }
        deltas.append(delta)
    }

    func snapshot() -> [StateDelta] {
        lock.lock(); defer { lock.unlock() }
        return deltas
    }
}
