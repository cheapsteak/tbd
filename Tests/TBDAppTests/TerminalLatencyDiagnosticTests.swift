import Foundation
import TBDShared
import Testing

@testable import TBDApp

/// Tests for `TerminalLatencyDiagnostic` — the gate, the panel registry, and
/// the request handling that decides whether a probe ever types into a
/// terminal.
///
/// Isolation matters: TBDApp ships as an unbundled SPM executable, so its
/// `UserDefaults.standard` domain is `TBDApp.plist` in the developer's home —
/// the same domain a running production TBDApp reads. Every test below drives
/// the gate through a per-test `UserDefaults(suiteName:)` and tears the domain
/// down afterwards, so `.standard` is never touched. Nothing here calls
/// `startWatching()`: the request-file tests drive `consumeRequestFiles()`
/// against a directory of their own under `NSTemporaryDirectory()`, so no
/// dispatch source is armed and TBD's real runtime directory is never read.
@MainActor
@Suite("Terminal latency diagnostic")
struct TerminalLatencyDiagnosticTests {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [String] = []

        func append(_ line: String) {
            lock.lock()
            storage.append(line)
            lock.unlock()
        }

        var all: [String] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
    }

    private func withDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let suiteName = "TBDAppTests.TerminalLatency.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        try body(defaults)
    }

    private func request(terminalID: UUID, seq: UInt64) -> Data {
        Data(#"{"terminalID": "\#(terminalID.uuidString)", "seq": \#(seq)}"#.utf8)
    }

    // MARK: - The gate

    @Test("the gate is off when nobody has set the key, and `make` returns nil")
    func gateDefaultsOff() {
        withDefaults { defaults in
            #expect(AppState.terminalLatencyDiagnosticEnabled(defaults: defaults) == false)
            #expect(TerminalLatencyDiagnostic.make(defaults: defaults) == nil)
        }
    }

    @Test("with the key on, `make` builds a diagnostic")
    func gateOnBuildsTheDiagnostic() {
        withDefaults { defaults in
            defaults.set(true, forKey: AppState.enableTerminalLatencyDiagnosticKey)
            #expect(AppState.terminalLatencyDiagnosticEnabled(defaults: defaults))
            #expect(TerminalLatencyDiagnostic.make(defaults: defaults) != nil)
        }
    }

    @Test("an explicit false is honoured, not merely the absence of the key")
    func gateExplicitFalseIsOff() {
        withDefaults { defaults in
            defaults.set(false, forKey: AppState.enableTerminalLatencyDiagnosticKey)
            #expect(TerminalLatencyDiagnostic.make(defaults: defaults) == nil)
        }
    }

    // MARK: - Requests

    @Test("a request naming a terminal no panel claims is refused as unknown")
    func unknownTerminalIsRefused() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let id = UUID()
        diagnostic.handleRequest(request(terminalID: id, seq: 1))
        #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=unknownterminal"])
    }

    @Test("a request naming an agent terminal is refused — this path types into sessions")
    func agentTerminalIsRefused() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let id = UUID()
        let invoked = Lines()
        _ = diagnostic.register(terminalID: id, kind: { .claude }) { seq in
            invoked.append("\(seq)")
            return nil
        }
        diagnostic.handleRequest(request(terminalID: id, seq: 3))
        #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=notshell"])
        #expect(invoked.all.isEmpty)
    }

    @Test("a terminal whose kind the app has not loaded is refused, not assumed a shell")
    func unknownKindIsRefused() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let id = UUID()
        _ = diagnostic.register(terminalID: id, kind: { nil }) { _ in nil }
        diagnostic.handleRequest(request(terminalID: id, seq: 3))
        #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=notshell"])
    }

    @Test("an undecodable request is refused with no terminal to name")
    func malformedRequestIsRefused() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        diagnostic.handleRequest(Data("not json".utf8))
        #expect(lines.all == ["echorefused terminal=- reason=malformed"])
    }

    @Test("a panel that cannot write right now is refused with noview")
    func probeWithNoViewIsRefused() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let id = UUID()
        _ = diagnostic.register(terminalID: id, kind: { .shell }) { _ in "noview" }
        diagnostic.handleRequest(request(terminalID: id, seq: 5))
        #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=noview"])
    }

    @Test("a registered shell terminal's probe runs with the request's sequence number")
    func shellTerminalProbeRuns() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let id = UUID()
        let invoked = Lines()
        _ = diagnostic.register(terminalID: id, kind: { .shell }) { seq in
            invoked.append("\(seq)")
            return nil
        }
        diagnostic.handleRequest(request(terminalID: id, seq: 42))
        #expect(invoked.all == ["42"])
        #expect(lines.all.isEmpty)
    }

    @Test("a panel that would swallow the write refuses with its own reason, not noview")
    func probeRefusalReasonIsReportedVerbatim() {
        for reason in ["ingestingsnapshot", "handbackinflight"] {
            let lines = Lines()
            let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
            let id = UUID()
            _ = diagnostic.register(terminalID: id, kind: { .shell }) { _ in reason }
            diagnostic.handleRequest(request(terminalID: id, seq: 8))
            #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=\(reason)"])
        }
    }

    @Test("the kind is asked for at request time, so a row loaded later is honoured")
    func kindIsResolvedPerRequest() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let id = UUID()
        let invoked = Lines()
        // A panel registers as soon as it has a view; AppState may not carry
        // its row yet. The box is that row arriving afterwards.
        let kind = KindBox()
        _ = diagnostic.register(terminalID: id, kind: { kind.value }) { seq in
            invoked.append("\(seq)")
            return nil
        }

        diagnostic.handleRequest(request(terminalID: id, seq: 1))
        #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=notshell"])
        #expect(invoked.all.isEmpty)

        kind.value = .shell
        diagnostic.handleRequest(request(terminalID: id, seq: 2))
        #expect(lines.all.count == 1)
        #expect(invoked.all == ["2"])
    }

    /// A terminal kind the app learns after the panel registered.
    @MainActor
    private final class KindBox {
        var value: TerminalKind?
    }

    // MARK: - The request files

    /// One directory event can stand for several renames, so a turn that finds
    /// two request files has to answer BOTH, in the order they were issued.
    ///
    /// The files are created newest-first so the directory's own enumeration
    /// order cannot be mistaken for request order, and the assertion is on the
    /// sequence numbers the probe saw: a consumer that reads one file per event
    /// answers `["2"]`, and one that trusts the enumeration answers `["2", "1"]`.
    @Test("two request files waiting at once are both consumed, in name order")
    func requestFilesAreConsumedInNameOrder() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TBDAppTests.TerminalLatency.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(
            now: { 0 }, runtimeDirectory: directory, emit: { lines.append($0) })
        let id = UUID()
        let seen = Lines()
        _ = diagnostic.register(terminalID: id, kind: { .shell }) { seq in
            seen.append("\(seq)")
            return nil
        }

        for seq in [2, 1] {
            let name = "\(TerminalLatencyDiagnostic.requestFilePrefix)"
                + String(format: "%06d", seq)
                + TerminalLatencyDiagnostic.requestFileSuffix
            try request(terminalID: id, seq: UInt64(seq))
                .write(to: directory.appendingPathComponent(name))
        }
        // A file the instrument does not own. The runtime directory is shared
        // — `claude-overlay.json` lives there — so a consumer that swept it
        // would eat somebody else's state.
        let foreign = directory.appendingPathComponent("claude-overlay.json")
        try Data("{}".utf8).write(to: foreign)

        diagnostic.consumeRequestFiles()

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(seen.all == ["1", "2"])
        #expect(lines.all.isEmpty)
        #expect(
            remaining == ["claude-overlay.json"],
            "every request file is removed as it is handled, and nothing else is touched")
    }

    @Test("a consumed request file is removed before its probe runs, so no event replays it")
    func requestFileIsRemovedBeforeHandling() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TBDAppTests.TerminalLatency.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let diagnostic = TerminalLatencyDiagnostic(
            now: { 0 }, runtimeDirectory: directory, emit: { _ in })
        let id = UUID()
        let remainingDuringProbe = Lines()
        _ = diagnostic.register(terminalID: id, kind: { .shell }) { _ in
            let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            remainingDuringProbe.append(names.joined(separator: ","))
            return nil
        }

        let name = TerminalLatencyDiagnostic.requestFilePrefix + "000001"
            + TerminalLatencyDiagnostic.requestFileSuffix
        try request(terminalID: id, seq: 1).write(to: directory.appendingPathComponent(name))

        diagnostic.consumeRequestFiles()

        #expect(remainingDuringProbe.all == [""])
    }

    // MARK: - The registry

    @Test("unregistering a superseded claim leaves the live one in place")
    func supersededUnregisterIsANoOp() {
        let diagnostic = TerminalLatencyDiagnostic(now: { 0 }, emit: { _ in })
        let id = UUID()
        let stale = diagnostic.register(terminalID: id, kind: { .shell }) { _ in "noview" }
        _ = diagnostic.register(terminalID: id, kind: { .shell }) { _ in nil }
        diagnostic.unregister(stale)
        #expect(diagnostic.registrationCount == 1)

        let lines = Lines()
        let live = TerminalLatencyDiagnostic(now: { 0 }, emit: { lines.append($0) })
        let registration = live.register(terminalID: id, kind: { .shell }) { _ in nil }
        live.unregister(registration)
        #expect(live.registrationCount == 0)
        live.handleRequest(request(terminalID: id, seq: 1))
        #expect(lines.all == ["echorefused terminal=\(id.uuidString) reason=unknownterminal"])
    }

    @Test("a tap made by the diagnostic emits through the diagnostic's own sink and clock")
    func tapsInheritTheDiagnosticsSeams() {
        let lines = Lines()
        let diagnostic = TerminalLatencyDiagnostic(now: { 1.5 }, emit: { lines.append($0) })
        let id = UUID(uuidString: "0a0a0a0a-0b0b-0c0c-0d0d-0e0e0e0e0e0e")!
        let tap = diagnostic.makeTap(terminalID: id, transport: .holder)
        #expect(tap.now() == 1.5)
        tap.noteChunk(Array("x".utf8)[...], feedAt: 1.0, feedReturnedAt: 1.002)
        tap.noteDrawWillBegin(at: 1.5, isOnScreen: true)
        #expect(
            lines.all == [
                "draw transport=holder terminal=0A0A0A0A-0B0B-0C0C-0D0D-0E0E0E0E0E0E"
                    + " chunks=1 oldestms=500.000 newestms=500.000 parsemaxms=2.000"
                    + " dropped=0 vis=1"
            ])
    }
}
