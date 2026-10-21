import Foundation
import os
import TBDShared

/// Holds the daemon's view of open Claude Code dialogs, in two shapes.
///
/// - **Captures** – pending `AskUserQuestion`s recorded by the pre-tool hook,
///   keyed on `(terminalID, toolUseID)`. The app's `AskUserQuestionMerger`
///   drops one once its `tool_use_id` reaches the JSONL — see
///   `RPCRouter+TerminalHandlers.swift`.
/// - **Prompts** – dialogs the session's TBD mod reported open so the app can
///   answer them from the transcript
///   (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`), keyed on
///   `(terminalID, toolUseID)`: the prompt id is the dialog's tool call id.
///   The mod drives each one through four inputs:
///   - **open** – the dialog appeared (or the mod re-posts it after a
///     reconnect, which refreshes the same prompt);
///   - **wait** – the mod's held request for an answer, repeated while the
///     dialog stays open;
///   - **receipt** – the mod returned TBD's decision to Claude Code;
///   - **closed** – the terminal answered first.
///
/// Memory-only; a daemon restart wipes the store, and the mod re-posts its
/// open dialogs. It creates no durable resource: Claude Code owns the dialog,
/// and every record here resolves on its own (a receipt, a close, the terminal
/// or session ending, no wait request for a minute, or shutdown).
///
/// Not to be confused with `PendingPromptCoordinator`, which parks a
/// worktree's queued first message.
public actor PendingPromptStore {
    public struct Key: Hashable, Sendable {
        public let terminalID: UUID
        public let toolUseID: String
    }

    /// One terminal's captures and prompts together with the revision that
    /// produced them.
    ///
    /// Handed out as a unit by a single actor call on purpose. A broadcaster
    /// that read the set and its revision in two `await`s could be suspended
    /// between them and publish a set stamped with someone else's revision —
    /// exactly the tear the revision exists to detect.
    public struct Snapshot: Sendable, Equatable {
        public let entries: [PendingAskUserQuestion]
        public let prompts: [PendingPromptPayload]
        public let revision: UInt64
    }

    /// Why a prompt ended, for the log and for tests.
    public enum Resolution: String, Sendable, Equatable {
        /// The mod's receipt: TBD's decision reached Claude Code (or no
        /// receipt came back in time after the hand-over).
        case answered
        /// The mod's close: the terminal answered first.
        case answeredInTerminal
        /// The terminal ended.
        case terminalGone
        /// The terminal's Claude session ended.
        case sessionEnded
        /// No wait request held the prompt for the idle threshold: the mod
        /// that reported it is no longer waiting on it.
        case modDisconnected
        /// The daemon is stopping.
        case daemonShutdown
    }

    public enum AnswerOutcome: Sendable, Equatable {
        /// The mod's receipt arrived: the decision reached Claude Code.
        case delivered
        /// Unknown id, a different terminal, already answered, or the
        /// terminal answered first: the terminal is in charge.
        case alreadyResolved
        /// The decision went to the mod but no receipt came back within the
        /// ack timeout: it may or may not have reached Claude. The prompt is
        /// resolved either way, so a retry reads `.alreadyResolved`.
        case deliveryUnconfirmed
        /// No wait request picked the decision up within the pickup timeout.
        /// The decision is withdrawn and the prompt stays open, so the caller
        /// may retry.
        case hookDetached
        /// The answer does not fit the prompt; the prompt stays open.
        case invalid(PromptAnswerValidation)
    }

    /// What one wait request gets back.
    public enum WaitResult: Sendable, Equatable {
        /// TBD's decision: the `decision` object as one JSON string
        /// (`PromptDecisionEncoder.decisionJSON`).
        case decision(String)
        /// Nothing yet: the hold elapsed, or a newer wait request replaced
        /// this one. The mod asks again while the dialog is open.
        case pending
        /// The prompt is unknown or has resolved: stop waiting.
        case resolved
    }

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "pendingPrompt")

    // MARK: Captures

    private var pending: [Key: PendingAskUserQuestion] = [:]

    // MARK: Prompts

    /// A held wait request.
    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<WaitResult, Never>
        /// Returns `.pending` once the hold elapses.
        let holdTimer: Task<Void, Never>
    }

    /// What an `answer` call parked on the prompt is told.
    private enum AnswerSignal {
        /// A wait request took the held decision.
        case pickedUp
        /// The phase's timeout elapsed first.
        case timedOut
        /// The prompt ended.
        case resolved(Resolution)
    }

    /// The one answer a prompt accepts, while it is in flight.
    private struct PendingAnswer {
        /// Names this answer's waits, so a stale timer or signal cannot touch
        /// a later one.
        let token: UUID
        let decisionJSON: String
        /// A wait request has the decision; the answer waits for a receipt.
        var handedOver: Bool
        /// The parked `answer` call, while it is parked.
        var continuation: CheckedContinuation<AnswerSignal, Never>?
        /// Names the current park, so the pickup park's timer cannot end the
        /// receipt park that follows it.
        var parkID: UUID?
    }

    private struct PromptRecord {
        var payload: PendingPromptPayload
        /// The Claude session the mod reported, for the log only. Prompts are
        /// keyed and cleared by terminal; a session ID is not an address.
        var sessionID: String?
        /// When a wait request last attached to or left this prompt, or when
        /// it was opened. With no wait attached, the idle sweep measures from
        /// here (``resolveIdlePrompts(now:threshold:)``).
        var lastWaitAt: Date
        /// Distinguishes this record from a later one under the same key, so
        /// an `answer` that outlived its prompt cannot act on a newer one.
        let generation: UUID
        var waiter: Waiter?
        var pendingAnswer: PendingAnswer?
    }

    private var promptRecords: [Key: PromptRecord] = [:]
    /// Signals that reached a pending answer between its two parks (after a
    /// pickup, before it parked for the receipt), by answer token. The parked
    /// call collects its own entry, so none outlives its `answer`.
    private var earlySignals: [UUID: AnswerSignal] = [:]

    /// Per-terminal mutation counter. Monotonic within one daemon run, and
    /// only ever compared against another revision for the SAME terminal —
    /// terminals never share an ordering domain.
    ///
    /// It exists because publishing is two steps (mutate, then read-and-send)
    /// and the actor only makes each step atomic, not the pair. Two tasks
    /// mutating one terminal can therefore reach `broadcast` in either order,
    /// and the app replaces its whole list per delta — so a `set` that lands
    /// after a `clear` resurrects a question the user already answered.
    /// Stamping each published set lets the app drop what it can see is stale.
    private var revisions: [UUID: UInt64] = [:]

    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    public init(
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.now = now
        self.clock = clock
    }

    private func bumpRevision(_ terminalID: UUID) {
        revisions[terminalID, default: 0] += 1
    }

    // MARK: - Captures

    public func set(terminalID: UUID, _ value: PendingAskUserQuestion) {
        let key = Key(terminalID: terminalID, toolUseID: value.toolUseID)
        pending[key] = value
        bumpRevision(terminalID)
    }

    public func clear(terminalID: UUID, toolUseID: String) {
        pending.removeValue(forKey: Key(terminalID: terminalID, toolUseID: toolUseID))
        bumpRevision(terminalID)
    }

    /// Drops everything the terminal holds: its captures and its open prompts
    /// (resolved `.terminalGone`, so each held wait request returns
    /// `.resolved`). Every lifecycle site that ends a terminal already calls
    /// this.
    public func clear(terminalID: UUID) {
        pending = pending.filter { $0.key.terminalID != terminalID }
        for key in promptRecords.keys where key.terminalID == terminalID {
            resolve(key, .terminalGone, bump: false)
        }
        bumpRevision(terminalID)
    }

    public func entries(forTerminal terminalID: UUID) -> [PendingAskUserQuestion] {
        pending
            .filter { $0.key.terminalID == terminalID }
            .values
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// The terminal's open prompts, oldest first.
    public func prompts(forTerminal terminalID: UUID) -> [PendingPromptPayload] {
        promptRecords
            .filter { $0.key.terminalID == terminalID }
            .values
            .map(\.payload)
            .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// The set and its revision, read together. This is what a broadcaster
    /// publishes — see ``Snapshot``.
    public func snapshot(forTerminal terminalID: UUID) -> Snapshot {
        Snapshot(
            entries: entries(forTerminal: terminalID),
            prompts: prompts(forTerminal: terminalID),
            revision: revisions[terminalID] ?? 0)
    }

    /// Reap captures older than `maxAge` relative to `now`, and report which
    /// terminals lost one. An entry strands when a user-installed PreToolUse
    /// hook returns `decision: "block"`, so no matching `tool_use_id` ever
    /// reaches the JSONL to satisfy it.
    ///
    /// Driven by `PendingPromptExpirySweep` on its own timer, and also once
    /// per `handleTerminalTranscript` while that path is still live. The
    /// returned terminal ids are what a caller broadcasts: a reap is a
    /// mutation like any other, and a set reaped without a retraction leaves
    /// the app rendering an entry the daemon no longer holds.
    @discardableResult
    public func gcExpired(now: Date, maxAge: Duration) -> Set<UUID> {
        let cutoff = now.addingTimeInterval(-Self.seconds(maxAge))
        var reaped: Set<UUID> = []
        for (key, value) in pending where value.timestamp < cutoff {
            pending.removeValue(forKey: key)
            reaped.insert(key.terminalID)
        }
        for terminalID in reaped {
            bumpRevision(terminalID)
        }
        return reaped
    }

    // MARK: - Open

    /// Records a dialog the mod reported open. Returns the terminals whose
    /// prompt set changed.
    ///
    /// `kind` is `.question` for `AskUserQuestion`, `.permission` otherwise.
    /// `sessionID` is informational (the log); the mod may omit it.
    /// A repeat for the same `(terminalID, toolUseID)` is the same prompt
    /// re-posted after a reconnect: it refreshes the payload and keeps
    /// `createdAt`, any held wait request and any answer in flight. Every
    /// open, repeat or not, restarts the prompt's idle measure. The same
    /// `toolUseID` under another terminal is a separate prompt — two
    /// terminals resumed into one session stay apart because the address is
    /// the terminal.
    @discardableResult
    public func open(terminalID: UUID, sessionID: String?, toolUseID: String, toolName: String,
                     toolInputJSON: String, suggestionsJSON: String?) -> Set<UUID> {
        let key = Key(terminalID: terminalID, toolUseID: toolUseID)
        let kind: PendingPromptKind = toolName == "AskUserQuestion" ? .question : .permission
        let existing = promptRecords[key]
        let payload = PendingPromptPayload(
            id: toolUseID, kind: kind, toolUseID: toolUseID, toolName: toolName,
            toolInputJSON: toolInputJSON, suggestionsJSON: suggestionsJSON,
            createdAt: existing?.payload.createdAt ?? now())
        if var record = existing {
            record.payload = payload
            record.sessionID = sessionID
            record.lastWaitAt = now()
            promptRecords[key] = record
        } else {
            promptRecords[key] = PromptRecord(
                payload: payload, sessionID: sessionID, lastWaitAt: now(),
                generation: UUID(), waiter: nil, pendingAnswer: nil)
        }
        bumpRevision(terminalID)
        Self.log.debug(
            "prompt opened id=\(toolUseID, privacy: .public) kind=\(kind.rawValue, privacy: .public) session=\(sessionID ?? "-", privacy: .public) repeat=\(existing != nil, privacy: .public)")
        return [terminalID]
    }

    // MARK: - Wait

    /// The mod's held request for an answer.
    ///
    /// - An unknown or resolved prompt returns `.resolved` at once.
    /// - An answer already in flight returns its decision at once, and the
    ///   record counts as handed over. That includes a decision handed to an
    ///   earlier request whose connection dropped before it was written: the
    ///   same decision again is harmless, and the receipt settles it.
    /// - Otherwise the request attaches as the prompt's waiter, replacing an
    ///   older one (which gets `.pending`), and returns `.pending` once `hold`
    ///   elapses with no answer.
    ///
    /// `token` names this request, so `waiterGone(token:)` detaches only it.
    /// Cancelling the calling task detaches it too, returning `.pending`
    /// whether the cancellation lands before the request attaches or while it
    /// is attached, and never resolves the prompt. A request cancelled before
    /// it attaches takes no decision, so the decision stays for the next one.
    /// Every request, and every way one ends, stamps the prompt's
    /// `lastWaitAt`, so the idle sweep spares a prompt the mod is still
    /// waiting on.
    public func waitForAnswer(terminalID: UUID, toolUseID: String, token: UUID,
                              hold: Duration) async -> WaitResult {
        let key = Key(terminalID: terminalID, toolUseID: toolUseID)
        guard let record = promptRecords[key] else { return .resolved }
        stampWait(key)
        // The request's connection already closed: nobody would receive a
        // decision, so leave it for the next request.
        if Task.isCancelled { return .pending }
        if let decision = takeDecision(key) { return .decision(decision) }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<WaitResult, Never>) in
                guard var current = promptRecords[key], current.generation == record.generation else {
                    continuation.resume(returning: .resolved)
                    return
                }
                // Checked on the actor, before attaching: a cancellation whose
                // handler ran earlier found no waiter to detach, so it is
                // honoured here; one that lands after this finds the waiter
                // attached and detaches it through `waiterGone`.
                guard !Task.isCancelled else {
                    continuation.resume(returning: .pending)
                    return
                }
                if let decision = takeDecision(key) {
                    continuation.resume(returning: .decision(decision))
                    return
                }
                current.lastWaitAt = now()
                if let old = current.waiter {
                    old.holdTimer.cancel()
                    old.continuation.resume(returning: .pending)
                }
                let holdTimer = Task { [weak self, clock] in
                    do { try await clock.sleep(for: hold) } catch { return }
                    await self?.holdElapsed(key: key, token: token)
                }
                current.waiter = Waiter(token: token, continuation: continuation, holdTimer: holdTimer)
                promptRecords[key] = current
            }
        } onCancel: {
            Task { await self.waiterGone(token: token) }
        }
    }

    /// The wait request's connection went away (the mod aborted its fetch),
    /// or its task was cancelled. Detaches that waiter and never resolves the
    /// prompt: the next wait request or a close decides. Harmless for a token
    /// no longer attached.
    public func waiterGone(token: UUID) {
        guard let key = promptRecords.first(where: { $0.value.waiter?.token == token })?.key else { return }
        detachWaiter(key, returning: .pending)
    }

    private func holdElapsed(key: Key, token: UUID) {
        guard promptRecords[key]?.waiter?.token == token else { return }
        detachWaiter(key, returning: .pending)
    }

    private func detachWaiter(_ key: Key, returning result: WaitResult) {
        guard var record = promptRecords[key], let waiter = record.waiter else { return }
        record.waiter = nil
        record.lastWaitAt = now()
        promptRecords[key] = record
        waiter.holdTimer.cancel()
        waiter.continuation.resume(returning: result)
    }

    /// Restarts the prompt's idle measure: a wait request arrived or left.
    private func stampWait(_ key: Key) {
        promptRecords[key]?.lastWaitAt = now()
    }

    /// The decision of the answer in flight, marking it handed over and
    /// telling an `answer` parked for pickup. Nil with no answer in flight.
    private func takeDecision(_ key: Key) -> String? {
        guard var record = promptRecords[key], var answer = record.pendingAnswer else { return nil }
        let pickupWaiter = answer.handedOver ? nil : answer.continuation
        answer.handedOver = true
        if pickupWaiter != nil { answer.continuation = nil }
        record.pendingAnswer = answer
        promptRecords[key] = record
        pickupWaiter?.resume(returning: .pickedUp)
        return answer.decisionJSON
    }

    // MARK: - Receipt and close

    /// The mod returned TBD's decision to Claude Code: an answer waiting for
    /// its receipt reads `.delivered`, and the prompt resolves `.answered`.
    /// Returns the terminals whose prompt set changed.
    @discardableResult
    public func receipt(terminalID: UUID, toolUseID: String) -> Set<UUID> {
        resolveOne(Key(terminalID: terminalID, toolUseID: toolUseID), .answered)
    }

    /// The terminal answered first: the prompt resolves `.answeredInTerminal`,
    /// and an answer waiting for its receipt reads `.alreadyResolved`.
    /// Returns the terminals whose prompt set changed.
    @discardableResult
    public func closed(terminalID: UUID, toolUseID: String) -> Set<UUID> {
        resolveOne(Key(terminalID: terminalID, toolUseID: toolUseID), .answeredInTerminal)
    }

    private func resolveOne(_ key: Key, _ resolution: Resolution) -> Set<UUID> {
        guard let terminal = resolve(key, resolution) else { return [] }
        return [terminal]
    }

    // MARK: - Answer

    /// Hands `answer` to the prompt's dialog and returns once the outcome is
    /// known.
    ///
    /// A prompt takes one answer. The second answer to a prompt, and an
    /// answer naming another terminal, read `.alreadyResolved`. With a wait
    /// request attached the decision goes to it at once; otherwise it is held
    /// for the next wait request within `pickupTimeout`, and withdrawn after
    /// that with `.hookDetached` (the prompt stays open, so the caller may
    /// retry). Once handed over, the answer waits `ackTimeout` for the mod:
    /// a receipt reads `.delivered`, a close `.alreadyResolved`, and neither
    /// `.deliveryUnconfirmed` — the decision may have reached Claude — with
    /// the prompt resolved.
    func answer(terminalID: UUID, promptID: String, answer: PromptAnswer,
                ackTimeout: Duration = .seconds(5),
                pickupTimeout: Duration = .seconds(60)) async -> (outcome: AnswerOutcome, changed: Set<UUID>) {
        let key = Key(terminalID: terminalID, toolUseID: promptID)
        guard var record = promptRecords[key], record.pendingAnswer == nil else {
            return (.alreadyResolved, [])
        }
        let decisionJSON: String
        do {
            decisionJSON = try PromptDecisionEncoder.decisionJSON(
                answer: answer, kind: record.payload.kind,
                toolInputJSON: record.payload.toolInputJSON,
                suggestionsJSON: record.payload.suggestionsJSON)
        } catch let validation as PromptAnswerValidation {
            return (.invalid(validation), [])
        } catch {
            // The encoder only fails this way on input JSONSerialization
            // cannot write back, which a decoded payload never produces.
            Self.log.error(
                "prompt answer failed to encode id=\(promptID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return (.invalid(.kindMismatch), [])
        }

        let answerToken = UUID()
        let generation = record.generation
        record.pendingAnswer = PendingAnswer(
            token: answerToken, decisionJSON: decisionJSON, handedOver: false,
            continuation: nil, parkID: nil)
        promptRecords[key] = record

        if let waiter = record.waiter {
            _ = takeDecision(key)
            promptRecords[key]?.waiter = nil
            stampWait(key)
            waiter.holdTimer.cancel()
            waiter.continuation.resume(returning: .decision(decisionJSON))
        } else {
            switch await parkAnswer(key: key, answerToken: answerToken, timeout: pickupTimeout) {
            case .pickedUp:
                break
            case .timedOut:
                // `answerTimedOut` withdrew the decision; the prompt stays open.
                return (.hookDetached, [])
            case .resolved(let resolution):
                return (resolution == .answered ? .delivered : .alreadyResolved, [terminalID])
            }
        }

        switch await parkAnswer(key: key, answerToken: answerToken, timeout: ackTimeout) {
        case .resolved(.answered):
            return (.delivered, [terminalID])
        case .resolved:
            return (.alreadyResolved, [terminalID])
        case .timedOut:
            // `answerTimedOut` already resolved the prompt.
            return (.deliveryUnconfirmed, [terminalID])
        case .pickedUp:
            // Only ever sent before the hand-over, so it cannot reach this
            // park; handled like the timeout it would be, touching the prompt
            // only while this answer is still the one it holds.
            if promptRecords[key]?.generation == generation,
               promptRecords[key]?.pendingAnswer?.token == answerToken {
                promptRecords[key]?.pendingAnswer = nil
                resolve(key, .answered)
            }
            return (.deliveryUnconfirmed, [terminalID])
        }
    }

    /// Parks the answer until a signal for `answerToken` arrives or `timeout`
    /// elapses.
    private func parkAnswer(key: Key, answerToken: UUID, timeout: Duration) async -> AnswerSignal {
        if let early = earlySignals.removeValue(forKey: answerToken) { return early }
        let parkID = UUID()
        let timer = Task { [weak self, clock] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.answerTimedOut(key: key, parkID: parkID)
        }
        let signal = await withCheckedContinuation { (continuation: CheckedContinuation<AnswerSignal, Never>) in
            if let early = earlySignals.removeValue(forKey: answerToken) {
                continuation.resume(returning: early)
                return
            }
            guard var record = promptRecords[key], var answer = record.pendingAnswer,
                  answer.token == answerToken else {
                // Unreachable: whatever removed the answer stashed a signal
                // for it first. Read as the terminal being in charge.
                continuation.resume(returning: .resolved(.answeredInTerminal))
                return
            }
            answer.continuation = continuation
            answer.parkID = parkID
            record.pendingAnswer = answer
            promptRecords[key] = record
        }
        timer.cancel()
        return signal
    }

    /// The parked answer's timeout, settled in this actor turn so nothing
    /// can slip in before the parked call resumes. Before the hand-over the
    /// decision is withdrawn and the prompt stays open, so no wait request
    /// can take it after the answer has been told `.hookDetached`. After the
    /// hand-over the prompt resolves `.answered` here, so a second answer
    /// cannot install itself on a prompt this one is about to end.
    private func answerTimedOut(key: Key, parkID: UUID) {
        guard var record = promptRecords[key], let answer = record.pendingAnswer,
              answer.parkID == parkID, let continuation = answer.continuation else { return }
        record.pendingAnswer = nil
        promptRecords[key] = record
        continuation.resume(returning: .timedOut)
        if answer.handedOver {
            resolve(key, .answered)
        }
    }

    /// Delivers `signal` to the answer: to its parked call, or into
    /// `earlySignals` when it is between parks.
    private func signal(_ answer: PendingAnswer, _ signal: AnswerSignal) {
        if let continuation = answer.continuation {
            continuation.resume(returning: signal)
        } else {
            earlySignals[answer.token] = signal
        }
    }

    // MARK: - Bulk resolution and shutdown

    /// Resolves every open prompt of the terminal with `resolution`, leaving
    /// its captures alone. Returns the terminals whose prompt set changed.
    @discardableResult
    public func resolvePrompts(terminalID: UUID, _ resolution: Resolution) -> Set<UUID> {
        var changed: Set<UUID> = []
        for key in promptRecords.keys where key.terminalID == terminalID {
            if let terminal = resolve(key, resolution) { changed.insert(terminal) }
        }
        return changed
    }

    /// The terminals holding at least one open prompt.
    public func terminalsWithOpenPrompts() -> Set<UUID> {
        Set(promptRecords.keys.map(\.terminalID))
    }

    /// Resolves `.modDisconnected` every prompt that has no wait request
    /// attached and whose `lastWaitAt` is more than `threshold` before `now`,
    /// and returns the terminals whose prompt set changed.
    ///
    /// Liveness is judged per prompt, not per terminal: a mod that keeps
    /// polling but stopped waiting on one dialog (a lost close, a reload that
    /// forgot the dialog) still loses that card, and a mod whose poll loop is
    /// down but whose dialog waits still run keeps its cards. A prompt opened
    /// a moment ago, before its first wait arrives, is measured from its open.
    @discardableResult
    public func resolveIdlePrompts(now: Date, threshold: Duration) -> Set<UUID> {
        let thresholdSeconds = Self.seconds(threshold)
        var changed: Set<UUID> = []
        for (key, record) in promptRecords
        where record.waiter == nil && now.timeIntervalSince(record.lastWaitAt) > thresholdSeconds {
            if let terminal = resolve(key, .modDisconnected) { changed.insert(terminal) }
        }
        return changed
    }

    /// The terminals holding at least one capture or open prompt — the ones a
    /// new `state.subscribe` subscriber is sent a snapshot for.
    public func terminalsWithPendingState() -> Set<UUID> {
        Set(pending.keys.map(\.terminalID)).union(promptRecords.keys.map(\.terminalID))
    }

    /// Daemon shutdown: every held wait request gets `.resolved` and every
    /// answer in flight reads `.alreadyResolved`.
    @discardableResult
    func resolveAll() -> Set<UUID> {
        var changed: Set<UUID> = []
        for key in Array(promptRecords.keys) {
            if let terminal = resolve(key, .daemonShutdown) { changed.insert(terminal) }
        }
        return changed
    }

    // MARK: - Diagnostics (tests and logs)

    /// Whether a wait request is held on the prompt right now.
    func isWaiterAttached(terminalID: UUID, toolUseID: String) -> Bool {
        promptRecords[Key(terminalID: terminalID, toolUseID: toolUseID)]?.waiter != nil
    }

    // MARK: - Resolution

    /// Removes the prompt, releases its waiter with `.resolved`, tells an
    /// answer in flight how it ended, and returns its terminal — or nil when
    /// the store no longer holds it. Every path that ends a prompt comes
    /// through here, so no continuation leaks and none resumes twice.
    @discardableResult
    private func resolve(_ key: Key, _ resolution: Resolution, bump: Bool = true) -> UUID? {
        guard let record = promptRecords.removeValue(forKey: key) else { return nil }
        if let waiter = record.waiter {
            waiter.holdTimer.cancel()
            waiter.continuation.resume(returning: .resolved)
        }
        if let answer = record.pendingAnswer {
            signal(answer, .resolved(resolution))
        }
        if bump { bumpRevision(key.terminalID) }
        Self.log.debug(
            "prompt resolved id=\(key.toolUseID, privacy: .public) resolution=\(resolution.rawValue, privacy: .public)")
        return key.terminalID
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}
