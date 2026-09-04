import Darwin
import Foundation
import Testing
@testable import TBDHolder
@testable import TBDShared

/// The parts of the holder that need no process: the command line, the wire
/// framing, the exit-status decode, and the one delay that carries the clock
/// seam.
@Suite("Holder invocation")
struct HolderInvocationTests {
    private static let launch = HolderLaunchRequest(
        executable: "/bin/zsh",
        arguments: ["-l"],
        workingDirectory: "/tmp",
        environment: ["TERM": "xterm-256color"],
        columns: 120,
        rows: 40)

    /// A descriptor holding `bytes`, closed on the writing side so a reader
    /// sees end of file — the shape `HolderSpawner` hands the holder. Returned
    /// open; `HolderArguments.parse` closes it as it consumes it.
    private static func descriptor(holding bytes: Data) throws -> Int32 {
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0, "could not make a payload pipe")
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(ends[1], raw.baseAddress?.advanced(by: offset), raw.count - offset)
                guard written > 0 else { break }
                offset += written
            }
        }
        close(ends[1])
        return ends[0]
    }

    /// The launch request travels on a descriptor, never on argv: argv is
    /// readable with `ps` by anything running as the same user, and the request
    /// carries the session's whole environment.
    private static func commandLine(
        session: UUID,
        lockFD: String = "9",
        launchFD: String? = nil,
        payload: Data? = nil,
        owner: String? = "installation-abc"
    ) throws -> [String] {
        let resolvedFD: String
        if let launchFD {
            resolvedFD = launchFD
        } else {
            resolvedFD = String(try descriptor(holding: payload ?? JSONEncoder().encode(launch)))
        }
        var arguments = [
            "--session", session.uuidString,
            "--socket", "/tmp/holders/session.sock",
            "--lock-fd", lockFD,
            "--launch-fd", resolvedFD,
        ]
        if let owner { arguments += ["--owner", owner] }
        return arguments
    }

    @Test func parsesAFullInvocation() throws {
        let session = UUID()
        let parsed = try HolderArguments.parse(try Self.commandLine(session: session))
        #expect(parsed.sessionID == session)
        #expect(parsed.socketPath == "/tmp/holders/session.sock")
        #expect(parsed.lockFD == 9)
        #expect(parsed.launch == Self.launch)
        #expect(parsed.owner == HolderOwnerToken(rawValue: "installation-abc"))
    }

    /// The lock is a DESCRIPTOR NUMBER, never a path. A holder that took a path
    /// could not name the descriptor it inherited, and therefore could not keep
    /// it out of the job — the one thing about the lock that must not happen.
    @Test func refusesALockPathWhereADescriptorBelongs() throws {
        let arguments = try Self.commandLine(session: UUID(), lockFD: "/tmp/holders/session.lock")
        #expect(throws: HolderStartupError.invalidLockDescriptorArgument("/tmp/holders/session.lock")) {
            _ = try HolderArguments.parse(arguments)
        }
    }

    /// A holder started by hand for diagnosis has no installation behind it.
    @Test func ownerIsOptional() throws {
        let parsed = try HolderArguments.parse(try Self.commandLine(session: UUID(), owner: nil))
        #expect(parsed.owner == HolderOwnerToken(rawValue: ""))
    }

    /// A long-lived session keeps running the holder binary it was born with,
    /// so a newer daemon will eventually pass a flag an older holder never
    /// heard of. That must not be the difference between a session starting and
    /// not; a bare word with no leading `--` still is, because that is a
    /// quoting mistake rather than version skew.
    @Test func toleratesAnUnrecognisedFlagButNotABareWord() throws {
        let session = UUID()
        var arguments = try Self.commandLine(session: session)
        arguments += ["--future-flag", "whatever"]
        #expect(try HolderArguments.parse(arguments).sessionID == session)

        #expect(throws: HolderStartupError.unknownArgument("stray")) {
            _ = try HolderArguments.parse(try Self.commandLine(session: session) + ["stray"])
        }
    }

    @Test func refusesAnIncompleteInvocation() throws {
        #expect(throws: HolderStartupError.missingArgument("session")) {
            _ = try HolderArguments.parse(["--socket", "/tmp/x.sock"])
        }
        #expect(throws: HolderStartupError.missingValue("--socket")) {
            _ = try HolderArguments.parse(["--socket"])
        }
        #expect(throws: HolderStartupError.invalidLaunchPayload) {
            _ = try HolderArguments.parse(try Self.commandLine(
                session: UUID(), payload: Data("not-json".utf8)))
        }
    }

    // MARK: - The launch descriptor

    /// The launch request is a DESCRIPTOR NUMBER, never the request itself. A
    /// holder that took the bytes on its command line published the session's
    /// entire environment — every credential in it — to the process table, where
    /// `ps` shows argv to anything running as the same user, for as long as the
    /// session lived.
    @Test func refusesTheRequestItselfWhereADescriptorBelongs() throws {
        let inlinePayload = try JSONEncoder().encode(Self.launch).base64EncodedString()
        let arguments = try Self.commandLine(session: UUID(), launchFD: inlinePayload)
        #expect(throws: HolderStartupError.invalidLaunchDescriptorArgument(inlinePayload)) {
            _ = try HolderArguments.parse(arguments)
        }
    }

    /// A descriptor the spawner never placed is a spawner bug, and must be said
    /// so rather than surfacing as an empty request that decodes to nothing.
    ///
    /// `-1` rather than a large unused number: this process opens descriptors
    /// on other threads throughout the run, so any number that merely happens
    /// to be free right now could be taken before the read. -1 never can be.
    @Test func refusesADescriptorNothingWasPlacedOn() throws {
        #expect(throws: HolderStartupError.unreadableLaunchPayload(descriptor: -1, errno: EBADF)) {
            _ = try HolderArguments.parse(try Self.commandLine(session: UUID(), launchFD: "-1"))
        }
    }

    /// The descriptor is spent by parsing and must not still be open at
    /// `forkpty`: a launch request is the one thing in the holder that holds the
    /// session's secrets, and a fork would copy it into the job.
    ///
    /// Asserted from the far end of a socket pair rather than by asking whether
    /// the number is still open — a closed number can be handed straight back
    /// out to another thread, so only the peer can answer this without racing.
    @Test func theLaunchDescriptorIsClosedOnceItIsRead() throws {
        var ends: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &ends) == 0)
        let ours = ends[0]
        let holders = ends[1]
        defer { close(ours) }

        try JSONEncoder().encode(Self.launch).withUnsafeBytes { raw in
            _ = write(ours, raw.baseAddress, raw.count)
        }
        // Half-close, not close: the holder's end must see end of file while
        // this end stays open to watch what becomes of it.
        shutdown(ours, SHUT_WR)
        _ = fcntl(ours, F_SETFL, O_NONBLOCK)

        var byte: UInt8 = 0
        #expect(
            read(ours, &byte, 1) == -1 && errno == EAGAIN,
            "precondition: the holder's end is still open before parsing")

        let parsed = try HolderArguments.parse(
            try Self.commandLine(session: UUID(), launchFD: String(holders)))
        #expect(parsed.launch == Self.launch)
        #expect(read(ours, &byte, 1) == 0, "the spent descriptor must be closed, not left open")
    }

    /// A request split across reads is a stream that has not finished arriving,
    /// not a truncated message: the frame is end of file. Forced by a request
    /// twice the read buffer, which no single `read` can return.
    @Test func aRequestLargerThanOneReadIsReassembled() throws {
        var big = Self.launch
        big.environment["BULK"] = String(repeating: "x", count: 8_000)
        let parsed = try HolderArguments.parse(try Self.commandLine(
            session: UUID(), payload: try JSONEncoder().encode(big)))
        #expect(parsed.launch == big)
    }

    // MARK: - Framing

    @Test func framesSurviveArbitraryChunking() throws {
        let responses: [HolderResponse] = [
            .described(HolderChildDescription(
                childPID: 4242,
                ttyName: "/dev/ttys004",
                status: .alive,
                launch: Self.launch,
                owner: HolderOwnerToken(rawValue: "installation-abc"))),
            .forgotten,
            .rejected(version: HolderProtocolVersion.busySentinel),
        ]
        var stream = Data()
        for response in responses { stream += try HolderFraming.frame(response) }

        // Feed the scanner one byte at a time: a stream socket may split a
        // frame anywhere, and a scanner that assumes a whole frame per read
        // desyncs the moment it does.
        var buffer = Data()
        var decoded: [HolderResponse] = []
        for byte in stream {
            buffer.append(byte)
            decoded += try HolderFraming.drain(HolderResponse.self, from: &buffer)
        }
        #expect(decoded == responses)
        #expect(buffer.isEmpty)
    }

    /// A desynced peer must not be able to make the holder allocate on its
    /// behalf just by claiming a large length.
    @Test func refusesAnOversizedLengthWord() throws {
        var buffer = Data()
        var length = UInt32(HolderFraming.maximumFrameSize + 1).littleEndian
        buffer.append(Data(bytes: &length, count: MemoryLayout<UInt32>.size))
        #expect(throws: HolderFramingError.self) {
            _ = try HolderFraming.drainRequests(from: &buffer)
        }
    }

    // MARK: - Exit status

    /// A child killed by a signal has no exit code, so the holder says it could
    /// not observe one rather than inventing a number downstream cannot tell
    /// apart from a real exit.
    @Test func signalledChildrenReportAnUnknownStatus() {
        #expect(Holder.status(fromWaitpidStatus: 42 << 8) == .exited(code: 42))
        #expect(Holder.status(fromWaitpidStatus: 0) == .exited(code: 0))
        #expect(Holder.status(fromWaitpidStatus: SIGKILL) == .exitedStatusUnknown)
    }

    // MARK: - Exit codes

    /// A spawner reading a dead holder's exit code has exactly one decision to
    /// make — could retrying help? — so the codes must split on that line and
    /// nothing else. A single code for every startup failure answers it wrongly
    /// half the time: it reads a rendezvous directory that momentarily could not
    /// be created as a mistake in the spawner's own command line, and abandons a
    /// session a second attempt would have started.
    @Test func startupErrorsSeparateABadInvocationFromABadMachine() {
        #expect(HolderExitCode.badInvocation != HolderExitCode.environmentFailure)

        let badInvocations: [HolderStartupError] = [
            .unknownArgument("stray"),
            .missingValue("--socket"),
            .missingArgument("session"),
            .invalidSessionID("not-a-uuid"),
            .invalidLaunchPayload,
            .invalidLaunchDescriptorArgument("eyJleGVjdXRhYmxlIjoi"),
            .unreadableLaunchPayload(descriptor: 10, errno: EBADF),
            .invalidLockDescriptorArgument("/tmp/holders/session.lock"),
            .invalidLockDescriptor(1),
            .socketPathTooLong(path: "/tmp/holders/session.sock", limit: 104),
        ]
        for error in badInvocations {
            #expect(
                error.exitCode == HolderExitCode.badInvocation,
                "\(error) is the command line being wrong; retrying it changes nothing")
        }

        let badMachines: [HolderStartupError] = [
            .socketDirectoryUnavailable(path: "/tmp/holders", errno: ENOTDIR),
            .cannotBind(path: "/tmp/holders/session.sock", errno: EADDRINUSE),
            .cannotListen(path: "/tmp/holders/session.sock", errno: EINVAL),
            .forkFailed(errno: EAGAIN),
        ]
        for error in badMachines {
            #expect(
                error.exitCode == HolderExitCode.environmentFailure,
                "\(error) is the machine refusing, and a later attempt can succeed")
        }
    }

    // MARK: - The clock seam

    /// A clock whose every `now` read advances by a fixed step, so elapsed time
    /// is exactly countable instead of being whatever the machine was doing.
    private final class SteppingClock: Clock, @unchecked Sendable {
        typealias Instant = ContinuousClock.Instant

        private let step: Duration
        private var current = ContinuousClock.Instant.now

        init(step: Duration) { self.step = step }

        var now: ContinuousClock.Instant {
            defer { current = current.advanced(by: step) }
            return current
        }
        var minimumResolution: Duration { .nanoseconds(1) }
        func sleep(until deadline: ContinuousClock.Instant, tolerance: Duration?) async throws {}
    }

    @Test func theExitReportWindowIsUntimedUntilArmed() {
        // Each `charging` reads `now` twice, so it charges two steps.
        var window = ExitReportWindow(limit: .seconds(1), clock: SteppingClock(step: .seconds(10)))
        for _ in 0..<20 { window.charging {} }
        #expect(!window.isArmed)
        #expect(!window.isExpired, "a holder serving a live child must never time itself out")
    }

    @Test func theExitReportWindowExpiresOnceArmed() {
        // Each `charging` reads `now` twice, one step apart, so it charges one
        // step against the limit.
        var window = ExitReportWindow(limit: .seconds(1), clock: SteppingClock(step: .milliseconds(400)))
        window.arm()
        #expect(window.isArmed)
        window.charging {}
        #expect(!window.isExpired, "0.4s of a 1s window")
        window.charging {}
        #expect(!window.isExpired, "0.8s of a 1s window")
        window.charging {}
        #expect(window.isExpired, "1.2s of a 1s window")
    }
}
