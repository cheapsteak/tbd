import Darwin
import Foundation
import TBDShared

/// History only enumerates durable catalog associations. Neither a rollout's
/// cwd nor any discovery of files in the shared home grants worktree ownership.
enum CodexSessionScanner {
    enum ReadError: Error, LocalizedError, CustomStringConvertible {
        var errorDescription: String? { description }
        case unsafePath, changedAssociation, changedFile
        var description: String {
            switch self {
            case .unsafePath: "Refusing unsafe Codex transcript path"
            case .changedAssociation: "Codex session association changed while reading"
            case .changedFile: "Codex transcript changed while validating its path"
            }
        }
    }

    static func summary(_ session: LocalAgentSession) -> SessionSummary {
        var metadata = CodexTranscriptParser.SummaryMetadata()
        var modifiedAt = session.lastObservedAt
        var size: Int64 = 0
        var available = false
        if let file = try? openTranscript(session) {
            modifiedAt = file.modifiedAt
            size = file.size
            if let scanned = try? CodexTranscriptParser.summary(fileHandle: file.handle), file.isCurrent() {
                metadata = scanned
                available = true
            }
        }
        return SessionSummary(
            sessionId: session.identity.sessionID, filePath: session.transcriptPath ?? "",
            modifiedAt: modifiedAt, fileSize: size, lineCount: metadata.lineCount,
            firstUserMessage: metadata.firstUserMessage, lastUserMessage: metadata.lastUserMessage,
            cwd: metadata.cwd, gitBranch: metadata.gitBranch,
            lastMessageAt: metadata.lastMessageAt ?? modifiedAt,
            agentKind: .codex, transcriptAvailable: available)
    }

    /// Re-fetching the association across the open and parse boundaries binds
    /// this read to the worktree, identity, path, and home that authorized it.
    /// The injected fetch is the same store lookup the router used initially.
    static func messages(
        _ session: LocalAgentSession, tailLimit: Int? = nil,
        currentSession: () async throws -> LocalAgentSession?
    ) async throws -> [TranscriptItem] {
        let file = try openTranscript(session)
        guard try await currentSession() == session else { throw ReadError.changedAssociation }
        guard let file else { return [] }
        guard file.isCurrent() else { throw ReadError.changedFile }
        let items = try CodexTranscriptParser.parse(fileHandle: file.handle, limit: tailLimit)
        guard try await currentSession() == session else { throw ReadError.changedAssociation }
        guard file.isCurrent() else { throw ReadError.changedFile }
        return items
    }

    private static func openTranscript(_ session: LocalAgentSession) throws -> CodexTranscriptFile? {
        guard session.identity.agentKind == .codex else { throw ReadError.unsafePath }
        guard let path = session.transcriptPath else { return nil }
        let home = session.codexLaunchOptions?.codexHome.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? CodexHomeManager().codexHome
        let root = home.standardizedFileURL.path
        let candidate = URL(fileURLWithPath: path).standardizedFileURL.path
        guard path.hasPrefix("/"), !path.utf8.contains(0), candidate.hasPrefix(root + "/") else {
            throw ReadError.unsafePath
        }
        // Foundation intentionally preserves macOS aliases such as /var even
        // after resolvingSymlinksInPath. realpath gives openat a physical root;
        // only this trusted root is resolved, never the untrusted path below it.
        var rootInfo = stat()
        guard lstat(root, &rootInfo) == 0 else {
            if errno == ENOENT || errno == EACCES { return nil }
            throw ReadError.unsafePath
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else { throw ReadError.unsafePath }
        guard let resolvedRoot = CodexTranscriptFile.resolveRoot(root) else {
            if errno == ENOENT || errno == EACCES { return nil }
            throw ReadError.unsafePath
        }
        return try CodexTranscriptFile.open(
            path: resolvedRoot + candidate.dropFirst(root.count), sourceRoot: root, resolvedRoot: resolvedRoot)

    }
}

/// A descriptor and the identities of every directory used to reach it.
/// openat + NOFOLLOW prevents a directory or leaf symlink substitution from
/// redirecting the read. Checking the chain again catches rename/replacement;
/// parsing uses the held descriptor, never the path that could be exchanged.
private final class CodexTranscriptFile {
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
        let birthSeconds: Int
        let birthNanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            birthSeconds = info.st_birthtimespec.tv_sec
            birthNanoseconds = info.st_birthtimespec.tv_nsec
        }
    }

    let handle: FileHandle
    let size: Int64
    let modifiedAt: Date
    private let path: String
    private let identities: [Identity]
    private let sourceRoot: String
    private let resolvedRoot: String

    private init(descriptor: Int32, info: stat, path: String, identities: [Identity],
                 sourceRoot: String, resolvedRoot: String) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        size = info.st_size
        modifiedAt = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                          + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        self.path = path
        self.identities = identities
        self.sourceRoot = sourceRoot
        self.resolvedRoot = resolvedRoot
    }

    deinit { try? handle.close() }

    static func resolveRoot(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func open(path: String, sourceRoot: String, resolvedRoot: String) throws -> CodexTranscriptFile? {
        let components = path.split(separator: "/").map(String.init)
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexSessionScanner.ReadError.unsafePath }
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        var identities: [Identity] = []
        for (index, component) in components.enumerated() {
            let isFile = index == components.count - 1
            let flags = O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK | (isFile ? 0 : O_DIRECTORY)
            let next = openat(descriptor, component, flags)
            guard next >= 0 else {
                let reason = errno
                // A missing/unreadable cataloged file is resumable. Symlinks,
                // directories in the leaf, and other unsafe types are errors.
                if reason == ENOENT || reason == EACCES { return nil }
                throw CodexSessionScanner.ReadError.unsafePath
            }
            Darwin.close(descriptor)
            descriptor = next
            var info = stat()
            guard fstat(descriptor, &info) == 0,
                  info.st_mode & S_IFMT == (isFile ? S_IFREG : S_IFDIR) else {
                throw CodexSessionScanner.ReadError.unsafePath
            }
            identities.append(Identity(info))
            if isFile {
                let file = CodexTranscriptFile(descriptor: descriptor, info: info, path: path, identities: identities,
                                               sourceRoot: sourceRoot, resolvedRoot: resolvedRoot)
                descriptor = -1
                return file
            }
        }
        throw CodexSessionScanner.ReadError.unsafePath
    }

    func isCurrent() -> Bool {
        var rootInfo = stat()
        guard Self.resolveRoot(sourceRoot) == resolvedRoot,
              lstat(sourceRoot, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR,
              let current = try? Self.open(path: path, sourceRoot: sourceRoot, resolvedRoot: resolvedRoot) else { return false }
        return current.identities == identities
    }
}
