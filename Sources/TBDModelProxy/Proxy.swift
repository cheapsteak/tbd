import Darwin
import Foundation
import TBDShared
import os

// Everything TBDModelProxy decides, so it can be exercised without spawning a
// process — `main.swift` next door holds nothing but the call into `run()`.
// The split mirrors `TBDHolder`/`Holder.swift`, for the same reason: a
// five-branch argument parser and an exit-code taxonomy are worth testing
// directly, and a top-level `main.swift` offers a test nothing but a binary.
//
// TBDModelProxy — one process per TBD home
// (docs/specs/2026-09-05-transcript-streaming-model-proxy-design.md).
//
// Invoked as:
//
//   TBDModelProxy [--port <n>] [--home <path>] [--lock-fd <n>]
//
// It listens on loopback, forwards every request under its base URL to the
// upstream a route names, and tees assistant text deltas into a per-terminal
// stream file. It is spawned by the daemon, outlives it, and is replaced only
// by a successor that takes `proxy.lock` first.
//
// Nothing is written to stdout, ever. A proxy's stdout and stderr are
// redirected into `proxy.log` by its spawner, so ordinary operation must leave
// that file empty; diagnostics go to `os.Logger` and only an invocation that
// cannot run at all reaches stderr. `no_print_in_sources` covers this target.

/// Exit statuses `TBDModelProxy` can end on, split the way `HolderExitCode`
/// splits the holder's: 2 means the command line is wrong and will stay wrong,
/// 3 means the machine refused and a later attempt can succeed.
enum TBDModelProxyExit {
    /// A missing or malformed flag. The same command line fails the same way
    /// forever, so a supervisor must fix its arguments rather than respawn.
    static let badArguments: Int32 = 2
    /// The listener could not bind the port it was asked for. Distinct from
    /// every other failure because it is the one the supervisor acts on: it
    /// probes `GET /tbd/status` on that port, adopts a TBD proxy that answers,
    /// and mints a fresh port when anything else holds it.
    static let bindFailed: Int32 = 3
}

/// What the daemon puts on the proxy's command line.
///
/// Unrecognised `--flags` are refused rather than ignored — unlike the holder,
/// which must tolerate a newer daemon's flags because a session keeps the
/// holder binary it was born with. A proxy is replaced whenever its version
/// differs from the daemon's, so a flag it has never heard of is a bug, not
/// version skew.
struct ProxyArguments: Equatable {
    /// The port to bind. Zero asks the kernel to assign one, which is how the
    /// first proxy on a TBD home is started; every later one is asked for the
    /// port persisted in the config row.
    var port: Int
    /// The TBD home whose `proxy/`, `streams/` and route files this proxy owns.
    var home: String
    /// An inherited `flock` descriptor, already held by the spawner. The proxy
    /// keeps it open for its whole life and never closes it; that a descriptor
    /// cannot be inherited by accident is what makes it proof of ownership.
    var lockDescriptor: Int32?

    static let usage = "usage: TBDModelProxy [--port <n>] [--home <path>] [--lock-fd <n>]"

    /// `arguments` excludes argv[0].
    static func parse(
        _ arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ProxyArguments {
        var values: [String: String] = [:]
        var index = 0
        while index < arguments.count {
            let flag = arguments[index]
            guard flag.hasPrefix("--") else {
                throw ProxyStartupError.unknownArgument(flag)
            }
            let name = String(flag.dropFirst(2))
            guard ["port", "home", "lock-fd"].contains(name) else {
                throw ProxyStartupError.unknownArgument(flag)
            }
            guard index + 1 < arguments.count else {
                throw ProxyStartupError.missingValue(flag)
            }
            values[name] = arguments[index + 1]
            index += 2
        }

        var port = 0
        if let text = values["port"] {
            guard let parsed = Int(text), (0...65535).contains(parsed) else {
                throw ProxyStartupError.invalidPort(text)
            }
            port = parsed
        }

        var lockDescriptor: Int32?
        if let text = values["lock-fd"] {
            guard let parsed = Int32(text), parsed >= 0 else {
                throw ProxyStartupError.invalidLockDescriptor(text)
            }
            lockDescriptor = parsed
        }

        let home = values["home"].flatMap { $0.isEmpty ? nil : $0 }
            ?? TBDConstants.configDir(environment: environment).path

        return ProxyArguments(port: port, home: home, lockDescriptor: lockDescriptor)
    }
}

enum ProxyStartupError: LocalizedError, Equatable {
    case unknownArgument(String)
    case missingValue(String)
    case invalidPort(String)
    case invalidLockDescriptor(String)

