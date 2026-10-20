import Foundation
import os

/// The daemon-to-mod half of the session-mod channel: one outbox and one held
/// poll per terminal, plus the poll times that say whether a terminal's mod is
/// connected (`docs/specs/2026-10-20-mod-channel-prompt-answer-design.md`,
/// "The channel").
///
/// - **Outbox.** `enqueue` appends an item with the terminal's next sequence
///   number. A poll's `after` confirms (drops) every item up to it; every item
///   still unconfirmed goes out on each poll until one confirms it, and the mod
///   drops a number it has already seen, so each item takes effect at most
///   once.
/// - **Holding.** A poll with nothing to send waits up to its hold for an
///   item. An item that no poll takes within ``holdWindow`` is dropped and its
///   sender's `onExpired` called. A poll taking the item restarts that window,
///   so an item whose reply was lost has the full window to be re-sent and
///   confirmed.
/// - **Liveness.** A terminal is connected while a poll is held for it, or
///   for ``connectedWindow`` after its last poll arrived.
///
/// Memory-only, like `PendingPromptStore`: a daemon restart drops every held
/// item without calling `onExpired`.
actor ModChannel {
    struct Item: Codable, Sendable, Equatable {
        let seq: UInt64
        let kind: String
        /// JSON text.
        let body: String
    }

    /// How long an item waits for a poll to take it.
    static let holdWindow: Duration = .seconds(60)
    /// How long after its last poll a terminal's mod still counts as
    /// connected.
    static let connectedWindow: TimeInterval = 30

    private static let log = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

    private struct Queued {
        let item: Item
        let onExpired: @Sendable () -> Void
        /// Names the current expiry timer, so a cancelled timer that still
        /// fires cannot drop an item a later poll took.
        var expiryID: UUID
        var expiryTimer: Task<Void, Never>
    }

    /// A held poll.
    private struct PollWaiter {
        let token: UUID
        let continuation: CheckedContinuation<[Item], Never>
        let holdTimer: Task<Void, Never>
    }

    private struct TerminalState {
        var lastSeq: UInt64 = 0
        var outbox: [Queued] = []
        var waiter: PollWaiter?
        var lastPollAt: Date?
    }

    private var terminals: [UUID: TerminalState] = [:]

    private let now: @Sendable () -> Date
    private let clock: any Clock<Duration>

    init(
        now: @escaping @Sendable () -> Date = { Date() },
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.now = now
        self.clock = clock
    }

    // MARK: - Outbox

    /// Queues an item for the terminal's mod and returns its sequence number.
    /// A held poll returns at once with it. `onExpired` runs if no poll takes
    /// the item within ``holdWindow``.
    @discardableResult
    func enqueue(terminalID: UUID, kind: String, body: String,
                 onExpired: @escaping @Sendable () -> Void) -> UInt64 {
        var state = terminals[terminalID] ?? TerminalState()
        state.lastSeq += 1
        let seq = state.lastSeq
        let expiryID = UUID()
        state.outbox.append(Queued(
            item: Item(seq: seq, kind: kind, body: body),
            onExpired: onExpired,
            expiryID: expiryID,
            expiryTimer: expiryTimer(terminalID: terminalID, seq: seq, expiryID: expiryID)))
        let waiter = state.waiter
        state.waiter = nil
        terminals[terminalID] = state
        if let waiter {
            waiter.holdTimer.cancel()
            waiter.continuation.resume(returning: takeOutbox(terminalID))
        }
        return seq
    }

    // MARK: - Poll

    /// The mod's held poll. Confirms every item numbered `after` or lower,
    /// returns the unconfirmed rest at once if there are any, and otherwise
    /// waits up to `hold` for one (returning `[]` when the hold elapses). A
    /// newer poll for the same terminal releases an older held one with `[]`.
    ///
    /// `token` names this request, so `pollGone(token:)` releases only it.
    func poll(terminalID: UUID, after: UInt64, token: UUID,
              hold: Duration = .seconds(25)) async -> [Item] {
        var state = terminals[terminalID] ?? TerminalState()
        state.lastPollAt = now()
        var confirmed: [Queued] = []
        state.outbox.removeAll { queued in
            guard queued.item.seq <= after else { return false }
            confirmed.append(queued)
            return true
        }
        let superseded = state.waiter
        state.waiter = nil
        terminals[terminalID] = state
        for queued in confirmed { queued.expiryTimer.cancel() }
        if let superseded {
            superseded.holdTimer.cancel()
            superseded.continuation.resume(returning: [])
        }

        let ready = takeOutbox(terminalID)
        if !ready.isEmpty { return ready }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[Item], Never>) in
            // Re-checked inside the continuation so nothing that ran between
            // the read above and here can be missed.
            let late = takeOutbox(terminalID)
            guard late.isEmpty else {
                continuation.resume(returning: late)
                return
            }
            var current = terminals[terminalID] ?? TerminalState()
            if let other = current.waiter {
                other.holdTimer.cancel()
                other.continuation.resume(returning: [])
            }
            let holdTimer = Task { [weak self, clock] in
                do { try await clock.sleep(for: hold) } catch { return }
                await self?.releasePoll(terminalID: terminalID, token: token)
            }
            current.waiter = PollWaiter(token: token, continuation: continuation, holdTimer: holdTimer)
            terminals[terminalID] = current
        }
    }

    /// The poll's connection went away. Releases that poll with `[]`; harmless
    /// for a token no longer held.
    func pollGone(token: UUID) {
        guard let terminalID = terminals.first(where: { $0.value.waiter?.token == token })?.key else {
            return
        }
        releasePoll(terminalID: terminalID, token: token)
    }

    // MARK: - Liveness

    /// True while a poll is held for the terminal, or within
    /// ``connectedWindow`` of its last poll.
    func isConnected(terminalID: UUID) -> Bool {
        guard let state = terminals[terminalID] else { return false }
        if state.waiter != nil { return true }
        guard let last = state.lastPollAt else { return false }
        return now().timeIntervalSince(last) < Self.connectedWindow
    }

    func lastPollAt(terminalID: UUID) -> Date? {
        terminals[terminalID]?.lastPollAt
    }

    // MARK: - Diagnostics (tests)

    /// Whether a poll is held for the terminal right now.
    func isPollAttached(terminalID: UUID) -> Bool {
        terminals[terminalID]?.waiter != nil
    }

    // MARK: - Internals

    /// Every unconfirmed item, oldest first, with each one's hold window
    /// restarted because a poll is taking it now.
    private func takeOutbox(_ terminalID: UUID) -> [Item] {
        guard var state = terminals[terminalID], !state.outbox.isEmpty else { return [] }
        for index in state.outbox.indices {
            state.outbox[index].expiryTimer.cancel()
            let expiryID = UUID()
            let seq = state.outbox[index].item.seq
            state.outbox[index].expiryID = expiryID
            state.outbox[index].expiryTimer = expiryTimer(
                terminalID: terminalID, seq: seq, expiryID: expiryID)
        }
        terminals[terminalID] = state
        return state.outbox.map(\.item)
    }

    private func releasePoll(terminalID: UUID, token: UUID) {
        guard var state = terminals[terminalID], let waiter = state.waiter, waiter.token == token else {
            return
        }
        state.waiter = nil
        terminals[terminalID] = state
        waiter.holdTimer.cancel()
        waiter.continuation.resume(returning: [])
    }

    private func expiryTimer(terminalID: UUID, seq: UInt64, expiryID: UUID) -> Task<Void, Never> {
        Task { [weak self, clock] in
            do { try await clock.sleep(for: Self.holdWindow) } catch { return }
            await self?.expire(terminalID: terminalID, seq: seq, expiryID: expiryID)
        }
    }

    private func expire(terminalID: UUID, seq: UInt64, expiryID: UUID) {
        guard var state = terminals[terminalID],
              let index = state.outbox.firstIndex(where: { $0.item.seq == seq }),
              state.outbox[index].expiryID == expiryID else { return }
        let queued = state.outbox.remove(at: index)
        terminals[terminalID] = state
        Self.log.debug(
            "mod channel item expired terminal=\(terminalID.uuidString, privacy: .public) seq=\(seq, privacy: .public) kind=\(queued.item.kind, privacy: .public)")
        queued.onExpired()
    }
}
