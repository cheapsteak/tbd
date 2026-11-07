import CryptoKit
import Darwin
import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "phone-bridge")

/// Why the laptop key file cannot be used.
///
/// Every case except `.io` and `.missing` describes a file that exists and
/// that the store leaves exactly as it found it. Each description names the
/// problem and the way out, because the Phone pane shows it as the reason
/// phone control is not running.
enum LaptopKeyStoreError: Error, Equatable, LocalizedError {
    /// There is no file, and the caller asked the store not to create one
    /// because phones are still paired with the key it held.
    case missing
    /// The file's permission bits (`mode & 0o777`) are not 0600.
    case permissionMismatch(mode: Int)
    /// The file belongs to another user.
    case ownerMismatch
    /// The file does not hold exactly 32 bytes.
    case malformed(byteCount: Int)
    /// The key path names a symbolic link, a folder or another kind of file
    /// that is not a regular file.
    case notARegularFile
    /// A system call failed. The text names the call, the path and the error.
    case io(String)

    var errorDescription: String? {
        switch self {
        case .missing:
            return "The laptop key file is missing, but phones are still paired with this laptop. "
                + "Restore it from a backup, or revoke every paired phone in Settings → Phone to start again."
        case .permissionMismatch(let mode):
            return "The laptop key file has mode \(Self.octal(mode)); it must be 0600. "
                + "Fix the mode or remove the file (this unpairs every phone)."
        case .ownerMismatch:
            return "The laptop key file belongs to another user; it must belong to you. "
                + "Fix its owner or remove the file (this unpairs every phone)."
        case .malformed(let byteCount):
            return "The laptop key file holds \(byteCount) bytes; it must hold 32. "
                + "Restore it from a backup or remove the file (this unpairs every phone)."
        case .notARegularFile:
            return "The laptop key file is a symbolic link or another kind of file, not a regular file. "
                + "Put the key file itself in its place or remove it (this unpairs every phone)."
        case .io(let detail):
            return "TBD could not read or create the laptop key file (\(detail)). "
                + "Check that your user owns TBD's phone folder and can write to it."
        }
    }

    /// `mode` as four octal digits, the way `ls` and `chmod` write it: 0644.
    private static func octal(_ mode: Int) -> String {
        let digits = String(mode, radix: 8)
        return String(repeating: "0", count: max(0, 4 - digits.count)) + digits
    }
}

/// The laptop's long-term X25519 private key, in one owner-only file
/// (`TBDConstants.phoneLaptopKeyPath`).
///
/// Every paired phone trusts this key's public half, so a new key unpairs
/// every phone. The store therefore creates the file only where none exists,
/// and never overwrites or regenerates a file that fails a check: a loosened
/// mode, a truncated write or a restore from backup is refused with a reason
/// the user can act on, and the file is left alone.
struct LaptopKeyStore: Sendable {
    static let keyByteCount = 32
    /// How many times a load reads again after another creator's file appeared
    /// first and then vanished before it could be read.
    private static let maxAttempts = 3

    let path: URL
    private let now: @Sendable () -> Date

    init(path: URL, now: @escaping @Sendable () -> Date = Date.init) {
        self.path = path
        self.now = now
    }

    /// The key at `path`, created on first use.
    ///
    /// 1. Removes temporary files that an interrupted create left more than
    ///    `PhoneBridgeConstants.keyTempMaxAge` ago.
    /// 2. Reads an existing file only after checking that it is a regular file
    ///    with mode 0600, owned by this user, holding 32 bytes. Any failed
    ///    check throws and writes nothing.
    /// 3. When there is no file and `createIfMissing` is false, throws
    ///    `.missing` and creates nothing. A caller with paired phones passes
    ///    false: a new key would unpair every one of them without a word.
    /// 4. Otherwise writes a new key, complete and synced, to a temporary file
    ///    and hard-links it into place. A link never replaces an existing file,
    ///    so when another creator wins the race, its key is read instead.
    func loadOrCreate(createIfMissing: Bool = true) throws -> Curve25519.KeyAgreement.PrivateKey {
        let directory = path.deletingLastPathComponent()
        sweepStaleTempFiles(in: directory)
        for _ in 0..<Self.maxAttempts {
            if let existing = try readExisting() {
                return existing
            }
            guard createIfMissing else {
                throw LaptopKeyStoreError.missing
            }
            if let created = try create(in: directory) {
                return created
            }
        }
        throw LaptopKeyStoreError.io("\(path.path) appeared and vanished \(Self.maxAttempts) times while it was being read")
    }

