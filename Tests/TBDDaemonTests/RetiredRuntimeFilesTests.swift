import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("RetiredRuntimeFiles")
struct RetiredRuntimeFilesTests {

    private static func makeRuntimeDir() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-retired-runtime-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes a regular file at `name` under `dir`, creating its parent folders.
    private static func seed(_ name: String, in dir: URL) throws {
        let url = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "left by an earlier build".write(to: url, atomically: true, encoding: .utf8)
    }

    private static func exists(_ name: String, in dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path)
    }

    /// One of each retired kind, with a terminal UUID as the session key the
    /// way the capture path builder was always called.
    private static func retiredNames() -> [String] {
        let key = UUID().uuidString
        let credential = "\(UUID().uuidString)-\(UUID().uuidString).json"
        return [
            RetiredRuntimeFiles.teeScriptName,
            "statusline-capture-\(key).json",
            "statusline-capture-\(key).json.48213.tmp.json",
            RetiredRuntimeFiles.leaseCredentialDirectoryName + "/" + credential,
            "continue-in-claude-packet-\(key.lowercased())-\(UUID().uuidString.lowercased()).txt",
        ]
    }

    @Test func presentRetiredFilesAreRemoved() throws {
        let dir = try Self.makeRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let retired = Self.retiredNames()
        for name in retired { try Self.seed(name, in: dir) }
        try Self.seed(RetiredRuntimeFiles.leaseCredentialDirectoryName + "/.pending.tmp", in: dir)
        for name in retired {
            #expect(Self.exists(name, in: dir), "\(name) was not seeded")
        }

        // The script, two captures, the credential directory counted once, and
        // the packet.
        #expect(RetiredRuntimeFiles(runtimeDir: dir).removeAll() == 5)

        for name in retired {
            #expect(!Self.exists(name, in: dir), "\(name) survived")
        }
        #expect(!Self.exists(RetiredRuntimeFiles.leaseCredentialDirectoryName, in: dir))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining.isEmpty)
    }

    @Test func nothingPresentIsANoOp() throws {
        let dir = try Self.makeRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(RetiredRuntimeFiles(runtimeDir: dir).removeAll() == 0)
        #expect(RetiredRuntimeFiles(runtimeDir: dir).removeAll() == 0)
    }

    @Test func aMissingRuntimeDirIsANoOpAndIsNotCreated() throws {
        let parent = try Self.makeRuntimeDir()
        defer { try? FileManager.default.removeItem(at: parent) }
        let dir = parent.appendingPathComponent("runtime")

        #expect(RetiredRuntimeFiles(runtimeDir: dir).removeAll() == 0)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func unrelatedRuntimeFilesAreUntouched() throws {
        let dir = try Self.makeRuntimeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let key = UUID().uuidString
        let unrelated = [
            "claude-overlay.json",
            "claude-overlay-session-\(key).json",
            "mod-key",
            "continue-in-claude-packet-\(key.lowercased()).txt",
            "continue-in-claude-packet-\(key.lowercased())-\(UUID().uuidString.lowercased()).json",
            "statusline-tee.sh.bak",
            "statusline-capture-\(key).txt",
            "statusline-capture-.json",
            "statusline-capture-\(key).json.tmp.json",
            "statusline-capture-\(key).json.12a.tmp.json",
            "xstatusline-capture-\(key).json",
            "presession/statusline-capture-\(key).json",
            "setup/statusline-tee.sh",
        ]
        for name in unrelated { try Self.seed(name, in: dir) }
        for name in Self.retiredNames() { try Self.seed(name, in: dir) }

        #expect(RetiredRuntimeFiles(runtimeDir: dir).removeAll() == 5)

        for name in unrelated {
            #expect(Self.exists(name, in: dir), "\(name) was removed")
        }
    }

    @Test(arguments: [
        ("statusline-capture-0F3C2A7E-1B2C-4D5E-8F90-ABCDEF012345.json", true),
        ("statusline-capture-a_b-C9.json", true),
        ("statusline-capture-a_b-C9.json.7.tmp.json", true),
        ("statusline-capture-a_b-C9.json.123456.tmp.json", true),
        ("statusline-capture-.json", false),
        ("statusline-capture-a b.json", false),
        ("statusline-capture-a.b.json", false),
        ("statusline-capture-key.json.tmp.json", false),
        ("statusline-capture-key.json..tmp.json", false),
        ("statusline-capture-key.json.12a.tmp.json", false),
        ("statusline-capture-key.json.12.tmp.json.json", false),
        ("statusline-capture-key.txt", false),
        ("statusline-capture-key", false),
        ("claude-overlay-session-key.json", false),
        ("statusline-tee.sh", false),
    ])
    func captureNamesMatchOnlyTheTeeShapes(name: String, isCapture: Bool) {
        #expect(RetiredRuntimeFiles.isStatuslineCapture(name) == isCapture)
    }

    @Test(arguments: [
        ("continue-in-claude-packet-0f3c2a7e-1b2c-4d5e-8f90-abcdef012345-11111111-2222-3333-4444-555555555555.txt", true),
        ("continue-in-claude-packet-0F3C2A7E-1B2C-4D5E-8F90-ABCDEF012345-11111111-2222-3333-4444-555555555555.txt", true),
        ("continue-in-claude-packet-0f3c2a7e-1b2c-4d5e-8f90-abcdef012345.txt", false),
        ("continue-in-claude-packet-0f3c2a7e-1b2c-4d5e-8f90-abcdef012345_11111111-2222-3333-4444-555555555555.txt", false),
        ("continue-in-claude-packet-0f3c2a7e-1b2c-4d5e-8f90-abcdef012345-11111111-2222-3333-4444-55555555555z.txt", false),
        ("continue-in-claude-packet-0f3c2a7e-1b2c-4d5e-8f90-abcdef012345-11111111-2222-3333-4444-555555555555.json", false),
        ("continue-in-claude-packet-.txt", false),
        ("statusline-tee.sh", false),
    ])
    func packetNamesMatchOnlyThePacketShape(name: String, isPacket: Bool) {
        #expect(RetiredRuntimeFiles.isContinuationPacket(name) == isPacket)
    }

    /// A retired entry that cannot be removed — here the credential directory,
    /// made read-only so its file cannot be unlinked — is logged and left; the
    /// others are still removed and the call returns normally.
    @Test func aRemovalThatFailsDoesNotStopTheOthers() throws {
        let dir = try Self.makeRuntimeDir()
        let leases = dir.appendingPathComponent(RetiredRuntimeFiles.leaseCredentialDirectoryName)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: leases.path)
            try? FileManager.default.removeItem(at: dir)
        }
        for name in Self.retiredNames() { try Self.seed(name, in: dir) }
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: leases.path)

        // The script, the two captures and the packet; not the credential
        // directory.
        #expect(RetiredRuntimeFiles(runtimeDir: dir).removeAll() == 4)

        #expect(!Self.exists(RetiredRuntimeFiles.teeScriptName, in: dir))
        #expect(FileManager.default.fileExists(atPath: leases.path))
        let remaining = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(remaining == [RetiredRuntimeFiles.leaseCredentialDirectoryName])
    }
}
