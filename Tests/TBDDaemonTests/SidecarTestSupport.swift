import Darwin
import Foundation
import TBDShared

/// Shared helpers for the framed-sidecar tests (M2.1). Daemon-target tests can't
/// import the app-side `FDSidecarClient`, so they decode vend frames directly
/// through the public `TBDShared` framing primitives.
enum SidecarTestSupport {

    /// Block until one complete `.fdVend` frame arrives on `socket`, returning
    /// its paired fd and decoded header. Reassembles across `recvmsg` calls, so
    /// it tolerates a frame split into multiple chunks.
    static func receiveVend(from socket: Int32) throws -> (fd: Int32, header: FDVendHeader) {
        let scanner = SidecarFrameScanner()
        var pendingFDs: [Int32] = []
        while true {
            let message = try FDChannel.receiveMessage(from: socket, capacity: 16 * 1024)
            pendingFDs.append(contentsOf: message.fds)
            for frame in scanner.append(message.data) {
                guard frame.type == SidecarFrameType.fdVend.rawValue else { continue }
                let header = try JSONDecoder().decode(FDVendHeader.self, from: frame.payload)
                let fd = pendingFDs.isEmpty ? -1 : pendingFDs.removeFirst()
                return (fd, header)
            }
        }
    }
}

/// Thread-safe collector for `onInput` callbacks, which fire on the receive
/// thread. Tests poll `count` until the expected frames land.
final class SidecarInputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(header: SidecarInputHeader, bytes: Data)] = []

    func record(_ header: SidecarInputHeader, _ bytes: Data) {
        lock.lock(); items.append((header, bytes)); lock.unlock()
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var all: [(header: SidecarInputHeader, bytes: Data)] { lock.lock(); defer { lock.unlock() }; return items }
}

/// Poll `condition` until it holds or `timeout` elapses. Returns its final value.
func waitUntil(_ condition: @Sendable () -> Bool, timeout: Duration = .seconds(2)) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
