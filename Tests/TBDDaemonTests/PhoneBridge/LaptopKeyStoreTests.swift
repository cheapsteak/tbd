import CryptoKit
import Darwin
import Foundation
import os
import Testing
import TBDShared
import TestSupport

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

    private func isFIFO(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFIFO
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

    /// While phones are paired, a missing key is an error, never a new key:
    /// a new one would unpair every phone without a word.
    @Test func aMissingKeyIsNotCreatedWhenCreationIsOff() throws {
        // No phone folder at all: none is made.
        let bare = Fixture()
        defer { bare.remove() }
        #expect(throws: LaptopKeyStoreError.missing) {
            _ = try LaptopKeyStore(path: bare.keyPath).loadOrCreate(createIfMissing: false)
        }
        #expect(!FileManager.default.fileExists(atPath: bare.phoneDir.path))

        // A phone folder holding only a stale leftover: the sweep still runs,
        // and no key and no temporary file are written.
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stale = fixture.phoneDir.appendingPathComponent(".laptop.key.A.tmp")
        try Data(repeating: 1, count: 32).write(to: stale)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: stale.path)

        #expect(throws: LaptopKeyStoreError.missing) {
            _ = try LaptopKeyStore(path: fixture.keyPath, now: { now }).loadOrCreate(createIfMissing: false)
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.keyPath.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.phoneDir.path) == [])
        let reason = LaptopKeyStoreError.missing.localizedDescription
        #expect(reason.contains("missing") && reason.contains("revoke every paired phone"))
    }

    /// Creators racing on one path all end up with the one key that was
    /// linked into place. A create that replaced the file instead (a rename)
    /// would hand different callers different keys.
    @Test func concurrentCreatorsAllReturnTheOneKeyThatWasLinked() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        // TBD's home exists before the bridge runs; the race under test is the
        // phone folder's and the key's.
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: true)
        let creators = 16
        let stores = (0..<creators).map { _ in LaptopKeyStore(path: fixture.keyPath) }
        let results = OSAllocatedUnfairLock(initialState: [Result<Data, any Error>]())

        DispatchQueue.concurrentPerform(iterations: creators) { index in
            let result: Result<Data, any Error> = Result { try stores[index].loadOrCreate().rawRepresentation }
            results.withLock { $0.append(result) }
        }

        let collected = results.withLock { $0 }
        #expect(collected.count == creators)
        let keys = try collected.map { try $0.get() }
        #expect(Set(keys).count == 1)
        #expect(try Data(contentsOf: fixture.keyPath) == keys.first)
        // Every loser removed its temporary file.
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

    /// A mode that keeps the owner from reading the file fails the open
    /// itself, and is still reported as the mode it is, not as an I/O error.
    @Test func anUnreadableModeIsRefusedAsAModeMismatch() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let store = LaptopKeyStore(path: fixture.keyPath)
        _ = try store.loadOrCreate()
        let originalBytes = try Data(contentsOf: fixture.keyPath)
        #expect(chmod(fixture.keyPath.path, 0o200) == 0)

        #expect(throws: LaptopKeyStoreError.permissionMismatch(mode: 0o200)) {
            _ = try store.loadOrCreate()
        }

        #expect(mode(of: fixture.keyPath) == 0o200)
        // Readable again only so the bytes can be compared.
        #expect(chmod(fixture.keyPath.path, 0o600) == 0)
        #expect(try Data(contentsOf: fixture.keyPath) == originalBytes)
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

    /// What the loading thread reported, read from the test's poll.
    private final class LoadProbe: @unchecked Sendable {
        private let lock = NSLock()
        private var _started = false
        private var _result: Result<Data, any Error>?

        var started: Bool { lock.withLock { _started } }
        var result: Result<Data, any Error>? { lock.withLock { _result } }

        func markStarted() { lock.withLock { _started = true } }
        func finish(_ value: Result<Data, any Error>) { lock.withLock { _result = value } }
    }

    /// What the bounded wait observed when it expired. Thrown so the
    /// diagnostic lands on the CI summary's primary failure line.
    private struct LoadDidNotReturn: Error, CustomStringConvertible {
        let started: Bool
        let elapsed: Duration
        var description: String {
            started
                ? "loadOrCreate started but had not returned after \(elapsed): it blocked "
                    + "opening a FIFO at the key path, so O_NONBLOCK is gone"
                : "the loading thread never got to run within \(elapsed): a scheduling "
                    + "starvation, not a blocked open"
        }
    }

    /// `open(2)` for reading on a FIFO with no writer never returns unless
    /// `O_NONBLOCK` is set. The load runs on a dedicated thread behind a
    /// bounded wait, so a regression fails this test instead of hanging the
    /// suite; the bound is a hang guard, not the assertion, because a blocked
    /// open never returns at all. If it does block, the test opens the write
    /// end to release the stuck open.
    @Test func aFIFOAtTheKeyPathIsRefusedWithoutBlocking() async throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        try fixture.makePhoneDir()
        let made = mkfifo(fixture.keyPath.path, 0o600)
        let code = errno
        try #require(made == 0, Comment(rawValue: "mkfifo failed: \(String(cString: strerror(code)))"))

        let store = LaptopKeyStore(path: fixture.keyPath)
        let probe = LoadProbe()
        let started = ContinuousClock.now
        let worker = Thread {
            probe.markStarted()
            probe.finish(Result { try store.loadOrCreate().rawRepresentation })
        }
        worker.name = "laptop-key-fifo-probe"
        worker.start()

        let outcome = await pollUntilTrue(
            timeout: TestDeadlines.saturatedPass, pollInterval: .milliseconds(20)
        ) { @Sendable in
            probe.result != nil
        }
        if outcome == .timedOut {
            let didStart = probe.started
            let writeEnd = open(fixture.keyPath.path, O_WRONLY | O_NONBLOCK)
            if writeEnd >= 0 { close(writeEnd) }
            Issue.record(LoadDidNotReturn(started: didStart, elapsed: ContinuousClock.now - started))
            return
        }
        guard outcome == .satisfied, let result = probe.result else { return }

        #expect(throws: LaptopKeyStoreError.notARegularFile) {
            _ = try result.get()
        }
        #expect(isFIFO(fixture.keyPath))
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

    /// The sweep matches temporary names only: a key older than the
    /// temporary-file age limit is the key, and it stays.
    @Test func theStaleTempSweepSparesAnOldKey() throws {
        let fixture = Fixture()
        defer { fixture.remove() }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = LaptopKeyStore(path: fixture.keyPath, now: { now })
        let first = try store.loadOrCreate()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-120)], ofItemAtPath: fixture.keyPath.path)

        let again = try store.loadOrCreate()

        #expect(FileManager.default.fileExists(atPath: fixture.keyPath.path))
        #expect(again.rawRepresentation == first.rawRepresentation)
        #expect(try Data(contentsOf: fixture.keyPath) == first.rawRepresentation)
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
