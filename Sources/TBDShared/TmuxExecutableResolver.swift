import Foundation

public struct TmuxExecutableResolution: Equatable, Sendable {
    public enum Source: Equatable, Sendable {
        case path
        case savedFallback
    }

    public let path: String
    public let source: Source

    public init(path: String, source: Source) {
        self.path = path
        self.source = source
    }
}

public enum TmuxExecutableResolverError: LocalizedError, Equatable {
    case pathMustBeAbsolute
    case pathIsNotExecutable

    public var errorDescription: String? {
        switch self {
        case .pathMustBeAbsolute:
            "The tmux executable path must be absolute."
        case .pathIsNotExecutable:
            "The tmux executable path does not point to an executable file."
        }
    }
}

public struct TmuxExecutableResolver: Sendable {
    private let environment: [String: String]
    private let configurationURL: URL

    public init(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        configurationURL: URL? = nil
    ) {
        self.environment = environment
        self.configurationURL = configurationURL
            ?? TBDConstants.tmuxExecutablePathFile(environment: environment)
    }

    public var savedPath: String? {
        guard let contents = try? String(contentsOf: configurationURL, encoding: .utf8) else {
            return nil
        }
        let path = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    public func resolve() -> TmuxExecutableResolution? {
        if let path = executableFromPath() {
            return TmuxExecutableResolution(path: path, source: .path)
        }
        guard let savedPath, isRegularExecutable(savedPath) else {
            return nil
        }
        return TmuxExecutableResolution(path: savedPath, source: .savedFallback)
    }

    public func save(_ path: String) throws {
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        try validate(trimmedPath)
        try FileManager.default.createDirectory(
            at: configurationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try trimmedPath.write(to: configurationURL, atomically: true, encoding: .utf8)
    }

    public func clear() throws {
        do {
            try FileManager.default.removeItem(at: configurationURL)
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            // Already clear.
        }
    }

    private func executableFromPath() -> String? {
        for directory in environment["PATH"]?.split(separator: ":", omittingEmptySubsequences: false) ?? [] {
            let directory = String(directory)
            guard NSString(string: directory).isAbsolutePath else { continue }
            let candidate = URL(fileURLWithPath: directory, isDirectory: true)
                .appendingPathComponent("tmux")
                .standardizedFileURL
                .path
            if isRegularExecutable(candidate) {
                return candidate
            }
        }
        return nil
    }

    private func validate(_ path: String) throws {
        guard NSString(string: path).isAbsolutePath else {
            throw TmuxExecutableResolverError.pathMustBeAbsolute
        }
        guard isRegularExecutable(path) else {
            throw TmuxExecutableResolverError.pathIsNotExecutable
        }
    }

    private func isRegularExecutable(_ path: String) -> Bool {
        guard NSString(string: path).isAbsolutePath,
              FileManager.default.isExecutableFile(atPath: path) else {
            return false
        }
        let resolvedURL = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let values = try? resolvedURL.resourceValues(forKeys: [.isRegularFileKey])
        return values?.isRegularFile == true
    }
}
