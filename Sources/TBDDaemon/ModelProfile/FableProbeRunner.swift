import Foundation
import os
import TBDShared

private let logger = Logger(subsystem: "com.tbd.daemon", category: "fableProbe")

/// Runs the Fable probe under a profile's credentials and classifies what it
/// prints.
///
/// The command is `claude -p --model claude-fable-5-2 --output-format json
/// "Reply with only the word ok"`, run in the environment `tbd profile exec`
/// gives its child (`ProfileExecEnvironmentBuilder` + `ProfileExecEnvironment`),
/// so the probe runs on exactly the account a Fable session on the profile
/// would use. A probe is a few tokens when the account has credits and bills
/// nothing when it does not.
///
/// Never logs the environment, the arguments' environment or any output: the
/// environment holds the credential, and the output is the account's reply.
enum FableProbeRunner {
    static let timeout: TimeInterval = 60
    static let prompt = "Reply with only the word ok"
    /// Output beyond this is dropped; a result object is a few hundred bytes.
    static let maxOutputBytes = 1_000_000

    static func arguments() -> [String] {
        ["-p", "--model", FableModel.probeModelID, "--output-format", "json", prompt]
    }

    /// The probe for the daemon's store: loads the profile's environment (not
    /// counted as a use of the profile), runs `claude`, classifies.
    static func live(
        profiles: ModelProfileStore,
        repos: RepoStore,
        config: ConfigStore,
        configDirManager: ClaudeProfileConfigDirManager
    ) -> FableAvailabilityStore.Probe {
        let resolver = ModelProfileResolver(profiles: profiles, repos: repos, config: config)
        return { profileID in
            let started = Date()
            func unknown(_ reason: String) -> FableAvailability {
                FableAvailability(state: .unknown, reason: reason, checkedAt: Date(), source: .probe)
            }
            let built: ProfileExecEnvironmentBuilder.Outcome
            do {
                built = try await ProfileExecEnvironmentBuilder.build(
                    profileID: profileID, resolver: resolver,
                    configDirManager: configDirManager, config: config,
                    touchLastUsed: false)
            } catch {
                return unknown("environment_unavailable")
            }
            guard case .built(let exec) = built else { return unknown("profile_not_runnable") }
            // Only the kinds that can run Fable on usage credits are probed
            // by the pool; an API-key or Bedrock profile is billed elsewhere.
            guard exec.kind == .oauth || exec.kind == .oauthToken else {
                return unknown("not_a_pool_profile")
            }
            let executable: String
            do {
                executable = try ClaudeExecutableResolver.resolve()
            } catch {
                return unknown("claude_not_found")
            }
            let env = ProfileExecEnvironment.compose(
                inherited: ProcessInfo.processInfo.environment, profile: exec.environment)
            let output = await run(executable: executable, arguments: arguments(),
                                   environment: env, timeout: timeout)
            let reading: FableAvailability
            switch output {
            case .timedOut: reading = unknown("probe_timeout")
            case .failedToRun: reading = unknown("probe_failed_to_run")
            case .finished(let data): reading = FableProbeClassifier.classify(resultJSON: data, now: Date())
            }
            logger.info("fable probe \(profileID.uuidString, privacy: .public): \(reading.state.rawValue, privacy: .public) (\(reading.reason ?? "-", privacy: .public)) in \(Int(Date().timeIntervalSince(started)))s")
            return reading
        }
    }

    enum RunOutput: Equatable {
        case finished(Data)
        case timedOut
        case failedToRun
    }

    /// Run a process to completion or until `timeout`, capturing stdout (stderr
    /// is discarded). On timeout the child gets SIGTERM, then SIGKILL two
    /// seconds later.
    static func run(
        executable: String, arguments: [String], environment: [String: String],
        timeout: TimeInterval
    ) async -> RunOutput {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = FileManager.default.temporaryDirectory
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe

        let exited = AsyncStream<Void> { continuation in
            process.terminationHandler = { _ in
                continuation.yield()
                continuation.finish()
            }
        }
        do { try process.run() } catch { return .failedToRun }

        let reader = Task.detached { () -> Data in
            var data = Data()
            let handle = pipe.fileHandleForReading
            while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                if data.count < maxOutputBytes { data.append(chunk) }
            }
            return data
        }
        let timedOut = TimedOutFlag()
        let killer = Task {
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled, process.isRunning else { return }
            timedOut.set()
            process.terminate()
            try? await Task.sleep(for: .seconds(2))
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        for await _ in exited { break }
        killer.cancel()
        // A timed-out probe is `unknown` whatever it printed, and a stray
        // grandchild holding the pipe open must not hold the probe with it.
        if timedOut.value { return .timedOut }
        return .finished(await reader.value)
    }

    private final class TimedOutFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.lock(); flag = true; lock.unlock() }
        var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
    }
}