    var errorDescription: String? {
        switch self {
        case .unknownArgument(let flag):
            return "unknown argument \(flag)\n\(ProxyArguments.usage)"
        case .missingValue(let flag):
            return "\(flag) needs a value\n\(ProxyArguments.usage)"
        case .invalidPort(let text):
            return "--port must be 0-65535, got \(text)"
        case .invalidLockDescriptor(let text):
            return "--lock-fd must be a non-negative descriptor, got \(text)"
        }
    }
}

/// Loggers live on a type rather than at top level: a top-level `let` in
/// `main.swift` is a main-actor-isolated global under the Swift 6 language
/// mode, which a signal handler cannot touch.
enum ProxyLog {
    static let main = Logger(subsystem: "com.tbd.modelproxy", category: "main")
}

enum TBDModelProxyMain {
    static func run() -> Never {
        let arguments: ProxyArguments
        do {
            arguments = try ProxyArguments.parse(Array(CommandLine.arguments.dropFirst()))
        } catch {
            FileHandle.standardError.write(Data("TBDModelProxy: \(error.localizedDescription)\n".utf8))
            exit(TBDModelProxyExit.badArguments)
        }

        ProxyLog.main.debug(
            """
            starting: pid \(getpid(), privacy: .public), \
            port \(arguments.port, privacy: .public), \
            home \(arguments.home, privacy: .public), \
            lock-fd \(arguments.lockDescriptor.map(String.init) ?? "none", privacy: .public)
            """)

        // Every path this process owns hangs off the home it was given, so the
        // one `TBD_HOME` override below is all it takes to give a test — or a
        // second checkout — its own proxy with no injection seam added for the
        // purpose.
        let homeEnvironment = ["TBD_HOME": arguments.home]
        let routes = RouteTable(
            routesDir: TBDConstants.modelProxyRoutesDir(environment: homeEnvironment),
            streamsDir: TBDConstants.streamsDir(environment: homeEnvironment))

        // `status` and `onRetire` are the seams `GET /tbd/status` and
        // `POST /tbd/retire` read, and both endpoints answer 501 until Task A5
        // lands them; nothing calls either closure yet. The placeholders are
        // deliberately inert rather than half-right — a status that reported a
        // plausible-looking route count nobody had counted would be worse than
        // one that is obviously unwired.
        let server = ProxyServer(
            port: arguments.port,
            routes: routes,
            tee: nil,
            status: {
                ModelProxyStatus(
                    version: "unwired", pid: getpid(), processStartTime: Date(),
                    port: arguments.port, streamsInFlight: 0, routeCount: 0)
            },
            onRetire: {})

        // `run()` is synchronous and returns `Never`, so the async start is
        // driven to completion here rather than escaping into a task nobody
        // waits on: a bind failure has to become an exit status before the
        // signal wait below begins.
        let startOutcome = BlockingResultBox<Int>()
        Task {
            do {
                // A directory that cannot be listed is worth a line and not
                // worth refusing to start over: the daemon rewrites route
                // files as it spawns, so an empty table recovers by itself.
                try await routes.loadAll()
            } catch {
                ProxyLog.main.error(
                    "route load failed: \(error.localizedDescription, privacy: .public)")
            }
            do {
                startOutcome.finish(.success(try await server.start()))
            } catch {
                startOutcome.finish(.failure(error))
            }
        }

        switch startOutcome.wait() {
        case .success(let port):
            ProxyLog.main.debug("bound port \(port, privacy: .public)")
        case .failure(let error):
            FileHandle.standardError.write(
                Data("TBDModelProxy: bind failed: \(error.localizedDescription)\n".utf8))
            exit(TBDModelProxyExit.bindFailed)
        }

        // Signals are taken with `DispatchSource` rather than `signal(2)`, so
        // the handler runs on a queue instead of in signal context and may do
        // real work — closing the listener and draining in-flight streams once
        // there is something to drain. The disposition must be ignored first,
        // or the default action kills the process before the source fires.
        let stopped = DispatchSemaphore(value: 0)
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        let sources = [SIGTERM, SIGINT].map { number -> DispatchSourceSignal in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                ProxyLog.main.debug("received signal \(number, privacy: .public), stopping")
                stopped.signal()
            }
            source.resume()
            return source
        }

        stopped.wait()
        // Keeps the sources alive until the wait returns; a cancelled source
        // stops delivering, and a released one is cancelled.
        for source in sources { source.cancel() }

        let stopOutcome = BlockingResultBox<Void>()
        Task {
            await server.stop()
            stopOutcome.finish(.success(()))
        }
        _ = stopOutcome.wait()
        exit(0)
    }
}

/// A one-shot result handed from a `Task` back to the synchronous `run()`.
///
/// `run()` returns `Never` and owns the process, so it cannot become `async`
/// without moving the exit-code taxonomy somewhere a test cannot reach. This
/// box is the narrow bridge: one `finish`, one `wait`, no polling.
final class BlockingResultBox<Value: Sendable>: @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Value, Error>?

    func finish(_ value: Result<Value, Error>) {
        let first = lock.withLock { () -> Bool in
            guard result == nil else { return false }
            result = value
            return true
        }
        guard first else { return }
        ready.signal()
    }

    func wait() -> Result<Value, Error> {
        ready.wait()
        // Non-nil by construction: the semaphore is signalled only after the
        // result is stored, and `finish` stores exactly once.
        return lock.withLock { result } ?? .failure(ProxyServerError.boundAddressUnreadable)
    }
}
