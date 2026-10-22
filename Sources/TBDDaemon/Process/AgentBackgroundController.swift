import Foundation
import os
import TBDShared

private let backgroundLogger = Logger(subsystem: "com.tbd.daemon", category: "agent-background")

/// Why `AgentBackgroundController.on(for:)` refused.
enum AgentBackgroundError: LocalizedError, Equatable, CustomStringConvertible {
    case durationNotPositive
    case durationTooLong(maximumSeconds: Int)

    var errorDescription: String? { description }

    var description: String {
        switch self {
        case .durationNotPositive:
            return "The lease must be longer than zero seconds"
        case .durationTooLong(let maximum):
            return "The lease is at most \(maximum) seconds (2 hours)"
        }
    }
}

/// Holds agent process trees at macOS background priority for a lease, and puts
/// them back when the lease ends.
///
/// Design: docs/specs/2026-10-21-agent-start-admission-design.md, "Background
/// priority". TBD does not decide when a call is on: a caller renews the lease
/// while it wants the agents quiet, and the clock here restores them when it
/// stops renewing.
///
/// **What it lowers.** The roots `rootsProvider` names (the job a holder tab
/// runs, or a tmux pane's process) and everything below each. Never the holder
/// or the tmux server: they carry the terminal's input and output, and a root's
/// subtree does not contain its parent. A process already in the background is
/// left alone and never recorded, so a restore never undoes someone else's
/// choice.
///
/// **What it restores.** Each recorded `(pid, start time)` whose current start
/// time still equals the recorded one. A recycled pid, or one that exited, is
/// skipped. A process that started during the lease and inherited background
/// priority keeps it until it exits.
///
/// **Reclaimer.** `agent-background.json` is one file, rewritten in place, owned
/// by this actor: `sweep()` deletes it when the lease ends and `recoverOnStart()`
/// deletes it when a daemon starts to find an expired or unreadable one. If the
/// daemon never comes back the lowered processes stay lowered until they exit.
actor AgentBackgroundController {
    /// One lowered process.
    struct Record: Codable, Equatable, Sendable {
        let pid: Int32
        let startMicros: Int64
    }

    /// The persisted lease and what it lowered.
    struct State: Codable, Equatable, Sendable {
        var leaseEndsAt: Date
        var lowered: [Record]
    }

    private let priority: any ProcessPriority
    private let rootsProvider: @Sendable () async -> [pid_t]
    private let statePath: String
    private let now: @Sendable () -> Date
    private let sweepInterval: Duration
    private let clock: any Clock<Duration>
    private var state: State?
    private var loopTask: Task<Void, Never>?

    init(
        priority: any ProcessPriority = ProductionProcessPriority(),
        roots: @escaping @Sendable () async -> [pid_t],
        statePath: String = TBDConstants.agentBackgroundStatePath,
        now: @escaping @Sendable () -> Date = { Date() },
        sweepInterval: Duration = .seconds(60),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.priority = priority
        self.rootsProvider = roots
        self.statePath = statePath
        self.now = now
        self.sweepInterval = sweepInterval
        self.clock = clock
    }

    // MARK: - Commands

    /// Starts or renews a lease of `duration` from now, then lowers what it can.
    /// Renewing replaces the end and keeps the record.
    @discardableResult
    func on(for duration: Duration) async throws -> AgentsBackgroundResult {
        let seconds = Int(duration.components.seconds)
        guard seconds > 0 else { throw AgentBackgroundError.durationNotPositive }
        guard seconds <= AgentBackgroundLimits.maximumLeaseSeconds else {
            throw AgentBackgroundError.durationTooLong(
                maximumSeconds: AgentBackgroundLimits.maximumLeaseSeconds)
        }
        let ends = now().addingTimeInterval(TimeInterval(seconds))
        state = State(leaseEndsAt: ends, lowered: state?.lowered ?? [])
        persist()
        await sweep()
        return status()
    }

    /// Restores everything now and ends the lease.
    @discardableResult
    func off() -> AgentsBackgroundResult {
        endLease()
        return status()
    }

    func status() -> AgentsBackgroundResult {
        guard let state else { return AgentsBackgroundResult(active: false) }
        return AgentsBackgroundResult(
            active: true, leaseEndsAt: state.leaseEndsAt, loweredCount: state.lowered.count)
    }

    /// One pass: end an expired lease, otherwise lower any agent process that
    /// appeared since the last one. Does nothing without a lease.
    func sweep() async {
        guard let leased = state else { return }
        if now() >= leased.leaseEndsAt {
            endLease()
            return
        }
        // Read the roots first: everything after this await is synchronous, so
        // `off()` or a renewal cannot land between a process being lowered and
        // being recorded.
        let roots = await rootsProvider()
        guard var current = state else { return }
        // Forget records whose process is gone or is now somebody else's.
        let before = current.lowered.count
        current.lowered.removeAll { priority.startTimeMicros(of: $0.pid) != $0.startMicros }
        let changed = current.lowered.count != before
        var recorded = Set(current.lowered.map(\.pid))

        var candidates: [Record] = []
        for root in roots {
            for pid in priority.subtree(of: root) where !recorded.contains(pid) {
                guard let start = priority.startTimeMicros(of: pid),
                      priority.isBackground(pid) == false
                else { continue }
                candidates.append(Record(pid: pid, startMicros: start))
                recorded.insert(pid)
            }
        }
        guard !candidates.isEmpty else {
            state = current
            if changed { persist() }
            return
        }

        // Written down before lowered, so a daemon that dies in between leaves
        // a record the next one restores rather than a lowered process nobody
        // knows about. When the record cannot be written, nothing new is
        // lowered this pass.
        let known = current
        current.lowered += candidates
        state = current
        guard persist() else {
            backgroundLogger.error(
                "lowered none of \(candidates.count, privacy: .public) new agent processes: their record could not be written")
            state = known
            return
        }
        var refused: Set<pid_t> = []
        for record in candidates where !priority.lowerToBackground(record.pid) {
            backgroundLogger.error("could not lower pid \(record.pid, privacy: .public)")
            refused.insert(record.pid)
        }
        if !refused.isEmpty {
            current.lowered.removeAll { refused.contains($0.pid) }
            state = current
            persist()
        }
        backgroundLogger.info(
            "lowered \(current.lowered.count, privacy: .public) agent processes")
    }

    // MARK: - Lifecycle

    /// Reads a lease a previous daemon left. Expired: restore and delete. Live:
    /// keep it for the loop to sweep. Unreadable: log, restore nothing, delete.
    func recoverOnStart() {
        guard FileManager.default.fileExists(atPath: statePath) else { return }
        let loaded: State
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: statePath))
            loaded = try Self.decoder.decode(State.self, from: data)
        } catch {
            backgroundLogger.error(
                "agent-background.json unreadable (\(type(of: error), privacy: .public)); removing it")
            removeFile()
            return
        }
        state = loaded
        if now() >= loaded.leaseEndsAt {
            endLease()
        } else {
            backgroundLogger.info(
                "resuming a lease with \(loaded.lowered.count, privacy: .public) lowered processes")
        }
    }

    /// Recovers a left-over lease, then sweeps every `sweepInterval` until `stop()`.
    func start() {
        guard loopTask == nil else { return }
        recoverOnStart()
        let interval = sweepInterval
        let clock = clock
        loopTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await clock.sleep(for: interval)
                guard !Task.isCancelled, let self else { break }
                await self.sweep()
            }
        }
    }

    func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    // MARK: - Private

    private func endLease() {
        if let state {
            var restored = 0
            for record in state.lowered where priority.startTimeMicros(of: record.pid) == record.startMicros {
                if priority.restore(record.pid) { restored += 1 }
            }
            backgroundLogger.info(
                "restored \(restored, privacy: .public) of \(state.lowered.count, privacy: .public) agent processes")
        }
        state = nil
        removeFile()
    }

    /// Writes the lease and its records. False when the file could not be written.
    @discardableResult
    private func persist() -> Bool {
        guard let state else { return false }
        do {
            let data = try Self.encoder.encode(state)
            try data.write(to: URL(fileURLWithPath: statePath), options: .atomic)
            return true
        } catch {
            backgroundLogger.error(
                "could not write agent-background.json (\(type(of: error), privacy: .public))")
            return false
        }
    }

    private func removeFile() {
        try? FileManager.default.removeItem(atPath: statePath)
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
