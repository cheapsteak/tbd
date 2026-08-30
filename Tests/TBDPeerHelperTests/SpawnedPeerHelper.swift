import Darwin
import Foundation
import TBDShared

/// One real `TBDPeerHelper` process, spawned the way the daemon spawns it.
///
/// **Everything here goes through the production path on purpose.** The bugs
/// this suite exists to catch — a whole agent frame smuggled into `content`, a
/// shutdown that never unlinks anything — both survive any test that hand-builds
/// the artifacts under inspection. `ShadowPeerManagerTests` already asserts "no
/// `/tmp/`, no `.sock`" on an outbound frame and passes while the leak is live,
/// because the frame it asserts on comes from a fake helper handed
/// `content: "ack"`. So this fixture binds the real socket, publishes the real
/// record, and reads back exactly the bytes the shipped binary wrote.
///
/// `@unchecked Sendable` rather than a lock: exactly one test task ever drives
/// one of these, the fixture never escapes to another, and lock ceremony around
/// state nothing contends for would only obscure that.
final class SpawnedPeerHelper: @unchecked Sendable {
    /// How long any single bounded wait may take before the test gives up.
    ///
    /// A **hang bound**, not an assertion: a healthy helper publishes its
    /// artifacts and exits in milliseconds, so this costs a passing run
    /// nothing. It is sized for the fast parallel pass, where per-test latency
    /// scales with the whole package's test population
    /// (`Tests/CLAUDE.md` § "Population is the scheduler").
    static let waitLimit: TimeInterval = 30
    /// Poll cadence for every bounded wait below.
    static let pollInterval: Duration = .milliseconds(20)

    let handle: String
    /// The fixture's private scratch root, deleted whole on teardown.
    let root: URL
    /// Where the helper binds — never `/tmp/cc-socks`, which every real session
    /// on this machine reads.
    let socketDirectory: URL
    /// Where the helper publishes — never the host Claude store.
    let sessionsDirectory: URL
    let store: ShadowPeerRecordStore

    private let process: Process
    private let stdinHandle: FileHandle
    private let stdoutFD: Int32
    private var stdinClosed = false
    private var pendingStdout = Data()

    // MARK: - Locating the binary

    private final class BundleMarker {}

    /// The built `TBDPeerHelper`, a sibling of the test bundle in the products
    /// directory — the same sibling lookup
    /// `ShadowPeerHelperProcessSpawner.defaultExecutablePath` does from the
    /// daemon. Throws naming every path searched, because an opaque "not found"
    /// here reads as a broken test rather than a missing product.
    static func locateExecutable() throws -> URL {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        var searched: [String] = []
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDPeerHelper")
            searched.append(candidate.path)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw PeerHelperFixtureError.executableNotFound(searched: searched)
    }

    // MARK: - Lifecycle

    /// Spawn a helper against a fresh scratch root.
    ///
    /// The root lives directly under `/tmp` rather than under `$TMPDIR`, for the
    /// reason `scripts/test.sh` gives for its own scratch home: darwin's
    /// `$TMPDIR` is a ~43-character path under `/var/folders`, and a unix
    /// socket's `sun_path` caps at ~104 bytes. `/tmp/tbdph-<8 hex>/s/<pid>.sock`
    /// is ~32 bytes and cannot overflow.
    init(
        handle: String = "h-\(UUID().uuidString.prefix(8))",
        name: String = "acme:test-shadow",
        status: String = "idle",
        peerProtocol: Int = PeerBridgeFrameCodec.peerProtocol,
        sessionID: String = UUID().uuidString
    ) throws {
        self.handle = handle
        let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        root = URL(fileURLWithPath: "/tmp/tbdph-\(suffix)", isDirectory: true)
        socketDirectory = root.appendingPathComponent("s", isDirectory: true)
        sessionsDirectory = root.appendingPathComponent("r", isDirectory: true)
        store = ShadowPeerRecordStore(sessionsDirectory: sessionsDirectory)
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process = Process()
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutFD = stdoutPipe.fileHandleForReading.fileDescriptor
        // Every stored property is set above, and nothing above can throw: a
        // class initializer may not throw while the instance is only partly
        // initialized, so all the fallible work lives below this line.

        do {
            // Only the root is created here. The helper creates its own socket
            // directory (0700), and `ShadowPeerRecordStore.write` creates the
            // registry directory — a fixture that pre-created either would skip
            // a production path. `withIntermediateDirectories: false` so a name
            // collision fails loudly instead of joining somebody else's run.
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: false)

            process.executableURL = try Self.locateExecutable()
            // The same argv `ShadowPeerHelperInvocation.arguments` composes,
            // with `--handle` leading. The two are a contract between targets
            // that share no type, pinned by a test on each side.
            process.arguments = [
                "--handle", handle,
                "--name", name,
                "--status", status,
                "--peer-protocol", String(peerProtocol),
                "--cwd", root.path,
                "--socket-dir", socketDirectory.path,
                "--sessions-dir", sessionsDirectory.path,
                "--session-id", sessionID,
            ]
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice
            try process.run()
        } catch {
            try? FileManager.default.removeItem(at: root)
            throw error
        }

