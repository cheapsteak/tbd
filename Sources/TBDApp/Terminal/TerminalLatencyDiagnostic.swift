import Foundation
import TBDShared
import os

/// The process-wide half of the terminal transport latency instrument: the
/// gate, the tap factory, the panel registry, and the request file the driver
/// script writes.
///
/// See `docs/specs/2026-09-22-terminal-transport-latency-instrument-design.md`.
/// `TerminalLatencyTap` is the per-panel half and carries the line formats.
///
/// ## A request is a file
///
/// The driver writes `~/tbd/runtime/terminal-latency-probe.json` naming a
/// terminal id and a sequence number; this object watches the runtime
/// directory with a dispatch source while the diagnostic is on, reads the
/// file, deletes it, and asks the named panel to write one token. The
/// precedent is the runtime directory's other app-read file,
/// `claude-overlay.json`. A daemon RPC was rejected: three times the plumbing
/// to deliver two fields, and it would put the daemon's RPC latency on the
/// path before the app stamps the start.
///
/// ## Refusals, because this writes input into a session
///
/// The probe types into a terminal. It therefore refuses anything that is not
/// a plain shell, and says why:
///
///     echorefused terminal=<uuid> reason=unknownterminal    no panel registered
///     echorefused terminal=<uuid> reason=notshell           an agent, or kind unknown
///     echorefused terminal=<uuid> reason=noview             the panel has no view
///     echorefused terminal=<uuid> reason=ingestingsnapshot  a snapshot preamble is in flight
///     echorefused terminal=<uuid> reason=handbackinflight   the panel is collecting mode replies
///     echorefused terminal=- reason=malformed               the request did not decode
///
/// A terminal whose kind the app has not loaded counts as not-a-shell: the
/// refusal must fail closed, because the cost of being wrong is keystrokes in
/// somebody's agent session.
///
/// The last three come from the panel, not from here: a write that the panel's
/// own outbound path would have swallowed must be a refusal rather than a
/// silent lost token, because a token the transport never saw is not a
/// measurement of the transport.
@MainActor
final class TerminalLatencyDiagnostic {
    /// Writes one token into the panel's real keystroke path and arms its tap.
    /// Returns `nil` when the token went out, or the reason it did not — the
    /// panel is still registered, it just cannot answer right now.
    typealias Probe = @MainActor (UInt64) -> String?

    /// A panel's terminal kind, asked for at REQUEST time rather than snapshot
    /// at registration: a panel registers as soon as it has a view, which can
    /// be before `AppState.terminals` carries its row, and a kind snapshotted
    /// as nil then would refuse every request for that panel's whole life.
    typealias KindResolver = @MainActor () -> TerminalKind?

    /// Where a finished line goes. Injected so tests can capture without a
    /// log-store round trip.
    typealias Emit = @Sendable (String) -> Void

    nonisolated static let logger = Logger(subsystem: "com.tbd.app", category: "terminallatency")

    /// The file the driver renames into the runtime directory, one request at
    /// a time.
    static let requestFileName = "terminal-latency-probe.json"

    /// A panel's claim on one terminal's probe requests. Opaque, and the only
    /// thing that can withdraw the claim — same shape and the same
    /// superseded-registration rule as `TerminalInjectionRouter.Registration`,
    /// so a torn-down coordinator cannot remove the entry its successor for
    /// the same terminal already installed.
    struct Registration: Equatable, Sendable {
        let terminalID: UUID
        fileprivate let token: UUID
    }

    private struct Entry {
        let token: UUID
        /// Answers with the terminal's kind as the app knows it *now*, or nil
        /// when AppState has not loaded the row. Nil is refused, not assumed.
        let kind: KindResolver
        let probe: Probe
    }

    private struct Request: Decodable {
        let terminalID: UUID
        let seq: UInt64
    }

    private var entries: [UUID: Entry] = [:]

    /// Monotonic seconds, shared with every tap this object makes so the two
    /// ends of an echo come off one source.
    let now: @Sendable () -> Double
    private let emit: Emit
    let runtimeDirectory: URL

    private var watchSource: DispatchSourceFileSystemObject?

    init(
        now: @escaping @Sendable () -> Double = { ProcessInfo.processInfo.systemUptime },
        runtimeDirectory: URL = TBDConstants.runtimeDir,
        emit: @escaping Emit = { line in
            TerminalLatencyDiagnostic.logger.info("\(line, privacy: .public)")
        }
    ) {
        self.now = now
        self.runtimeDirectory = runtimeDirectory
        self.emit = emit
    }

