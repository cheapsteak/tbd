import CryptoKit
import Darwin
import Foundation
import Testing
import TBDShared

@testable import TBDDaemonLib

@Suite("LaptopKeyStore")
struct LaptopKeyStoreTests {
    /// A fresh root under the temporary directory, standing in for `TBD_HOME`.
    /// The key goes where `TBDConstants` puts it for that home.
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-phone-key-\(UUID().uuidString)")
        var phoneDir: URL { TBDConstants.phoneDir(environment: ["TBD_HOME": root.path]) }
        var keyPath: URL { TBDConstants.phoneLaptopKeyPath(environment: ["TBD_HOME": root.path]) }

        func makePhoneDir() throws {
            try FileManager.default.createDirectory(at: phoneDir, withIntermediateDirectories: true)
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    /// The permission bits of the entry itself, never a link's target.
    private func mode(of url: URL) -> Int? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        return Int(info.st_mode & 0o777)
    }

    private func isSymbolicLink(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
    }

    @Test func pathHonorsTBDHome() {
        #expect(TBDConstants.phoneLaptopKeyPath(environment: ["TBD_HOME": "/tmp/acme-home"]).path
            == "/tmp/acme-home/phone/laptop.key")
        #expect(TBDConstants.phoneDir(environment: ["TBD_HOME": "/tmp/acme-home"]).path == "/tmp/acme-home/phone")
    }

    @Test func firstUseCreatesAnOwnerOnlyKeyAndTheSecondReadsItBack() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = LaptopKeyStore(path: fixture.keyPath)

        let first = try store.loadOrCreate()

        #expect(mode(of: fixture.keyPath) == 0o600)
        #expect(mode(of: fixture.phoneDir) == 0o700)
        #expect(try store.loadOrCreate().rawRepresentation == first.rawRepresentation)
        let bytes = try Data(contentsOf: fixture.keyPath)
        #expect(bytes.count == 32)
        #expect(bytes == first.rawRepresentation)
        // The temporary file is gone once its key is linked into place.
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.phoneDir.path) == ["laptop.key"])
    }

    @Test func aLooseFolderIsTightenedWhenTheKeyIsCreated() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        #expect(chmod(fixture.phoneDir.path, 0o755) == 0)

        _ = try LaptopKeyStore(path: fixture.keyPath).loadOrCreate()

        #expect(mode(of: fixture.phoneDir) == 0o700)
    }

    @Test func aLooseModeIsRefusedAndLeftAlone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = LaptopKeyStore(path: fixture.keyPath)
        _ = try store.loadOrCreate()
        let originalBytes = try Data(contentsOf: fixture.keyPath)
        #expect(chmod(fixture.keyPath.path, 0o644) == 0)

        #expect(throws: LaptopKeyStoreError.permissionMismatch(mode: 0o644)) {
            _ = try store.loadOrCreate()
        }

        #expect(try Data(contentsOf: fixture.keyPath) == originalBytes)
        #expect(mode(of: fixture.keyPath) == 0o644)
        let reason = LaptopKeyStoreError.permissionMismatch(mode: 0o644).localizedDescription
        #expect(reason.contains("0644") && reason.contains("0600"))
    }

    @Test func aTruncatedKeyIsRefusedAndLeftAlone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        let truncated = Data(repeating: 0x5A, count: 31)
        try truncated.write(to: fixture.keyPath)
        #expect(chmod(fixture.keyPath.path, 0o600) == 0)

        #expect(throws: LaptopKeyStoreError.malformed(byteCount: 31)) {
            _ = try LaptopKeyStore(path: fixture.keyPath).loadOrCreate()
        }

        #expect(try Data(contentsOf: fixture.keyPath) == truncated)
        #expect(LaptopKeyStoreError.malformed(byteCount: 31).localizedDescription.contains("31 bytes"))
    }

    @Test func aSymbolicLinkAtTheKeyPathIsRefusedAndLeftAlone() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        // A well-formed key elsewhere, so the link is the only fault.
        let elsewhere = fixture.root.appendingPathComponent("elsewhere.key")
        try Data(repeating: 7, count: 32).write(to: elsewhere)
        #expect(chmod(elsewhere.path, 0o600) == 0)
        try FileManager.default.createSymbolicLink(at: fixture.keyPath, withDestinationURL: elsewhere)

        #expect(throws: LaptopKeyStoreError.notARegularFile) {
            _ = try LaptopKeyStore(path: fixture.keyPath).loadOrCreate()
        }

        #expect(isSymbolicLink(fixture.keyPath))
        #expect(try Data(contentsOf: elsewhere) == Data(repeating: 7, count: 32))
    }

    @Test func aDanglingSymbolicLinkIsNeverWrittenThrough() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        let target = fixture.root.appendingPathComponent("planted.key")
        try FileManager.default.createSymbolicLink(at: fixture.keyPath, withDestinationURL: target)

        #expect(throws: LaptopKeyStoreError.notARegularFile) {
            _ = try LaptopKeyStore(path: fixture.keyPath).loadOrCreate()
        }

        #expect(isSymbolicLink(fixture.keyPath))
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func staleTempFilesAreSweptAndFreshOnesKept() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = fixture.phoneDir.appendingPathComponent(".laptop.key.A.tmp")
        let fresh = fixture.phoneDir.appendingPathComponent(".laptop.key.B.tmp")
        for (url, age) in [(stale, 120.0), (fresh, 5.0)] {
            try Data(repeating: 1, count: 32).write(to: url)
            try FileManager.default.setAttributes(
                [.modificationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path)
        }

        _ = try LaptopKeyStore(path: fixture.keyPath, now: { now }).loadOrCreate()

        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(atPath: fresh.path))
    }

    @Test func laptopNamesAreCutAtACharacterBoundary() {
        #expect(LaptopName.limited("  acme-laptop \n") == "acme-laptop")
        // U+00E9 is 2 UTF-8 bytes, so 128 of them fill 256.
        let accented = "\u{E9}"
        #expect(LaptopName.limited(String(repeating: accented, count: 200)) == String(repeating: accented, count: 128))
        // One Character, 18 UTF-8 bytes: 14 fit in 256 (252 bytes), and the
        // 15th is dropped whole rather than split.
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        #expect(family.count == 1 && family.utf8.count == 18)
        #expect(LaptopName.limited(String(repeating: family, count: 20)) == String(repeating: family, count: 14))
        #expect(LaptopName.limited("   ") == "Mac")
    }

    @Test func theCurrentLaptopNameFits() {
        let name = LaptopName.current()
        #expect(!name.isEmpty)
        #expect(name.utf8.count <= PhoneBridgeConstants.laptopNameMaxUTF8Bytes)
    }
}