        // Non-blocking, so `nextLine` can poll a pipe that has nothing on it
        // yet without parking the test's thread. Fatal rather than best-effort:
        // a blocking read end would wedge the *test* in exactly the way the
        // helper's own self-pipe used to wedge, and a hang is the one failure
        // that says nothing about what went wrong.
        let flags = fcntl(stdoutFD, F_GETFL)
        guard flags >= 0, fcntl(stdoutFD, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            let code = errno
            tearDown()
            throw PeerHelperFixtureError.nonBlockingFailed(errno: code)
        }
    }

    var pid: pid_t { process.processIdentifier }
    var socketPath: String { socketDirectory.appendingPathComponent("\(pid).sock").path }
    var recordPath: String { store.recordURL(pid: pid).path }
    var isRunning: Bool { process.isRunning }
    /// The exit status, or nil while the helper is still running.
    ///
    /// Optional rather than raw because `Process.terminationStatus` **raises**
    /// when the process has not exited, and the failure this suite exists to
    /// catch is precisely a helper that has not exited. A raise there would
    /// take down the whole test process instead of reddening one test.
    var exitStatus: Int32? { process.isRunning ? nil : process.terminationStatus }

    /// Close the helper's stdin — the load-bearing cleanup signal.
    func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        try? stdinHandle.close()
    }

    /// Kill whatever is left and remove the scratch root. Idempotent.
    func tearDown() {
        closeStdin()
        if process.isRunning {
            kill(pid, SIGKILL)
            process.waitUntilExit()
        }
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Driving it

    /// Write one control frame to the helper's stdin, encoded by the shipped
    /// codec rather than by hand.
    func send(_ frame: PeerBridgeFrame) throws {
        let line = try PeerBridgeFrameCodec.encodeLine(frame)
        try stdinHandle.write(contentsOf: Data(line.utf8))
    }

    /// Connect to the helper's socket, write `payload`, close — Claude Code's
    /// whole local transport.
    func deliverToSocket(_ payload: Data) throws {
        let fd = try connectToSocket()
        defer { Darwin.close(fd) }
        var offset = 0
        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < raw.count {
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                if written > 0 {
                    offset += written
                    continue
                }
                if written < 0 && errno == EINTR { continue }
                throw PeerHelperFixtureError.socketWriteFailed(errno: errno)
            }
        }
    }

    /// Connect and drop without writing — what `ListAgents` does to probe
    /// liveness, and the reason the listener has to exist at all.
    func probeSocket() throws {
        let fd = try connectToSocket()
        Darwin.close(fd)
    }

    private func connectToSocket() throws -> Int32 {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: address.sun_path)
        let path = socketPath
        guard path.utf8.count < sunPathSize else {
            throw PeerHelperFixtureError.socketPathTooLong(path: path, limit: sunPathSize - 1)
        }
        path.withCString { source in
            withUnsafeMutablePointer(to: &address.sun_path) { destination in
                destination.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { chars in
                    _ = strlcpy(chars, source, sunPathSize)
                }
            }
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw PeerHelperFixtureError.socketUnavailable(errno: errno) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, length)
            }
        }
        guard connected == 0 else {
            let code = errno
            Darwin.close(fd)
            throw PeerHelperFixtureError.connectFailed(path: path, errno: code)
        }
        return fd
    }

    // MARK: - Bounded waits

    /// The next complete line the helper wrote on stdout, or nil if none
    /// arrived inside `limit`.
    func nextLine(within limit: TimeInterval = SpawnedPeerHelper.waitLimit) async -> String? {
        await poll(within: limit) { () -> String? in self.takeBufferedLine() }
    }

    /// Anything the helper said during `window`, or nil if it stayed silent —
    /// the liveness-probe case, where saying anything at all is the bug.
    func lineEmitted(during window: TimeInterval) async -> String? {
        let deadline = Date().addingTimeInterval(window)
        while Date() < deadline {
            if let line = takeBufferedLine() { return line }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return takeBufferedLine()
    }

    private func takeBufferedLine() -> String? {
        drainStdout()
        guard let newline = pendingStdout.firstIndex(of: 0x0A) else { return nil }
        let lineData = pendingStdout[pendingStdout.startIndex..<newline]
        pendingStdout = Data(pendingStdout[pendingStdout.index(after: newline)...])
        return String(data: lineData, encoding: .utf8)
    }

    private func drainStdout() {
        var chunk = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = Darwin.read(stdoutFD, &chunk, chunk.count)
            if count > 0 {
                pendingStdout.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0 && errno == EINTR { continue }
            return
        }
    }

    /// Wait for the helper to exit. False means it was still running at the
    /// deadline — which is precisely the wedge a blocking self-pipe read
    /// produces on the signal path.
    func waitForExit(within limit: TimeInterval = SpawnedPeerHelper.waitLimit) async -> Bool {
        let exited: Bool? = await poll(within: limit) { () -> Bool? in
            self.process.isRunning ? nil : true
        }
        return exited ?? false
    }

    /// Wait for the socket and the record to both exist — the two-artifact
    /// membership test `docs/cross-session-messaging.md` defines for a peer.
    func waitForPublication(
        within limit: TimeInterval = SpawnedPeerHelper.waitLimit
    ) async -> Bool {
        let published: Bool? = await poll(within: limit) { () -> Bool? in
            (self.socketExists && self.recordExists) ? true : nil
        }
        return published ?? false
    }

    /// Wait for both artifacts to be gone.
    func waitForReclamation(
        within limit: TimeInterval = SpawnedPeerHelper.waitLimit
    ) async -> Bool {
        let reclaimed: Bool? = await poll(within: limit) { () -> Bool? in
            (!self.socketExists && !self.recordExists) ? true : nil
        }
        return reclaimed ?? false
    }

    /// Wait for the published record to satisfy `predicate`.
    func waitForRecord(
        within limit: TimeInterval = SpawnedPeerHelper.waitLimit,
        matching predicate: (ShadowPeerRecord) -> Bool
    ) async -> ShadowPeerRecord? {
        await poll(within: limit) { () -> ShadowPeerRecord? in
            guard let record = try? self.store.read(pid: self.pid) else { return nil }
            return predicate(record) ? record : nil
        }
    }

    var socketExists: Bool { FileManager.default.fileExists(atPath: socketPath) }
    var recordExists: Bool { FileManager.default.fileExists(atPath: recordPath) }

    /// The record's key set, read as raw JSON rather than through
    /// `ShadowPeerRecord` — a typed decode cannot see a key the type does not
    /// define, and an undefined key is exactly what makes a record invisible to
    /// every listing while surviving on disk.
    func recordKeys() throws -> Set<String> {
        let data = try Data(contentsOf: store.recordURL(pid: pid))
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw PeerHelperFixtureError.recordNotAnObject(path: recordPath)
        }
        return Set(object.keys)
    }

    private func poll<T>(
        within limit: TimeInterval, until produce: () -> T?
    ) async -> T? {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            if let value = produce() { return value }
            if Date() >= deadline { return produce() }
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
}

