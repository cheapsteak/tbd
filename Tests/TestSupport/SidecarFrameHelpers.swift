import Darwin
import Foundation
import TBDShared

/// Shared helpers for the framed-sidecar tests (M2.1). Daemon-target tests can't
/// import the app-side `FDSidecarClient`, so they decode vend frames directly
/// through the public `TBDShared` framing primitives.
///
/// Lives in `TestSupport` rather than a test target because it is used from both
/// `TBDDaemonTests` and the tier-3 `TBDDaemonLiveTests` target
/// (docs/specs/2026-07-24-test-hardening-design.md §3).
public enum SidecarTestSupport {

    /// Block until one complete `.fdVend` frame arrives on `socket`, returning
    /// its paired fd and decoded header. Reassembles across `recvmsg` calls, so
    /// it tolerates a frame split into multiple chunks.
    public static func receiveVend(from socket: Int32) throws -> (fd: Int32, header: FDVendHeader) {
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
