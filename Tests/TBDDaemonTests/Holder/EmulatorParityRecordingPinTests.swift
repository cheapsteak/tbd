import CryptoKit
import Foundation
import Testing

/// The recordings `HolderEmulatorParityTests` feeds are the bytes `manifest.json` describes, so a
/// parity result always refers to the same streams. A recording that changed, or a manifest that
/// lists another set, fails here before the parity suite reads it. Rerunning
/// `scripts/record-emulator-parity-corpus.py` rewrites both together.
@Suite struct EmulatorParityRecordingPinTests {
    @Test func theManifestListsTheRecordingsTheSuiteFeeds() throws {
        let entries = try EmulatorParity.Recordings.entries()
        #expect(entries.map(\.name) == EmulatorParity.Recordings.names)
    }

    @Test(arguments: EmulatorParity.Recordings.names)
    func recordingMatchesItsManifestEntry(_ name: String) throws {
        let entry = try EmulatorParity.Recordings.entry(named: name)
        let bytes = try EmulatorParity.Recordings.bytes(of: entry)
        #expect(bytes.count == entry.bytes, "\(entry.file) is \(bytes.count) bytes; the manifest says \(entry.bytes)")
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        #expect(digest == entry.sha256, "\(entry.file) has SHA-256 \(digest); the manifest says \(entry.sha256)")
        #expect(entry.cols > 0 && entry.rows > 0, "\(name) is recorded at \(entry.cols)x\(entry.rows)")
    }
}
