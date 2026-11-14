import Foundation

/// The fd sidecar as the attach handlers hold it: the channel a holder-backed
/// session's pty descriptor is vended over. `FDVendingServer` conforms.
protocol AttachFDVending: Sendable {
    func sendReportingRecipient(fd: Int32, header: Data) async throws -> ProcessIdentity?
}

/// What `attach.request` needs from the daemon's wiring beyond the holder
/// registry: the sidecar to vend through, and how long an attach may sit
/// unacknowledged before the daemon cancels it.
///
/// `Daemon` builds one around its `FDVendingServer` and hands it to the
/// router. A router without one answers a holder attach with an error, so a
/// test that never attaches does not need to build a sidecar.
struct AttachSidecar: Sendable {
    /// Where the pty descriptor goes. The sidecar listens whenever the daemon
    /// does.
    let fdVending: any AttachFDVending
    /// How long a vended attach may wait for its `attach.ready` before the
    /// daemon cancels it. An app that died mid-attach would otherwise leave
    /// the session suspended behind a descriptor nobody reads.
    let readyTimeout: Duration
    /// Clock behind `readyTimeout`. Tests pass a `TestClock` and drive virtual
    /// time instead of sleeping.
    let clock: any Clock<Duration>

    init(
        fdVending: any AttachFDVending,
        readyTimeout: Duration = .seconds(5),
        clock: any Clock<Duration> = ContinuousClock()
    ) {
        self.fdVending = fdVending
        self.readyTimeout = readyTimeout
        self.clock = clock
    }
}
