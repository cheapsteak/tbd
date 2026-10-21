import CryptoKit
import Darwin
import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "modChannel")

/// The credential a session mod presents to the daemon's channel socket.
///
/// A token is the lowercase-hex HMAC-SHA256 of a spawn's incarnation ID (its
/// uppercase canonical string) under a daemon key. An incarnation is minted
/// per spawn, so the token binds a request to one process in one terminal, and
/// because it is derived it survives a daemon restart with no stored state.
struct ModChannelToken: Sendable {
    static let keyByteCount = 32

    private let key: SymmetricKey

    init(key: SymmetricKey) {
        self.key = key
    }

    /// The process-wide token, loaded from `TBDConstants.modKeyPath` on first
    /// use. Nil when the key file cannot be read or created; the failure is
    /// logged once and spawns then go without a channel token.
    static let shared: ModChannelToken? = {
        let url = TBDConstants.modKeyPath
        do {
            return try loadOrCreate(at: url)
        } catch {
            logger.error("""
                mod channel: the key at \(url.path, privacy: .public) could not be \
                loaded: \(error.localizedDescription, privacy: .public)
                """)
            return nil
        }
    }()

    func token(incarnationID: UUID) -> String {
        Self.hex(Data(mac(incarnationID)))
    }

    /// True when `token` is this key's token for `incarnationID`. Compares in
    /// constant time; a token that is not hex of the right length is false.
    func verify(_ token: String, incarnationID: UUID) -> Bool {
        guard let presented = Self.data(fromHex: token),
              presented.count == SHA256.byteCount else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(
            presented,
            authenticating: Data(incarnationID.uuidString.utf8),
            using: key)
    }

    /// Reads the 32-byte key at `url`, creating it (and its directory) with
    /// mode 0600 when absent. A file of any other length is replaced.
    ///
    /// The file is created with `O_CREAT | O_EXCL` and mode 0600 in the one
    /// `open` call, so it is never readable by anyone else, not even for an
    /// instant, and never written through a file someone else created. If the
    /// file appears between the check and the create, the key it holds is used.
    static func loadOrCreate(at url: URL) throws -> ModChannelToken {
        let fileManager = FileManager.default
        if let existing = readKey(at: url) {
            return ModChannelToken(key: existing)
        }
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A file here has the wrong length: replace it.
        try? fileManager.removeItem(at: url)
        let fresh = SymmetricKey(size: .bits256)
        let bytes = fresh.withUnsafeBytes { Data($0) }
        let descriptor = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            let code = errno
            if code == EEXIST, let existing = readKey(at: url) {
                return ModChannelToken(key: existing)
            }
            throw posixError(code, url)
        }
        do {
            try writeAll(bytes, to: descriptor, url: url)
            guard fsync(descriptor) == 0 else { throw posixError(errno, url) }
        } catch {
            close(descriptor)
            unlink(url.path)
            throw error
        }
        guard close(descriptor) == 0 else {
            let code = errno
            unlink(url.path)
            throw posixError(code, url)
        }
        return ModChannelToken(key: fresh)
    }

    /// The key at `url` when the file holds exactly `keyByteCount` bytes.
    private static func readKey(at url: URL) -> SymmetricKey? {
        guard let data = FileManager.default.contents(atPath: url.path),
              data.count == keyByteCount else { return nil }
        return SymmetricKey(data: data)
    }

    private static func writeAll(_ bytes: Data, to descriptor: Int32, url: URL) throws {
        try bytes.withUnsafeBytes { (buffer: UnsafeRawBufferPointer) in
            guard let base = buffer.baseAddress else { return }
            var offset = 0
            while offset < buffer.count {
                let written = write(descriptor, base + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw posixError(errno, url)
                }
                offset += written
            }
        }
    }

    private static func posixError(_ code: Int32, _ url: URL) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain, code: Int(code),
            userInfo: [NSFilePathErrorKey: url.path])
    }

    private func mac(_ incarnationID: UUID) -> HMAC<SHA256>.MAC {
        HMAC<SHA256>.authenticationCode(
            for: Data(incarnationID.uuidString.utf8), using: key)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func data(fromHex string: String) -> Data? {
        let bytes = Array(string.utf8)
        guard bytes.count.isMultiple(of: 2) else { return nil }
        var out = Data(capacity: bytes.count / 2)
        func nibble(_ c: UInt8) -> UInt8? {
            switch c {
            case 0x30...0x39: return c - 0x30
            case 0x61...0x66: return c - 0x61 + 10
            case 0x41...0x46: return c - 0x41 + 10
            default: return nil
            }
        }
        var index = 0
        while index < bytes.count {
            guard let high = nibble(bytes[index]), let low = nibble(bytes[index + 1]) else { return nil }
            out.append(high << 4 | low)
            index += 2
        }
        return out
    }
}
