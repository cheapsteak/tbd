import Foundation
import Testing
@testable import TBDModelProxy

/// The half of `TBDModelProxyTests`' dependency on the EXECUTABLE target that
/// `@testable import` does not cover: that depending on `TBDModelProxy` really
/// does build the product into the same products directory as the test bundle.
///
/// It is asserted here, with the target, rather than left to the suites that
/// will need it. Part B2's supervisor tests will spawn this binary through the
/// real spawner; if the products directory were the thing that broke, those
/// suites would look correct and find no binary to spawn. Shaped after
/// `Tests/TBDHolderTests/HolderBinaryTests.swift`, which exists for exactly
/// this reason.
@Suite("Model proxy binary")
struct ProxyBinaryTests {
    private final class BundleMarker {}

    /// The built `TBDModelProxy`, a sibling of the test bundle in the products
    /// directory — the same sibling lookup `HolderFixture.locateExecutable`
    /// does for the holder.
    private static func locateExecutable() -> URL? {
        let bundleURL = Bundle(for: BundleMarker.self).bundleURL
        var candidates = [bundleURL.deletingLastPathComponent(), bundleURL]
        if let main = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(main)
        }
        for directory in candidates {
            let candidate = directory.appendingPathComponent("TBDModelProxy")
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    @Test("the binary is built beside the test bundle")
    func binaryIsBuiltBesideTheTestBundle() throws {
        #expect(Self.locateExecutable() != nil, "TBDModelProxy was not built into the products directory")
    }

    /// The parser's verdict, observed through the process rather than through
    /// `@testable`: a bad command line has to exit 2 with the usage line on
    /// stderr and nothing at all on stdout.
    ///
    /// Exit 2 is what tells a supervisor not to respawn — the same arguments
    /// will fail the same way forever — and it is only a distinction if the
    /// binary really produces it, which no in-process parse test can show. The
    /// stdout assertion pins the other invariant this target carries: a proxy's
    /// stdout is redirected into `proxy.log`, so ordinary output there would be
    /// indistinguishable from a diagnostic.
    ///
    /// An unknown flag is the safe way to reach that exit: a well-formed
    /// invocation would block on the termination semaphore forever, and this
    /// one refuses before it can touch a home or bind anything. The environment
    /// is explicit and rc-free for the same reason every holder bootstrap is —
    /// nothing here may come from the developer's shell.
    @Test("a bad invocation exits 2 with a usage diagnostic and a silent stdout")
    func aBadInvocationExitsTwoWithAUsageDiagnostic() throws {
        let executable = try #require(Self.locateExecutable())
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--stream-dir", "/tmp"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let stderrPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = stdoutPipe
        try process.run()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        #expect(process.terminationStatus == TBDModelProxyExit.badArguments)
        let diagnostic = String(decoding: stderrData, as: UTF8.self)
        #expect(diagnostic.contains("unknown argument --stream-dir"))
        #expect(diagnostic.contains("--lock-fd"), "the usage line must name the descriptor flag")
        #expect(stdoutData.isEmpty, "a proxy must never write to stdout")
    }
}
