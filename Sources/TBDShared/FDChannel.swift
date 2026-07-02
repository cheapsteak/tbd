import Darwin
import Foundation

/// Errors raised by `FDChannel.sendFD` / `receiveFD`.
public enum FDChannelError: Error, Equatable {
    case sendFailed(Int32)          // errno from sendmsg or setup
    case receiveFailed(Int32)       // errno from recvmsg
    case peerClosed                 // clean EOF from the peer
    case noAncillaryData            // recvmsg succeeded but no SCM_RIGHTS attached
    case unexpectedControlLevel     // cmsg header wasn't SOL_SOCKET / SCM_RIGHTS
}

/// Structured header accompanying every vended pane fd (JSON-encoded into the
/// `sendmsg` payload). The composite (worktreeID, paneID) identity is what the
/// app-side receive loop uses to route a received fd to the right waiter —
/// bare pane IDs are only unique within one tmux server, and concurrent
/// attaches for different panes interleave on the single sidecar socket.
public struct FDVendHeader: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let paneID: String
    public init(worktreeID: UUID, paneID: String) {
        self.worktreeID = worktreeID
        self.paneID = paneID
    }
    /// Stable key used by both sides' demux maps.
    public var routingKey: String { "\(worktreeID.uuidString)/\(paneID)" }
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

    /// Send `fd` plus `header` over `socket`. On return, `fd` is still owned by
    /// the caller (the kernel duplicated it into the peer's fd table); it is
    /// safe — and usually correct — to `close(fd)` immediately after.
    public static func sendFD(_ fd: Int32, over socket: Int32, header: Data) throws {
        // Layout the ancillary buffer for exactly one fd.
        let controlLen = cmsgSpace(MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: controlLen)

        try header.withUnsafeBytes { headerBytes in
            try control.withUnsafeMutableBufferPointer { controlBuf in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: headerBytes.baseAddress),
                    iov_len: headerBytes.count)
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
            }
        }
    }

    /// Receive one fd + header from `socket`. `headerCapacity` sets the max
    /// header bytes the caller expects; larger senders will be truncated.
    /// Returned fd is owned by the caller and must be `close()`d.
    public static func receiveFD(from socket: Int32, headerCapacity: Int) throws -> (fd: Int32, header: Data) {
        let controlLen = cmsgSpace(MemoryLayout<Int32>.size)
        var control = [UInt8](repeating: 0, count: controlLen)
        var headerBuffer = [UInt8](repeating: 0, count: max(headerCapacity, 1))

        var receivedFD: Int32 = -1
        var receivedBytes = 0

        try headerBuffer.withUnsafeMutableBufferPointer { headerBuf in
            try control.withUnsafeMutableBufferPointer { controlBuf in
                var iov = iovec(iov_base: headerBuf.baseAddress, iov_len: headerBuf.count)
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

                guard let cmsg = firstControlHeader(in: msg) else {
                    throw FDChannelError.noAncillaryData
                }
                guard cmsg.pointee.cmsg_level == SOL_SOCKET,
                      cmsg.pointee.cmsg_type == SCM_RIGHTS else {
                    throw FDChannelError.unexpectedControlLevel
                }
                let fdPtr = controlData(cmsg).assumingMemoryBound(to: Int32.self)
                receivedFD = fdPtr.pointee
            }
        }

        return (fd: receivedFD, header: Data(headerBuffer.prefix(receivedBytes)))
    }
}
