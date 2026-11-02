import Darwin

/// The descriptor in this process that is the write end of the pipe whose read
/// end is descriptor `readEnd` of process `readerPID`, or `nil` when there is
/// none.
///
/// For a test that has to read a property of a write end the code under test
/// keeps to itself (`F_GETNOSIGPIPE`, most often) and can reach only the other
/// end: the read end a call returned, or a child's standard input. libproc
/// reports, for each pipe descriptor, an opaque handle for its own end and one
/// for its peer (`pipe_info.pipe_handle` and `pipe_peerhandle`, the pair `lsof`
/// prints as `->0x…`), so the write end is the pipe descriptor here whose own
/// handle is the read end's peer.
///
/// **Both ends must stay open from the first libproc query to the last**, and
/// the callers guarantee it by holding them: the test holds the read end, or
/// the child holds it as its blocked stdin, and the code under test holds the
/// write end. A handle names a live kernel pipe, and while both ends are open
/// no other pipe can have it, so the match is exact rather than a guess from
/// descriptor numbers. Close either end in that window and the kernel can hand
/// the freed pipe's handle to a new one, which this could then return.
///
/// **Each end's direction is checked**, from the open-file flags libproc
/// reports with it (`proc_fileinfo.fi_openflags`). That works for a child's
/// descriptor as well as for one in this process, so `readEnd` must be open
/// for reading only and the match for writing only, or the result is `nil`.
///
/// A descriptor another suite closes or opens while this runs costs one failed
/// query and is skipped. `readerPID` may be a child of this process: libproc
/// answers for any process of the same user.
///
/// - Returns: `nil` when `readEnd` is not a pipe's read end in `readerPID`, when
///   its write end has closed, or when no descriptor in this process holds that
///   end.
public func pipeWriteEnd(peerOf readEnd: Int32, inProcess readerPID: pid_t = getpid()) -> Int32? {
    let infoSize = Int32(MemoryLayout<pipe_fdinfo>.stride)
    var readInfo = pipe_fdinfo()
    guard proc_pidfdinfo(readerPID, readEnd, PROC_PIDFDPIPEINFO, &readInfo, infoSize) == infoSize,
          openDirection(of: readInfo) == .readOnly else {
        return nil
    }
    let peer = readInfo.pipeinfo.pipe_peerhandle
    guard peer != 0 else { return nil }

    let ourPID = getpid()
    // The kernel's size for the list already has room to spare; the extra
    // entries cover descriptors other suites open between the two calls.
    let estimate = proc_pidinfo(ourPID, PROC_PIDLISTFDS, 0, nil, 0)
    guard estimate > 0 else { return nil }
    let entrySize = MemoryLayout<proc_fdinfo>.stride
    var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimate) / entrySize + 64)
    let filled = entries.withUnsafeMutableBytes { buffer in
        proc_pidinfo(ourPID, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
    }
    guard filled > 0 else { return nil }
    for entry in entries.prefix(Int(filled) / entrySize) where entry.proc_fdtype == UInt32(PROX_FDTYPE_PIPE) {
        var info = pipe_fdinfo()
        guard proc_pidfdinfo(ourPID, entry.proc_fd, PROC_PIDFDPIPEINFO, &info, infoSize) == infoSize else {
            continue
        }
        if info.pipeinfo.pipe_handle == peer {
            return openDirection(of: info) == .writeOnly ? entry.proc_fd : nil
        }
    }
    return nil
}

private enum OpenDirection {
    case readOnly
    case writeOnly
    case other
}

/// Which way a pipe descriptor was opened, from the kernel's `FREAD` (0x1) and
/// `FWRITE` (0x2) bits in `fi_openflags`. Spelled out as literals rather than
/// imported, because `sys/fcntl.h` defines the two names only outside strict
/// POSIX mode.
private func openDirection(of info: pipe_fdinfo) -> OpenDirection {
    let canRead = (info.pfi.fi_openflags & 0x1) != 0
    let canWrite = (info.pfi.fi_openflags & 0x2) != 0
    switch (canRead, canWrite) {
    case (true, false): return .readOnly
    case (false, true): return .writeOnly
    default: return .other
    }
}
