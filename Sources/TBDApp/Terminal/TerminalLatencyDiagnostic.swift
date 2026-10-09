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
/// ## A request is a file, and each request is its own file
///
/// The driver writes `~/tbd/runtime/terminal-latency-probe.<NNNNNN>.json`,
/// one file per request, naming a terminal id and a sequence number; this
/// object watches the runtime directory with a dispatch source while the
/// diagnostic is on, enumerates the request files in name order, and for each
/// one reads it, deletes it, and asks the named panel to write one token. The
/// precedent is the runtime directory's other app-read file,
/// `claude-overlay.json`. A daemon RPC was rejected: three times the plumbing
/// to deliver two fields, and it would put the daemon's RPC latency on the
/// path before the app stamps the start.
///
/// The counter in the name is what makes a request survive its neighbours. A
/// single fixed path loses requests two ways: two directory events landing
/// between one pair of main-queue turns leave only the second rename's
/// content behind, and a driver that deletes the path on its way out can
/// delete a request the main thread has not read yet. Distinct names remove
/// both — nothing overwrites anything, and the driver's cleanup only ever
/// removes what is genuinely left over.
///
/// ## Refusals, because this writes input into a session
///
/// The probe types into a terminal. It therefore refuses anything that is not
/// a plain shell, and says why:
///
///     echorefused terminal=<uuid> reason=unknownterminal    no panel registered
///     echorefused terminal=<uuid> reason=notshell           an agent, or kind unknown
///     echorefused terminal=<uuid> reason=noview             no view, or a cleared holder
///     echorefused terminal=<uuid> reason=ingestingsnapshot  a snapshot preamble is in flight
///     echorefused terminal=<uuid> reason=handbackinflight   the panel is collecting mode replies
///     echorefused terminal=<uuid> reason=unwritable         the bytes reached no transport
///     echorefused terminal=- reason=malformed               unreadable, or did not decode
///
/// A terminal whose kind the app has not loaded counts as not-a-shell: the
/// refusal must fail closed, because the cost of being wrong is keystrokes in
/// somebody's agent session.
///
/// The middle four come from the panel, not from here: a write that the
/// panel's own outbound path would have swallowed must be a refusal rather
/// than a silent lost token, because a token the transport never saw is not a
/// measurement of the transport. `unwritable` is the one of those the panel
/// can only know afterwards — the queue reports it when the bytes reached no
/// transport at all — so the probe retires its own pending token before
/// refusing, and no `echolost` line is emitted for a token nothing was given.
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

    /// What every request file the driver renames into the runtime directory
    /// is named between: `terminal-latency-probe.000001.json`. The driver's
    /// counter is zero-padded so name order is request order.
    static let requestFilePrefix = "terminal-latency-probe."
    static let requestFileSuffix = ".json"

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

    /// Watch the runtime directory for request files. Only `shared` calls
    /// this in production; a diagnostic built by `make(defaults:)` in a test
    /// drives `handleRequest` or `consumeRequestFiles` directly, or watches a
    /// directory of its own and stops with `stopWatching()`.
    ///
    /// The directory is drained once, immediately, before any event can
    /// arrive: a dispatch source reports only writes that happen after it is
    /// resumed, so a request already sitting there — a driver SIGKILLed
    /// mid-run, or a run made while the diagnostic was off — would otherwise
    /// wait for the next unrelated write to the runtime directory and be
    /// answered then, typing a stale token into a terminal minutes or hours
    /// late. Draining at start answers it now, or refuses it now, and either
    /// way the file is gone.
    func startWatching() {
        guard watchSource == nil else { return }
        try? FileManager.default.createDirectory(
            at: runtimeDirectory, withIntermediateDirectories: true)
        let descriptor = open(runtimeDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else {
            // Captured on the line after the failing call, before anything
            // else can run: `errno` is thread-local but call-order sensitive,
            // and read inside a string interpolation it is whatever the last
            // evaluated subexpression left behind.
            let err = errno
            Self.logger.error(
                "could not watch \(self.runtimeDirectory.path, privacy: .public) for latency probe requests (errno \(err, privacy: .public))"
            )
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.consumeRequestFiles() }
        }
        source.setCancelHandler { close(descriptor) }
        watchSource = source
        source.resume()
        consumeRequestFiles()
    }

    /// Stop watching and close the descriptor. Nothing in the app calls this —
    /// the process-wide diagnostic watches for the app's whole life — but a
    /// test that exercises `startWatching()` against a temp directory needs
    /// the source cancelled and the file descriptor closed when it is done.
    func stopWatching() {
        watchSource?.cancel()
        watchSource = nil
    }

    /// Read every request file waiting in the directory, oldest first, remove
    /// each one, and act on it.
    ///
    /// **In name order**, which is request order, because one directory event
    /// can stand for several renames: the source coalesces, so a turn that
    /// finds two files must answer both, and must answer them in the order the
    /// driver issued them or the sequence numbers in the log stop matching the
    /// loads recorded against them.
    ///
    /// Each file's removal comes before its handling, so a probe that throws
    /// or a panel that blocks cannot leave a stale request to be replayed by
    /// the next directory event. That holds for a file this cannot even read:
    /// it is removed first and then refused as `malformed`, because a file
    /// left behind on the unreadable path would be re-enumerated by every
    /// subsequent event for as long as the app ran.
    func consumeRequestFiles() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: runtimeDirectory.path))
            ?? []
        for name in names.filter({
            $0.hasPrefix(Self.requestFilePrefix) && $0.hasSuffix(Self.requestFileSuffix)
        }).sorted() {
            let url = runtimeDirectory.appendingPathComponent(name)
            let data = readRequestFile(at: url)
            try? FileManager.default.removeItem(at: url)
            guard let data else {
                // Unreadable, not merely undecodable — a truncated rename, a
                // permission, a name that is not a file at all. It still has to
                // leave the directory, or every later directory event finds it
                // again and refuses it again.
                refuse(terminal: "-", reason: "malformed")
                continue
            }
            handleRequest(data)
        }
    }

    /// The most a request file may be. A request is two fields; 4 KiB is room
    /// for any of them and for none of what a runtime directory might
    /// otherwise be holding.
    static let maxRequestBytes = 4096

    /// Read one request file, refusing anything that is not a small regular
    /// file, on this thread, with no allocation the file's own size controls.
    ///
    /// The runtime directory is shared and world-writable in practice, and
    /// this runs on the main actor. `Data(contentsOf:)` there is two hazards
    /// at once: a FIFO or a device node carrying a matching name blocks the
    /// main thread until something writes to it, and an ordinary file of any
    /// size allocates that size. So the descriptor is opened
    /// `O_NOFOLLOW | O_NONBLOCK` — a symlink is refused outright rather than
    /// followed out of the directory, and a FIFO opens instead of blocking —
    /// the mode is checked to be a regular file, the size is capped, and the
    /// read is bounded. Anything that fails returns nil, and the caller
    /// removes the entry and refuses it as `malformed`.
    private func readRequestFile(at url: URL) -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0,
            (info.st_mode & S_IFMT) == S_IFREG,
            info.st_size > 0,
            info.st_size <= Self.maxRequestBytes
        else { return nil }
        var buffer = [UInt8](repeating: 0, count: Self.maxRequestBytes)
        let count = buffer.withUnsafeMutableBytes { raw in
            read(descriptor, raw.baseAddress, raw.count)
        }
        guard count > 0 else { return nil }
        return Data(buffer[0..<count])
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
