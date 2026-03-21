import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import TBDShared

/// Errors from the DaemonClient.
enum DaemonClientError: Error, CustomStringConvertible, Sendable {
    case daemonNotRunning
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case invalidResponse
    case rpcError(String)

    var description: String {
        switch self {
        case .daemonNotRunning:
            return "TBD daemon is not running"
        case .connectionFailed(let msg):
            return "Connection failed: \(msg)"
        case .sendFailed(let msg):
            return "Send failed: \(msg)"
        case .receiveFailed(let msg):
            return "Receive failed: \(msg)"
        case .invalidResponse:
            return "Invalid response from daemon"
        case .rpcError(let msg):
            return "RPC error: \(msg)"
        }
    }
}

/// Actor that communicates with the TBD daemon over a Unix domain socket.
/// Uses one-shot POSIX socket connections per RPC call (same approach as the CLI).
actor DaemonClient {
    private let socketPath: String
    private(set) var connected: Bool = false

    init(socketPath: String = TBDConstants.socketPath) {
        self.socketPath = socketPath
    }

    // MARK: - Connection

    /// Attempt to connect to the daemon (verifies socket exists and is reachable).
    func connect() -> Bool {
        do {
            _ = try sendRaw(RPCRequest(method: RPCMethod.daemonStatus))
            connected = true
            return true
        } catch {
            connected = false
            return false
        }
    }

    // MARK: - Low-level socket communication

    /// Send an RPCRequest over a fresh POSIX Unix socket and return the RPCResponse.
    private func sendRaw(_ request: RPCRequest) throws -> RPCResponse {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw DaemonClientError.daemonNotRunning
        }

        // Create socket
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonClientError.connectionFailed("Could not create socket")
        }
        defer { close(fd) }

        // Connect
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            throw DaemonClientError.connectionFailed("Socket path too long")
        }
        withUnsafeMutablePointer(to: &addr.sun_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: pathBytes.count) { dest in
                for i in 0..<pathBytes.count {
                    dest[i] = pathBytes[i]
                }
            }
        }

        let connectResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard connectResult == 0 else {
            throw DaemonClientError.daemonNotRunning
        }

        // Encode request as JSON + newline
        let encoder = JSONEncoder()
        let requestData = try encoder.encode(request)
        var message = requestData
        message.append(contentsOf: [0x0A]) // newline delimiter

        // Send
        let sent = message.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress!, buffer.count, 0)
        }
        guard sent == message.count else {
            throw DaemonClientError.sendFailed("Sent \(sent) of \(message.count) bytes")
        }

        // Read response until newline or connection closes
        var responseData = Data()
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while true {
            let bytesRead = recv(fd, buffer, bufferSize, 0)
            if bytesRead < 0 {
                throw DaemonClientError.receiveFailed("recv failed with errno \(errno)")
            }
            if bytesRead == 0 {
                break
            }
            responseData.append(buffer, count: bytesRead)
            if responseData.contains(0x0A) {
                break
            }
        }

        // Trim trailing newline
        if let newlineIndex = responseData.firstIndex(of: 0x0A) {
            responseData = responseData[responseData.startIndex..<newlineIndex]
        }

        guard !responseData.isEmpty else {
            throw DaemonClientError.invalidResponse
        }

        let decoder = JSONDecoder()
        return try decoder.decode(RPCResponse.self, from: responseData)
    }

    /// Send an RPC request with typed params and decode a typed result.
    private func call<P: Encodable, R: Decodable>(
        method: String, params: P, resultType: R.Type
    ) throws -> R {
        let request = try RPCRequest(method: method, params: params)
        let response = try sendRaw(request)
        guard response.success else {
            throw DaemonClientError.rpcError(response.error ?? "Unknown error")
        }
        return try response.decodeResult(resultType)
    }

    /// Send an RPC request with typed params that returns no meaningful result.
    private func callVoid<P: Encodable>(method: String, params: P) throws {
        let request = try RPCRequest(method: method, params: params)
        let response = try sendRaw(request)
        guard response.success else {
            throw DaemonClientError.rpcError(response.error ?? "Unknown error")
        }
    }

    /// Send an RPC request with no params and decode a typed result.
    private func callNoParams<R: Decodable>(method: String, resultType: R.Type) throws -> R {
        let request = RPCRequest(method: method)
        let response = try sendRaw(request)
        guard response.success else {
            throw DaemonClientError.rpcError(response.error ?? "Unknown error")
        }
        return try response.decodeResult(resultType)
    }

    // MARK: - Typed RPC Methods

    /// Add a repository by path.
    func addRepo(path: String) throws -> Repo {
        connected = true
        return try call(
            method: RPCMethod.repoAdd,
            params: RepoAddParams(path: path),
            resultType: Repo.self
        )
    }

    /// Remove a repository.
    func removeRepo(repoID: UUID, force: Bool = false) throws {
        try callVoid(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repoID, force: force)
        )
    }

    /// List all repositories.
    func listRepos() throws -> [Repo] {
        return try callNoParams(method: RPCMethod.repoList, resultType: [Repo].self)
    }

    /// Create a new worktree in a repo.
    func createWorktree(repoID: UUID) throws -> Worktree {
        return try call(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID),
            resultType: Worktree.self
        )
    }

    /// List worktrees, optionally filtered by repo and/or status.
    func listWorktrees(repoID: UUID? = nil, status: WorktreeStatus? = nil) throws -> [Worktree] {
        return try call(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repoID, status: status),
            resultType: [Worktree].self
        )
    }

    /// Archive a worktree.
    func archiveWorktree(id: UUID, force: Bool = false) throws {
        try callVoid(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: id, force: force)
        )
    }

    /// Revive an archived worktree.
    func reviveWorktree(id: UUID) throws {
        try callVoid(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: id)
        )
    }

    /// Rename a worktree's display name.
    func renameWorktree(id: UUID, displayName: String) throws {
        try callVoid(
            method: RPCMethod.worktreeRename,
            params: WorktreeRenameParams(worktreeID: id, displayName: displayName)
        )
    }

    /// Create a terminal in a worktree.
    func createTerminal(worktreeID: UUID, cmd: String? = nil) throws -> Terminal {
        return try call(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd),
            resultType: Terminal.self
        )
    }

    /// List terminals for a worktree.
    func listTerminals(worktreeID: UUID) throws -> [Terminal] {
        return try call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID),
            resultType: [Terminal].self
        )
    }

    /// Send text to a terminal.
    func sendToTerminal(terminalID: UUID, text: String) throws {
        try callVoid(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminalID, text: text)
        )
    }

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil) throws {
        try callVoid(
            method: RPCMethod.notify,
            params: NotifyParams(worktreeID: worktreeID, type: type, message: message)
        )
    }

    /// Get daemon status.
    func daemonStatus() throws -> DaemonStatusResult {
        return try callNoParams(method: RPCMethod.daemonStatus, resultType: DaemonStatusResult.self)
    }

    /// Resolve a filesystem path to a repo/worktree.
    func resolvePath(_ path: String) throws -> ResolvedPathResult {
        return try call(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: path),
            resultType: ResolvedPathResult.self
        )
    }
}
