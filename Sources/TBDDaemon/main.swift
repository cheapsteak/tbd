import Foundation
import Dispatch
import TBDDaemonLib
import TBDShared

print("tbdd v\(TBDConstants.version) starting...")

let daemon = Daemon()

// Set up signal handling using DispatchSource (compatible with Swift 6 concurrency).
// We must ignore the default signal behavior first, then use DispatchSource to handle them.
signal(SIGTERM, SIG_IGN)
signal(SIGINT, SIG_IGN)

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
        print("[tbdd] Fatal: \(error)")
        Foundation.exit(1)
    }
}

// Keep the process alive
dispatchMain()
