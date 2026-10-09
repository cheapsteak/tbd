import Foundation
import TBDShared
import os

/// Asks the viewer that holds a holder-backed session's pty what is on its
/// screen, and waits a bounded time for the answer.
///
/// The read-direction sibling of `HolderInjectionCourier`, deliberately built
/// to the same shape: one frame out over the fd sidecar, one correlated frame
/// back, a pending map keyed by the request's own id, a bound on an injected
/// clock, and a late answer that is **counted, logged and dropped** rather than
/// applied. Where the courier asks "did you write these bytes", this asks "what
/// does your terminal look like" — and the two sit on opposite sides of the
/// same fact, that while a viewer is attached the app's SwiftTerm is the live
/// store and the daemon's retained emulator is frozen
/// (`docs/specs/2026-08-30-pty-holder-session-transport-design.md`,
/// `docs/specs/2026-09-05-child-as-contract-party-design.md`).
///
/// ## What this type does not decide
///
/// It does not decide *whether* to pull — that is a question about which store
/// is live, and it belongs to the resolver above this. It does not build a
/// `TerminalScreen` either. The reply carries a `ViewerScreenPayload`, and the
/// provenance a screen needs — `source`, the age, `modesObserved`,
/// `contentObserved` — is stamped by the daemon from its own reader, because a
/// viewer's emulator was seeded by the daemon's attach preamble and can hand
/// back no more than the daemon gave it. So this type's whole job is: get the
/// frame out, match the answer, bound the wait, and be honest about which of
/// the four outcomes happened.
///
/// ## Why the bound is short, and why expiring is not a failure
///
/// `HolderInputTiming.screenPullBound` is 500 ms, far shorter than the
/// injection ack's five seconds, and that type's doc argues the asymmetry: a
/// write loses nothing by waiting, while this read sits on the critical path of
/// every holder send to an open tab and has a correct fallback to land on. An
/// expiry means the daemon answers from the emulator it suspended at attach,
/// which is what every consumer's policy was already written against. An app
/// that is napping, wedged or mid-paste was never going to answer in five
/// seconds either, and those are exactly the moments supervision most wants to
/// act — so the read must not be the thing that blocks it.
///
/// It is the default rather than the rule: a caller whose wait is spent
/// somewhere costlier can tighten it per request, and the disposal path does,
/// because its wait sits inside a window the user is watching close.
///
/// ## Overlapping pulls are independent
///
/// Two pulls for one session each get their own `requestID`, their own
/// continuation and their own answer, taken from the app's live terminal at the
/// moment each is handled. They are deliberately not joined: joining would hand
/// the second caller an `ageMilliseconds` measured for the first caller's
/// observation, and the whole point of that field is that it describes *this*
/// answer. Memory is bounded without a cap, because every pending entry lives
/// at most one bound.
///
/// ## The counters can misattribute, and the answers cannot
///
/// `record` and `connectionLost` are both `nonisolated` and both hand their
/// work to an unordered `Task`, because their caller is the sidecar's receive
/// thread and has nothing to await on. So a reply immediately followed by that
/// connection ending can be processed in either order. **Every outcome is safe
/// either way** — whichever lands first resolves the request, and the second
/// finds nothing to resolve — but the two land in different buckets: the same
/// event can be counted as an answer or as a late reply depending on a
/// scheduling order nothing here controls. A soak reading
/// `answeredPullsObserved` against `lateRepliesObserved` should therefore read
/// a reconnect's worth of requests as approximate. Ordering the pair would mean
/// serializing the receive thread's two sinks through a queue of their own,
/// which is a mechanism for a miscount rather than for a wrong answer.
actor HolderScreenPull {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "holderScreenPull")

    /// What came back, in the four shapes a caller's policy can differ on.
    enum Answer: Sendable, Equatable {
        /// A viewer projected its live terminal. `styledCapture` is present
        /// only when the request asked for one and the viewer could produce it.
        case answered(ViewerScreenPayload, styledCapture: String?)
        /// The app answered, and its answer was that it cannot produce a
        /// screen — no panel claims the session, or the panel's terminal is
        /// gone. A *knowable, synchronous* refusal reported truthfully, which
        /// is what lets the caller fall back at once instead of burning the
        /// bound; the same reasoning as an injection ack's `written: false`.
        case refused(SidecarScreenReply.Unavailable)
        /// The request never reached an app: no sidecar connection, an encode
        /// failure, or the connection it went out on ended. Also an immediate
        /// answer, not a wait.
        case undeliverable(String)
        /// The bound elapsed with no answer. The app may be alive and merely
        /// silent, which is the case the bound exists for.
        case timedOut
    }

    private struct Pending {
        let terminalID: UUID
        /// The sidecar connection the request went out on, or nil while the
        /// send has not yet returned one. A reply cannot arrive before the
        /// frame is on the wire, so nil means "necessarily this connection".
        var epoch: UInt64?
        /// What this request's caller is willing to wait — its own, not the
        /// puller's, because two callers on this one path spend their wait in
        /// different places (`HolderInputTiming`).
        let bound: Duration
        var boundTask: Task<Void, Never>?
        let continuation: CheckedContinuation<Answer, Never>
    }

    /// Puts one encoded frame on the app sidecar and answers which connection
    /// epoch it went out on. Throws when there is no connected app.
    private let sendFrame: @Sendable (Data) async throws -> UInt64
    private let bound: Duration
    private let clock: any Clock<Duration>

    /// Requests whose answer has not arrived and whose bound has not fired,
    /// keyed by the request's own id — so a reply can be matched to exactly the
    /// request it answers, and one that matches nothing can be recognized as
    /// late.
    private var pending: [UUID: Pending] = [:]

    /// The highest sidecar connection epoch known to have ended.
    ///
    /// Closes the one window `failEveryRequest` cannot see: a connection that
    /// ends between `sendFrame` returning an epoch and that epoch being stamped
    /// onto the pending entry. The sweep matches on the stamp, so such a
    /// request would sit unmatched and resolve `.timedOut` a whole bound later
    /// — a correct answer arrived at slowly, on a path that now has callers
    /// waiting on it. `dispatch` compares the epoch it was just handed against
    /// this and resolves at once instead.
    ///
    /// **One `UInt64`, not a set, because epochs are monotonic.**
    /// `ConnectionEpochBox.advance()` only ever increments, so "this epoch has
    /// ended" is `epoch <= lastEndedEpoch` — no accumulating collection, and
    /// nothing to bound.
    private var lastEndedEpoch: UInt64 = 0

    /// A reply arrived for a request that was no longer waiting, or arrived on
    /// a connection the request was not sent on.
    ///
    /// Test-facing, and the instrument for the property that matters most here:
    /// a late answer must be *observed and ignored*. The daemon has already
    /// answered its caller from the frozen emulator by then, and letting a
    /// later arrival through would mean a consumer's screen and the `source` it
    /// was told about describe different observations.
    private(set) var lateRepliesObserved = 0

    /// A reply whose `terminalID` disagreed with the request's. Dropped, and
    /// **the pending entry is left pending** — a stray reply must not be able
    /// to steal another session's pull.
    private(set) var misaddressedRepliesObserved = 0

    /// Outcome counters, for the soak that graduates this path: how often a
    /// viewer answers versus how often the bound wins is the evidence, and it
    /// cannot be reconstructed afterwards from anything else.
    private(set) var answeredPullsObserved = 0
    private(set) var timedOutPullsObserved = 0

    /// How many sidecar connections have ended under this puller.
    ///
    /// Part of the same soak picture — a run whose timed-out pulls cluster
    /// around reconnects is a different story from one where the app is merely
    /// slow — and the gate a test needs to know the ended-epoch mark has
    /// landed, since `connectionLost` is fire-and-forget by design.
    private(set) var connectionsLostObserved = 0

    init(
        sendFrame: @escaping @Sendable (Data) async throws -> UInt64,
        bound: Duration = HolderInputTiming.screenPullBound,
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.sendFrame = sendFrame
        self.bound = bound
        self.clock = clock
    }

    /// Ask the viewer holding `terminalID`'s pty for its screen.
    ///
    /// - Parameter lines: how many lines of scrollback-plus-viewport the
    ///   caller wants. `0` is a modes-only reading: the shared projection's
    ///   `maxLines <= 0` arm yields no lines, so the app walks nothing.
    /// - Parameter retainedScrollbackLines: the daemon's own retained depth.
    ///   `SidecarScreenRequest`'s initializer clamps `lines` to it, so the
    ///   answer a reader gets does not depend on who happens to be looking at
    ///   the session.
    /// - Parameter wantStyledCapture: whether the reply should also carry the
    ///   SGR-intact capture Closed Terminals history records.
    /// - Parameter bound: how long *this* caller waits, defaulting to the
    ///   puller's own. An override rather than a second puller because there
    ///   is one reply sink and one pending map; what differs between callers is
    ///   the wait, not the protocol. The disposal path takes a tighter one
    ///   (`HolderInputTiming.closedTerminalPullBound`) because its wait is
    ///   spent inside a window closing.
    ///
    /// **The request is registered before it is sent**, which is the one place
    /// this departs from the courier's order and it is a correctness point
    /// rather than a style one: an answer that arrived between the send
    /// returning and the continuation being installed would be matched against
    /// nothing, counted late, and the caller would then wait out the whole
    /// bound for an answer it already had. Registering first makes "early"
    /// impossible, and costs a pending entry that the send's own failure path
    /// resolves.
    func pull(
        terminalID: UUID, lines: Int, retainedScrollbackLines: Int, wantStyledCapture: Bool,
        bound: Duration? = nil
    ) async -> Answer {
        let requestID = UUID()
        let request = SidecarScreenRequest(
            terminalID: terminalID,
            requestID: requestID,
            requestedLines: lines,
            retainedScrollbackLines: retainedScrollbackLines,
            wantStyledCapture: wantStyledCapture)
        let frame: Data
        do {
            frame = try SidecarFrameCodec.encodeScreenRequest(request)
        } catch {
            // Two UUIDs, two Ints and a Bool cannot fail to encode; reported
            // rather than swallowed on principle, and without consuming the
            // bound.
            return .undeliverable(
                "a screen request for session \(terminalID.uuidString) could not be encoded")
        }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Answer, Never>) in
            pending[requestID] = Pending(
                terminalID: terminalID, epoch: nil, bound: bound ?? self.bound,
                boundTask: nil, continuation: continuation)
            // Inherits this actor's isolation, so the send, the epoch stamp and
            // the bound all land on the same executor `record` does and no two
            // of them can resolve one waiter.
            Task { await self.dispatch(requestID: requestID, terminalID: terminalID, frame: frame) }
        }
    }

    /// Record a viewer's answer.
    ///
    /// `nonisolated` and fire-and-forget because the caller is the sidecar's
    /// receive thread, which has nothing to await on. `epoch` is the connection
    /// the reply arrived on.
    nonisolated func record(_ reply: SidecarScreenReply, epoch: UInt64) {
        Task { await self.ingest(reply, epoch: epoch) }
    }

    /// Fail every request outstanding on a sidecar connection that has ended.
    ///
    /// `nonisolated` for the same reason `record` is: the caller is the receive
    /// thread on its way out. A reconnect is the ordinary case — not a death,
    /// and still the end of that epoch, so nothing sent on it can be answered.
    nonisolated func connectionLost(epoch: UInt64) {
        Task { await self.failEveryRequest(onEpoch: epoch) }
    }

    // MARK: - Actor-isolated internals

    private func dispatch(requestID: UUID, terminalID: UUID, frame: Data) async {
        let epoch: UInt64
        do {
            epoch = try await sendFrame(frame)
        } catch {
            Self.logger.debug("""
                could not put a screen request for session \
                \(terminalID.uuidString, privacy: .public) on the app sidecar: \
                \(error.localizedDescription, privacy: .public)
                """)
            resolve(
                requestID,
                with: .undeliverable("""
                    the app sidecar could not carry a screen request for session \
                    \(terminalID.uuidString): \(error.localizedDescription)
                    """))
            return
        }
        // Already resolved — the connection ended, or a reply raced in while
        // the send was in flight. Either way there is nothing left to arm.
        guard pending[requestID] != nil else { return }
        // The connection this went out on has already ended, and the sweep ran
        // before there was a stamp to match. Answered now rather than at the
        // bound: nothing on a dead connection is ever coming back, and a
        // caller waiting on the answer should not pay for the race.
        guard epoch > lastEndedEpoch else {
            resolve(
                requestID,
                with: .undeliverable("""
                    the app sidecar connection carrying the screen request for session \
                    \(terminalID.uuidString) ended before it was answered
                    """))
            return
        }
        pending[requestID]?.epoch = epoch
        // This request's own bound, which the caller may have tightened.
        let bound = pending[requestID]?.bound ?? self.bound
        let boundTask = Task { [clock] in
            // Non-throwing on cancellation: `try?` swallows the
            // `CancellationError`, and the guard then stops a cancelled bound
            // from expiring a request that was answered.
            try? await clock.sleep(for: bound)
            guard !Task.isCancelled else { return }
            await self.expire(requestID)
        }
        // Resolved while the bound was being built: cancel it rather than leave
        // a timer for an entry nobody is waiting on.
        if pending[requestID] == nil {
            boundTask.cancel()
        } else {
            pending[requestID]?.boundTask = boundTask
        }
    }

    private func ingest(_ reply: SidecarScreenReply, epoch: UInt64) {
        guard let entry = pending[reply.requestID] else {
            lateRepliesObserved += 1
            Self.logger.info("""
                screen request \(reply.requestID.uuidString, privacy: .public) was answered after \
                its bound had already elapsed or its connection had ended; the daemon has already \
                answered its caller from its own emulator, so this answer is dropped
                """)
            return
        }
        guard entry.terminalID == reply.terminalID else {
            misaddressedRepliesObserved += 1
            Self.logger.fault("""
                screen reply \(reply.requestID.uuidString, privacy: .public) claims session \
                \(reply.terminalID.uuidString, privacy: .public) but that request was made for \
                \(entry.terminalID.uuidString, privacy: .public); dropping it and leaving the \
                request pending
                """)
            return
        }
        // nil means the send has not returned an epoch yet, which can only
        // happen for a reply to a frame this connection carried.
        if let sentOn = entry.epoch, sentOn != epoch {
            lateRepliesObserved += 1
            Self.logger.info("""
                screen reply \(reply.requestID.uuidString, privacy: .public) arrived on sidecar \
                epoch \(epoch, privacy: .public) but its request went out on \
                \(sentOn, privacy: .public); dropping it rather than matching by id alone
                """)
            return
        }
        if let screen = reply.screen {
            answeredPullsObserved += 1
            resolve(reply.requestID, with: .answered(screen, styledCapture: reply.styledCapture))
            return
        }
        // No screen and no named reason is a malformed reply rather than a
        // state; treated as a refusal with the reason the app would have sent
        // for "nothing here can answer", because the caller's behaviour is the
        // same and silence would cost it the bound.
        resolve(reply.requestID, with: .refused(reply.unavailable ?? .noPanel))
    }

    private func failEveryRequest(onEpoch epoch: UInt64) {
        // Recorded before the sweep, so a request whose send has not yet
        // returned an epoch is caught by `dispatch`'s own check rather than
        // waiting out the bound unmatched.
        lastEndedEpoch = max(lastEndedEpoch, epoch)
        connectionsLostObserved += 1
        for (requestID, entry) in pending where entry.epoch == epoch {
            resolve(
                requestID,
                with: .undeliverable("""
                    the app sidecar connection carrying the screen request for session \
                    \(entry.terminalID.uuidString) ended before it was answered
                    """))
        }
    }

    private func expire(_ requestID: UUID) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        timedOutPullsObserved += 1
        Self.logger.info("""
            no viewer answered the screen request for session \
            \(entry.terminalID.uuidString, privacy: .public) within \
            \(String(describing: entry.bound), privacy: .public); answering from the daemon's own \
            emulator instead
            """)
        entry.continuation.resume(returning: .timedOut)
    }

    private func resolve(_ requestID: UUID, with answer: Answer) {
        guard let entry = pending.removeValue(forKey: requestID) else { return }
        entry.boundTask?.cancel()
        entry.continuation.resume(returning: answer)
    }
}
