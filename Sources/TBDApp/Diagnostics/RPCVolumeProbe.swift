import Foundation
import TBDShared
import os

/// Default-off gate for the RPC volume probe.
///
/// App-only behaviour, so `UserDefaults` is the right home per CLAUDE.md —
/// precedent is `enableTranscript`. There is deliberately no Settings toggle:
/// this is a measurement instrument, not a feature, and the flag is read once
/// per process (see `RPCVolumeProbe.init`) so the receive path costs one
/// already-loaded `Bool` when it is off.
///
/// Enable for a measurement session with
/// `defaults write TBDApp enableRPCVolumeDiagnostic -bool true`, then relaunch
/// the app. `defaults delete TBDApp enableRPCVolumeDiagnostic` returns to unset.
enum RPCVolumeDiagnosticPreferences {
    static let enabledKey = "enableRPCVolumeDiagnostic"

    /// The one default for `enabledKey`. Every read site must spell the
    /// default with this constant rather than a bare literal.
    ///
    /// Off, because the probe is not free: enabled, it takes two monotonic
    /// clock reads and one uncontended lock acquisition per message received
    /// from the daemon, and keeps a per-second window of per-type totals.
    static let enabledDefault = false

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: enabledKey) as? Bool ?? enabledDefault
    }
}

/// Measures how much data the daemon pushes at the app and what decoding it
/// costs, per message, on both receive paths in `DaemonClient`.
///
/// ## Why this exists
///
/// A `sample` of TBDApp taken during a confirmed terminal-lag episode found
/// 1,265 samples inside `JSONDecoder` internals against 81 blocked in
/// `read`/`recv`/`poll`/`cond_wait`, spread over six cooperative-pool threads.
/// Those threads were not waiting on the socket; they were burning CPU
/// decoding. Nothing logged payload sizes, so there was no way to tell whether
/// that is a meaningful load or a sampling artifact. This closes that gap.
///
/// ## Rate limiting: a periodic summary, flushed lazily
///
/// The measurement's whole premise is that messages may arrive hundreds of
/// times a second. One log line each would cost more than the decode it
/// measures and would corrupt the reading, so records aggregate into a window
/// (1 s by default) and only the window is logged.
///
/// The alternative — logging individual lines above a byte or duration
/// threshold — was rejected because it cannot answer the question asked. The
/// suspicion is death by a thousand small deltas; a threshold high enough to
/// be safe would discard exactly the messages under suspicion, and the
/// denominators (total bytes, total decode ms, messages/second) would be lost.
///
/// The window is closed **lazily, by the next record that finds it expired**
/// (whose own message then opens the new window) — there is no timer, no
/// `Task`, and therefore no sleeping and no `Clock` seam. The cost is that a
/// window whose traffic stops is not emitted until traffic resumes, and the
/// final partial window at app exit is dropped; for a diagnostic that only
/// runs while traffic is flowing, that is the right trade against putting a
/// scheduled wake-up inside the thing being measured.
///
/// ## What is logged
///
/// One `kind=window` line with the totals, then one line per (kind, type)
/// pair — capped at the union of the top eight by bytes and the top eight by
/// decode time, with the remainder rolled into a `type=(other)` line so the
/// per-type totals still sum to the window's. Both rankings the reader needs —
/// which messages dominate *bytes* and which dominate *decode time* — survive
/// that cap, and they are not the same ranking.
///
/// **Sizes, type names and timings only.** Payloads carry the user's real
/// work and never reach a log line. The `type` values are compile-time
/// constants: an `RPCMethod` string for a response, a `StateDelta` case name
/// for a delta.
///
/// ## What it does NOT see
///
/// `DaemonClient`'s two receive paths, and nothing else.
/// `FDSidecarClient.handleFDVend` also decodes daemon-pushed JSON — a small
/// `FDVendHeader` per control-mode attach, not a hot path — and is deliberately
/// left uninstrumented, so the totals here are the app's RPC traffic rather
/// than every byte the daemon sends it.
final class RPCVolumeProbe: Sendable {
    /// Which receive path the message arrived on. The two have different
    /// fixes — a response is one call the app chose to make, a delta is
    /// pushed traffic the app cannot decline — so they are never merged.
    enum Kind: String, Sendable {
        case delta
        case response
    }

