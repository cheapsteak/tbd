import Foundation
import TBDShared

public enum HookEvent: String, Sendable {
    case setup
    case archive

    public var conductorKey: String {
        switch self {
        case .setup: return "setup"
        case .archive: return "archive"
        }
    }

    public var dmuxHookName: String {
        switch self {
        case .setup: return "worktree_created"
        case .archive: return "before_worktree_remove"
        }
    }
}

public struct HookResolver: Sendable {
    public let globalHooksDir: String

    public init(
        globalHooksDir: String = TBDConstants.configDir
            .appendingPathComponent("hooks/default").path
    ) {
        self.globalHooksDir = globalHooksDir
    }

    /// Resolves which hook script to run. First match wins, no chaining.
    /// Priority: appHookPath > conductor.json > .dmux-hooks > global default
    public func resolve(event: HookEvent, repoPath: String, appHookPath: String?) -> String? {
        // 1. App per-repo config
        if let path = appHookPath, FileManager.default.fileExists(atPath: path) {
            return path
        }

        // 2. conductor.json
        if let path = resolveConductor(event: event, repoPath: repoPath) {
            return path
        }

        // 3. .dmux-hooks
        if let path = resolveDmux(event: event, repoPath: repoPath) {
            return path
        }

        // 4. Global default
        let globalPath = (globalHooksDir as NSString).appendingPathComponent(event.rawValue)
        if FileManager.default.isExecutableFile(atPath: globalPath) {
            return globalPath
        }

        return nil
    }

    /// Execute a hook asynchronously with timeout. Returns (success, output).
    public func execute(
        hookPath: String, cwd: String, env: [String: String],
        timeout: TimeInterval = 60
    ) async throws -> (Bool, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [hookPath]
        process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        process.environment = ProcessInfo.processInfo.environment.merging(env) { _, new in new }

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let state = ResumeState()

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Bool, String), Error>) in
            let resumeOnce: @Sendable (Result<(Bool, String), Error>) -> Void = { result in
                if state.tryResume() {
                    continuation.resume(with: result)
                }
            }

            process.terminationHandler = { terminatedProcess in
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                resumeOnce(.success((terminatedProcess.terminationStatus == 0, output)))
            }

            do {
                try process.run()
            } catch {
                resumeOnce(.failure(error))
                return
            }

            // Timeout handling
            let deadline = DispatchTime.now() + timeout
            DispatchQueue.global().asyncAfter(deadline: deadline) {
                if process.isRunning {
                    process.terminate()
                }
            }
        }
    }

    // MARK: - Internal

    /// Thread-safe one-shot gate for continuation resumption.
    private final class ResumeState: @unchecked Sendable {
        private var resumed = false
        private let lock = NSLock()

        /// Returns true exactly once; all subsequent calls return false.
        func tryResume() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if resumed { return false }
            resumed = true
            return true
        }
    }

    // MARK: - Private

    private func resolveConductor(event: HookEvent, repoPath: String) -> String? {
        let conductorPath = (repoPath as NSString).appendingPathComponent("conductor.json")
        guard FileManager.default.fileExists(atPath: conductorPath),
              let data = FileManager.default.contents(atPath: conductorPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String],
              let scriptRelPath = scripts[event.conductorKey]
        else {
            return nil
        }
        let fullPath = (repoPath as NSString).appendingPathComponent(scriptRelPath)
        return FileManager.default.fileExists(atPath: fullPath) ? fullPath : nil
    }

    private func resolveDmux(event: HookEvent, repoPath: String) -> String? {
        let hookPath = (repoPath as NSString)
            .appendingPathComponent(".dmux-hooks/\(event.dmuxHookName)")
        return FileManager.default.isExecutableFile(atPath: hookPath) ? hookPath : nil
    }
}
