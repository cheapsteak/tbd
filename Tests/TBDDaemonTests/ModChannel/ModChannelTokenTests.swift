import CryptoKit
import Foundation
import TestSupport
import Testing
@testable import TBDDaemonLib
@testable import TBDShared

@Suite struct ModChannelTokenTests {
    private static func scratch() throws -> URL {
        let url = URL(fileURLWithPath: fencedScratchRoot(prefix: "modkey"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func tokenIsStableAndBoundToIncarnation() {
        let key = SymmetricKey(size: .bits256)
        let token = ModChannelToken(key: key)
        let incarnation = UUID()
        let other = UUID()

        let minted = token.token(incarnationID: incarnation)
        #expect(minted == ModChannelToken(key: key).token(incarnationID: incarnation))
        #expect(minted != token.token(incarnationID: other))
        #expect(minted.count == 64)
        #expect(minted == minted.lowercased())
        #expect(token.verify(minted, incarnationID: incarnation))
        #expect(!token.verify(minted, incarnationID: other))
        #expect(!ModChannelToken(key: SymmetricKey(size: .bits256))
            .verify(minted, incarnationID: incarnation))
    }

    @Test func verifyRejectsMalformedTokens() {
        let token = ModChannelToken(key: SymmetricKey(size: .bits256))
        let incarnation = UUID()
        let good = token.token(incarnationID: incarnation)
        for bad in ["", "zz", String(good.dropLast()), good + "00", String(repeating: "g", count: 64)] {
            #expect(!token.verify(bad, incarnationID: incarnation), "accepted \(bad)")
        }
    }

    @Test func loadOrCreateWritesThirtyTwoBytesMode0600() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("runtime/mod-key")

        let first = try ModChannelToken.loadOrCreate(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 32)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        let second = try ModChannelToken.loadOrCreate(at: url)
        let incarnation = UUID()
        #expect(first.token(incarnationID: incarnation) == second.token(incarnationID: incarnation))
    }

    /// A key that is already there is used as it is: never rewritten, so
    /// tokens minted before a daemon restart still verify.
    @Test func loadOrCreateKeepsAnExistingKey() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mod-key")
        let key = SymmetricKey(size: .bits256)
        let bytes = key.withUnsafeBytes { Data($0) }
        #expect(FileManager.default.createFile(
            atPath: url.path, contents: bytes, attributes: [.posixPermissions: 0o600]))

        let loaded = try ModChannelToken.loadOrCreate(at: url)
        let incarnation = UUID()
        #expect(loaded.token(incarnationID: incarnation)
            == ModChannelToken(key: key).token(incarnationID: incarnation))
        #expect(FileManager.default.contents(atPath: url.path) == bytes)
    }

    @Test func loadOrCreateReplacesWrongLengthKey() throws {
        let root = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("mod-key")
        try Data("short".utf8).write(to: url)

        let token = try ModChannelToken.loadOrCreate(at: url)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.size] as? NSNumber)?.intValue == 32)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let again = try ModChannelToken.loadOrCreate(at: url)
        let incarnation = UUID()
        #expect(token.token(incarnationID: incarnation) == again.token(incarnationID: incarnation))
    }

    @Test func modSocketPathFollowsHomeAndOverride() {
        #expect(TBDConstants.modSocketPath(environment: ["TBD_HOME": "/tmp/h"]) == "/tmp/h/mod.sock")
        #expect(TBDConstants.modSocketPath(environment: [
            "TBD_HOME": "/tmp/h", "TBD_MOD_SOCKET_PATH": "/tmp/s/m.sock",
        ]) == "/tmp/s/m.sock")
        #expect(TBDConstants.modSocketPath(environment: [
            "TBD_HOME": "/tmp/h", "TBD_MOD_SOCKET_PATH": "",
        ]) == "/tmp/h/mod.sock")
        #expect(TBDConstants.modKeyPath(environment: ["TBD_HOME": "/tmp/h"]).path
            == "/tmp/h/runtime/mod-key")
    }
}
