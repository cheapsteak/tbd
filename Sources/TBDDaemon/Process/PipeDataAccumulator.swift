import Foundation

/// Thread-safe accumulator for incremental pipe reads.
///
/// Invariant: the readability handler's read and the corresponding append
/// happen under the same lock as `finish`. This prevents `terminationHandler`
/// from snapshotting between a readability handler's read and its append,
/// which would silently drop the in-flight chunk.
///
/// `finish` deliberately never blocks waiting for EOF: if the child forked
/// background grandchildren (a login shell's rc files often do), they inherit
/// the pipe write end and EOF never arrives after the direct child dies. A
/// blocking read-to-EOF would park a thread — and retain the pipe FD and every
/// captured closure — for the grandchildren's lifetime. Instead `finish`
/// drains only what is already buffered in the kernel pipe (non-blocking) and
/// closes the parent's read end, so nothing outlives the call.
///
/// Package-internal (not `private`) so `TmuxManager.runExternalCommand` shares
/// it — same >64KB drain deadlock, same grandchild-holds-write-end leak, same
/// fix (mirrors the shared `ContinuationGuard`).
final class PipeDataAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var finished = false

    /// Reads any available data from `handle` and appends it atomically.
    /// Returns `false` on EOF or after `finish` closed the handle (so the
    /// caller detaches the readability handler), `true` otherwise.
    func readAvailable(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        let chunk = handle.availableData
        if chunk.isEmpty {
            return false
        }
        data.append(chunk)
        return true
    }

    /// `readAvailable`'s raw-`read(2)` twin, for a descriptor that is not a
    /// pipe. A pseudo-terminal primary returns -1/EIO — not 0 — once the last
    /// holder of the replica exits, and `FileHandle.availableData` turns that
    /// errno into an Objective-C `NSFileHandleOperationException`, which Swift
    /// cannot catch and which would abort the daemon. Reading the descriptor
    /// directly keeps EOF a return value.
    func readAvailableRaw(from handle: FileHandle) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return false }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        let count = read(handle.fileDescriptor, &chunk, chunk.count)
        if count > 0 {
            data.append(contentsOf: chunk.prefix(count))
            return true
        }
        if count < 0 && (errno == EINTR || errno == EAGAIN) { return true }
        // 0 = EOF; -1/EIO = the replica's last holder exited. Either way there
        // is nothing more to wait for.
        return false
    }

    /// Drains whatever is already buffered in the pipe WITHOUT blocking,
    /// closes the parent's read end, and returns the full accumulated buffer.
    /// On the termination path the direct child is dead, so everything it
    /// wrote is already in the kernel pipe buffer and the non-blocking read
    /// loop loses nothing. On the timeout and spawn-failure paths the child
    /// may still be alive (or wedged, SIGKILL-immune); anything it writes
    /// after this snapshot is intentionally dropped — the call is already
    /// failing, and waiting for EOF is exactly the leak this exists to avoid.
    /// Acquiring the lock blocks until any in-flight `readAvailable` call has
    /// completed its append (and prevents it from touching the closed handle
    /// afterwards). Idempotent: later calls return the buffer untouched.
    func finish(handle: FileHandle) -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard !finished else { return data }
        finished = true
        let fd = handle.fileDescriptor
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
        var chunk = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(fd, &chunk, chunk.count)
            if count > 0 {
                data.append(contentsOf: chunk.prefix(count))
            } else if count < 0 && errno == EINTR {
                continue
            } else {
                // 0 = EOF; -1/EAGAIN = drained all buffered data. Either way
                // the writer can add nothing we are obliged to wait for.
                break
            }
        }
        try? handle.close()
        return data
    }
}
