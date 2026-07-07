import Foundation
import Dispatch
import os
import TBDDaemonLib
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "startup")

logger.info("tbdd v\(TBDConstants.version, privacy: .public) starting...")

let daemon = Daemon()

// Set up signal handling using DispatchSource (compatible with Swift 6 concurrency).
// We must ignore the default signal behavior first, then use DispatchSource to handle them.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)
// A raw write to a peer-closed UNIX socket (FDVendingServer's sidecar sends)
// would otherwise raise a process-killing SIGPIPE instead of returning EPIPE
// into FDChannel's error path. Pty writes (control mode) fail with EIO and
// never signal, but the sidecar socket path needs this (R7-H1 hardening).
signal(SIGPIPE, SIG_IGN)

let sigTermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigTermSource.setEventHandler {
    Task {
        await daemon.stop()
    }
}
sigTermSource.resume()

let sigIntSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigIntSource.setEventHandler {
    Task {
        await daemon.stop()
    }
}
sigIntSource.resume()

// Start the daemon
Task {
    do {
        try await daemon.start()
    } catch {
        logger.error("Fatal: \(error.localizedDescription, privacy: .public)")
        Foundation.exit(1)
    }
}

// Keep the process alive
dispatchMain()
