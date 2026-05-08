import Foundation
import Testing
@testable import TBDShared

@Suite struct SettingsJSONSafetyTests {

    private func makeTempPath() -> String {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-safety-\(UUID().uuidString).json")
            .path
    }

    @Test func ensureBackupCopiesOnceThenSkipsSubsequentCalls() throws {
        let src = makeTempPath()
        defer {
            try? FileManager.default.removeItem(atPath: src)
            try? FileManager.default.removeItem(atPath: src + SettingsJSONSafety.backupSuffix)
        }
        try #"{"hooks":{}}"#.data(using: .utf8)!.write(to: URL(fileURLWithPath: src))
        // First call → creates backup.
        let first = try SettingsJSONSafety.ensureBackup(of: src)
        #expect(first)
        #expect(FileManager.default.fileExists(atPath: src + SettingsJSONSafety.backupSuffix))
        // Mutate the source file.
        try #"{"hooks":{"Stop":[]}}"#.data(using: .utf8)!.write(to: URL(fileURLWithPath: src))
        // Second call → should NOT overwrite the original backup.
        let second = try SettingsJSONSafety.ensureBackup(of: src)
        #expect(!second)
        let backup = try String(contentsOfFile: src + SettingsJSONSafety.backupSuffix, encoding: .utf8)
        #expect(backup == #"{"hooks":{}}"#)
    }

    @Test func ensureBackupNoOpWhenSourceMissing() throws {
        let src = makeTempPath()
        let result = try SettingsJSONSafety.ensureBackup(of: src)
        #expect(!result)
        #expect(!FileManager.default.fileExists(atPath: src + SettingsJSONSafety.backupSuffix))
    }

    @Test func atomicWriteSucceedsAndPersistsBytes() throws {
        let target = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: target) }
        let bytes = #"{"a":1}"#.data(using: .utf8)!
        try SettingsJSONSafety.atomicWriteValidated(
            proposedBytes: bytes,
            targetPath: target,
            invariant: { _ in }
        )
        let written = try Data(contentsOf: URL(fileURLWithPath: target))
        #expect(written == bytes)
    }

    @Test func atomicWriteRejectsMalformedJSON() throws {
        let target = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: target) }
        let bytes = "not json".data(using: .utf8)!
        do {
            try SettingsJSONSafety.atomicWriteValidated(
                proposedBytes: bytes,
                targetPath: target,
                invariant: { _ in }
            )
            Issue.record("Expected roundtrip failure")
        } catch SettingsJSONSafety.Error.roundtripFailed {
            // expected
        }
        // Target file must NOT have been written.
        #expect(!FileManager.default.fileExists(atPath: target))
    }

    @Test func atomicWriteAbortsWhenInvariantThrows() throws {
        let target = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: target) }
        // Pre-existing file we can compare against — must remain untouched.
        try #"{"existing":true}"#.data(using: .utf8)!.write(to: URL(fileURLWithPath: target))
        let bytes = #"{"hooks":{}}"#.data(using: .utf8)!
        do {
            try SettingsJSONSafety.atomicWriteValidated(
                proposedBytes: bytes,
                targetPath: target,
                invariant: { _ in
                    throw SettingsJSONSafety.Error.invariantFailed("synthetic")
                }
            )
            Issue.record("Expected invariant failure")
        } catch SettingsJSONSafety.Error.invariantFailed {
            // expected
        }
        let onDisk = try String(contentsOfFile: target, encoding: .utf8)
        #expect(onDisk == #"{"existing":true}"#)
    }

    @Test func atomicWriteRejectsNonObjectTopLevel() throws {
        let target = makeTempPath()
        defer { try? FileManager.default.removeItem(atPath: target) }
        let arrayBytes = "[]".data(using: .utf8)!
        do {
            try SettingsJSONSafety.atomicWriteValidated(
                proposedBytes: arrayBytes,
                targetPath: target,
                invariant: { _ in }
            )
            Issue.record("Expected roundtrip failure for array top-level")
        } catch SettingsJSONSafety.Error.roundtripFailed {
            // expected
        }
        #expect(!FileManager.default.fileExists(atPath: target))
    }
}
