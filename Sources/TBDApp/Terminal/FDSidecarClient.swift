import Darwin
import Foundation
import TBDShared
import os

enum FDSidecarError: Error {
    case connectFailed(Int32)
    case notConnected
    case timedOut
    case superseded      // a newer expectation for the same key replaced this one
    case disconnected    // sidecar socket EOF'd with waiters pending
}

/// App-side sidecar client: connects to the daemon's FD-vending socket and
/// runs one receive loop on a dedicated `Thread`. Each received fd carries a
/// JSON `FDVendHeader`; the loop delivers it to the waiter registered under
/// `header.routingKey`. Unmatched fds are closed and logged (stale vend after
/// a timed-out attach).
final class FDSidecarClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tbd.app", category: "fdVending")
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var waiters: [String: (Int32?, Error?) -> Void] = [:]

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return socketFD >= 0 }

    /// Connect to `path` and start the receive thread. Idempotent.
    func connect(path: String) throws {
        lock.lock()
        if socketFD >= 0 { lock.unlock(); return }
        lock.unlock()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw FDSidecarError.connectFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let sunPathSize = MemoryLayout.size(ofValue: addr.sun_path)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: sunPathSize) { dstChars in
                    _ = strlcpy(dstChars, src, sunPathSize)
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 { Darwin.close(fd); throw FDSidecarError.connectFailed(errno) }
        adopt(fd: fd)
    }

    /// Adopt a pre-connected socket (unit tests use a socketpair end).
    /// Ownership of `fd` transfers here. Idempotent while connected.
    func adopt(fd: Int32) {
        lock.lock()
        if socketFD >= 0 {
            lock.unlock()
            Darwin.close(fd)
            return
        }
        socketFD = fd
        lock.unlock()

        let thread = Thread { [weak self] in self?.receiveLoop(fd) }
        thread.name = "fd-sidecar-receive"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Register interest in the fd for (worktreeID, paneID) and return a
    /// promise. Registration is SYNCHRONOUS — call this BEFORE issuing
    /// `attach.request`, so the vended fd can never race past the waiter.
    /// A second expectation for the same key supersedes (fails) the first.
    func expectFD(worktreeID: UUID, paneID: String) -> FDPromise {
        let key = FDVendHeader(worktreeID: worktreeID, paneID: paneID).routingKey
        let promise = FDPromise()
        lock.lock()
        let old = waiters[key]
        waiters[key] = { fd, error in promise.settle(fd: fd, error: error) }
        lock.unlock()
        old?(nil, FDSidecarError.superseded)
        promise.onCancelOrTimeout = { [weak self] in self?.removeWaiter(key) }
        return promise
    }

    private func removeWaiter(_ key: String) {
        lock.lock(); waiters[key] = nil; lock.unlock()
    }

    private func receiveLoop(_ fd: Int32) {
        while true {
            guard let (rxFD, header) = try? FDChannel.receiveFD(from: fd, headerCapacity: 256) else { break }
            guard let hdr = try? JSONDecoder().decode(FDVendHeader.self, from: header) else {
                logger.error("sidecar: undecodable vend header, closing fd")
                Darwin.close(rxFD)
                continue
            }
            lock.lock()
            let waiter = waiters.removeValue(forKey: hdr.routingKey)
            lock.unlock()
            if let waiter {
                waiter(rxFD, nil)
            } else {
                logger.info("sidecar: no waiter for \(hdr.routingKey, privacy: .public) (stale vend), closing fd")
                Darwin.close(rxFD)
            }
        }
        // EOF: fail everything pending, mark disconnected (reconnect is a
        // Phase 7 crash-recovery concern).
        lock.lock()
        let pending = waiters; waiters = [:]
        socketFD = -1
        lock.unlock()
        Darwin.close(fd)
        for (_, waiter) in pending { waiter(nil, FDSidecarError.disconnected) }
        logger.info("sidecar receive loop exited")
    }
}

/// One-shot settlement cell bridging the receive thread to an async caller.
/// `settle` may be called from any thread; `value(timeout:)` is awaited once.
final class FDPromise: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Int32, Error>?
    private var continuation: CheckedContinuation<Int32, Error>?
    var onCancelOrTimeout: (() -> Void)?

    func settle(fd: Int32?, error: Error?) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            if let fd { Darwin.close(fd) }   // settled twice: drop the extra fd
            return
        }
        let result: Result<Int32, Error> = fd.map { .success($0) } ?? .failure(error ?? FDSidecarError.disconnected)
        outcome = result
        let cont = continuation; continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    /// Await the fd with a deadline. On timeout the waiter is deregistered and
    /// `FDSidecarError.timedOut` is thrown; a late-arriving fd is then closed
    /// by the receive loop's no-waiter path.
    func value(timeout: Duration) async throws -> Int32 {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.onCancelOrTimeout?()
            self?.settle(fd: nil, error: FDSidecarError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let outcome {
                lock.unlock()
                cont.resume(with: outcome)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func cancel() {
        onCancelOrTimeout?()
        settle(fd: nil, error: FDSidecarError.timedOut)
    }
}
