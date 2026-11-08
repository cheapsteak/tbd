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
///
/// The folder that holds the key is opened once per load and checked on its
/// descriptor. Every later call names the key and its temporary files by
/// their names in that descriptor (`openat`, `linkat`, `unlinkat`,
/// `fstatat`), never by a path, so the folder that was checked is the one
/// read, written and swept, whatever happens to its path in between.
struct LaptopKeyStore: Sendable {
    static let keyByteCount = 32
    /// How many times a load reads again after another creator's file appeared
    /// first and then vanished before it could be read.
    private static let maxAttempts = 3

    let path: URL
    private let now: @Sendable () -> Date
    /// Runs after the folder that will hold a new key has been checked and
    /// made owner-only, and before anything is written in it. A test replaces
    /// the folder there, to show that the writes still land in the folder
    /// that was checked.
    private let afterFolderCheck: (@Sendable () -> Void)?

    init(
        path: URL,
        now: @escaping @Sendable () -> Date = Date.init,
        afterFolderCheck: (@Sendable () -> Void)? = nil
    ) {
        self.path = path
        self.now = now
        self.afterFolderCheck = afterFolderCheck
    }

    /// The key at `path`, created on first use.
    ///
    /// 1. Opens the folder that holds the key, when there is one, refusing a
    ///    symbolic link there or anything that is not a folder.
    /// 2. Removes temporary files in it that an interrupted create left more
    ///    than `PhoneBridgeConstants.keyTempMaxAge` ago.
    /// 3. Reads an existing file only after checking that it is a regular file
    ///    with mode 0600, owned by this user, holding 32 bytes. Any failed
    ///    check throws and writes nothing.
    /// 4. When there is no file and `createIfMissing` is false, throws
    ///    `.missing` and creates nothing, not even the folder. A caller with
    ///    paired phones passes false: a new key would unpair every one of
    ///    them without a word.
    /// 5. Otherwise creates the folder if there is none, makes it owner-only,
    ///    writes a new key, complete and synced, to a temporary file and
    ///    hard-links it into place. A link never replaces an existing file,
    ///    so when another creator wins the race, its key is read instead.
    func loadOrCreate(createIfMissing: Bool = true) throws -> Curve25519.KeyAgreement.PrivateKey {
        let directory = path.deletingLastPathComponent()
        var folder = try openFolder(directory)
        defer { if let folder { close(folder) } }
        if let folder {
            sweepStaleTempFiles(in: folder)
        }
        for _ in 0..<Self.maxAttempts {
            if let folder, let existing = try readExisting(in: folder) {
                return existing
            }
            guard createIfMissing else {
                throw LaptopKeyStoreError.missing
            }
            let target = try folder ?? createFolder(directory)
            folder = target
            if let created = try create(in: target) {
                return created
            }
        }
        throw LaptopKeyStoreError.io("\(path.path) appeared and vanished \(Self.maxAttempts) times while it was being read")
    }

    // MARK: - The folder

