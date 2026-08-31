import Foundation
import Testing
@testable import TBDHolder

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

    /// A bad invocation must fail loudly, and distinguishably. Exit 2 is "the
    /// command line was wrong", separate from a holder that started and then
    /// failed, so a spawner can tell a mistake of its own from a bad machine —
    /// and either way it must never get back a session whose pty nobody owns.
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
}
