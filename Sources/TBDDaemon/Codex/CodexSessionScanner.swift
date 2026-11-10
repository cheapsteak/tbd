import Darwin
import Foundation
import TBDShared

/// Bounded metadata storage. A cache hit never substitutes for opening and
/// validating the currently authorized path and its ancestors.
final class CodexSummaryCache: @unchecked Sendable {
    static let shared = CodexSummaryCache(capacity: 256)
    fileprivate struct Key: Hashable {
        let worktreeID: UUID
        let identity: AgentSessionIdentity
        let path: String?
        let home: String?
        let version: CodexTranscriptFile.Version
    }
    private let lock = NSLock()
    private let capacity: Int
    private var values: [Key: CodexTranscriptParser.SummaryMetadata] = [:]
    private var order: [Key] = []

    init(capacity: Int) { self.capacity = max(1, capacity) }

    fileprivate func get(_ key: Key) -> CodexTranscriptParser.SummaryMetadata? {
        lock.withLock { values[key] }
    }

    fileprivate func put(_ value: CodexTranscriptParser.SummaryMetadata, for key: Key) {
        lock.withLock {
            if values[key] == nil {
                if order.count == capacity { values.removeValue(forKey: order.removeFirst()) }
                order.append(key)
            }
            values[key] = value
        }
    }
}

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

    static func summary(_ session: LocalAgentSession, cache: CodexSummaryCache = .shared,
                        readMetadata: (FileHandle) throws -> CodexTranscriptParser.SummaryMetadata = CodexTranscriptParser.summary) -> SessionSummary {
        var metadata = CodexTranscriptParser.SummaryMetadata()
        var modifiedAt = session.lastObservedAt
        var size: Int64 = 0
        var available = false
        if let file = try? openTranscript(session) {
            modifiedAt = file.modifiedAt
            size = file.size
            let key = CodexSummaryCache.Key(worktreeID: session.worktreeID, identity: session.identity,
                path: session.transcriptPath, home: session.codexLaunchOptions?.codexHome, version: file.version)
            if let scanned = cache.get(key) ?? (try? readMetadata(file.handle)), file.isCurrent() {
                metadata = scanned
                cache.put(scanned, for: key)
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
        let home = session.codexLaunchOptions?.codexHome ?? CodexHomeManager().codexHome.path
        return try CodexTranscriptFile.open(path: path, home: home)

    }
}

/// A descriptor and the identities of every directory used to reach it,
/// including the ancestors of the configured home. Only the verified macOS
/// /tmp and /var aliases may be rewritten; every physical component is opened
/// with NOFOLLOW from /. Checking the original paths again catches replacement
/// of an ancestor or alias while parsing consumes the held descriptor.
private final class CodexTranscriptFile {
    struct Version: Hashable {
        let device: dev_t
        let inode: ino_t
        let size: Int64
        let seconds: Int
        let nanoseconds: Int
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            seconds = info.st_mtimespec.tv_sec
            nanoseconds = info.st_mtimespec.tv_nsec
        }
    }
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

    /// Pin the symbolic link itself as well as its one permitted destination.
    /// No caller-selected ancestor is resolved through realpath.
    private struct PlatformAlias: Equatable {
        let component: String
        let identity: Identity
        let destination: String

        static func read(_ component: String) throws -> Self {
            let path = "/" + component
            var before = stat()
            var after = stat()
            guard lstat(path, &before) == 0, before.st_mode & S_IFMT == S_IFLNK,
                  let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: path),
                  destination == "private/" + component || destination == "/private/" + component,
                  lstat(path, &after) == 0, after.st_mode & S_IFMT == S_IFLNK,
                  Identity(before) == Identity(after) else {
                throw CodexSessionScanner.ReadError.unsafePath
            }
            return Self(component: component, identity: Identity(after), destination: destination)
        }
    }

    let handle: FileHandle
    let size: Int64
    let modifiedAt: Date
    let version: Version
    private let path: String
    private let home: String
    private let identities: [Identity]
    private let aliases: [PlatformAlias]

    private init(descriptor: Int32, info: stat, path: String, home: String,
                 identities: [Identity], aliases: [PlatformAlias]) {
        handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        size = info.st_size
        version = Version(info)
        modifiedAt = Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec)
                          + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)
        self.path = path
        self.home = home
        self.identities = identities
        self.aliases = aliases
    }

    deinit { try? handle.close() }

    /// Lexical normalization never asks whether the leaf exists. Foundation's
    /// standardization can change /private prefixes when a leaf is deleted.
    /// Reject parent traversal instead of erasing a possibly linked component.
    private static func components(_ path: String, aliases: inout [PlatformAlias]) throws -> [String] {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw CodexSessionScanner.ReadError.unsafePath }
        var components = path.split(separator: "/").filter { $0 != "." }.map(String.init)
        guard !components.contains("..") else { throw CodexSessionScanner.ReadError.unsafePath }
        if let first = components.first, first == "tmp" || first == "var" {
            let alias = try PlatformAlias.read(first)
            if let recorded = aliases.first(where: { $0.component == first }) {
                guard recorded == alias else { throw CodexSessionScanner.ReadError.changedFile }
            } else { aliases.append(alias) }
            components.insert("private", at: 0)
        }
        return components
    }

    static func open(path: String, home: String) throws -> CodexTranscriptFile? {
        var aliases: [PlatformAlias] = []
        let root = try components(home, aliases: &aliases)
        let candidate = try components(path, aliases: &aliases)
        guard !root.isEmpty, candidate.count > root.count, candidate.starts(with: root) else {
            throw CodexSessionScanner.ReadError.unsafePath
        }
        var descriptor = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexSessionScanner.ReadError.unsafePath }
        defer { if descriptor >= 0 { Darwin.close(descriptor) } }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0, rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw CodexSessionScanner.ReadError.unsafePath
        }
        var identities = [Identity(rootInfo)]
        for (index, component) in candidate.enumerated() {
            let isFile = index == candidate.count - 1
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
                let file = CodexTranscriptFile(descriptor: descriptor, info: info, path: path, home: home,
                                               identities: identities, aliases: aliases)
                descriptor = -1
                return file
            }
        }
        throw CodexSessionScanner.ReadError.unsafePath
    }

    func isCurrent() -> Bool {
        guard let current = try? Self.open(path: path, home: home) else { return false }
        return current.identities == identities && current.aliases == aliases && current.version == version
    }
}
