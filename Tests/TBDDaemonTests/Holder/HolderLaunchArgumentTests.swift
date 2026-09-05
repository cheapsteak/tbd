import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// What a holder's command line may contain, and where its launch request
/// travels instead.
///
/// The rule these tests exist to hold: **a `HolderLaunchRequest` never touches
/// argv.** It carries the session's entire environment, and argv is readable by
/// every process running as the same user — one `ps -ww` and a session's
/// credentials are in the process table for as long as the session lives. The
/// request goes down a descriptor the spawner places with a `posix_spawn` file
/// action, which nothing outside the process tree can name.
///
/// The command line is asserted as a **whole list**, not searched for the one
/// string that used to leak. A blacklist only ever catches the leak somebody
/// already thought of; pinning the entire list means any future argument
/// carrying anything from the launch request has to fail this test to get in.
@Suite("Holder launch arguments")
struct HolderLaunchArgumentTests {
    /// Distinctive, obviously fake stand-ins for the secret-bearing fields.
    /// Nothing here is a real credential; they exist to be searched for — so
    /// none of them may share a substring with anything the command line
    /// legitimately carries, or the search below would fail for the wrong
    /// reason.
    private static let launch = HolderLaunchRequest(
        executable: "/bin/zsh",
        arguments: ["-lc", "run-the-agent --flag"],
        workingDirectory: "/tmp/the-sessions-working-directory",
        environment: [
            "PATH": "/usr/bin:/bin",
            "TERM": "xterm-256color",
            "EXAMPLE_API_KEY": "placeholder-launch-secret-do-not-log",
        ],
        columns: 120,
        rows: 40)

    private static let owner = HolderOwnerToken(rawValue: "tbd-home:/tmp/an-installation")

    // MARK: - argv

    @Test func theCommandLineIsExactlyTheseArguments() {
        let session = UUID()
        let arguments = HolderSpawner.commandLine(
            executablePath: "/opt/tbd/TBDHolder",
            sessionID: session,
            socketPath: "/tmp/holders/\(session.uuidString.lowercased()).sock",
            owner: Self.owner)

        #expect(arguments == [
            "/opt/tbd/TBDHolder",
            "--session", session.uuidString,
            "--socket", "/tmp/holders/\(session.uuidString.lowercased()).sock",
            "--lock-fd", "9",
            "--launch-fd", "10",
            "--owner", "tbd-home:/tmp/an-installation",
        ])
    }

    /// The same claim from the other direction, so a failure says *what* leaked
    /// rather than only that the list changed. Every secret-bearing field of
    /// the request is looked for in every argument.
    @Test func noPartOfTheLaunchRequestReachesTheCommandLine() {
        let session = UUID()
        let arguments = HolderSpawner.commandLine(
            executablePath: "/opt/tbd/TBDHolder",
            sessionID: session,
            socketPath: "/tmp/holders/\(session.uuidString.lowercased()).sock",
            owner: Self.owner)
        let commandLine = arguments.joined(separator: " ")

        var forbidden = Array(Self.launch.environment.keys)
        forbidden += Array(Self.launch.environment.values)
        forbidden += Self.launch.arguments
        forbidden += [Self.launch.executable, Self.launch.workingDirectory]
        // The encoded request in both shapes it has ever been passed in.
        let json = try? JSONEncoder().encode(Self.launch)
        forbidden += [
            String(decoding: json ?? Data(), as: UTF8.self),
            (json ?? Data()).base64EncodedString(),
        ]

        for secret in forbidden where !secret.isEmpty {
            #expect(
                !commandLine.contains(secret),
                """
                "\(secret)" reached the holder's command line, where `ps` shows it to \
                every process running as this user
                """)
        }

        // Encoding is not concealment, and base64 is how the request used to
        // ride argv — a shape the plain-substring search above cannot see,
        // because the encoder is free to order the JSON keys differently than
        // this test would. So decode every argument and refuse any that turns
        // out to be a launch request.
        for argument in arguments {
            guard let decoded = Data(base64Encoded: argument),
                  let smuggled = try? JSONDecoder().decode(
                      HolderLaunchRequest.self, from: decoded)
            else { continue }
            Issue.record("""
                an argument decodes to a launch request for \(smuggled.executable) with \
                \(smuggled.environment.count) environment entries; encoding it does not \
                keep it out of `ps`
                """)
        }
    }

    /// Both inherited descriptors must be above stdio and distinct: `forkpty`
    /// dup2s the pty slave onto 0/1/2 in the job, and two file actions aimed at
    /// one number would mean the holder read one of them as the other.
    @Test func theInheritedDescriptorNumbersAreDistinctAndAboveStdio() {
        #expect(HolderSpawner.lockDescriptorNumber > 2)
        #expect(HolderSpawner.launchDescriptorNumber > 2)
        #expect(HolderSpawner.lockDescriptorNumber != HolderSpawner.launchDescriptorNumber)
    }

    // MARK: - The descriptor the request travels on

    @Test func theLaunchRequestTravelsWholeOnItsDescriptor() throws {
        let descriptor = try HolderSpawner.makeLaunchPayloadChannel(Self.launch)
        defer { close(descriptor) }

        let payload = Self.readToEndOfFile(descriptor)
        let decoded = try JSONDecoder().decode(HolderLaunchRequest.self, from: payload)
        #expect(decoded == Self.launch)
        #expect(decoded.environment["EXAMPLE_API_KEY"] == "placeholder-launch-secret-do-not-log")
    }

    /// The whole request is queued before `posix_spawn` is ever called and the
    /// writing end is closed, so the holder reads to end of file and stops.
    /// Were the write deferred until after the spawn, a holder that never
    /// reached `main` would park the daemon thread that was feeding it.
    @Test func theWritingEndIsAlreadyClosedSoTheReaderSeesEndOfFile() throws {
        let descriptor = try HolderSpawner.makeLaunchPayloadChannel(Self.launch)
        defer { close(descriptor) }
        _ = Self.readToEndOfFile(descriptor)

        var byte: UInt8 = 0
        #expect(read(descriptor, &byte, 1) == 0, "a second read must report end of file, not block")
    }

    /// A request far larger than any real environment still fits: the channel
    /// sizes its buffers to the payload, which is the reason it is a socket
    /// rather than a darwin pipe (whose buffer cannot be resized).
    @Test func aLargeRequestStillFitsWithoutADeadlock() throws {
        var big = Self.launch
        big.environment["BULK"] = String(repeating: "x", count: 256 * 1024)
        let descriptor = try HolderSpawner.makeLaunchPayloadChannel(big)
        defer { close(descriptor) }

        let decoded = try JSONDecoder().decode(
            HolderLaunchRequest.self, from: Self.readToEndOfFile(descriptor))
        #expect(decoded == big)
    }

    private static func readToEndOfFile(_ descriptor: Int32) -> Data {
        var payload = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                payload.append(contentsOf: buffer[0..<count])
                continue
            }
            if count < 0, errno == EINTR { continue }
            return payload
        }
    }
}
