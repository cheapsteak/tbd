import os
import Synchronization

/// Where the libghostty engine logs: the `terminalEngine` category, under a subsystem the host
/// chooses.
///
/// The host calls `configure(subsystem:)` once at startup, before it makes a terminal. The app
/// keeps the default, `com.tbd.app`; the daemon will pass `com.tbd.daemon`, so the engine's lines
/// in each process sit under that process's own subsystem and one predicate shows them with the
/// rest of its log. Until a host calls it, the engine logs under the default.
public enum GhosttyCoreLog {
    /// The subsystem the engine logs under until a host configures another.
    public static let defaultSubsystem = "com.tbd.app"
    /// The category of every line the engine logs.
    static let category = "terminalEngine"

    /// A subsystem and the logger made for it.
    private struct Configured: Sendable {
        let subsystem: String
        let logger: Logger

        init(subsystem: String) {
            self.subsystem = subsystem
            self.logger = Logger(subsystem: subsystem, category: GhosttyCoreLog.category)
        }
    }

    /// The configured subsystem and its logger, swapped together so a reader never sees one
    /// without the other. Process-wide, as the setting is.
    private static let state = Mutex(Configured(subsystem: defaultSubsystem))

    /// Sets the subsystem the engine logs under from now on. Lines already logged keep theirs.
    public static func configure(subsystem: String) {
        let configured = Configured(subsystem: subsystem)
        state.withLock { $0 = configured }
    }

    /// The subsystem `configure(subsystem:)` last set, or the default. `Logger` does not report its
    /// own, so this is what a test reads.
    static var subsystem: String { state.withLock { $0.subsystem } }

    /// The engine's logger, made once per `configure(subsystem:)`, not once per line.
    static var logger: Logger { state.withLock { $0.logger } }
}

/// The engine's log: the `terminalEngine` category, under the subsystem the host configured
/// (`GhosttyCoreLog`), so one predicate shows every engine in a process.
package var terminalEngineLog: Logger { GhosttyCoreLog.logger }