    // MARK: - Taps

    func makeTap(terminalID: UUID, transport: TerminalTransport) -> TerminalLatencyTap {
        TerminalLatencyTap(
            terminalID: terminalID, transport: transport, now: now, emit: emit)
    }

    // MARK: - The panel registry

    /// Test-facing: how many panels currently claim a terminal.
    var registrationCount: Int { entries.count }

    func register(
        terminalID: UUID, kind: @escaping KindResolver, probe: @escaping Probe
    ) -> Registration {
        let token = UUID()
        entries[terminalID] = Entry(token: token, kind: kind, probe: probe)
        return Registration(terminalID: terminalID, token: token)
    }

    /// Withdraw a claim. A no-op when a newer registration for the same
    /// terminal has replaced this one.
    func unregister(_ registration: Registration) {
        guard entries[registration.terminalID]?.token == registration.token else { return }
        entries.removeValue(forKey: registration.terminalID)
    }

    // MARK: - Requests

    /// Decode one request and write its token, or say why not.
    func handleRequest(_ data: Data) {
        guard let request = try? JSONDecoder().decode(Request.self, from: data) else {
            refuse(terminal: "-", reason: "malformed")
            return
        }
        guard let entry = entries[request.terminalID] else {
            refuse(terminal: request.terminalID.uuidString, reason: "unknownterminal")
            return
        }
        guard entry.kind() == .shell else {
            refuse(terminal: request.terminalID.uuidString, reason: "notshell")
            return
        }
        if let reason = entry.probe(request.seq) {
            refuse(terminal: request.terminalID.uuidString, reason: reason)
        }
    }

    private func refuse(terminal: String, reason: String) {
        emit("echorefused terminal=\(terminal) reason=\(reason)")
    }

    // MARK: - The directory watch

    /// Watch the runtime directory for the request file. Only `shared` calls
    /// this; a diagnostic built by `make(defaults:)` in a test drives
    /// `handleRequest` directly and touches no filesystem.
    func startWatching() {
        guard watchSource == nil else { return }
        try? FileManager.default.createDirectory(
            at: runtimeDirectory, withIntermediateDirectories: true)
        let descriptor = open(runtimeDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Self.logger.error(
                "could not watch \(self.runtimeDirectory.path, privacy: .public) for latency probe requests (errno \(errno, privacy: .public))"
            )
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.consumeRequestFile() }
        }
        source.setCancelHandler { close(descriptor) }
        watchSource = source
        source.resume()
    }

    /// Read the request file if it is there, remove it, and act on it. Removal
    /// comes before handling so a probe that throws or a panel that blocks
    /// cannot leave a stale request to be replayed by the next directory
    /// event.
    private func consumeRequestFile() {
        let url = runtimeDirectory.appendingPathComponent(Self.requestFileName)
        guard let data = try? Data(contentsOf: url) else { return }
        try? FileManager.default.removeItem(at: url)
        handleRequest(data)
    }

    // MARK: - Gate

    private static var didResolveShared = false
    private static var sharedStorage: TerminalLatencyDiagnostic?

    /// The process-wide diagnostic, or `nil` when it is off — which is the
    /// default. `nil` is the whole gate: no tap is created, the feed seam does
    /// one nil-check, the view does one nil-check, and no directory is
    /// watched.
    ///
    /// Resolved once, from `applicationDidFinishLaunching`, so the request
    /// directory is watched before any panel exists; the first panel to ask
    /// resolves it instead if that startup call ever goes away. Flipping the
    /// key takes effect on the next launch; a measurement session starts with
    /// a relaunch anyway.
    static var shared: TerminalLatencyDiagnostic? {
        if !didResolveShared {
            didResolveShared = true
            sharedStorage = make(defaults: .standard)
            sharedStorage?.startWatching()
        }
        return sharedStorage
    }

    /// Builds a diagnostic if the flag in `defaults` is on, `nil` otherwise.
    /// The injectable half of `shared`, so both branches of the gate are
    /// testable without touching `UserDefaults.standard` — which on this
    /// unbundled executable is the developer's live `TBDApp.plist`.
    static func make(defaults: UserDefaults) -> TerminalLatencyDiagnostic? {
        guard AppState.terminalLatencyDiagnosticEnabled(defaults: defaults) else { return nil }
        return TerminalLatencyDiagnostic()
    }
}