enum PeerHelperFixtureError: Error, CustomStringConvertible {
    case executableNotFound(searched: [String])
    case socketPathTooLong(path: String, limit: Int)
    case socketUnavailable(errno: Int32)
    case connectFailed(path: String, errno: Int32)
    case socketWriteFailed(errno: Int32)
    case nonBlockingFailed(errno: Int32)
    case recordNotAnObject(path: String)

    var description: String {
        switch self {
        case .executableNotFound(let searched):
            return "TBDPeerHelper was not in the products directory; searched "
                + searched.joined(separator: ", ")
        case .socketPathTooLong(let path, let limit):
            return "\(path) is longer than sun_path allows (\(limit) bytes)"
        case .socketUnavailable(let code):
            return "could not create a socket: \(String(cString: strerror(code)))"
        case .connectFailed(let path, let code):
            return "could not connect to \(path): \(String(cString: strerror(code)))"
        case .socketWriteFailed(let code):
            return "could not write to the helper's socket: \(String(cString: strerror(code)))"
        case .nonBlockingFailed(let code):
            return "could not make the helper's stdout non-blocking: "
                + "\(String(cString: strerror(code)))"
        case .recordNotAnObject(let path):
            return "the record at \(path) is not a JSON object"
        }
    }
}

// MARK: - Claude Code's own frame, as captured