    /// The process-wide probe used by `DaemonClient`.
    static let shared = RPCVolumeProbe()

    /// Read once at construction. A per-message `UserDefaults` lookup would
    /// itself be overhead on the path being measured, so toggling the flag
    /// takes effect at the next app launch.
    let isEnabled: Bool

    private let windowNanos: UInt64
    private let latencySampleCap: Int
    private let now: @Sendable () -> UInt64
    private let emit: @Sendable (String) -> Void
    private let window: OSAllocatedUnfairLock<Window>

    private static let logger = Logger(subsystem: "com.tbd.app", category: "rpcvolume")

    /// - Parameters:
    ///   - defaults: the domain the gate is read from.
    ///   - windowSeconds: how much traffic one summary line covers.
    ///   - latencySampleCap: upper bound on decode durations retained per
    ///     window for percentiles. Counts, byte totals and decode-time totals
    ///     stay exact past the cap; only the percentiles are drawn from the
    ///     first `latencySampleCap` messages. Bounds the probe's own
    ///     allocation under exactly the flood it is there to catch.
    ///   - now: monotonic nanosecond source. A closure seam, not a `Clock`:
    ///     nothing here sleeps or schedules, and these readings are compared,
    ///     never persisted.
    ///   - emit: one formatted line. Defaults to the `rpcvolume` logger.
    init(
        defaults: UserDefaults = .standard,
        windowSeconds: Double = 1.0,
        latencySampleCap: Int = 8192,
        now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        emit: (@Sendable (String) -> Void)? = nil
    ) {
        self.isEnabled = RPCVolumeDiagnosticPreferences.isEnabled(defaults)
        self.windowNanos = UInt64(max(0, windowSeconds) * 1_000_000_000)
        self.latencySampleCap = latencySampleCap
        self.now = now
        // `.info` so the lines persist for a `log show` after an episode, and
        // `.public` because every interpolated value is a size, a count, a
        // duration, or a compile-time type name.
        self.emit = emit ?? { line in Self.logger.info("\(line, privacy: .public)") }
        self.window = OSAllocatedUnfairLock(initialState: Window(startedAt: now()))
    }

    // MARK: - Recording

    /// Timestamp to hand back to `record`, or nil when the probe is off — in
    /// which case no clock is read and no measurement overhead is taken.
    func startMeasurement() -> UInt64? {
        isEnabled ? now() : nil
    }

    /// Record one received message. A nil `start` (probe off) returns
    /// immediately.
    ///
    /// - Parameters:
    ///   - start: the value `startMeasurement()` returned before decoding began.
    ///   - bytes: length of the framed message, excluding the newline delimiter.
    ///   - type: the RPC method name for a response, the `StateDelta` case
    ///     name for a delta.
    func record(start: UInt64?, kind: Kind, type: String, bytes: Int) {
        guard let start else { return }
        let end = now()
        let decodeNanos = Self.elapsed(from: start, to: end)
        let key = TypeKey(kind: kind.rawValue, type: type)

        let closed: Window? = window.withLock { current -> Window? in
            // Roll BEFORE adding: this message arrived after the old window's
            // span ended, so its bytes belong to the new one. Attributing them
            // to a window whose `secs` does not cover them inflates that
            // window's byte rate by exactly one message.
            //
            // The elapsed subtraction saturates rather than wrapping. `end` is
            // read before the lock, so a thread descheduled between its clock
            // read and its turn at the lock can arrive with a reading OLDER
            // than a window another thread has already opened — and `sendRaw`
            // on arbitrary detached threads runs concurrently with the
            // long-lived `subscribe(onDelta:)` receive loop, which is exactly
            // the contention this probe exists to observe. Unsigned wrapping
            // would turn that into a near-`UInt64.max` elapsed, a spurious
            // roll, and an astronomical `secs=` that drags the reader's rate
            // denominators toward zero.
            var finished: Window?
            if Self.elapsed(from: current.startedAt, to: end) >= windowNanos {
                // An expired window with nothing in it is a quiet stretch, not
                // a measurement; replace it rather than logging an empty line.
                if current.messages > 0 { finished = current }
                current = Window(startedAt: end)
            }
            current.add(key: key, bytes: bytes, decodeNanos: decodeNanos, latencySampleCap: latencySampleCap)
            return finished
        }
        if let closed { report(closed, endedAt: end) }
    }

