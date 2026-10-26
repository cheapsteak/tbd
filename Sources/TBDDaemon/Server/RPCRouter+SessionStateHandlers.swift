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
/// terminal it performs **a handful of small or byte-bounded file reads** (the
/// transcript tail, once for the rate-limit classification and once inside
/// `ContextLoadReader`; for a Claude session with a session directory, its
/// `spawn.json`, `alive.json` and — when the mod is confirmed running —
/// `usage.json`) and **zero** subprocesses, tmux calls, pane reads and model
/// calls. That is the property that lets the pass be called on a cadence for
/// every agent at once.
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
    /// The session mod's sessions root, where each Claude session's
    /// `spawn.json`, `alive.json` and `usage.json` live. Injected so a test can
    /// point it at a temp dir without reaching for `TBD_HOME`.
    var sessionsDir: URL = TBDConstants.sessionsDir()

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
        sessionsDir: URL = TBDConstants.sessionsDir()
    ) {
        self.tailWindowBytes = tailWindowBytes
        self.contextLoadReader = contextLoadReader ?? ContextLoadReader(now: now)
        self.now = now
        self.sessionsDir = sessionsDir
    }

    /// - Parameter programStatus: the terminal's OSC 7501 snapshot, read by
    ///   the caller from `ProgramStatusStore` (an actor, so it cannot be read
    ///   from this synchronous pass). nil when the flag is off.
    func facts(
        for terminal: Terminal, programStatus: ProgramStatusSnapshot? = nil
    ) -> SessionStateFacts {
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
            liveness: nil,
            programStatus: programStatus)
    }

    func contextLoad(for terminal: Terminal) -> ContextLoad {
        switch usageSource(for: terminal) {
        case .parked:
            return contextLoadReader.readParked(transcriptPath: terminal.transcriptPath)
        case .spawn(let path, let liveness):
            return contextLoadReader.read(
                usagePath: path,
                usageIncarnationID: terminal.sessionIncarnationID,
                usageLiveness: liveness,
                transcriptPath: terminal.transcriptPath)
        }
    }

    private enum UsageSource {
        /// Parked, and the session's last spawn ran `usage`.
        case parked
        /// Where the usage file lives, and the `usage` liveness for the row's
        /// own incarnation.
        case spawn(path: String?, liveness: SessionModLiveness)
    }

    /// Whether this session was spawned to record its usage through the
    /// session mod, and where that file lives.
    ///
    /// Liveness is evaluated against the row's live incarnation, as
    /// `ComposerDraftStatus` does, so a `spawn.json` left by an earlier life of
    /// the session reads `.legacy` rather than vouching for this one. The mod
    /// loads into Claude Code only, so every other kind is `.legacy` — and so
    /// is a row with no session ID, or one unsafe to use as a path, which has
    /// no directory to read.
    ///
    /// A parked row carries the inert shell's incarnation, so that check would
    /// read it `.legacy` and report it as spawned without the feature. When the
    /// session's spawn record lists `usage`, a parked row is reported as
    /// `.parked` instead, and the reader does not read the usage file: no
    /// process is reporting its window, and the shared, overwritten
    /// `spawn.json` cannot say whose file is on disk. A parked row whose spawn
    /// did not list `usage` reads `.legacy`. A parked row whose mod still
    /// confirms against its live incarnation (a wake whose `clearHibernated`
    /// failed) reports its window as a live row does, and a parked row with an
    /// unreadable spawn record is `.parked` too.
    private func usageSource(for terminal: Terminal) -> UsageSource {
        guard terminal.kind == .claude, let id = terminal.claudeSessionID,
              let dir = SessionModFiles.directory(sessionsDir: sessionsDir, claudeSessionID: id) else {
            return .spawn(path: nil, liveness: .legacy)
        }
        let spawn = SessionModFiles.read(
            SessionModFiles.SpawnRecord.self, at: dir.appendingPathComponent(SessionModFiles.spawnFileName))
        let liveness = SessionModLiveness.evaluate(
            feature: .usage, spawn: spawn,
            alive: SessionModFiles.read(
                SessionModFiles.AliveRecord.self, at: dir.appendingPathComponent(SessionModFiles.aliveFileName)),
            liveIncarnationID: terminal.sessionIncarnationID, now: now())
        // A woken process whose `clearHibernated` failed still reads parked, but
        // its mod confirms against the row's live incarnation: report its window.
        if terminal.isParked {
            if case .confirmed = liveness {} else {
                switch spawn {
                case .record(let record):
                    if record.features.contains(SessionModFeature.usage.rawValue) { return .parked }
                case .unreadable:
                    // The spawn cannot say it did not run `usage`.
                    return .parked
                case .missing:
                    break
                }
            }
        }
        return .spawn(path: dir.appendingPathComponent(SessionModFiles.usageFileName).path, liveness: liveness)
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
    /// limit": a state report disagreeing with the actuator about whether a
    /// session is rate-limited would be worse than not reporting it.
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
    /// state triple and the context load.
    ///
    /// A machine surface with no CLI twin: a script or agent that wants each
    /// session's state, with the provenance behind it, asks the daemon socket.
    ///
    /// The pass is built to be called on a cadence for every agent at once: per
    /// terminal it costs database reads plus bounded file tails, and no
    /// subprocess, tmux call, pane read or model call. Keep it that way — the
    /// moment anything here shells out, the method stops being cheap enough to
    /// ask about every agent.
    func handleSessionStates(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(SessionStatesParams.self, from: paramsData)
        // Agent-bearing kinds only. A plain shell has no transcript, no context
        // window and no hook rail, so a `SessionStateReport` about one would
        // spend a stat and a transcript-tail attempt on every call to explain
        // why a shell has no denominator. A nil kind is a pre-`kind` row, which
        // in practice is an agent terminal — included, because dropping a real
        // agent from the report is the worse error of the two.
        let terminals = try await db.terminals.list(worktreeID: params.worktreeID)
            .filter { $0.kind?.isAgentBearing ?? true }

        let resolver = SessionStateResolver(now: now)
        let gatherer = SessionStateFactGatherer(now: now)

        var reports: [SessionStateReport] = []
        reports.reserveCapacity(terminals.count)

        for terminal in terminals {
            let programStatusSnapshot: ProgramStatusSnapshot?
            if programStatus.gate.isEnabled {
                programStatusSnapshot = await programStatus.snapshot(for: terminal.id)
            } else {
                programStatusSnapshot = nil
            }
            let state = resolver.resolve(
                gatherer.facts(for: terminal, programStatus: programStatusSnapshot))
            let contextLoad = gatherer.contextLoad(for: terminal)

            reports.append(SessionStateReport(
                terminalID: terminal.id,
                worktreeID: terminal.worktreeID,
                state: state,
                contextLoad: contextLoad))
        }

        sessionStateLog.debug(
            "session.states: reported \(reports.count, privacy: .public) terminal(s)")
        return try RPCResponse(result: SessionStatesResult(reports: reports))
    }
}
