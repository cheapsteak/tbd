import Darwin
import Foundation

/// Errors raised by `FDChannel.sendFD` / `sendData` / `receiveMessage`.
public enum FDChannelError: LocalizedError, Equatable {
    case sendFailed(Int32)          // errno from sendmsg/write or setup
    case receiveFailed(Int32)       // errno from recvmsg
    case peerClosed                 // clean EOF from the peer
    case emptyPayload               // sendFDMinimal with nothing to carry the fd

    public var errorDescription: String? {
        switch self {
        case .sendFailed(let code):
            return "fd channel send failed: errno \(code) (\(Self.errnoText(code)))"
        case .receiveFailed(let code):
            return "fd channel receive failed: errno \(code) (\(Self.errnoText(code)))"
        case .peerClosed:
            return "fd channel peer closed the connection (clean EOF)"
        case .emptyPayload:
            return "fd channel send needs at least one payload byte to carry the descriptor"
        }
    }

    private static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}

/// Structured header accompanying every vended pane fd (JSON-encoded into the
/// `sendmsg` payload). The composite (worktreeID, paneID, attachID) identity
/// is what the app-side receive loop uses to route a received fd to the right
/// waiter — bare pane IDs are only unique within one tmux server, concurrent
/// attaches for different panes interleave on the single sidecar socket, and
/// `attachID` (a per-request nonce the app mints and the daemon echoes)
/// prevents a superseded attach's stale fd from being delivered to a fresh
/// attach for the SAME pane that raced it.
public struct FDVendHeader: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let paneID: String
    public let attachID: UUID
    public init(worktreeID: UUID, paneID: String, attachID: UUID) {
        self.worktreeID = worktreeID
        self.paneID = paneID
        self.attachID = attachID
    }
    /// Stable key used by both sides' demux maps.
    public var routingKey: String { "\(worktreeID.uuidString)/\(paneID)/\(attachID.uuidString)" }
}

/// Stateless helpers for handing a single file descriptor plus a small header
/// across a Unix stream socket, using `sendmsg`/`recvmsg` + `SCM_RIGHTS`.
///
/// The header travels in the message payload (not the ancillary data). Callers
/// choose their own header encoding — Phase 2 uses JSON `FDVendHeader` —
/// the channel itself does not interpret it.
public enum FDChannel {

    // MARK: CMSG_* macro equivalents

    // Darwin's CMSG_SPACE / CMSG_LEN / CMSG_FIRSTHDR / CMSG_DATA are
    // function-like C macros, which Swift does not import ("function like
    // macros not supported"). These reimplement <sys/socket.h>'s definitions,
    // which align on 32-bit boundaries via __DARWIN_ALIGN32.

    /// `__DARWIN_ALIGN32`: round `length` up to a 4-byte boundary.
    private static func align32(_ length: Int) -> Int {
        let mask = MemoryLayout<UInt32>.size - 1
        return (length + mask) & ~mask
    }

    /// `CMSG_SPACE(l)`: total ancillary buffer space for `l` data bytes.
    private static func cmsgSpace(_ dataLength: Int) -> Int {
        align32(MemoryLayout<cmsghdr>.size) + align32(dataLength)
    }

    /// `CMSG_LEN(l)`: value for `cmsg_len` covering `l` data bytes.
    private static func cmsgLen(_ dataLength: Int) -> Int {
        align32(MemoryLayout<cmsghdr>.size) + dataLength
    }

    /// `CMSG_FIRSTHDR(mhdr)`: first control message, or nil when the message
    /// carries no (complete) ancillary data.
    private static func firstControlHeader(in msg: msghdr) -> UnsafeMutablePointer<cmsghdr>? {
        guard Int(msg.msg_controllen) >= MemoryLayout<cmsghdr>.size else { return nil }
        return msg.msg_control?.assumingMemoryBound(to: cmsghdr.self)
    }