    /// Close and emit the current window even though it has not expired.
    /// Production never calls this — the next record rolls the window — but it
    /// lets a test close a partial window without waiting on wall time.
    func flush() {
        guard isEnabled else { return }
        let end = now()
        let closed: Window? = window.withLock { current in
            guard current.messages > 0 else { return nil }
            let finished = current
            current = Window(startedAt: end)
            return finished
        }
        if let closed { report(closed, endedAt: end) }
    }

    // MARK: - Reporting

    /// Saturating monotonic difference. See the note in `record`.
    private static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? end - start : 0
    }

    private func report(_ closed: Window, endedAt: UInt64) {
        let seconds = Double(Self.elapsed(from: closed.startedAt, to: endedAt)) / 1e9
        let latencies = closed.latencies.sorted()
        emit(
            "rpc kind=window secs=\(fmt(seconds, 3)) msgs=\(closed.messages) bytes=\(closed.bytes) "
            + "decodems=\(millis(closed.decodeNanos)) p50ms=\(millis(percentile(latencies, 0.5))) "
            + "p90ms=\(millis(percentile(latencies, 0.9))) maxms=\(millis(closed.maxDecodeNanos)) "
            + "types=\(closed.byType.count) sampled=\(latencies.count)"
        )
        // Both rankings are kept whole — a type that dominates bytes and one
        // that dominates decode time are frequently different types, and that
        // difference is the actionable part — but the line count per window
        // stays bounded, so a window with pathologically many distinct types
        // cannot turn the summary back into per-message logging.
        let byBytes = closed.byType.sorted { $0.value.bytes > $1.value.bytes }
        let byTime = closed.byType.sorted { $0.value.decodeNanos > $1.value.decodeNanos }
        var kept = Set(byBytes.prefix(Self.typeLinesPerRanking).map(\.key))
        kept.formUnion(byTime.prefix(Self.typeLinesPerRanking).map(\.key))

        var other = TypeTotals()
        for (key, totals) in byBytes {
            guard kept.contains(key) else {
                other.count += totals.count
                other.bytes += totals.bytes
                other.decodeNanos += totals.decodeNanos
                other.maxDecodeNanos = max(other.maxDecodeNanos, totals.maxDecodeNanos)
                continue
            }
            emit(typeLine(kind: key.kind, type: key.type, totals: totals))
        }
        if other.count > 0 {
            emit(typeLine(kind: "mixed", type: "(other)", totals: other))
        }
    }

    /// How many types each ranking contributes to a window's per-type lines.
    /// The union of the two rankings plus the `(other)` rollup caps a window
    /// at `2 * typeLinesPerRanking + 2` lines.
    private static let typeLinesPerRanking = 8

    private func typeLine(kind: String, type: String, totals: TypeTotals) -> String {
        "rpc kind=\(kind) type=\(type) n=\(totals.count) bytes=\(totals.bytes) "
        + "decodems=\(millis(totals.decodeNanos)) maxms=\(millis(totals.maxDecodeNanos))"
    }

    private func millis(_ nanos: UInt64) -> String {
        fmt(Double(nanos) / 1_000_000, 3)
    }

    private func fmt(_ value: Double, _ places: Int) -> String {
        String(format: "%.\(places)f", value)
    }

    private func percentile(_ sorted: [UInt64], _ quantile: Double) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * quantile))]
    }

    // MARK: - Window

    private struct TypeKey: Hashable, Sendable {
        let kind: String
        let type: String
    }

    private struct TypeTotals: Sendable {
        var count = 0
        var bytes = 0
        var decodeNanos: UInt64 = 0
        var maxDecodeNanos: UInt64 = 0
    }

    private struct Window: Sendable {
        let startedAt: UInt64
        var messages = 0
        var bytes = 0
        var decodeNanos: UInt64 = 0
        var maxDecodeNanos: UInt64 = 0
        var latencies: [UInt64] = []
        var byType: [TypeKey: TypeTotals] = [:]

        init(startedAt: UInt64) {
            self.startedAt = startedAt
        }

        mutating func add(key: TypeKey, bytes: Int, decodeNanos: UInt64, latencySampleCap: Int) {
            messages += 1
            self.bytes += bytes
            self.decodeNanos += decodeNanos
            maxDecodeNanos = max(maxDecodeNanos, decodeNanos)
            if latencies.count < latencySampleCap { latencies.append(decodeNanos) }
            var totals = byType[key] ?? TypeTotals()
            totals.count += 1
            totals.bytes += bytes
            totals.decodeNanos += decodeNanos
            totals.maxDecodeNanos = max(totals.maxDecodeNanos, decodeNanos)
            byType[key] = totals
        }
    }
}

