import Foundation
import Testing
@testable import TBDShared

@Suite("Watch Desk lease capability wire and file safety")
struct WatchDeskLeaseCredentialTests {
    @Test("status snapshot is redacted")
    func statusSnapshotRedactsToken() throws {
        let snapshot = WatchDeskLeaseSnapshot(
            worktreeID: UUID(), terminalID: UUID(), generation: 7,
            acquiredAt: Date(), renewedAt: Date(), expiresAt: Date(), valid: true)
        let encoded = try JSONEncoder().encode(snapshot)
        let json = try #require(String(data: encoded, encoding: .utf8))
        #expect(!json.contains("token"))
    }

    @Test("capability file round-trips outside the worktree at mode 0600")
    func capabilityFile() throws {
        let home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tbd-lease-capability-\(UUID())")
        let environment = ["TBD_HOME": home.path]
        defer { try? FileManager.default.removeItem(at: home) }
        let credential = WatchDeskLeaseCredential(
            worktreeID: UUID(), terminalID: UUID(), token: UUID(), generation: 3)
        let path = try WatchDeskLeaseCredentialFile.write(
            credential, environment: environment)
        #expect(!path.contains(credential.token.uuidString))
        #expect(try WatchDeskLeaseCredentialFile.read(path: path) == credential)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(
            atPath: WatchDeskLeaseCredentialFile.directory(environment: environment).path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)

        let refreshed = WatchDeskLeaseCredential(
            worktreeID: credential.worktreeID, terminalID: credential.terminalID,
            token: credential.token, generation: 4)
        let refreshedPath = try WatchDeskLeaseCredentialFile.ensure(
            refreshed, environment: environment)
        #expect(URL(fileURLWithPath: refreshedPath).resolvingSymlinksInPath()
            == URL(fileURLWithPath: path).resolvingSymlinksInPath())
        #expect(try WatchDeskLeaseCredentialFile.read(path: path) == refreshed)
    }
}
