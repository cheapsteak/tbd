import Foundation
import Testing
@testable import TBDHolder
@testable import TBDShared

/// The holder's own suite. It is here now to hold the target open for the
/// holder itself; the one thing worth asserting about a placeholder binary is
/// the thing that will still matter afterwards — that `TBDHolderTests`'
/// dependency on the EXECUTABLE target really does build the product into the
/// same products directory as the test bundle, which is the load-bearing half
/// of the same dependency `TBDPeerHelperTests` documents.
///
/// Without that, the holder's integration tests would look correct and find no
/// binary to spawn.
@Suite("Holder binary")
struct HolderBinaryTests {
    private final class BundleMarker {}

    /// The built `TBDHolder`, a sibling of the test bundle in the products
    /// directory — the same sibling lookup `SpawnedPeerHelper` does.
    private static func locateExecutable() -> URL? {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDHolder")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @Test func binaryIsBuiltBesideTheTestBundle() throws {
        #expect(Self.locateExecutable() != nil, "TBDHolder was not built into the products directory")
    }

    /// A bad invocation must fail loudly, and distinguishably. Exit 2 means the
    /// command line was wrong: the same arguments will fail the same way
    /// forever, so a spawner that sees it must fix them or give up rather than
    /// retry — and either way it must never get back a session whose pty nobody
    /// owns.
    @Test func aBadInvocationExitsTwoWithAUsageDiagnostic() throws {
        let executable = try #require(Self.locateExecutable())
        let process = Process()
        process.executableURL = executable
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        #expect(process.terminationStatus == 2)
        let diagnostic = String(decoding: stderrData, as: UTF8.self)
        #expect(diagnostic.contains("--session is required"))
        #expect(diagnostic.contains("--lock-fd"), "the usage line must name the descriptor flag")
    }

    /// The other side of that distinction, which is only real if the codes
    /// actually differ. A perfectly-formed invocation whose rendezvous
    /// directory cannot exist is the machine refusing, not a spawner mistake:
    /// it must exit 3, so a retry stays on the table.
    ///
    /// The socket is asked for under `/dev/null`, which exists and is not a
    /// directory — `mkdir` there fails with `ENOTDIR` on any machine, needing
    /// no permissions games and leaving nothing behind. A bootstrap `sh` opens
    /// the lock descriptor the holder demands and then `exec`s, so the status
    /// observed here is the holder's own.
    @Test func anEnvironmentFailureExitsThreeRatherThanTwo() throws {
        let executable = try #require(Self.locateExecutable())
        let launch = HolderLaunchRequest(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 1"],
            workingDirectory: "/tmp",
            environment: ["PATH": "/usr/bin:/bin"],
            columns: 80,
            rows: 24)
        let payload = try JSONEncoder().encode(launch).base64EncodedString()
        let command = [
            "exec 9</dev/null;",
            "exec", Self.shellQuoted(executable.path),
            "--session", UUID().uuidString,
            "--socket", "/dev/null/holders/session.sock",
            "--lock-fd", "9",
            "--launch", Self.shellQuoted(payload),
        ].joined(separator: " ")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        // Explicit and rc-free: nothing here may come from the developer's
        // shell, and the holder must not find a real TBD home to write into.
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(
            process.terminationStatus == 3,
            "an environment failure must not be reported as a bad command line")
        let diagnostic = String(decoding: stderrData, as: UTF8.self)
        #expect(diagnostic.contains("could not create the holder rendezvous directory"))
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
