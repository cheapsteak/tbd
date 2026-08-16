import Foundation
import os
import TBDShared

private let sessionStateLog = Logger(subsystem: "com.tbd.daemon", category: "sessionState")

// MARK: - Gathering the facts

/// Reads the per-terminal machine facts `SessionStateResolver` composes, and
/// the session's context load.
///
/// Separated from the handler so the whole fact-gathering pass is a value with
/// injectable seams — and so the cost model is legible in one place. Per
/// terminal it performs **at most two byte-bounded file reads** (the transcript
/// tail, once for the rate-limit classification and once inside
/// `ContextLoadReader`, plus the statusline capture when one exists) and
/// **zero** subprocesses, tmux calls, pane reads and model calls. That is the
/// property that lets the whole fleet be asked about every cycle.
/// Not `Sendable`, and it does not need to be: one gatherer is built inside a
/// single `session.states` pass and never crosses an isolation boundary.
struct SessionStateFactGatherer {
    /// The same 64 KiB window `DeliveryVerifier` and `ContextLoadReader` tail
    /// with. A rate-limit record sits at the very end of a transcript when it
    /// is the current state, so a tail is where it is or it is not current.
    static let defaultTailWindowBytes = 64 * 1024

    var tailWindowBytes: Int = SessionStateFactGatherer.defaultTailWindowBytes
    var contextLoadReader = ContextLoadReader()
    var now: @Sendable () -> Date = { Date() }
    /// Resolves a session's statusline capture path. Injected so a test can
    /// point it at a temp dir without reaching for `TBD_HOME`.
    var capturePath: @Sendable (String) -> String = { StatuslineTee.capturePath(sessionKey: $0) }

    /// Written out rather than left memberwise so the injected date seam
    /// reaches the collaborator that has one of its own.
    ///
    /// `ContextLoadReader` carries a `now` because it needs a fallback stamp
    /// for a transcript record that arrives with no parseable `timestamp`.
    /// A memberwise `init(now:)` left that reader on its own default — wall
    /// time — so a caller who pinned this type's clock still got `Date()` in
    /// that one field. A reader passed in explicitly keeps whatever seam its
    /// caller gave it; only the default one is threaded.
    init(
        tailWindowBytes: Int = SessionStateFactGatherer.defaultTailWindowBytes,
        contextLoadReader: ContextLoadReader? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        capturePath: @escaping @Sendable (String) -> String = {
            StatuslineTee.capturePath(sessionKey: $0)
        }
    ) {
        self.tailWindowBytes = tailWindowBytes
        self.contextLoadReader = contextLoadReader ?? ContextLoadReader(now: now)
        self.now = now
        self.capturePath = capturePath
    }

    func facts(for terminal: Terminal) -> SessionStateFacts {
        // One tail read serves both transcript-derived facts: the rate-limit
        // classification and the append stamp the resolver's staleness rule
        // compares against. Reading twice would double the cost of the pass and
        // let the two facts describe different moments of the same file.
        let tail = transcriptTail(for: terminal)
        return SessionStateFacts(
            terminal: terminal,
            transcriptRateLimit: transcriptRateLimit(tail),
            transcriptLastAppendedAt: tail?.lastAppendedAt.map {
                ObservedFact(value: $0, source: .transcriptTail, observedAt: tail?.readAt ?? now())
            },
            // Deliberately nil: nothing on this path establishes pane or
            // process liveness, and this path does not go and find out. See
            // `SessionStateResolver`'s note on `.gone`.
            liveness: nil)
    }

    func contextLoad(for terminal: Terminal) -> ContextLoad {
        contextLoadReader.read(
            capturePath: capturePath(terminal.id.uuidString),
            transcriptPath: terminal.transcriptPath,
            tee: teeStatus(for: terminal))
    }

    /// The desk role brands the ROW; the tee installs on the Claude spawn path
    /// only. `spawnPrimaryTerminals` resolves the primary agent from
    /// `primaryAgentPreference`, so a desk created on a Codex-preferring install
    /// gets a `.codex` row wearing a desk role and no tee — and reporting "the
    /// tee is installed but has not fired yet" for it would be a false statement
    /// about a session that will never produce a capture.
    private func teeStatus(for terminal: Terminal) -> ContextLoadReader.TeeStatus {
        guard terminal.watchDeskRole != nil else { return .notADesk }
        return terminal.kind == .claude ? .installed : .deskWithoutTee
    }

    /// One bounded read of a session's transcript tail, and the two things the
    /// pass learns from it.
    private struct TranscriptTail {
        let data: Data
        /// The file's modification time — when it last grew — taken from the
        /// same open descriptor as `data`, so the stamp and the bytes describe
        /// one file rather than two. nil when `fstat` refused.
        let lastAppendedAt: Date?
        /// When TBD read it.
        let readAt: Date
    }

