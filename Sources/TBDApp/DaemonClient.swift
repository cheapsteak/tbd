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
enum DaemonClientError: Error, CustomStringConvertible, LocalizedError, Sendable {
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

    var errorDescription: String? { description }
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

    /// Create a connected Unix domain socket to the daemon.
    /// Caller is responsible for closing the returned file descriptor.
    private nonisolated func makeConnectedSocket() throws -> Int32 {
        guard FileManager.default.fileExists(atPath: socketPath) else {
            throw DaemonClientError.daemonNotRunning
        }

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonClientError.connectionFailed("Could not create socket")
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketPath.utf8CString
        guard pathBytes.count <= MemoryLayout.size(ofValue: addr.sun_path) else {
            close(fd)
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
            close(fd)
            throw DaemonClientError.daemonNotRunning
        }

        return fd
    }

    /// Send an RPCRequest over a fresh POSIX Unix socket and return the RPCResponse.
    /// Wrapped in autoreleasepool to ensure ObjC-bridged objects (from JSON coding,
    /// FileManager, etc.) are freed immediately — prevents accumulation across
    /// the 2-second polling cycle.
    private nonisolated func sendRaw(_ request: RPCRequest) throws -> RPCResponse {
        try autoreleasepool {
            let fd = try makeConnectedSocket()
            defer { close(fd) }

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
                    let savedErrno = errno
                    // Retry transient interruptions. Blocking recv on a Unix
                    // socket can be kicked out with EINTR when the app process
                    // services signals (GCD timers, Combine, etc.) during a
                    // long handler like claudeToken.add where the daemon is
                    // itself waiting on a network round-trip to Anthropic.
                    if savedErrno == EINTR || savedErrno == EAGAIN {
                        continue
                    }
                    throw DaemonClientError.receiveFailed(
                        "recv failed with errno \(savedErrno) (\(String(cString: strerror(savedErrno))))"
                    )
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

    // MARK: - Async RPC helpers (dispatch blocking recv off the cooperative thread pool)

    /// Wraps the blocking `sendRaw` in a detached task so it runs on a background thread.
    private func sendRawAsync(_ request: RPCRequest) async throws -> RPCResponse {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.sendRaw(request)
        }.value
    }

    private func callVoidAsync<P: Encodable>(method: String, params: P) async throws {
        let request = try RPCRequest(method: method, params: params)
        let response = try await sendRawAsync(request)
        guard response.success else {
            throw DaemonClientError.rpcError(response.error ?? "Unknown error")
        }
    }

    private func callAsync<P: Encodable, R: Decodable>(
        method: String, params: P, resultType: R.Type
    ) async throws -> R {
        let request = try RPCRequest(method: method, params: params)
        let response = try await sendRawAsync(request)
        guard response.success else {
            throw DaemonClientError.rpcError(response.error ?? "Unknown error")
        }
        return try response.decodeResult(resultType)
    }

    private func callNoParamsAsync<R: Decodable>(method: String, resultType: R.Type) async throws -> R {
        let request = RPCRequest(method: method)
        let response = try await sendRawAsync(request)
        guard response.success else {
            throw DaemonClientError.rpcError(response.error ?? "Unknown error")
        }
        return try response.decodeResult(resultType)
    }

    // MARK: - Typed RPC Methods

    /// Add a repository by path.
    func addRepo(path: String) async throws -> Repo {
        connected = true
        return try await callAsync(
            method: RPCMethod.repoAdd,
            params: RepoAddParams(path: path),
            resultType: Repo.self
        )
    }

    /// Remove a repository.
    func removeRepo(repoID: UUID, force: Bool = false) async throws {
        try await callVoidAsync(
            method: RPCMethod.repoRemove,
            params: RepoRemoveParams(repoID: repoID, force: force)
        )
    }

    /// Relocate a repository to a new on-disk path.
    func relocateRepo(repoID: UUID, newPath: String) async throws -> RepoRelocateResult {
        return try await callAsync(
            method: RPCMethod.repoRelocate,
            params: RepoRelocateParams(repoID: repoID, newPath: newPath),
            resultType: RepoRelocateResult.self
        )
    }

    /// Update per-repo instruction fields.
    func repoUpdateInstructions(repoID: UUID, renamePrompt: String?, customInstructions: String?) async throws -> Repo {
        return try await callAsync(
            method: RPCMethod.repoUpdateInstructions,
            params: RepoUpdateInstructionsParams(repoID: repoID, renamePrompt: renamePrompt, customInstructions: customInstructions),
            resultType: Repo.self
        )
    }

    /// List all repositories.
    func listRepos() async throws -> [Repo] {
        return try await callNoParamsAsync(method: RPCMethod.repoList, resultType: [Repo].self)
    }

    /// Create a new worktree in a repo.
    func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, cols: Int? = nil, rows: Int? = nil) async throws -> Worktree {
        return try await callAsync(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID, folder: folder, branch: branch, displayName: displayName, cols: cols, rows: rows),
            resultType: Worktree.self
        )
    }

    /// List worktrees, optionally filtered by repo and/or status.
    func listWorktrees(repoID: UUID? = nil, status: WorktreeStatus? = nil) async throws -> [Worktree] {
        return try await callAsync(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(repoID: repoID, status: status),
            resultType: [Worktree].self
        )
    }

    /// Archive a worktree.
    func archiveWorktree(id: UUID, force: Bool = false) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeArchive,
            params: WorktreeArchiveParams(worktreeID: id, force: force)
        )
    }

    /// Revive an archived worktree.
    func reviveWorktree(id: UUID, cols: Int? = nil, rows: Int? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: id, cols: cols, rows: rows)
        )
    }

    /// Rename a worktree's display name.
    func renameWorktree(id: UUID, displayName: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeRename,
            params: WorktreeRenameParams(worktreeID: id, displayName: displayName)
        )
    }

    /// Reorder worktrees within a repo.
    func reorderWorktrees(repoID: UUID, worktreeIDs: [UUID]) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeReorder,
            params: WorktreeReorderParams(repoID: repoID, worktreeIDs: worktreeIDs)
        )
    }

    /// Set or clear the pin on a terminal.
    func setTerminalPin(id: UUID, pinned: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalSetPin,
            params: TerminalSetPinParams(terminalID: id, pinned: pinned)
        )
    }

    /// Create a terminal in a worktree.
    func createTerminal(worktreeID: UUID, cmd: String? = nil, type: TerminalCreateType? = nil, resumeSessionID: String? = nil, overrideTokenID: UUID? = nil, cols: Int? = nil, rows: Int? = nil) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type, resumeSessionID: resumeSessionID, overrideTokenID: overrideTokenID, cols: cols, rows: rows),
            resultType: Terminal.self
        )
    }

    /// List terminals, optionally filtered by worktree.
    func listTerminals(worktreeID: UUID? = nil) async throws -> [Terminal] {
        return try await callAsync(
            method: RPCMethod.terminalList,
            params: TerminalListParams(worktreeID: worktreeID),
            resultType: [Terminal].self
        )
    }

    /// Recreate a dead tmux window for an existing terminal (preserves terminal ID).
    func recreateTerminalWindow(terminalID: UUID, cols: Int? = nil, rows: Int? = nil) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.terminalRecreateWindow,
            params: TerminalRecreateWindowParams(terminalID: terminalID, cols: cols, rows: rows),
            resultType: Terminal.self
        )
    }

    /// Tell the daemon the app's main terminal area has been resized so it
    /// can `tmux resize-window` every tracked window. Used to keep detached
    /// panes' cell dims sane; attached panes get overwritten by SwiftTerm.
    func setMainAreaSize(cols: Int, rows: Int) async throws {
        try await callVoidAsync(
            method: RPCMethod.setMainAreaSize,
            params: SetMainAreaSizeParams(cols: cols, rows: rows)
        )
    }

    /// Delete a terminal (kills tmux window and removes DB record).
    func deleteTerminal(terminalID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalDelete,
            params: TerminalDeleteParams(terminalID: terminalID)
        )
    }

    /// Send text to a terminal.
    func sendToTerminal(terminalID: UUID, text: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalSend,
            params: TerminalSendParams(terminalID: terminalID, text: text)
        )
    }

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.notify,
            params: NotifyParams(worktreeID: worktreeID, type: type, message: message)
        )
    }

    /// Get daemon status.
    func daemonStatus() async throws -> DaemonStatusResult {
        return try await callNoParamsAsync(method: RPCMethod.daemonStatus, resultType: DaemonStatusResult.self)
    }

    /// Resolve a filesystem path to a repo/worktree.
    func resolvePath(_ path: String) async throws -> ResolvedPathResult {
        return try await callAsync(
            method: RPCMethod.resolvePath,
            params: ResolvePathParams(path: path),
            resultType: ResolvedPathResult.self
        )
    }

    /// List unread notifications grouped by worktree (highest severity per worktree).
    func listNotifications() async throws -> [UUID: NotificationType] {
        let result = try await callNoParamsAsync(method: RPCMethod.notificationsList, resultType: NotificationsListResult.self)
        return result.notifications
    }

    /// Mark notifications as read for a worktree.
    func markNotificationsRead(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.notificationsMarkRead,
            params: NotificationsMarkReadParams(worktreeID: worktreeID)
        )
    }

    /// Fetch all cached PR statuses from the daemon.
    func listPRStatuses() async throws -> [UUID: PRStatus] {
        let result = try await callNoParamsAsync(method: RPCMethod.prList, resultType: PRListResult.self)
        return result.statuses
    }

    /// Notify the daemon which worktrees are currently selected in the app.
    func worktreeSelectionChanged(selectedWorktreeIDs: Set<UUID>, suspendEnabled: Bool = true) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeSelectionChanged,
            params: WorktreeSelectionChangedParams(selectedWorktreeIDs: Array(selectedWorktreeIDs), suspendEnabled: suspendEnabled)
        )
    }

    /// Manually suspend a single Claude terminal.
    func terminalSuspend(terminalID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalSuspend,
            params: TerminalSuspendParams(terminalID: terminalID)
        )
    }

    /// Manually resume a single suspended terminal.
    func terminalResume(terminalID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalResume,
            params: TerminalResumeParams(terminalID: terminalID)
        )
    }

    /// Suspend all Claude terminals in a worktree.
    func worktreeSuspend(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeSuspend,
            params: WorktreeSuspendParams(worktreeID: worktreeID)
        )
    }

    /// Resume all suspended terminals in a worktree.
    func worktreeResume(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeResume,
            params: WorktreeResumeParams(worktreeID: worktreeID)
        )
    }

    /// Trigger an immediate PR status refresh for one worktree.
    /// Returns nil if no PR exists for the worktree's branch.
    func refreshPRStatus(worktreeID: UUID) async throws -> PRStatus? {
        let result = try await callAsync(
            method: RPCMethod.prRefresh,
            params: PRRefreshParams(worktreeID: worktreeID),
            resultType: PRRefreshResult.self
        )
        return result.status
    }

    // MARK: - State Subscription

    typealias DeltaHandler = @Sendable (StateDelta) -> Void

    /// Open a persistent socket that receives state deltas from the daemon.
    /// Runs in a loop until the socket disconnects or the task is cancelled.
    nonisolated func subscribe(onDelta: @escaping DeltaHandler) async {
        guard let fd = try? makeConnectedSocket() else { return }

        // Send subscribe request
        let request = RPCRequest(method: RPCMethod.stateSubscribe)
        guard let requestData = try? JSONEncoder().encode(request) else {
            close(fd)
            return
        }
        var message = requestData
        message.append(contentsOf: [0x0A])
        let sent = message.withUnsafeBytes { buffer in
            Darwin.send(fd, buffer.baseAddress!, buffer.count, 0)
        }
        guard sent == message.count else {
            daemonClientLogger.warning("subscribe: partial send (\(sent)/\(message.count) bytes)")
            close(fd)
            return
        }

        // Read loop
        let bufferSize = 65536
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer {
            buffer.deallocate()
            close(fd)
        }

        var accumulated = Data()
        let decoder = JSONDecoder()

        while !Task.isCancelled {
            let bytesRead = recv(fd, buffer, bufferSize, 0)
            if bytesRead <= 0 { break }

            accumulated.append(buffer, count: bytesRead)

            while let newlineIndex = accumulated.firstIndex(of: 0x0A) {
                let lineData = accumulated[accumulated.startIndex..<newlineIndex]
                accumulated = accumulated[accumulated.index(after: newlineIndex)...]

                // Skip the initial ack from SocketServer's subscription handler.
                // This is the only RPC that sends an RPCResponse with success=true
                // and no result — all other RPCs include a result payload.
                if let response = try? decoder.decode(RPCResponse.self, from: Data(lineData)),
                   response.success && response.result == nil {
                    continue
                }

                if let delta = try? decoder.decode(StateDelta.self, from: Data(lineData)) {
                    onDelta(delta)
                }
            }
        }
    }

    // MARK: - Notes

    /// Create a new note in a worktree.
    func createNote(worktreeID: UUID) async throws -> Note {
        return try await callAsync(
            method: RPCMethod.noteCreate,
            params: NoteCreateParams(worktreeID: worktreeID),
            resultType: Note.self
        )
    }

    /// Get a note by ID.
    func getNote(noteID: UUID) async throws -> Note {
        return try await callAsync(
            method: RPCMethod.noteGet,
            params: NoteGetParams(noteID: noteID),
            resultType: Note.self
        )
    }

    /// Update a note's title and/or content.
    func updateNote(noteID: UUID, title: String? = nil, content: String? = nil) async throws -> Note {
        return try await callAsync(
            method: RPCMethod.noteUpdate,
            params: NoteUpdateParams(noteID: noteID, title: title, content: content),
            resultType: Note.self
        )
    }

    /// Delete a note.
    func deleteNote(noteID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.noteDelete,
            params: NoteDeleteParams(noteID: noteID)
        )
    }

    /// List notes, optionally filtered by worktree.
    func listNotes(worktreeID: UUID? = nil) async throws -> [Note] {
        return try await callAsync(
            method: RPCMethod.noteList,
            params: NoteListParams(worktreeID: worktreeID),
            resultType: [Note].self
        )
    }

    // MARK: - Conductors

    /// List all conductors.
    func listConductors() async throws -> [Conductor] {
        let result = try await callNoParamsAsync(method: RPCMethod.conductorList, resultType: ConductorListResult.self)
        return result.conductors
    }

    /// Set up a new conductor with defaults.
    func conductorSetup(name: String, repos: [String] = ["*"]) async throws -> Conductor {
        return try await callAsync(
            method: RPCMethod.conductorSetup,
            params: ConductorSetupParams(name: name, repos: repos),
            resultType: Conductor.self
        )
    }

    /// Start a conductor.
    func conductorStart(name: String) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.conductorStart,
            params: ConductorNameParams(name: name),
            resultType: Terminal.self
        )
    }

    /// Stop a conductor.
    func conductorStop(name: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.conductorStop,
            params: ConductorNameParams(name: name)
        )
    }

    /// Teardown (remove) a conductor.
    func conductorTeardown(name: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.conductorTeardown,
            params: ConductorNameParams(name: name)
        )
    }

    /// Clear the navigation suggestion for a conductor.
    func conductorClearSuggestion(name: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.conductorClearSuggestion,
            params: ConductorNameParams(name: name)
        )
    }

    // MARK: - Claude Tokens
    //
    // IMPORTANT: never log raw token bytes. The `addClaudeToken` wrapper is
    // the only place a secret token crosses the actor boundary in the app
    // process — keep it out of any logger / print statement.

    /// List all Claude tokens with cached usage and the global default ID.
    func listClaudeTokens() async throws -> ClaudeTokenListResult {
        return try await callNoParamsAsync(method: RPCMethod.claudeTokenList, resultType: ClaudeTokenListResult.self)
    }

    /// Add a Claude token. The raw token string MUST NOT be logged.
    func addClaudeToken(name: String, token: String) async throws -> ClaudeTokenAddResult {
        return try await callAsync(
            method: RPCMethod.claudeTokenAdd,
            params: ClaudeTokenAddParams(name: name, token: token),
            resultType: ClaudeTokenAddResult.self
        )
    }

    /// Delete a Claude token by ID.
    func deleteClaudeToken(id: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.claudeTokenDelete,
            params: ClaudeTokenDeleteParams(id: id)
        )
    }

    /// Rename a Claude token.
    func renameClaudeToken(id: UUID, name: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.claudeTokenRename,
            params: ClaudeTokenRenameParams(id: id, name: name)
        )
    }

    /// Set or clear the global default Claude token.
    func setGlobalDefaultClaudeToken(id: UUID?) async throws {
        try await callVoidAsync(
            method: RPCMethod.claudeTokenSetGlobalDefault,
            params: ClaudeTokenSetGlobalDefaultParams(id: id)
        )
    }

    /// Set or clear a per-repo Claude token override.
    func setRepoClaudeTokenOverride(repoID: UUID, tokenID: UUID?) async throws {
        try await callVoidAsync(
            method: RPCMethod.claudeTokenSetRepoOverride,
            params: ClaudeTokenSetRepoOverrideParams(repoID: repoID, tokenID: tokenID)
        )
    }

    /// Fetch fresh usage for a single Claude token (60s server-side dedupe).
    func fetchClaudeTokenUsage(id: UUID) async throws -> ClaudeTokenUsage {
        let result = try await callAsync(
            method: RPCMethod.claudeTokenFetchUsage,
            params: ClaudeTokenFetchUsageParams(id: id),
            resultType: ClaudeTokenFetchUsageResult.self
        )
        return result.usage
    }

    /// Swap the Claude token associated with a running terminal.
    /// Returns the newly created Terminal (the daemon forks a new tab).
    func swapClaudeTokenOnTerminal(terminalID: UUID, newTokenID: UUID?, cols: Int? = nil, rows: Int? = nil) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.terminalSwapClaudeToken,
            params: TerminalSwapClaudeTokenParams(terminalID: terminalID, newTokenID: newTokenID, cols: cols, rows: rows),
            resultType: Terminal.self
        )
    }

    /// List Claude session summaries for a worktree.
    func listSessions(worktreeID: UUID) async throws -> [SessionSummary] {
        return try await callAsync(
            method: RPCMethod.sessionList,
            params: SessionListParams(worktreeID: worktreeID),
            resultType: [SessionSummary].self
        )
    }

    /// Load full chat messages for a session file.
    func sessionMessages(filePath: String) async throws -> [ChatMessage] {
        return try await callAsync(
            method: RPCMethod.sessionMessages,
            params: SessionMessagesParams(filePath: filePath),
            resultType: [ChatMessage].self
        )
    }

    /// Notify the daemon whether the app is in the foreground (drives usage poller).
    func setAppForegroundState(isForeground: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.appSetForegroundState,
            params: AppSetForegroundStateParams(isForeground: isForeground)
        )
    }
}
