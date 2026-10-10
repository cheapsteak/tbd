import Foundation
import os
import TBDShared

/// Holds the daemon's view of open Claude Code dialogs, in two shapes.
///
/// - **Captures** – pending `AskUserQuestion`s recorded by the pre-tool hook,
///   keyed on `(terminalID, toolUseID)`. The app's `AskUserQuestionMerger`
///   drops one once its `tool_use_id` reaches the JSONL — see
///   `RPCRouter+TerminalHandlers.swift`.
/// - **Prompts** – dialogs a `PermissionRequest` hook registered so the app
///   can answer them from the transcript, each with the hook's waiting
///   `prompt.await` continuation
///   (`docs/specs/2026-10-09-transcript-prompt-answer-design.md`).
///
/// Memory-only; a daemon restart wipes the store. It creates no durable
/// resource: Claude Code owns the waiting hook process, and every record here
/// resolves on its own (an answer, the tool finishing, supersession, the hook
/// going away, the terminal ending, or the detached sweep).
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
        /// The app's answer reached the hook (or the hook vanished mid-delivery).
        case answered
        /// `PostToolUse`/`PostToolUseFailure` for its `tool_use_id`: the
        /// terminal won.
        case toolFinished
        /// A new `prompt.register` in the same session: one dialog at a time.
        case superseded
        /// The waiting hook's connection closed (No or Escape SIGTERMs it).
        case hookClosed
        /// The terminal or session ended.
        case terminalGone
        /// No hook attached for `PendingPromptExpirySweep.maxDetached`.
        case detachedTimeout
        /// The daemon is stopping.
        case daemonShutdown
    }

    public enum RegisterOutcome: Sendable, Equatable {
        /// `toolUseID` is the pairing the prompt holds, so the hook can hand
        /// it back as `knownToolUseID` if it has to register again after a
        /// daemon restart.
        case registered(promptID: String, toolUseID: String?)
    }

    public enum AnswerOutcome: Sendable, Equatable {
        /// The hook acknowledged that it has the decision.
        case delivered
        /// Unknown id, a different terminal, already answered, or the hook
        /// never acknowledged delivery: the terminal is in charge.
        case alreadyResolved
        /// No waiter attached right now (a daemon restart window). Retryable;
        /// the prompt stays open.
        case hookDetached
        /// The answer does not fit the prompt; the prompt stays open.
        case invalid(PromptAnswerValidation)
    }

    /// How long a `pre` note may trail its register and still attach.
    static let lateNoteWindow = Duration.seconds(5)
    /// Notes kept per session. A session has at most a handful of tool calls
    /// in flight; the cap only bounds a session whose posts never arrive.
    static let maxNotesPerSession = 16

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "pendingPrompt")

    // MARK: Captures

    private var pending: [Key: PendingAskUserQuestion] = [:]

    // MARK: Prompts

    /// A `PreToolUse` note: the tool call a later register pairs with.
    private struct Note {
        let toolUseID: String
        let toolName: String
        let inputHash: String?
        let at: Date
    }

    private struct Waiter {
        let token: UUID
        let continuation: CheckedContinuation<PromptAwaitResult, Never>
    }

    private struct PromptRecord {
        var payload: PendingPromptPayload
        let terminalID: UUID
        let sessionID: String
        let inputHash: String
        /// Distinguishes this record from a later one reusing its id, so a
        /// stale late-note timer cannot close a newer record's window.
        let generation: UUID
        var waiter: Waiter?
        /// Set while no hook is attached; the detached sweep reads it.
        var detachedSince: Date?
        /// The answer went to the waiter; the record waits for its ack.
        var answered: Bool
        /// Open while an unpaired prompt may still adopt a trailing note.
        var lateNoteWindowOpen: Bool
        var lateNoteTimer: Task<Void, Never>?
    }

    /// The scope a dialog lives in: one Claude session in one terminal. Two
    /// terminals can share a session id (`--resume` without
    /// `--fork-session`), and each still shows its own dialogs, so neither
    /// may supersede or pair with the other's.
    private struct SessionKey: Hashable {
        let terminalID: UUID
        let sessionID: String
    }

    private var promptRecords: [String: PromptRecord] = [:]
    /// One open prompt per session in a terminal.
    private var openPromptBySession: [SessionKey: String] = [:]
    /// Newest last.
    private var notes: [SessionKey: [Note]] = [:]
    /// `answer` calls parked until the hook acknowledges delivery, by token.
    private var ackWaiters: [UUID: CheckedContinuation<Bool, Never>] = [:]
    /// Tokens whose answer was handed over but whose ack waiter is not yet
    /// installed; an ack arriving in that gap lands in `earlyAcks`.
    private var awaitingAck: Set<UUID> = []
    private var earlyAcks: [UUID: Bool] = [:]

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

    /// Drops everything the terminal holds: its captures, its open prompts
    /// (resolved `.terminalGone`, so each waiting hook exits silently) and its
    /// notes. Every lifecycle site that ends a terminal already calls this.
    public func clear(terminalID: UUID) {
        pending = pending.filter { $0.key.terminalID != terminalID }
        for (id, record) in promptRecords where record.terminalID == terminalID {
            resolve(id, .terminalGone, bump: false)
        }
        notes = notes.filter { $0.key.terminalID != terminalID }
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
        promptRecords.values
            .filter { $0.terminalID == terminalID }
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

    // MARK: - Notes

    /// Records a `PreToolUse` note, or applies a `PostToolUse` /
    /// `PostToolUseFailure` one. Returns the terminals whose prompt set
    /// changed.
    ///
    /// - `pre`: kept for a later register to pair with — unless the session's
    ///   open prompt is still unpaired, registered within the last
    ///   `lateNoteWindow`, and shows the same tool and input, in which case
    ///   the note attaches to it at once (the note lost the race to the
    ///   register).
    /// - `post`: the tool call finished, so the terminal answered: any prompt
    ///   still open for that `tool_use_id` resolves `.toolFinished`. So does
    ///   the session's open prompt when it is unpaired (no `tool_use_id`, as
    ///   after a daemon restart) and shows the same tool and input hash —
    ///   otherwise nothing would close it until its hook went away.
    @discardableResult
    func note(terminalID: UUID, sessionID: String, phase: PromptNotePhase,
              toolUseID: String, toolName: String, inputHash: String?) -> Set<UUID> {
        let scope = SessionKey(terminalID: terminalID, sessionID: sessionID)
        switch phase {
        case .pre:
            if let openID = openPromptBySession[scope],
               var record = promptRecords[openID],
               record.payload.toolUseID == nil,
               record.lateNoteWindowOpen,
               record.payload.toolName == toolName,
               inputHash == record.inputHash {
                record.payload = record.payload.with(toolUseID: toolUseID)
                record.lateNoteWindowOpen = false
                record.lateNoteTimer?.cancel()
                record.lateNoteTimer = nil
                promptRecords[openID] = record
                bumpRevision(record.terminalID)
                Self.log.debug(
                    "late note attached prompt=\(openID, privacy: .public) toolUseID=\(toolUseID, privacy: .public)")
                return [record.terminalID]
            }
            var list = (notes[scope] ?? []).filter { $0.toolUseID != toolUseID }
            list.append(Note(toolUseID: toolUseID, toolName: toolName,
                             inputHash: inputHash, at: now()))
            if list.count > Self.maxNotesPerSession {
                list.removeFirst(list.count - Self.maxNotesPerSession)
            }
            notes[scope] = list
            return []
        case .post:
            if let list = notes[scope] {
                let kept = list.filter { $0.toolUseID != toolUseID }
                notes[scope] = kept.isEmpty ? nil : kept
            }
            var changed: Set<UUID> = []
            for (id, record) in promptRecords where record.payload.toolUseID == toolUseID {
                if let terminal = resolve(id, .toolFinished) { changed.insert(terminal) }
            }
            if let inputHash,
               let openID = openPromptBySession[scope],
               let record = promptRecords[openID],
               record.payload.toolUseID == nil,
               record.payload.toolName == toolName,
               record.inputHash == inputHash,
               let terminal = resolve(openID, .toolFinished) {
                changed.insert(terminal)
            }
            return changed
        }
    }

    // MARK: - Register

    /// Records an open dialog for a `PermissionRequest` hook.
    ///
    /// - A register in a session whose open prompt has a different id
    ///   supersedes it: a session shows one dialog at a time. The scope is
    ///   the session in this terminal, so a second terminal resumed into the
    ///   same session id never supersedes the first's dialog.
    /// - A register naming an id this store still holds for the same terminal
    ///   and session (the hook reconnected) refreshes that record and keeps it
    ///   open. A held id from another terminal or session is not this hook's
    ///   prompt: the register gets a fresh id and never touches that record.
    /// - Otherwise the prompt pairs with a note from the same session,
    ///   terminal and tool: the newest with an equal input hash, else the newest. An
    ///   unpaired prompt gets a fresh UUID and a `nil` `tool_use_id`, and may
    ///   still adopt a note arriving within `lateNoteWindow`. A re-register
    ///   after a daemon restart keeps its id (`knownPromptID`) but has no
    ///   note left to pair with.
    func register(_ params: PromptRegisterParams) -> (outcome: RegisterOutcome, changed: Set<UUID>) {
        var changed: Set<UUID> = []
        let scope = SessionKey(terminalID: params.terminalID, sessionID: params.sessionID)
        if let openID = openPromptBySession[scope], openID != params.knownPromptID,
           let terminal = resolve(openID, .superseded) {
            changed.insert(terminal)
        }

        let kind: PendingPromptKind = params.toolName == "AskUserQuestion" ? .question : .permission

        if let knownID = params.knownPromptID, var existing = promptRecords[knownID],
           existing.terminalID == params.terminalID, existing.sessionID == params.sessionID {
            existing.payload = PendingPromptPayload(
                id: knownID, kind: kind,
                toolUseID: existing.payload.toolUseID ?? params.knownToolUseID,
                toolName: params.toolName,
                toolInputJSON: params.toolInputJSON,
                suggestionsJSON: params.suggestionsJSON,
                createdAt: existing.payload.createdAt)
            promptRecords[knownID] = existing
            openPromptBySession[scope] = knownID
            bumpRevision(existing.terminalID)
            changed.insert(existing.terminalID)
            Self.log.debug("prompt re-registered id=\(knownID, privacy: .public)")
            return (.registered(promptID: knownID, toolUseID: existing.payload.toolUseID), changed)
        }

        let isReRegister = params.knownPromptID != nil
        let toolUseID = params.knownToolUseID
            ?? (isReRegister ? nil : takeNote(scope: scope,
                                              toolName: params.toolName,
                                              inputHash: params.inputHash))
        // A known id the store already holds reaches here only when it belongs
        // to another terminal or session; reusing it would overwrite that record.
        let id = params.knownPromptID.flatMap { promptRecords[$0] == nil ? $0 : nil } ?? UUID().uuidString
        let stamp = now()
        let generation = UUID()
        let opensLateWindow = toolUseID == nil && !isReRegister
        var record = PromptRecord(
            payload: PendingPromptPayload(
                id: id, kind: kind, toolUseID: toolUseID,
                toolName: params.toolName,
                toolInputJSON: params.toolInputJSON,
                suggestionsJSON: params.suggestionsJSON,
                createdAt: stamp),
            terminalID: params.terminalID,
            sessionID: params.sessionID,
            inputHash: params.inputHash,
            generation: generation,
            waiter: nil,
            detachedSince: stamp,
            answered: false,
            lateNoteWindowOpen: opensLateWindow,
            lateNoteTimer: nil)
        if opensLateWindow {
            record.lateNoteTimer = Task { [weak self, clock] in
                do { try await clock.sleep(for: Self.lateNoteWindow) } catch { return }
                await self?.closeLateNoteWindow(promptID: id, generation: generation)
            }
        }
        promptRecords[id] = record
        openPromptBySession[scope] = id
        bumpRevision(params.terminalID)
        changed.insert(params.terminalID)
        Self.log.debug(
            "prompt registered id=\(id, privacy: .public) kind=\(kind.rawValue, privacy: .public) paired=\(toolUseID != nil, privacy: .public)")
        return (.registered(promptID: id, toolUseID: toolUseID), changed)
    }

    /// The note in the session that this register pairs with, removed so no
    /// second register can take it: the newest one for `toolName` whose input
    /// hash matches, else the session's only note for `toolName`. With no
    /// hash match and several notes for the tool, recency cannot say which
    /// call the dialog belongs to, so the prompt stays unpaired rather than
    /// bind to the wrong tool call.
    private func takeNote(scope: SessionKey, toolName: String, inputHash: String) -> String? {
        guard var list = notes[scope] else { return nil }
        let index: Int
        if let matched = list.lastIndex(where: { $0.toolName == toolName && $0.inputHash == inputHash }) {
            index = matched
        } else {
            let candidates = list.indices.filter { list[$0].toolName == toolName }
            guard candidates.count == 1, let only = candidates.first else { return nil }
            index = only
        }
        let note = list.remove(at: index)
        notes[scope] = list.isEmpty ? nil : list
        return note.toolUseID
    }

    private func closeLateNoteWindow(promptID: String, generation: UUID) {
        guard var record = promptRecords[promptID], record.generation == generation else { return }
        record.lateNoteWindowOpen = false
        record.lateNoteTimer = nil
        promptRecords[promptID] = record
    }

    // MARK: - Await

    /// Suspends until the prompt resolves. `token` names this waiter so a
    /// closed connection cancels only itself. An unknown or already-answered
    /// id answers `.resolvedElsewhere` at once. A waiter already attached to
    /// the same prompt (a stale one from before a reconnect) is released with
    /// `.resolvedElsewhere`.
    ///
    /// `connectionClosed` closes the race between a waiter attaching and its
    /// connection closing. The socket marks the connection closed before it
    /// calls `waiterClosed(token:)`, and this reads the mark in the same actor
    /// turn that attaches the waiter: a close that `waiterClosed` ran too early
    /// to see is seen here instead, and the prompt resolves `.hookClosed`.
    func awaitResolution(
        promptID: String, token: UUID,
        connectionClosed: @escaping @Sendable () -> Bool = { false }
    ) async -> PromptAwaitResult {
        guard let record = promptRecords[promptID], !record.answered else { return .resolvedElsewhere }
        return await withCheckedContinuation { (continuation: CheckedContinuation<PromptAwaitResult, Never>) in
            guard var current = promptRecords[promptID], current.generation == record.generation, !current.answered else {
                continuation.resume(returning: .resolvedElsewhere)
                return
            }
            if connectionClosed() {
                resolve(promptID, .hookClosed)
                continuation.resume(returning: .resolvedElsewhere)
                return
            }
            current.waiter?.continuation.resume(returning: .resolvedElsewhere)
            current.waiter = Waiter(token: token, continuation: continuation)
            current.detachedSince = nil
            promptRecords[promptID] = current
        }
    }

    /// The waiter's connection closed. An attached, unanswered waiter means
    /// the hook was killed (No or Escape in the terminal), so its prompt
    /// resolves `.hookClosed`. Harmless for a token that is no longer
    /// attached — a delivered answer, or a waiter a reconnect replaced.
    ///
    /// A pending delivery ack is deliberately left alone: the write's own
    /// completion reports it through `acknowledgeDelivery`, and the two
    /// notifications reach this actor in no fixed order.
    @discardableResult
    func waiterClosed(token: UUID) -> Set<UUID> {
        guard let match = promptRecords.first(where: { $0.value.waiter?.token == token && !$0.value.answered }),
              let terminal = resolve(match.key, .hookClosed) else {
            return []
        }
        return [terminal]
    }

    // MARK: - Answer

    /// Hands `answer` to the prompt's waiting hook and returns once the hook
    /// acknowledges delivery (`acknowledgeDelivery`), or `ackTimeout` passes.
    ///
    /// The second answer to a prompt, an answer naming another terminal, and
    /// an answer whose delivery was never acknowledged all read
    /// `.alreadyResolved`. With no waiter attached the prompt stays open and
    /// the answer is `.hookDetached`, which the caller may retry.
    func answer(terminalID: UUID, promptID: String, answer: PromptAnswer,
                ackTimeout: Duration = .seconds(5)) async -> (outcome: AnswerOutcome, changed: Set<UUID>) {
        guard var record = promptRecords[promptID], record.terminalID == terminalID, !record.answered else {
            return (.alreadyResolved, [])
        }
        let hookOutput: String
        do {
            hookOutput = try PromptDecisionEncoder.hookOutput(
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
        guard let waiter = record.waiter else { return (.hookDetached, []) }

        record.answered = true
        record.waiter = nil
        promptRecords[promptID] = record
        awaitingAck.insert(waiter.token)
        waiter.continuation.resume(returning: .answered(hookOutput: hookOutput))

        let delivered = await waitForAck(token: waiter.token, timeout: ackTimeout)

        var changed: Set<UUID> = []
        if let current = promptRecords[promptID], current.generation == record.generation,
           let terminal = resolve(promptID, delivered ? .answered : .hookClosed) {
            changed.insert(terminal)
        }
        return (delivered ? .delivered : .alreadyResolved, changed)
    }

    /// The hook side reports whether the answer reached the hook. Ignored for
    /// a token no `answer` is waiting on.
    func acknowledgeDelivery(token: UUID, delivered: Bool) {
        settleAck(token: token, delivered: delivered)
    }

    private func waitForAck(token: UUID, timeout: Duration) async -> Bool {
        if let early = earlyAcks.removeValue(forKey: token) {
            awaitingAck.remove(token)
            return early
        }
        let timer = Task { [weak self, clock] in
            do { try await clock.sleep(for: timeout) } catch { return }
            await self?.settleAck(token: token, delivered: false)
        }
        let delivered = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if let early = earlyAcks.removeValue(forKey: token) {
                awaitingAck.remove(token)
                continuation.resume(returning: early)
            } else {
                ackWaiters[token] = continuation
            }
        }
        timer.cancel()
        return delivered
    }

    private func settleAck(token: UUID, delivered: Bool) {
        if let continuation = ackWaiters.removeValue(forKey: token) {
            awaitingAck.remove(token)
            continuation.resume(returning: delivered)
        } else if awaitingAck.contains(token) {
            earlyAcks[token] = delivered
        }
    }

    // MARK: - Sweeps and shutdown

    /// Resolves every prompt that has had no hook attached for `maxDetached`
    /// as of `now`, and drops notes older than that. Returns the terminals
    /// whose prompt set changed.
    @discardableResult
    func sweepDetachedPrompts(now: Date, maxDetached: Duration) -> Set<UUID> {
        let cutoff = now.addingTimeInterval(-Self.seconds(maxDetached))
        var changed: Set<UUID> = []
        for (id, record) in promptRecords where !record.answered && record.waiter == nil {
            guard let since = record.detachedSince, since <= cutoff else { continue }
            if let terminal = resolve(id, .detachedTimeout) { changed.insert(terminal) }
        }
        for (scope, list) in notes {
            let kept = list.filter { $0.at > cutoff }
            notes[scope] = kept.isEmpty ? nil : kept
        }
        return changed
    }

    /// Daemon shutdown: every waiter gets `.resolvedElsewhere` and every
    /// pending delivery reads as not delivered.
    @discardableResult
    func resolveAll() -> Set<UUID> {
        var changed: Set<UUID> = []
        for id in Array(promptRecords.keys) {
            if let terminal = resolve(id, .daemonShutdown) { changed.insert(terminal) }
        }
        for token in Array(ackWaiters.keys) {
            settleAck(token: token, delivered: false)
        }
        return changed
    }

    // MARK: - Diagnostics (tests and logs)

    /// Whether a hook is attached to the prompt right now.
    func isWaiterAttached(promptID: String) -> Bool {
        promptRecords[promptID]?.waiter != nil
    }

    /// The terminal an open prompt belongs to, or nil once it has resolved.
    func terminalID(ofPrompt promptID: String) -> UUID? {
        promptRecords[promptID]?.terminalID
    }

    /// Whether the unpaired prompt may still adopt a trailing note.
    func isLateNoteWindowOpen(promptID: String) -> Bool {
        promptRecords[promptID]?.lateNoteWindowOpen ?? false
    }

    // MARK: - Resolution

    /// Removes the prompt, releases its waiter with `.resolvedElsewhere`, and
    /// returns its terminal — or nil when the store no longer holds it. Every
    /// path that ends a prompt comes through here, so no continuation leaks
    /// and none resumes twice.
    @discardableResult
    private func resolve(_ promptID: String, _ resolution: Resolution, bump: Bool = true) -> UUID? {
        guard let record = promptRecords.removeValue(forKey: promptID) else { return nil }
        let scope = SessionKey(terminalID: record.terminalID, sessionID: record.sessionID)
        if openPromptBySession[scope] == promptID {
            openPromptBySession.removeValue(forKey: scope)
        }
        record.lateNoteTimer?.cancel()
        record.waiter?.continuation.resume(returning: .resolvedElsewhere)
        if bump { bumpRevision(record.terminalID) }
        Self.log.debug(
            "prompt resolved id=\(promptID, privacy: .public) resolution=\(resolution.rawValue, privacy: .public)")
        return record.terminalID
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        TimeInterval(duration.components.seconds)
            + TimeInterval(duration.components.attoseconds) / 1e18
    }
}

private extension PendingPromptPayload {
    func with(toolUseID: String) -> PendingPromptPayload {
        PendingPromptPayload(
            id: id, kind: kind, toolUseID: toolUseID, toolName: toolName,
            toolInputJSON: toolInputJSON, suggestionsJSON: suggestionsJSON,
            createdAt: createdAt)
    }
}
