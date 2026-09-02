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

    private static func commandLine(
        session: UUID,
        lockFD: String = "9",
        owner: String? = "installation-abc"
    ) throws -> [String] {
        var arguments = [
            "--session", session.uuidString,
            "--socket", "/tmp/holders/session.sock",
            "--lock-fd", lockFD,
            "--launch", try JSONEncoder().encode(launch).base64EncodedString(),
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
            _ = try HolderArguments.parse([
                "--session", UUID().uuidString,
                "--socket", "/tmp/x.sock",
                "--lock-fd", "9",
                "--launch", "not-base64-json",
            ])
        }
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
