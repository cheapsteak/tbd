import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import TBDShared
import os

private let daemonClientLogger = Logger(subsystem: "com.tbd.app", category: "DaemonClient")

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
    /// If the daemon is not running, tries to find and launch `tbdd` automatically.
    func connect() async -> Bool {
        // First try to connect directly
        if tryConnect() {
            return true
        }

        // Daemon not running — try to auto-start it
        daemonClientLogger.info("Daemon not running, attempting auto-start...")
        if let tbddPath = findTbddBinary() {
            daemonClientLogger.info("Found tbdd at \(tbddPath), launching...")
            launchDaemon(at: tbddPath)

            // Wait for daemon to start (up to 4 seconds, polling every 0.5s)
            for attempt in 1...8 {
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                if tryConnect() {
                    daemonClientLogger.info("Connected to daemon after \(attempt) attempts")
                    return true
                }
            }
            daemonClientLogger.warning("Daemon launched but could not connect")
        } else {
            daemonClientLogger.warning("Could not find tbdd binary")
        }

        connected = false
        return false
    }

    /// Try a single connection attempt (non-async).
    private func tryConnect() -> Bool {
        do {
            _ = try sendRaw(RPCRequest(method: RPCMethod.daemonStatus))
            connected = true
            return true
        } catch {
            connected = false
            return false
        }
    }

    /// Find the tbdd binary by checking several locations.
    private func findTbddBinary() -> String? {
        // 1. Same directory as the running app binary
        if let execURL = Bundle.main.executableURL {
            let siblingURL = execURL.deletingLastPathComponent().appendingPathComponent("tbdd")
            if FileManager.default.isExecutableFile(atPath: siblingURL.path) {
                return siblingURL.path
            }
        }

        // 2. Try `which tbdd` via shell
        let whichProcess = Process()
        let pipe = Pipe()
        whichProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        whichProcess.arguments = ["which", "tbdd"]
        whichProcess.standardOutput = pipe
        whichProcess.standardError = FileHandle.nullDevice
        do {
            try whichProcess.run()
            whichProcess.waitUntilExit()
            if whichProcess.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let path, FileManager.default.isExecutableFile(atPath: path) {
                    return path
                }
            }
        } catch {
            // Fall through
        }

        // 3. Common paths
        let commonPaths = [
            "/usr/local/bin/tbdd",
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/tbdd").path,
        ]
        for path in commonPaths {
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    /// Launch the tbdd daemon as a background process.
    private func launchDaemon(at path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        // Detach so the daemon outlives the app
        process.qualityOfService = .utility
        do {
            try process.run()
            daemonClientLogger.info("Launched tbdd (pid: \(process.processIdentifier))")
        } catch {
            daemonClientLogger.error("Failed to launch tbdd: \(error)")
        }
    }

    // MARK: - Low-level socket communication

    /// Send an RPCRequest over a fresh POSIX Unix socket and return the RPCResponse.
    /// Wrapped in autoreleasepool to ensure ObjC-bridged objects (from JSON coding,
    /// FileManager, etc.) are freed immediately — prevents accumulation across
    /// the 2-second polling cycle.
    private func sendRaw(_ request: RPCRequest) throws -> RPCResponse {
        try autoreleasepool {
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
    func createWorktree(repoID: UUID, name: String? = nil) throws -> Worktree {
        return try call(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID, name: name),
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

    /// Set or clear the pin on a terminal.
    func setTerminalPin(id: UUID, pinned: Bool) throws {
        try callVoid(
            method: RPCMethod.terminalSetPin,
            params: TerminalSetPinParams(terminalID: id, pinned: pinned)
        )
    }

    /// Create a terminal in a worktree.
    func createTerminal(worktreeID: UUID, cmd: String? = nil, type: TerminalCreateType? = nil) throws -> Terminal {
        return try call(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type),
            resultType: Terminal.self
        )
    }

    /// List terminals, optionally filtered by worktree.
    func listTerminals(worktreeID: UUID? = nil) throws -> [Terminal] {
        return try call(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID),
            resultType: [Terminal].self
        )
    }

    /// Recreate a dead tmux window for an existing terminal (preserves terminal ID).
    func recreateTerminalWindow(terminalID: UUID) throws -> Terminal {
        return try call(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminalID),
            resultType: Terminal.self
        )
    }

    /// Delete a terminal (kills tmux window and removes DB record).
    func deleteTerminal(terminalID: UUID) throws {
        try callVoid(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminalID)
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

    /// List unread notifications grouped by worktree (highest severity per worktree).
    func listNotifications() throws -> [UUID: NotificationType] {
        let result = try callNoParams(method: RPCMethod.notificationsList, resultType: NotificationsListResult.self)
        return result.notifications
    }

    /// Mark notifications as read for a worktree.
    func markNotificationsRead(worktreeID: UUID) throws {
        try callVoid(
            method: RPCMethod.notificationsMarkRead,
            params: NotificationsMarkReadParams(worktreeID: worktreeID)
        )
    }

    /// Fetch all cached PR statuses from the daemon.
    func listPRStatuses() throws -> [UUID: PRStatus] {
        let result = try callNoParams(method: RPCMethod.prList, resultType: PRListResult.self)
        return result.statuses
    }

    /// Notify the daemon which worktrees are currently selected in the app.
    func worktreeSelectionChanged(selectedWorktreeIDs: Set<UUID>, suspendEnabled: Bool = true) throws {
        try callVoid(
            method: RPCMethod.worktreeSelectionChanged,
            params: WorktreeSelectionChangedParams(selectedWorktreeIDs: Array(selectedWorktreeIDs), suspendEnabled: suspendEnabled)
        )
    }

    /// Manually suspend a single Claude terminal.
    func terminalSuspend(terminalID: UUID) throws {
        try callVoid(
            method: RPCMethod.terminalSuspend,
            params: TerminalSuspendParams(terminalID: terminalID)
        )
    }

    /// Manually resume a single suspended terminal.
    func terminalResume(terminalID: UUID) throws {
        try callVoid(
            method: RPCMethod.terminalResume,
            params: TerminalResumeParams(terminalID: terminalID)
        )
    }

    /// Suspend all Claude terminals in a worktree.
    func worktreeSuspend(worktreeID: UUID) throws {
        try callVoid(
            method: RPCMethod.worktreeSuspend,
            params: WorktreeSuspendParams(worktreeID: worktreeID)
        )
    }

    /// Resume all suspended terminals in a worktree.
    func worktreeResume(worktreeID: UUID) throws {
        try callVoid(
            method: RPCMethod.worktreeResume,
            params: WorktreeResumeParams(worktreeID: worktreeID)
        )
    }

    /// Trigger an immediate PR status refresh for one worktree.
    /// Returns nil if no PR exists for the worktree's branch.
    func refreshPRStatus(worktreeID: UUID) throws -> PRStatus? {
        let result = try call(
            method: RPCMethod.prRefresh,
            params: PRRefreshParams(worktreeID: worktreeID),
            resultType: PRRefreshResult.self
        )
        return result.status
    }

    // MARK: - Notes

    /// Create a new note in a worktree.
    func createNote(worktreeID: UUID) throws -> Note {
        return try call(
            method: RPCMethod.noteCreate,
            params: NoteCreateParams(worktreeID: worktreeID),
            resultType: Note.self
        )
    }

    /// Get a note by ID.
    func getNote(noteID: UUID) throws -> Note {
        return try call(
            method: RPCMethod.noteGet,
            params: NoteGetParams(noteID: noteID),
            resultType: Note.self
        )
    }

    /// Update a note's title and/or content.
    func updateNote(noteID: UUID, title: String? = nil, content: String? = nil) throws -> Note {
        return try call(
            method: RPCMethod.noteUpdate,
            params: NoteUpdateParams(noteID: noteID, title: title, content: content),
            resultType: Note.self
        )
    }

    /// Delete a note.
    func deleteNote(noteID: UUID) throws {
        try callVoid(
            method: RPCMethod.noteDelete,
            params: NoteDeleteParams(noteID: noteID)
        )
    }

    /// List notes, optionally filtered by worktree.
    func listNotes(worktreeID: UUID? = nil) throws -> [Note] {
        return try call(
            method: RPCMethod.noteList,
            params: NoteListParams(worktreeID: worktreeID),
            resultType: [Note].self
        )
    }
}