    /// A descriptor for `directory`, or nil when there is none.
    ///
    /// `O_NOFOLLOW` refuses a symbolic link there, so what is checked, read
    /// and written is TBD's own folder and nothing a link points to.
    /// `O_DIRECTORY` refuses a plain file, a FIFO or any other kind of file
    /// at the open itself. Two second guards stay behind it: `O_NONBLOCK`
    /// keeps a FIFO from blocking the open, and `fstat` refuses anything
    /// that is not a folder.
    ///
    /// The open asks to read the folder, because the sweep lists it, so it
    /// needs read permission there and not only search: a folder at mode
    /// 0300 or 0100 is refused with "Permission denied", even when the key
    /// in it could be read by its path. TBD makes the folder at 0700 and
    /// `create(in:)` sets that mode again, so only a folder whose mode
    /// someone else changed is refused this way.
    private func openFolder(_ directory: URL) throws -> Int32? {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT: return nil
            case ELOOP: throw Self.symbolicLinkRefusal(directory)
            case ENOTDIR: throw Self.refusalForNonFolder(directory)
            default: throw Self.ioError("open", directory.path, code)
            }
        }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            let code = errno
            close(descriptor)
            throw Self.ioError("fstat", directory.path, code)
        }
        guard (info.st_mode & S_IFMT) == S_IFDIR else {
            close(descriptor)
            throw Self.notAFolderRefusal(directory)
        }
        return descriptor
    }

    /// Why `directory` could not be opened as a folder (`ENOTDIR`). XNU
    /// reports a symbolic link opened with `O_NOFOLLOW | O_DIRECTORY` as
    /// `ENOTDIR`, not `ELOOP`, so `lstat`, which describes the entry itself
    /// and never a link's target, tells a link from another kind of file.
    /// It only picks the message; nothing is opened or read. When `lstat`
    /// fails as well (a folder above it is not one), or the entry has become
    /// a folder since the open, the open's own error stands.
    private static func refusalForNonFolder(_ directory: URL) -> LaptopKeyStoreError {
        var info = stat()
        guard lstat(directory.path, &info) == 0 else {
            return ioError("open", directory.path, ENOTDIR)
        }
        switch info.st_mode & S_IFMT {
        case S_IFLNK: return symbolicLinkRefusal(directory)
        case S_IFDIR: return ioError("open", directory.path, ENOTDIR)
        default: return notAFolderRefusal(directory)
        }
    }

    private static func symbolicLinkRefusal(_ directory: URL) -> LaptopKeyStoreError {
        .io("\(directory.path) is a symbolic link; it must be a folder")
    }

    private static func notAFolderRefusal(_ directory: URL) -> LaptopKeyStoreError {
        .io("\(directory.path) is not a folder")
    }

    /// Creates `directory` with mode 0700, and its parent if needed, and
    /// opens it the way `openFolder` does. An existing folder is opened as
    /// it is; `create(in:)` sets its mode.
    private func createFolder(_ directory: URL) throws -> Int32 {
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
        guard let descriptor = try openFolder(directory) else {
            throw Self.ioError("open", directory.path, ENOENT)
        }
        return descriptor
    }

    // MARK: - Reading

    /// The key in the existing file in `folder`, or nil when there is none.
    ///
    /// The checks run on the open descriptor (`fstat`), so the file that is
    /// checked is the file that is read, whatever happens to its name in
    /// between. `O_NOFOLLOW` refuses a symbolic link at the key's name
    /// rather than following it: the target's mode and owner would otherwise
    /// be the ones checked, and a link can point anywhere. `O_NONBLOCK` keeps
    /// a FIFO there from blocking the open; `fstat` then refuses it. A file
    /// the open is not allowed to read is described by
    /// `refusalForUnopenableFile(in:openError:)` instead.
    private func readExisting(in folder: Int32) throws -> Curve25519.KeyAgreement.PrivateKey? {
        let descriptor = Darwin.openat(folder, path.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else {
            let code = errno
            switch code {
            case ENOENT: return nil
            case ELOOP: throw LaptopKeyStoreError.notARegularFile
            case EACCES, EPERM: throw refusalForUnopenableFile(in: folder, openError: code)
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

    /// Why the key file in `folder` could not be opened for reading
    /// (`EACCES` or `EPERM`), in the terms the checks on an open file use: a
    /// file that belongs to another user, or whose mode keeps its owner from
    /// reading it, gets the same refusal as one that opened. `fstatat` with
    /// `AT_SYMLINK_NOFOLLOW` describes the entry itself and never a link's
    /// target, and nothing is read, so no file can change between the check
    /// and a read. When the entry passes every check, or `fstatat` fails
    /// too, the open's own error stands.
    private func refusalForUnopenableFile(in folder: Int32, openError openCode: Int32) -> LaptopKeyStoreError {
        var info = stat()
        guard fstatat(folder, path.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
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

    /// Makes `folder` owner-only, writes a new key in it and links it into
    /// place. Nil when a file appeared at the key's name first; the caller
    /// then reads that one.
    ///
    /// Every call names the files by their names in `folder`, so the key
    /// lands in the folder that was checked even if that folder's path now
    /// leads somewhere else.
    private func create(in folder: Int32) throws -> Curve25519.KeyAgreement.PrivateKey? {
        let directory = path.deletingLastPathComponent()
        guard fchmod(folder, 0o700) == 0 else {
            let code = errno
            throw Self.ioError("chmod", directory.path, code)
        }
        afterFolderCheck?()

        let key = Curve25519.KeyAgreement.PrivateKey()
        let name = path.lastPathComponent
        let tempName = ".\(name).\(UUID().uuidString).tmp"
        try Self.writeSynced(
            key.rawRepresentation, toNewFileNamed: tempName, in: folder,
            path: directory.appendingPathComponent(tempName).path)

        guard linkat(folder, tempName, folder, name, 0) == 0 else {
            let code = errno
            unlinkat(folder, tempName, 0)
            if code == EEXIST { return nil }
            throw Self.ioError("link", path.path, code)
        }
        unlinkat(folder, tempName, 0)
        // Make the new name itself durable: a key that phones pair with and
        // that a crash then loses would unpair them all.
        fsync(folder)
        logger.notice("phone bridge: created the laptop key file")
        return key
    }

    /// Creates `name` in `folder`, where nothing may have that name yet, with
    /// mode 0600, writes `bytes` and syncs them. On any failure the file is
    /// removed. `path` names the file in error messages.
    ///
    /// `O_EXCL` refuses any existing entry, a symbolic link included, so the
    /// bytes never go through a file someone else made. `fchmod` sets 0600
    /// whatever the umask removed from the mode `openat` asked for.
    private static func writeSynced(
        _ bytes: Data, toNewFileNamed name: String, in folder: Int32, path: String
    ) throws {
        let descriptor = Darwin.openat(folder, name, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
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
            unlinkat(folder, name, 0)
            throw error
        }
        guard close(descriptor) == 0 else {
            let code = errno
            unlinkat(folder, name, 0)
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

    /// Removes `.<key name>.*.tmp` files in `folder` whose modification date
    /// is more than `PhoneBridgeConstants.keyTempMaxAge` before now. An
    /// interrupted create leaves one behind; a younger one may belong to a
    /// create still running. Best effort: a file that cannot be read or
    /// removed stays for the next load.
    private func sweepStaleTempFiles(in folder: Int32) {
        let prefix = ".\(path.lastPathComponent)."
        let suffix = ".tmp"
        let cutoff = now().addingTimeInterval(-PhoneBridgeConstants.keyTempMaxAge)
        for name in Self.names(in: folder) {
            guard name.hasPrefix(prefix), name.hasSuffix(suffix),
                  name.count > prefix.count + suffix.count else { continue }
            var info = stat()
            guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let modified = Date(
                timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
                    + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
            guard modified < cutoff, unlinkat(folder, name, 0) == 0 else { continue }
            logger.notice("phone bridge: removed a temporary laptop key file left by an interrupted create")
        }
    }

    /// The names in `folder`, or none when it cannot be listed. Every name is
    /// read before any file is removed, so no removal can make the listing
    /// skip a name.
    ///
    /// The listing owns the descriptor it reads and closes it, so it reads a
    /// second descriptor made with `F_DUPFD_CLOEXEC`, which also keeps that
    /// one out of any process the daemon starts meanwhile. The second
    /// descriptor is not independent: both share one open file, and so one
    /// offset, so reading the listing moves `folder`'s offset to the end too.
    /// No other call here reads at that offset (each names an entry relative
    /// to `folder`, or acts on the folder itself), but `fdopendir` lists from
    /// the current offset, so `rewinddir` puts it back at the start for any
    /// later listing of `folder`.
    private static func names(in folder: Int32) -> [String] {
        let copy = fcntl(folder, F_DUPFD_CLOEXEC, 0)
        guard copy >= 0 else { return [] }
        guard let listing = fdopendir(copy) else {
            close(copy)
            return []
        }
        defer {
            rewinddir(listing)
            closedir(listing)
        }
        var found: [String] = []
        while let entry = readdir(listing) {
            let length = Int(entry.pointee.d_namlen)
            var field = entry.pointee.d_name
            // A name that is not UTF-8 is no temporary key file's, so it is
            // left out rather than decoded into one that names another file.
            let name = withUnsafeBytes(of: &field) { bytes in
                String(bytes: bytes.prefix(length), encoding: .utf8)
            }
            if let name { found.append(name) }
        }
        return found
    }

    private static func ioError(_ call: String, _ path: String, _ code: Int32) -> LaptopKeyStoreError {
        .io("\(call) \(path): \(String(cString: strerror(code)))")
    }
}