    // MARK: - Reading

    /// The key in the existing file, or nil when there is no file.
    ///
    /// The checks run on the open descriptor (`fstat`), so the file that is
    /// checked is the file that is read, whatever happens to the path in
    /// between. `O_NOFOLLOW` refuses a symbolic link at the key path rather
    /// than following it: the target's mode and owner would otherwise be the
    /// ones checked, and a link can point anywhere. `O_NONBLOCK` keeps a FIFO
    /// at the path from blocking the open; `fstat` then refuses it. A file
    /// the open is not allowed to read is described by
    /// `refusalForUnopenableFile(openError:)` instead.
    private func readExisting() throws -> Curve25519.KeyAgreement.PrivateKey? {
        let descriptor = Darwin.open(path.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT: return nil
            case ELOOP: throw LaptopKeyStoreError.notARegularFile
            case EACCES, EPERM: throw refusalForUnopenableFile(openError: code)
            default: throw Self.ioError("open", path.path, code)
            }
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            throw Self.ioError("fstat", path.path, code)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            throw LaptopKeyStoreError.notARegularFile
        }
        let mode = Int(info.st_mode & 0o777)
        guard mode == 0o600 else {
            throw LaptopKeyStoreError.permissionMismatch(mode: mode)
        }
        guard info.st_uid == getuid() else {
            throw LaptopKeyStoreError.ownerMismatch
        }
        guard info.st_size == Int64(Self.keyByteCount) else {
            throw LaptopKeyStoreError.malformed(byteCount: Int(info.st_size))
        }
        // One byte more than a key, so a file that grew after `fstat` is
        // still caught.
        let bytes = try Self.read(upTo: Self.keyByteCount + 1, from: descriptor, path: path.path)
        guard bytes.count == Self.keyByteCount,
              let key = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: bytes) else {
            throw LaptopKeyStoreError.malformed(byteCount: bytes.count)
        }
        return key
    }

    /// Why the key file could not be opened for reading (`EACCES` or
    /// `EPERM`), in the terms the checks on an open file use: a file that
    /// belongs to another user, or whose mode keeps its owner from reading
    /// it, gets the same refusal as one that opened. `lstat` describes the
    /// entry itself and never a link's target, and nothing is read, so no
    /// file can change between the check and a read. When the entry passes
    /// every check, or `lstat` fails too, the open's own error stands.
    private func refusalForUnopenableFile(openError openCode: Int32) -> LaptopKeyStoreError {
        var info = stat()
        guard lstat(path.path, &info) == 0 else {
            return Self.ioError("open", path.path, openCode)
        }
        guard (info.st_mode & S_IFMT) == S_IFREG else {
            return .notARegularFile
        }
        guard info.st_uid == getuid() else {
            return .ownerMismatch
        }
        let mode = Int(info.st_mode & 0o777)
        guard mode == 0o600 else {
            return .permissionMismatch(mode: mode)
        }
        return Self.ioError("open", path.path, openCode)
    }

    private static func read(upTo limit: Int, from descriptor: Int32, path: String) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: limit)
        var count = 0
        while count < limit {
            // `errno` is read inside the closure, right after the call, before
            // anything else can overwrite it.
            let (result, code): (Int, Int32) = buffer.withUnsafeMutableBytes { raw in
                let readCount = Darwin.read(descriptor, raw.baseAddress! + count, limit - count)
                return (readCount, readCount < 0 ? errno : 0)
            }
            if result < 0 {
                if code == EINTR { continue }
                throw ioError("read", path, code)
            }
            if result == 0 { break }
            count += result
        }
        return Data(buffer[0..<count])
    }

    // MARK: - Creating

    /// Writes a new key and links it into place. Nil when a file appeared at
    /// `path` first; the caller then reads that one.
    private func create(in directory: URL) throws -> Curve25519.KeyAgreement.PrivateKey? {
        let directoryDescriptor = try openOwnerOnlyDirectory(directory)
        defer { close(directoryDescriptor) }

        let key = Curve25519.KeyAgreement.PrivateKey()
        let tempPath = directory
            .appendingPathComponent(".\(path.lastPathComponent).\(UUID().uuidString).tmp").path
        try Self.writeSynced(key.rawRepresentation, toNewFileAt: tempPath)

        guard Darwin.link(tempPath, path.path) == 0 else {
            let code = errno
            unlink(tempPath)
            if code == EEXIST { return nil }
            throw Self.ioError("link", path.path, code)
        }
        unlink(tempPath)
        // Make the new name itself durable: a key that phones pair with and
        // that a crash then loses would unpair them all.
        fsync(directoryDescriptor)
        logger.notice("phone bridge: created the laptop key file")
        return key
    }

    /// Creates `directory` with mode 0700, or sets an existing one to 0700, and
    /// returns a descriptor for it. A symbolic link there is refused, so the
    /// mode change reaches TBD's own folder and nothing a link points to.
    private func openOwnerOnlyDirectory(_ directory: URL) throws -> Int32 {
        let parent = directory.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        } catch {
            throw LaptopKeyStoreError.io("create \(parent.path): \(error.localizedDescription)")
        }
        if mkdir(directory.path, 0o700) != 0 {
            let code = errno
            guard code == EEXIST else { throw Self.ioError("mkdir", directory.path, code) }
        }
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            if code == ELOOP {
                throw LaptopKeyStoreError.io("\(directory.path) is a symbolic link; it must be a folder")
            }
            throw Self.ioError("open", directory.path, code)
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw Self.ioError("fstat", directory.path, code)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw LaptopKeyStoreError.io("\(directory.path) is not a folder")
        }
        guard fchmod(descriptor, 0o700) == 0 else {
            let code = errno
            close(descriptor)
            throw Self.ioError("chmod", directory.path, code)
        }
        return descriptor
    }

    /// Creates `path`, which must not exist, with mode 0600, writes `bytes`
    /// and syncs them. On any failure the file is removed.
    ///
    /// `O_EXCL` refuses any existing entry, a symbolic link included, so the
    /// bytes never go through a file someone else made. `fchmod` sets 0600
    /// whatever the umask removed from the mode `open` asked for.
    private static func writeSynced(_ bytes: Data, toNewFileAt path: String) throws {
        let descriptor = Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            throw ioError("open", path, code)
        }
        do {
            guard fchmod(descriptor, 0o600) == 0 else {
                let code = errno
                throw ioError("chmod", path, code)
            }
            try writeAll(bytes, to: descriptor, path: path)
            guard fsync(descriptor) == 0 else {
                let code = errno
                throw ioError("fsync", path, code)
            }
        } catch {
            close(descriptor)
            unlink(path)
            throw error
        }
        guard close(descriptor) == 0 else {
            let code = errno
            unlink(path)
            throw ioError("close", path, code)
        }
    }

    private static func writeAll(_ bytes: Data, to descriptor: Int32, path: String) throws {
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw ioError("write", path, code)
                }
                offset += written
            }
        }
    }

    // MARK: - Leftovers

    /// Removes `.<key name>.*.tmp` files whose modification date is more than
    /// `PhoneBridgeConstants.keyTempMaxAge` before now. An interrupted create
    /// leaves one behind; a younger one may belong to a create still running.
    /// Best effort: a file that cannot be read or removed stays for the next
    /// load.
    private func sweepStaleTempFiles(in directory: URL) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let prefix = ".\(path.lastPathComponent)."
        let suffix = ".tmp"
        let cutoff = now().addingTimeInterval(-PhoneBridgeConstants.keyTempMaxAge)
        for name in names {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  name.count > prefix.count + suffix.count else { continue }
            let tempPath = directory.appendingPathComponent(name).path
            var info = stat()
            guard lstat(tempPath, &info) == 0 else { continue }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified < cutoff, unlink(tempPath) == 0 else { continue }
            logger.notice("phone bridge: removed a temporary laptop key file left by an interrupted create")
        }
    }

    private static func ioError(_ call: String, _ path: String, _ code: Int32) -> LaptopKeyStoreError {
        .io("\(call) \(path): \(String(cString: strerror(code)))")
    }
}
