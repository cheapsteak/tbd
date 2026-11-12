import CryptoKit
import Darwin
import Foundation

/// Evidence for one complete typed JSONL record in one regular file. Provider
/// interpretation belongs to the caller; this layer only binds bytes to a file.
struct BoundedJSONLRecordProof: Sendable, Equatable {
    let path: String
    private let device: dev_t
    private let inode: ino_t
    private let birthSeconds: Int
    private let birthNanoseconds: Int
    private let recordType: String
    private let digest: Data

    /// A growing transcript does not invalidate its metadata. Replacement of
    /// the file, or any change to the first matching record, does.
    func isCurrent() -> Bool {
        Self.read(path: path, recordType: recordType)?.proof == self
    }

    /// Bound both memory and I/O, including inside a database writer. A header
    /// beyond the first MiB is unproven; callers can retry a later observation.
    /// Only newline-terminated records count, so a concurrent partial append
    /// cannot become evidence. Malformed records before the header are skipped.
    static func read(path: String, recordType: String) -> (proof: Self, record: [String: Any])? {
        guard path.hasPrefix("/") else { return nil }
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        // NONBLOCK keeps a FIFO supplied in place of a rollout from parking the
        // database writer before fstat can reject it.
        let descriptor = open(standardizedPath, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let byteLimit = 1_048_576
        var remaining = byteLimit
        var pending = Data()
        do {
            while remaining > 0,
                  let chunk = try handle.read(upToCount: min(16_384, remaining)), !chunk.isEmpty {
                remaining -= chunk.count
                pending.append(chunk)
                while let newline = pending.firstIndex(of: 0x0A) {
                    let line = Data(pending[..<newline])
                    pending.removeSubrange(...newline)
                    guard let record = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          record["type"] as? String == recordType else { continue }
                    // Confirm the path still names the opened file, rather than
                    // a successor installed while its header was being read.
                    var current = stat()
                    guard stat(standardizedPath, &current) == 0,
                          current.st_dev == info.st_dev, current.st_ino == info.st_ino,
                          current.st_birthtimespec.tv_sec == info.st_birthtimespec.tv_sec,
                          current.st_birthtimespec.tv_nsec == info.st_birthtimespec.tv_nsec else { return nil }
                    return (Self(path: standardizedPath, device: info.st_dev, inode: info.st_ino,
                                 birthSeconds: info.st_birthtimespec.tv_sec,
                                 birthNanoseconds: info.st_birthtimespec.tv_nsec,
                                 recordType: recordType, digest: Data(SHA256.hash(data: line))), record)
                }
            }
        } catch {
            return nil
        }
        return nil
    }
}

typealias CodexRolloutProof = BoundedJSONLRecordProof