    /// `CMSG_DATA(cmsg)`: pointer to the control message's data bytes.
    private static func controlData(_ cmsg: UnsafeMutablePointer<cmsghdr>) -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer(cmsg) + align32(MemoryLayout<cmsghdr>.size)
    }

    /// Send `fd` alongside `frame` (the full length-prefixed frame bytes) over
    /// `socket` in a single `sendmsg`. On return, `fd` is still owned by the
    /// caller (the kernel duplicated it into the peer's fd table); it is safe —
    /// and usually correct — to `close(fd)` immediately after.
    ///
    /// SCM_RIGHTS ancillary data is associated with the first byte of `frame`,
    /// so the receiver observes the fd on the `recvmsg` that reads that byte,
    /// regardless of how the stream later re-chunks the frame.
    public static func sendFD(_ fd: Int32, over socket: Int32, frame: Data) throws {
        // Layout the ancillary buffer for exactly one fd.
        let controlLen = cmsgSpace(MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: controlLen)

        try frame.withUnsafeBytes { frameBytes in
            try control.withUnsafeMutableBufferPointer { controlBuf in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: frameBytes.baseAddress),
                    iov_len: frameBytes.count)
                var msg = msghdr()
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = UnsafeMutableRawPointer(controlBuf.baseAddress)
                    msg.msg_controllen = socklen_t(controlLen)

                    let cmsg = firstControlHeader(in: msg)!
                    cmsg.pointee.cmsg_len = socklen_t(cmsgLen(MemoryLayout<Int32>.size))
                    cmsg.pointee.cmsg_level = SOL_SOCKET
                    cmsg.pointee.cmsg_type = SCM_RIGHTS
                    let fdPtr = controlData(cmsg).assumingMemoryBound(to: Int32.self)
                    fdPtr.pointee = fd
                }

                let sent = withUnsafeMutablePointer(to: &msg) { sendmsg(socket, $0, 0) }
                if sent < 0 { throw FDChannelError.sendFailed(errno) }
                // A short sendmsg is POSIX-legal (R10-minor): the ancillary
                // fd rides whatever prefix landed, so send the REMAINDER of
                // the frame through the same full-write loop `sendData` uses
                // — otherwise the peer's scanner sees a truncated frame and
                // desyncs, the exact bug class sendData already closes.
                if sent < frameBytes.count {
                    try sendData(Data(frame.dropFirst(sent)), over: socket)
                }
            }
        }
    }

    /// Send `fd` over `socket` carrying exactly one byte of `payload`, then
    /// write the remainder with a plain full-write loop.
    ///
    /// Why one byte and not the whole frame: `sendmsg` with an `SCM_RIGHTS`
    /// control block has been observed failing with `EMSGSIZE` at payload sizes
    /// the man page permits, and an empty payload fails too. One byte is the
    /// size known to work, which is why an empty payload is a named error here
    /// rather than a silent no-op — a caller with nothing to say still needs a
    /// byte for the descriptor to ride on.
    ///
    /// The fd is never re-sent for the remainder: a second `sendmsg` carrying
    /// the same `SCM_RIGHTS` block would materialize a *duplicate* descriptor
    /// in the recipient, which then leaks (it is a second reference to the same
    /// open file, so closing one keeps the pty master alive). `sendFD` already
    /// handles a short `sendmsg` the same way, by sending only the remaining
    /// bytes through `sendData`.
    ///
    /// Like `sendFD`, `fd` remains the caller's to close on return.
    public static func sendFDMinimal(_ fd: Int32, over socket: Int32, payload: Data) throws {
        guard let first = payload.first else {
            throw FDChannelError.emptyPayload
        }
        try sendFD(fd, over: socket, frame: Data([first]))
        if payload.count > 1 {
            try sendData(payload.dropFirst(), over: socket)
        }
    }

    /// Write all of `data` to `socket` with a full-write loop (handling partial
    /// writes and `EINTR`). For frames that carry no fd — the app → daemon input
    /// path and any daemon → app control bytes.
    public static func sendData(_ data: Data, over socket: Int32) throws {
        if data.isEmpty { return }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let n = Darwin.write(socket, base + offset, raw.count - offset)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw FDChannelError.sendFailed(errno)
                }
                if n == 0 { throw FDChannelError.sendFailed(EIO) }
                offset += n
            }
        }
    }

    /// Receive one datagram-ish chunk plus any `SCM_RIGHTS` fds from `socket`.
    /// `capacity` bounds the data bytes read per call (the frame scanner
    /// reassembles across calls). On a stream socket, `recvmsg` will not read
    /// across an ancillary-data boundary, so at most the fd(s) sent with one
    /// `sendmsg` are returned per call, in send order.
    ///
    /// Returned fds are owned by the caller and must be `close()`d. Throws
    /// `.peerClosed` on clean EOF, `.receiveFailed` on error.
    public static func receiveMessage(from socket: Int32, capacity: Int) throws -> (data: Data, fds: [Int32]) {
        let controlLen = cmsgSpace(MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: controlLen)
        var dataBuffer = [UInt8](repeating: 0, count: max(capacity, 1))

        var fds: [Int32] = []
        var receivedBytes = 0

        try dataBuffer.withUnsafeMutableBufferPointer { dataBuf in
            try control.withUnsafeMutableBufferPointer { controlBuf in
                var iov = iovec(iov_base: dataBuf.baseAddress, iov_len: dataBuf.count)
                var msg = msghdr()
                let result = withUnsafeMutablePointer(to: &iov) { iovPtr -> ssize_t in
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = UnsafeMutableRawPointer(controlBuf.baseAddress)
                    msg.msg_controllen = socklen_t(controlLen)
                    return withUnsafeMutablePointer(to: &msg) { recvmsg(socket, $0, 0) }
                }
                if result < 0 { throw FDChannelError.receiveFailed(errno) }
                if result == 0 { throw FDChannelError.peerClosed }
                receivedBytes = Int(result)

                if let cmsg = firstControlHeader(in: msg),
                   cmsg.pointee.cmsg_level == SOL_SOCKET,
                   cmsg.pointee.cmsg_type == SCM_RIGHTS {
                    let dataBytes = Int(cmsg.pointee.cmsg_len) - align32(MemoryLayout<cmsghdr>.size)
                    let fdCount = max(0, dataBytes / MemoryLayout<Int32>.size)
                    let fdPtr = controlData(cmsg).assumingMemoryBound(to: Int32.self)
                    for i in 0..<fdCount { fds.append(fdPtr[i]) }
                }
            }
        }

        return (data: Data(dataBuffer.prefix(receivedBytes)), fds: fds)
    }
}
