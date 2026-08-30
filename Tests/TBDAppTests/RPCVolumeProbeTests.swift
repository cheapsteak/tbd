import Foundation
import Testing
import TBDShared
@testable import TBDApp

/// Tests for the default-off RPC volume probe, covering both branches of the
/// gate per the repo rule for gating conditionals.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is `TBDApp.plist` in the developer's home —
/// the SAME domain a running production TBDApp reads. Every test below builds
/// a per-test `UserDefaults(suiteName:)` and tears the domain down, so
/// `.standard` is never touched.
@Suite("RPC volume probe")
struct RPCVolumeProbeTests {
    /// Collects emitted lines from any thread the probe reports on.
    private final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) {
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }
        var all: [String] {
            lock.lock(); defer { lock.unlock() }
            return lines
        }
    }

    /// A monotonic clock the test drives by hand, so window rollover is
    /// deterministic rather than a race against wall time.
    private final class FakeClock: @unchecked Sendable {
        private let lock = NSLock()
        private var nanos: UInt64 = 0
        func read() -> UInt64 {
            lock.lock(); defer { lock.unlock() }
            return nanos
        }
        func advance(ms: Double) {
            lock.lock(); defer { lock.unlock() }
            nanos += UInt64(ms * 1_000_000)
        }
    }

    private func withIsolatedDefaults(seed: Bool?, _ body: (UserDefaults) -> Void) {
        let suiteName = "TBDAppTests.RPCVolume.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        if let seed { defaults.set(seed, forKey: RPCVolumeDiagnosticPreferences.enabledKey) }
        body(defaults)
    }

    // MARK: - The gate

    @Test("defaults to off when the user has never touched the key")
    func defaultsOff() {
        withIsolatedDefaults(seed: nil) { defaults in
            #expect(RPCVolumeDiagnosticPreferences.isEnabled(defaults) == false)
            #expect(RPCVolumeDiagnosticPreferences.enabledDefault == false)
        }
    }

    @Test("reads an explicit true and an explicit false")
    func readsExplicitValues() {
        withIsolatedDefaults(seed: true) { defaults in
            #expect(RPCVolumeDiagnosticPreferences.isEnabled(defaults) == true)
        }
        withIsolatedDefaults(seed: false) { defaults in
            #expect(RPCVolumeDiagnosticPreferences.isEnabled(defaults) == false)
        }
    }

    // MARK: - Flag OFF branch

    @Test("off: nothing is logged and no clock is read")
    func offBranchIsInert() {
        withIsolatedDefaults(seed: false) { defaults in
            let sink = Sink()
            let reads = Counter()
            let probe = RPCVolumeProbe(
                defaults: defaults,
                windowSeconds: 0,
                now: { reads.bump(); return 0 },
                emit: { sink.append($0) }
            )
            #expect(probe.isEnabled == false)

            // Init seeds the window with one read; everything after must add none.
            let baseline = reads.value
            #expect(probe.startMeasurement() == nil)
            probe.record(
                start: probe.startMeasurement(),
                kind: .delta, type: "terminalActivityUpdated", bytes: 4096
            )
            probe.flush()

            #expect(sink.all.isEmpty)
            #expect(reads.value == baseline, "off path must not read the clock")
        }
    }

    @Test("off: a nil start is ignored even if record is called anyway")
    func offBranchIgnoresNilStart() {
        withIsolatedDefaults(seed: false) { defaults in
            let sink = Sink()
            let probe = RPCVolumeProbe(defaults: defaults, windowSeconds: 0, emit: { sink.append($0) })
            probe.record(start: nil, kind: .response, type: "worktree.list", bytes: 1)
            #expect(sink.all.isEmpty)
        }
    }

    // MARK: - Flag ON branch

    @Test("on: records a message and emits a window plus a per-type line")
    func onBranchRecords() {
        withIsolatedDefaults(seed: true) { defaults in
            let sink = Sink()
            let clock = FakeClock()
            let probe = RPCVolumeProbe(
                defaults: defaults, windowSeconds: 1.0, now: { clock.read() }, emit: { sink.append($0) }
            )
            #expect(probe.isEnabled == true)

            let start = probe.startMeasurement()
            #expect(start != nil)
            clock.advance(ms: 7)
            probe.record(start: start, kind: .delta, type: "terminalActivityUpdated", bytes: 4096)
            #expect(sink.all.isEmpty, "window has not expired yet")

            probe.flush()
            let lines = sink.all
            #expect(lines.count == 2)
            #expect(lines[0].hasPrefix("rpc kind=window "))
            #expect(lines[0].contains("msgs=1"))
            #expect(lines[0].contains("bytes=4096"))
            #expect(lines[0].contains("decodems=7.000"))
            #expect(lines[0].contains("maxms=7.000"))
            #expect(lines[1] == "rpc kind=delta type=terminalActivityUpdated n=1 bytes=4096 "
                                + "decodems=7.000 maxms=7.000")
        }
    }

    @Test("on: aggregates a window and rolls it over only when it expires")
    func onBranchAggregatesAndRolls() {
        withIsolatedDefaults(seed: true) { defaults in
            let sink = Sink()
            let clock = FakeClock()
            let probe = RPCVolumeProbe(
                defaults: defaults, windowSeconds: 1.0, now: { clock.read() }, emit: { sink.append($0) }
            )

            // Three cheap deltas and one expensive response, all inside 1s.
            for _ in 0..<3 {
                let start = probe.startMeasurement()
                clock.advance(ms: 2)
                probe.record(start: start, kind: .delta, type: "terminalActivityUpdated", bytes: 1000)
            }
            let start = probe.startMeasurement()
            clock.advance(ms: 50)
            probe.record(start: start, kind: .response, type: "worktree.list", bytes: 200_000)
            #expect(sink.all.isEmpty, "still inside the window")

            // Cross the boundary: the next record closes the window.
            clock.advance(ms: 1000)
            let last = probe.startMeasurement()
            probe.record(start: last, kind: .delta, type: "terminalActivityUpdated", bytes: 10)

            let lines = sink.all
            #expect(lines.count == 3, "one window line plus one line per (kind,type)")
            let window = lines[0]
            #expect(window.contains("msgs=4"))
            #expect(window.contains("bytes=203000"))
            #expect(window.contains("decodems=56.000"))
            #expect(window.contains("maxms=50.000"))
            #expect(window.contains("types=2"))

            // Bytes-descending, so the response leads even though the deltas
            // are more numerous.
            #expect(lines[1] == "rpc kind=response type=worktree.list n=1 bytes=200000 "
                                + "decodems=50.000 maxms=50.000")
            #expect(lines[2] == "rpc kind=delta type=terminalActivityUpdated n=3 bytes=3000 "
                                + "decodems=6.000 maxms=2.000")

            // The message that rolled the window belongs to the NEW one.
            sink.append("--")
            probe.flush()
            #expect(sink.all.last!.contains("n=1"))
        }
    }

    @Test("on: the byte ranking and the decode ranking can disagree")
    func onBranchSeparatesTheTwoRankings() {
        withIsolatedDefaults(seed: true) { defaults in
            let sink = Sink()
            let clock = FakeClock()
            let probe = RPCVolumeProbe(
                defaults: defaults, windowSeconds: 1.0, now: { clock.read() }, emit: { sink.append($0) }
            )
            // Big and cheap.
            var start = probe.startMeasurement()
            clock.advance(ms: 1)
            probe.record(start: start, kind: .response, type: "blob", bytes: 1_000_000)
            // Small and expensive.
            start = probe.startMeasurement()
            clock.advance(ms: 100)
            probe.record(start: start, kind: .delta, type: "nested", bytes: 500)
            probe.flush()

            let perType = sink.all.dropFirst()
            #expect(perType.first!.contains("type=blob"), "bytes-descending puts blob first")
            let nested = perType.first { $0.contains("type=nested") }
            #expect(nested?.contains("decodems=100.000") == true)
        }
    }

    @Test("on: percentile sampling is capped but counts and totals stay exact")
    func onBranchCapsLatencySamples() {
        withIsolatedDefaults(seed: true) { defaults in
            let sink = Sink()
            let clock = FakeClock()
            let probe = RPCVolumeProbe(
                defaults: defaults, windowSeconds: 1.0, latencySampleCap: 4,
                now: { clock.read() }, emit: { sink.append($0) }
            )
            for _ in 0..<10 {
                let start = probe.startMeasurement()
                clock.advance(ms: 1)
                probe.record(start: start, kind: .delta, type: "reapRecordsChanged", bytes: 10)
            }
            probe.flush()
            let window = sink.all[0]
            #expect(window.contains("msgs=10"))
            #expect(window.contains("bytes=100"))
            #expect(window.contains("decodems=10.000"))
            #expect(window.contains("sampled=4"))
        }
    }

    @Test("on: per-type lines are capped, and the (other) rollup keeps the totals whole")
    func onBranchCapsTypeLines() {
        withIsolatedDefaults(seed: true) { defaults in
            let sink = Sink()
            let clock = FakeClock()
            let probe = RPCVolumeProbe(
                defaults: defaults, windowSeconds: 1.0, now: { clock.read() }, emit: { sink.append($0) }
            )
            // 30 distinct types. Byte size and decode cost are deliberately
            // anti-correlated, so the top-by-bytes and top-by-decode sets are
            // disjoint and the union is exactly 16 types.
            for i in 0..<30 {
                let start = probe.startMeasurement()
                clock.advance(ms: Double(i + 1))
                probe.record(start: start, kind: .delta, type: "t\(i)", bytes: (30 - i) * 1000)
            }
            probe.flush()

            let lines = sink.all
            #expect(lines[0].contains("types=30"))
            // 1 window + 8 + 8 distinct + 1 rollup.
            #expect(lines.count == 18)
            let rollup = lines.last!
            #expect(rollup.hasPrefix("rpc kind=mixed type=(other) "))
            #expect(rollup.contains("n=14"))

            // The per-type lines plus the rollup must still sum to the window.
            func sum(_ key: String) -> Int {
                lines.dropFirst().reduce(0) { total, line in
                    guard let field = line.split(separator: " ").first(where: { $0.hasPrefix(key + "=") }),
                          let value = Int(field.dropFirst(key.count + 1)) else { return total }
                    return total + value
                }
            }
            #expect(sum("n") == 30)
            #expect(sum("bytes") == (1...30).reduce(0) { $0 + $1 * 1000 })
        }
    }

    // MARK: - Naming

    @Test("delta type names are the case name and carry no payload")
    func deltaTypeNames() {
        #expect(StateDelta.reapRecordsChanged.rpcVolumeTypeName == "reapRecordsChanged")
        #expect(StateDelta.modelProfilesChanged.rpcVolumeTypeName == "modelProfilesChanged")
        let delta = StateDelta.worktreeArchived(WorktreeIDDelta(worktreeID: UUID()))
        #expect(delta.rpcVolumeTypeName == "worktreeArchived")
        #expect(!delta.rpcVolumeTypeName.contains("-"), "a UUID must never leak into the label")
    }
}

/// Thread-safe read counter for the "off path takes no clock read" assertion.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func bump() {
        lock.lock(); defer { lock.unlock() }
        count += 1
    }
    var value: Int {
        lock.lock(); defer { lock.unlock() }
        return count
    }
}