// MARK: - Delta naming

extension StateDelta {
    /// The case name alone, for the probe's `type=` field.
    ///
    /// An exhaustive switch on purpose: it is allocation-free on the path
    /// being measured (a `Mirror` is not), and a new `StateDelta` case breaks
    /// the build rather than silently going unlabelled. `String(describing:)`
    /// is not an option — for a case with a payload it would interpolate the
    /// payload, which is the user's real work.
    var rpcVolumeTypeName: String {
        switch self {
        case .worktreeCreated: return "worktreeCreated"
        case .worktreeArchived: return "worktreeArchived"
        case .worktreeRevived: return "worktreeRevived"
        case .worktreeRenamed: return "worktreeRenamed"
        case .notificationReceived: return "notificationReceived"
        case .repoAdded: return "repoAdded"
        case .repoRemoved: return "repoRemoved"
        case .repoRenamed: return "repoRenamed"
        case .repoHiddenChanged: return "repoHiddenChanged"
        case .repoExpandedChanged: return "repoExpandedChanged"
        case .terminalCreated: return "terminalCreated"
        case .terminalRemoved: return "terminalRemoved"
        case .worktreeConflictsChanged: return "worktreeConflictsChanged"
        case .terminalPinChanged: return "terminalPinChanged"
        case .worktreeReordered: return "worktreeReordered"
        case .modelProfileUsageUpdated: return "modelProfileUsageUpdated"
        case .modelProfilesChanged: return "modelProfilesChanged"
        case .terminalSessionUpdated: return "terminalSessionUpdated"
        case .terminalActivityUpdated: return "terminalActivityUpdated"
        case .terminalAwaitingInputChanged: return "terminalAwaitingInputChanged"
        case .terminalProfileChanged: return "terminalProfileChanged"
        case .watchDeskRolesChanged: return "watchDeskRolesChanged"
        case .worktreeMoved: return "worktreeMoved"
        case .terminalHibernationChanged: return "terminalHibernationChanged"
        case .controlModeInputHealthChanged: return "controlModeInputHealthChanged"
        case .reapRecordsChanged: return "reapRecordsChanged"
        case .panelSurfaceChanged: return "panelSurfaceChanged"
        case .remoteSessionsChanged: return "remoteSessionsChanged"
        case .remoteSessionAttention: return "remoteSessionAttention"
        }
    }
}