    /// Classify the transcript tail with `RateLimitDetection` — the existing
    /// classifier the CLI's StopFailure hook and `LimitResumeActuator` already
    /// share. There is deliberately no second implementation of "is this a hard
    /// limit": a supervision surface disagreeing with the actuator about
    /// whether a session is rate-limited would be worse than not reporting it.
    private func transcriptRateLimit(
        _ tail: TranscriptTail?
    ) -> SessionStateFacts.TranscriptRateLimit? {
        guard let tail else { return nil }
        guard let limit = RateLimitDetection.detect(transcriptData: tail.data, now: tail.readAt) else {
            return nil
        }
        return SessionStateFacts.TranscriptRateLimit(limit: limit, observedAt: tail.readAt)
    }

    /// Byte-bounded tail read, the shape `DeliveryVerifier.transcriptTail` and
    /// `ContextLoadReader.readTail` both use. Unreadable answers nil rather than
    /// empty: "could not read" and "read nothing" are different facts.
    private func transcriptTail(for terminal: Terminal) -> TranscriptTail? {
        guard let path = terminal.transcriptPath, !path.isEmpty,
              let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        let window = UInt64(max(tailWindowBytes, 0))
        do {
            try handle.seek(toOffset: size > window ? size - window : 0)
            let data = try handle.readToEnd() ?? Data()
            return TranscriptTail(
                data: data, lastAppendedAt: handle.modificationDate(), readAt: now())
        } catch {
            return nil
        }
    }
}

// MARK: - The handler

extension RPCRouter {
    /// `session.states` — one `SessionStateReport` per terminal: the composed
    /// state triple, the context load, and §13's counters.
    ///
    /// **There is deliberately no CLI twin for this method.** §10 of the
    /// fleet-supervision design is normative for the `tbd supervise` namespace
    /// and reserves `tbd supervise readout` for the sweep-program slice, which
    /// owns what a readout contains and how it is shaped for a reader. Adding a
    /// command here would either squat on that name or invent a second one for
    /// the same job. The machine surface is this RPC; the human surface arrives
    /// with the program that needs it.
    ///
    /// The pass is built to be called every cycle for the whole fleet: per
    /// terminal it costs database reads plus bounded file tails, and no
    /// subprocess, tmux call, pane read or model call. Keep it that way — the
    /// moment anything here shells out, the method stops being askable at fleet
    /// cadence and the supervision loop loses the facts it runs on.
    func handleSessionStates(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SessionStatesParams.self, from: paramsData)
        // Agent-bearing kinds only. A plain shell has no transcript, no context
        // window and no hook rail, so a `SessionStateReport` about one would
        // spend a stat and a transcript-tail attempt every cycle to explain why
        // a session that never had a statusline tee has no denominator. A nil
        // kind is a pre-`kind` row, which in practice is an agent terminal —
        // included, because dropping a real agent from the fleet's readout is
        // the worse error of the two.
        let terminals = try await db.terminals.list(worktreeID: params.worktreeID)
            .filter { $0.kind?.isAgentBearing ?? true }
        let sampledAt = now()

        let resolver = SessionStateResolver(now: now)
        let gatherer = SessionStateFactGatherer(now: now)

        // One worktree lookup per distinct worktree, not per terminal: several
        // terminals commonly share one, and the only field needed is `repoID`.
        var repoIDByWorktree: [UUID: UUID?] = [:]
        var reports: [SessionStateReport] = []
        reports.reserveCapacity(terminals.count)

        for terminal in terminals {
            let state = resolver.resolve(gatherer.facts(for: terminal))
            let contextLoad = gatherer.contextLoad(for: terminal)

            if !repoIDByWorktree.keys.contains(terminal.worktreeID) {
                repoIDByWorktree[terminal.worktreeID] =
                    (try? await db.worktrees.get(id: terminal.worktreeID))?.repoID
            }
            let commitsUnchangedSince: Date?
            if let repoID = repoIDByWorktree[terminal.worktreeID] ?? nil {
                commitsUnchangedSince = await lifecycle.branchTipTracker.unchangedSince(
                    repoID: repoID, worktreeID: terminal.worktreeID)
            } else {
                // No repo (a scratch space), or the worktree row is gone. The
                // sweep never resolved a tip for it, so the fact is not
                // established — nil, never "unchanged".
                commitsUnchangedSince = nil
            }

            let counters = await sessionCounters.sample(
                terminalID: terminal.id,
                worktreeID: terminal.worktreeID,
                transcriptPath: terminal.transcriptPath,
                commitsUnchangedSince: commitsUnchangedSince,
                at: sampledAt)

            reports.append(SessionStateReport(
                terminalID: terminal.id,
                worktreeID: terminal.worktreeID,
                state: state,
                contextLoad: contextLoad,
                counters: counters))
        }

        // Scoped to whatever `terminals` was filtered by: a call about one
        // worktree has not seen the rest of the fleet and may not prune it.
        await sessionCounters.retain(
            terminalIDs: Set(terminals.map(\.id)), inWorktree: params.worktreeID)

        sessionStateLog.debug(
            "session.states: reported \(reports.count, privacy: .public) terminal(s)")
        return try RPCResponse(result: SessionStatesResult(reports: reports))
    }
}
