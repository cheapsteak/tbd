import os
import Synchronization

/// Where the libghostty engine logs: the `terminalEngine` category, under a subsystem the host
/// chooses.
///
/// The host calls `configure(subsystem:)` once at startup, before it makes a terminal. The app
/// keeps the default, `com.tbd.app`; the daemon will pass `com.tbd.daemon`, so the engine's lines
/// in each process sit under that process's own subsystem and one predicate shows them with the
/// rest of its log. Until a host calls it, the engine logs under the default.
package enum GhosttyCoreLog {
    /// The subsystem the engine logs under until a host configures another.
    package static let defaultSubsystem = "com.tbd.app"
    /// The category of every line the engine logs.
    static let category = "terminalEngine"

    /// The destination the engine logs to. Process-wide, as the setting is; a test builds a
    /// `Destination` of its own rather than changing this one.
    package static let shared = Destination()

    /// Sets the subsystem the engine logs under from now on. Lines already logged keep theirs.
    package static func configure(subsystem: String) {
        shared.configure(subsystem: subsystem)
    }

    /// The engine's logger.
    static var logger: Logger { shared.logger }

    /// A subsystem and the logger made for it, behind a lock: set by the host, read from any
    /// thread that logs.
    package final class Destination: Sendable {
        private struct Configured: Sendable {
            let subsystem: String
            let logger: Logger

            init(subsystem: String) {
                self.subsystem = subsystem
                self.logger = Logger(subsystem: subsystem, category: GhosttyCoreLog.category)
            }
        }

        /// The subsystem and its logger, swapped together so a reader never sees one without
        /// the other.
        private let state: Mutex<Configured>

        package init(subsystem: String = GhosttyCoreLog.defaultSubsystem) {
            state = Mutex(Configured(subsystem: subsystem))
        }

        /// Sets the subsystem logged under from now on, and makes the logger for it.
        package func configure(subsystem: String) {
            let configured = Configured(subsystem: subsystem)
            state.withLock { $0 = configured }
        }

        /// The subsystem of the logger `logger` hands out. `Logger` does not report its own, so
        /// this is what a test reads.
        package var subsystem: String { state.withLock { $0.subsystem } }

        /// The logger for the configured subsystem, made once per `configure(subsystem:)`, not
        /// once per line.
        package var logger: Logger { state.withLock { $0.logger } }
    }
}

/// The engine's log: the `terminalEngine` category, under the subsystem the host configured
/// (`GhosttyCoreLog`), so one predicate shows every engine in a process.
package var terminalEngineLog: Logger { GhosttyCoreLog.logger }
