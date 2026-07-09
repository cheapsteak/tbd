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
    /// Serial queue for app → daemon input frames. Keeps `sendInput` off the
    /// caller's thread (SwiftTerm calls it on the main thread) and serializes
    /// writes so two frames never interleave on the socket.
    private let sendQueue = DispatchQueue(label: "fd-sidecar-send")

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
        path.withCString { src in
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

    /// Register interest in the fd for (worktreeID, paneID, attachID) and
    /// return a promise. Registration is SYNCHRONOUS — call this BEFORE
    /// issuing `attach.request`, so the vended fd can never race past the
    /// waiter. The attachID nonce makes the key unique per request, so two
    /// in-flight attaches for the same pane each get exactly their own fd.
    func expectFD(worktreeID: UUID, paneID: String, attachID: UUID) -> FDPromise {
        let key = FDVendHeader(worktreeID: worktreeID, paneID: paneID, attachID: attachID).routingKey
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

    /// Send keystroke `bytes` for a pane to the daemon as an `.input`
    /// frame. Never blocks the caller: encodes inline (cheap) then enqueues the
    /// write on `sendQueue`. Errors — including a disconnected socket — are
    /// logged and dropped; the receive loop's EOF path handles daemon death and
    /// Phase B owns reconnect.
    func sendInput(worktreeID: UUID, paneID: String, bytes: Data) {
        // Defense-in-depth cap (R6-H3), mirroring `sendPaste`'s guard: a
        // single `.input` frame that couldn't fit the daemon scanner's 4 MiB
        // hard cap would desync the ONE app-wide sidecar connection and kill
        // control-mode input everywhere (no Phase A reconnect). Keystrokes
        // are tiny — anything near the cap is a bug or abuse upstream (the
        // drag-drop and paste paths both route through PasteInterception),
        // so refusing is strictly safer than writing.
        guard bytes.count <= SidecarFrameCodec.maxPasteBytes else {
            logger.fault("""
                sidecar: sendInput payload \(bytes.count, privacy: .public) bytes exceeds cap \
                \(SidecarFrameCodec.maxPasteBytes, privacy: .public), dropping (input this large is a routing bug)
                """)
            return
        }
        let frame: Data
        do {
            frame = try SidecarFrameCodec.encodeInput(
                header: SidecarInputHeader(worktreeID: worktreeID, paneID: paneID), bytes: bytes)
        } catch {
            logger.error("sidecar: failed to encode input frame, dropping \(bytes.count, privacy: .public) bytes")
            return
        }
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let fd = self.socketFD; self.lock.unlock()
            guard fd >= 0 else {
                self.logger.error("sidecar: sendInput while disconnected, dropping \(bytes.count, privacy: .public) bytes")
                return
            }
            do {
                try FDChannel.sendData(frame, over: fd)
            } catch {
                self.logger.error("sidecar: input send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Send bulk paste `bytes` for a pane to the daemon as a `.paste` frame (the
    /// paste ruling v2: every control-mode paste rides this path). Same serial
    /// `sendQueue` + inline-encode pattern as `sendInput`, so a paste and a
    /// following keystroke stay FIFO-ordered on the wire. Oversize payloads are
    /// dropped defensively — the view-level `PasteInterception` gate already
    /// refuses them before they reach here.
    func sendPaste(worktreeID: UUID, paneID: String, bytes: Data) {
        guard bytes.count <= SidecarFrameCodec.maxPasteBytes else {
            logger.fault("""
                sidecar: sendPaste payload \(bytes.count, privacy: .public) bytes exceeds cap \
                \(SidecarFrameCodec.maxPasteBytes, privacy: .public), dropping (view gate should have prevented this)
                """)
            return
        }
        let frame: Data
        do {
            frame = try SidecarFrameCodec.encodePaste(
                header: SidecarInputHeader(worktreeID: worktreeID, paneID: paneID), bytes: bytes)
        } catch {
            logger.error("sidecar: failed to encode paste frame, dropping \(bytes.count, privacy: .public) bytes")
            return
        }
        sendQueue.async { [weak self] in
            guard let self else { return }
            self.lock.lock(); let fd = self.socketFD; self.lock.unlock()
            guard fd >= 0 else {
                self.logger.error("sidecar: sendPaste while disconnected, dropping \(bytes.count, privacy: .public) bytes")
                return
            }
            do {
                try FDChannel.sendData(frame, over: fd)
            } catch {
                self.logger.error("sidecar: paste send failed: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func receiveLoop(_ fd: Int32) {
        let scanner = SidecarFrameScanner()
        // FDs arrive in frame order (SCM_RIGHTS ancillary is delivered with the
        // first byte of the sendmsg segment, and recvmsg does not read across an
        // ancillary boundary), so a queue paired FIFO with completed `.fdVend`
        // frames routes each fd correctly.
        var pendingFDs: [Int32] = []
        while true {
            let message: (data: Data, fds: [Int32])
            do {
                message = try FDChannel.receiveMessage(from: fd, capacity: 16 * 1024)
            } catch {
                break   // EOF or read error
            }
            pendingFDs.append(contentsOf: message.fds)
            // Process the frames `append` returned FIRST, THEN check isDesynced
            // and break. A desync-tripping tail can arrive in the same read as
            // the last valid frames; checking before processing would silently
            // discard those valid frames (their waiters would get .disconnected
            // instead of their fd). This must stay in lockstep with the daemon's
            // receive loop in FDVendingServer.startReceiveThread, which likewise
            // drains the returned frames before its isDesynced break.
            for frame in scanner.append(message.data) {
                guard let type = SidecarFrameType(rawValue: frame.type) else {
                    logger.error("sidecar: unknown frame type \(frame.type, privacy: .public), skipping")
                    continue
                }
                switch type {
                case .fdVend:
                    let rxFD: Int32? = pendingFDs.isEmpty ? nil : pendingFDs.removeFirst()
                    handleFDVend(headerPayload: frame.payload, fd: rxFD)
                case .input, .paste:
                    // The daemon must never send input/paste frames — those
                    // directions are app → daemon only.
                    logger.error("sidecar: received \(frame.type, privacy: .public) frame from daemon (protocol violation), dropping")
                }
            }
            if scanner.isDesynced {
                logger.fault("sidecar: frame scanner desynced, closing connection")
                break
            }
        }
        // EOF: fail everything pending, mark disconnected (reconnect is a
        // Phase B crash-recovery concern).
        lock.lock()
        let pending = waiters; waiters = [:]
        socketFD = -1
        lock.unlock()
        // Barrier before close: a `sendInput` write block may be mid-`write()` on
        // this same fd right now. `sendFD` was already set to -1 above, so any
        // block that has NOT yet started sees the guard and drops; this barrier
        // waits out the one that's already inside `FDChannel.sendData`. Closing
        // under a mid-`write()` racer risks writing into a recycled fd number.
        sendQueue.sync {}
        Darwin.close(fd)
        for leftover in pendingFDs { Darwin.close(leftover) }   // fds with no completed frame
        for (_, waiter) in pending { waiter(nil, FDSidecarError.disconnected) }
        logger.info("sidecar receive loop exited")
    }

    /// Route a completed `.fdVend` frame's paired fd to its waiter, or close it.
    private func handleFDVend(headerPayload: Data, fd: Int32?) {
        guard let hdr = try? JSONDecoder().decode(FDVendHeader.self, from: headerPayload) else {
            logger.error("sidecar: undecodable vend header, closing fd")
            if let fd { Darwin.close(fd) }
            return
        }
        guard let fd else {
            // A completed fdVend frame with no paired fd is a protocol bug on
            // the daemon side — nothing to deliver.
            logger.error("sidecar: fdVend \(hdr.routingKey, privacy: .public) arrived with no paired fd")
            return
        }
        lock.lock()
        let waiter = waiters.removeValue(forKey: hdr.routingKey)
        lock.unlock()
        if let waiter {
            waiter(fd, nil)
        } else {
            logger.info("sidecar: no waiter for \(hdr.routingKey, privacy: .public) (stale vend), closing fd")
            Darwin.close(fd)
        }
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
