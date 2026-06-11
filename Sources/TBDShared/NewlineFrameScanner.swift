import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Accumulates recv chunks and scans only new bytes for a 0x0A newline delimiter,
/// eliminating the O(n²/chunk) re-scan that `Data.contains` / `Data.firstIndex(of:)`
/// triggers when the full accumulated buffer is re-walked after every recv call.
///
/// The caller appends each chunk immediately after recv; `memchr` inspects only
/// those new bytes. The absolute newline index is recorded on first hit so
/// subsequent appends (which callers should avoid after `hasNewline` is true)
/// do not re-scan.
///
/// Connection-closed semantics (no newline received before EOF):
/// `frameData` returns the entire accumulated buffer when `newlineIndex` is nil,
/// matching the original read-loop behavior where the post-loop `firstIndex(of:)`
/// found nothing and the full buffer was decoded as-is.
///
/// Usage:
/// ```swift
/// var scanner = NewlineFrameScanner()
/// while !scanner.hasNewline {
///     let n = recv(fd, buf, bufSize, 0)
///     guard n > 0 else { break }
///     scanner.append(buf, count: n)
/// }
/// let frame = scanner.frameData   // bytes before first newline, or all bytes if none
/// ```
public struct NewlineFrameScanner: Sendable {
    public private(set) var buffer = Data()
    /// Absolute byte offset of the first 0x0A found, or nil if no newline yet.
    public private(set) var newlineIndex: Int?

    public init() {}

    /// Append `count` bytes starting at `ptr`, scanning only the new bytes for 0x0A.
    ///
    /// Returns `true` if a newline has been found (in this chunk or a prior one).
    @discardableResult
    public mutating func append(_ ptr: UnsafePointer<UInt8>, count: Int) -> Bool {
        guard count > 0 else { return newlineIndex != nil }
        guard newlineIndex == nil else {
            // Newline already found — keep accumulating so the buffer stays coherent
            // for callers that inspect it after the loop, but skip the scan.
            buffer.append(ptr, count: count)
            return true
        }
        let baseOffset = buffer.count
        buffer.append(ptr, count: count)
        // Scan only the just-received bytes via memchr (single pass, no iterator).
        if let found = memchr(UnsafeRawPointer(ptr), Int32(0x0A), count) {
            newlineIndex = baseOffset + UnsafeRawPointer(ptr).distance(to: found)
            return true
        }
        return false
    }

    /// Convenience overload accepting `Data` (for testing and callers that already
    /// hold a `Data` value rather than a raw pointer).
    @discardableResult
    public mutating func append(data: Data) -> Bool {
        guard !data.isEmpty else { return newlineIndex != nil }
        return data.withUnsafeBytes { rawBuf -> Bool in
            guard let ptr = rawBuf.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return newlineIndex != nil
            }
            return append(ptr, count: rawBuf.count)
        }
    }

    /// `true` when a 0x0A byte has been observed.
    public var hasNewline: Bool { newlineIndex != nil }

    /// The framed response bytes — everything before the first newline.
    ///
    /// When no newline was received (connection closed without delimiter),
    /// returns the entire accumulated buffer so the caller can attempt to
    /// decode whatever partial frame arrived, matching the original semantics
    /// where a post-loop `firstIndex(of:)` finding nothing left the buffer intact.
    public var frameData: Data {
        if let idx = newlineIndex {
            return buffer[buffer.startIndex..<(buffer.startIndex + idx)]
        }
        return buffer
    }
}