/// One agent message frame in the shape a real `SendMessage` produces.
///
/// Transcribed from the verbatim capture in
/// `docs/research/2026-08-29-cross-machine-messaging/findings.md` § "Transport
/// is one JSON line per message" (**T1** — observed, not inferred), including
/// the detail the leak turns on: the sender's `uds:` socket path appears at top
/// level *and* again inside the `<cross-session-message …>` wrapper, together
/// with the name and permission class the sender claims for itself.
///
/// This is the one thing the suite hand-builds, and deliberately: it is written
/// by Claude Code, not by any code under test here. Nothing produced by TBD is
/// hand-built anywhere in these tests.
enum CapturedAgentFrame {
    /// A real socket path, embedding a real pid, exactly as captured.
    static let senderSocketPath = "/tmp/cc-socks/46403.sock"
    static let senderAddress = "uds:\(senderSocketPath)"
    static let senderName = "Agentbox Init Research"
    /// The sender's self-claimed permission class. TBD grants `default`; a
    /// sender naming its own class is the thing attribution-stamping exists to
    /// stop, so this value must not survive the hop.
    static let senderMode = "bypass"

    /// The wrapper the sender's own client composes, around `body`.
    static func wrapped(_ body: String) -> String {
        "<cross-session-message from=\"\(senderAddress)\" from-name=\"\(senderName)\""
            + " from-mode=\"\(senderMode)\">\n\(body)\n</cross-session-message>"
    }

    /// The whole frame, as it arrives on the socket: `body` inside the sender's
    /// own wrapper.
    static func payload(body: String, messageID: String = UUID().uuidString) -> Data {
        payload(rawContent: wrapped(body), messageID: messageID)
    }

    /// The whole frame with `message.content` set verbatim — for the cases where
    /// the content is *not* a well-formed wrapper.
    static func payload(rawContent: String, messageID: String = UUID().uuidString) -> Data {
        let frame: [String: Any] = [
            "msgV": 1,
            "msg_id": messageID,
            "type": "user",
            "priority": "next",
            "from": senderAddress,
            "message": ["role": "user", "content": rawContent],
        ]
        // `.withoutEscapingSlashes` so the captured path lands in the bytes as
        // `/tmp/cc-socks/…` — an escaped `\/tmp\/` would make the leak
        // assertions below pass for the wrong reason.
        return try! JSONSerialization.data(
            withJSONObject: frame, options: [.withoutEscapingSlashes])
    }
}
