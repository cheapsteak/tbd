import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import TBDShared
import os

private let daemonClientLogger = Logger(subsystem: "com.tbd.app", category: "DaemonClient")
private let perfTranscriptLog = Logger(subsystem: "com.tbd.app", category: "perf-transcript")

/// Errors from the DaemonClient.
enum DaemonClientError: Error, CustomStringConvertible, LocalizedError, Sendable {
    case daemonNotRunning
    case connectionFailed(String)
    case sendFailed(String)
    case receiveFailed(String)
    case invalidResponse
    case rpcError(String, code: String?)
    case attachUnavailable(String)

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
        case .rpcError(let msg, _):
            return "RPC error: \(msg)"
        case .attachUnavailable(let status):
            return "Control-mode attach unavailable (status: \(status))"
        }
    }

    var errorDescription: String? { description }

    /// The daemon-attached `RPCErrorCode` raw value, when present.
    var rpcCode: String? {
        if case .rpcError(_, let code) = self { return code }
        return nil
    }
}

/// `openAttach` failed AFTER `attach.request` succeeded — the daemon minted
/// an attach (generation known, sink allocated) but the vended fd never
/// arrived on the sidecar (timeout, supersession, or disconnect). The minted
/// generation rides the error (R6-H2) so the caller's failure teardown stays
/// generation-scoped: a nil-generation `pane.detach` here is UNCONDITIONAL
/// and can kill a healthy racing re-attach's fresh sink (the 56029f5b class,
/// from a different throw site). `generation` is nil only when an older
/// daemon minted none.
struct AttachFDVendError: LocalizedError {
    let generation: UInt64?
    let underlying: any Error

    var errorDescription: String? {
        let gen = generation.map(String.init) ?? "none"
        return "Attach fd vend failed (generation: \(gen)): \(underlying.localizedDescription)"
    }
}

/// Actor that communicates with the TBD daemon over a Unix domain socket.
/// Uses one-shot POSIX socket connections per RPC call (same approach as the CLI).
actor DaemonClient {
    private let socketPath: String
    private(set) var connected: Bool = false

    /// Sidecar for receiving vended pane fds. Connected eagerly right after
    /// the RPC socket, so the daemon's accept has completed long before the
    /// first attach needs it. Failure is non-fatal: control-mode attaches
    /// will fail and fall back to grouped sessions.
    let fdSidecar = FDSidecarClient()

    /// Upper bound a single one-shot RPC waits for the daemon's response
    /// before failing. Generous so legitimately slow handlers (model-profile
    /// add → Anthropic round-trip; worktree create/revive with blocking
    /// preSession hooks) still complete — it exists only to convert a
    /// half-dead-daemon hang into a bounded failure instead of a permanently
    /// parked background thread. Per-recv granularity is SO_RCVTIMEO (1s).
    /// 300s is deliberately generous: worktree create/revive can run a blocking
    /// preSession hook (e.g. `npm install`) that legitimately exceeds 2 minutes,
    /// so a shorter bound risks failing real work. The frequent poll path
    /// returns in milliseconds and never approaches this ceiling.
    nonisolated static let rpcRecvDeadlineSeconds: TimeInterval = 300

    init(socketPath: String? = nil) {
        // See HookResolver — resolve here, not at the caller's site.
        self.socketPath = socketPath ?? TBDConstants.socketPath
    }

    // MARK: - Connection

    /// Attempt to connect to the daemon (verifies socket exists and is reachable).
    /// If the daemon is not running, tries to find and launch `tbdd` automatically.
    func connect() async -> Bool {
        // First try to connect directly
        if tryConnect() {
            connectSidecar()
            return true
        }

        // Daemon not running — try to auto-start it
        daemonClientLogger.info("Daemon not running, attempting auto-start...")
        if let tbddPath = findTbddBinary() {
            daemonClientLogger.info("Found tbdd at \(tbddPath), launching...")
            launchDaemon(at: tbddPath)

            // Wait for daemon to start (up to 4 seconds, polling every 0.5s)
            for attempt in 1...8 {
                // swiftlint:disable:next no_raw_task_sleep - legacy sleep, see docs/specs/2026-07-24-test-hardening-design.md
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                if tryConnect() {
                    daemonClientLogger.info("Connected to daemon after \(attempt) attempts")
                    connectSidecar()
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

    /// Connect the FD-vending sidecar right after the RPC socket comes up.
    /// Eager (not lazy-on-first-attach) so the daemon's accept has completed
    /// long before any `attach.request` needs `send()` to work. Best-effort:
    /// on failure control-mode attaches fail and fall back to grouped
    /// sessions. Idempotent — `FDSidecarClient.connect` no-ops when already
    /// connected, so reconnect retries are safe.
    private func connectSidecar() {
        do {
            try fdSidecar.connect(path: TBDConstants.vendSocketPath)
        } catch {
            daemonClientLogger.warning(
                "FD sidecar connect failed (control-mode attach unavailable): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Try a single connection attempt (non-async).
    private func tryConnect() -> Bool {
        do {
            try sendRaw(RPCRequest(method: RPCMethod.daemonStatus)).finish()
            connected = true
            return true
        } catch {
            connected = false
            return false
        }
    }

    /// Find the TBDDaemon binary by checking sibling and source-worktree locations.
    private func findTbddBinary() -> String? {
        let sourceWorktreePath = SourceWorktreePathResolver.resolve(
            bundleURL: Bundle.main.bundleURL,
            executablePath: Bundle.main.executablePath
        )
        let candidates = DaemonCandidateFinder.daemonCandidatePaths(
            appExecutablePath: Bundle.main.executablePath,
            sourceWorktreePath: sourceWorktreePath
        )

        for path in candidates {
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

        // Bound every blocking recv() on this socket. Without this, a
        // half-dead daemon (connection stays ESTABLISHED with no FIN — e.g.
        // live tmux-server death) parks the reading thread in recv() forever,
        // saturating the cooperative pool and freezing the app↔daemon loop.
        // SO_RCVTIMEO makes recv() return -1/EAGAIN ~every second so callers
        // can re-check Task cancellation and overall deadlines.
        var recvTimeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &recvTimeout, socklen_t(MemoryLayout<timeval>.size))

        return fd
    }

    /// An `RPCResponse` paired with the still-open `RPCVolumeProbe`
    /// measurement of the frame that carried it.
    ///
    /// The envelope decode in `sendRaw` is only the first half of a response's
    /// cost: `RPCResponse.result` is a JSON *string*, so `decodeResult` runs a
    /// SECOND full decode over the whole payload, and that second decode is
    /// the expensive one this diagnostic exists to rank. Closing the
    /// measurement in `sendRaw` would report the string unescape and miss the
    /// structured parse entirely. So the measurement rides out to the caller
    /// and `finish()` closes it — after the typed decode where there is one,
    /// immediately where there is not (an error response, or a void call).
    private struct MeasuredResponse: Sendable {
        let response: RPCResponse
        let method: String
        let bytes: Int
        let start: UInt64?

        func finish() {
            RPCVolumeProbe.shared.record(
                start: start, kind: .response, type: method, bytes: bytes)
        }
    }

    /// Send an RPCRequest over a fresh POSIX Unix socket and return the RPCResponse.
    /// Wrapped in autoreleasepool to ensure ObjC-bridged objects (from JSON coding,
    /// FileManager, etc.) are freed immediately — prevents accumulation across
    /// the 2-second polling cycle.
    private nonisolated func sendRaw(_ request: RPCRequest) throws -> MeasuredResponse {
        // The app is the operator's hand: every request it makes is declared
        // `{"kind":"app"}` at this one encode chokepoint rather than at each
        // of the ~200 call sites.
        let request = request.stamping(actor: .app)
        return try autoreleasepool {
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

            // Read response until newline or connection closes.
            // NewlineFrameScanner scans only the just-received bytes for 0x0A
            // via memchr, avoiding the O(n²/chunk) re-scan that the previous
            // Data.contains call performed on the entire accumulated buffer.
            var scanner = NewlineFrameScanner()
            let bufferSize = 65536
            let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
            defer { buffer.deallocate() }

            let deadline = Date().addingTimeInterval(Self.rpcRecvDeadlineSeconds)
            while true {
                let bytesRead = recv(fd, buffer, bufferSize, 0)
                if bytesRead < 0 {
                    let savedErrno = errno
                    // EINTR: signal interruption (GCD timers, Combine) while a
                    // long daemon handler runs. EAGAIN/EWOULDBLOCK: SO_RCVTIMEO
                    // idle tick. Both mean "no data yet, not an error" — keep
                    // waiting until the overall deadline so a wedged daemon
                    // can't park this background thread indefinitely.
                    if savedErrno == EINTR || savedErrno == EAGAIN || savedErrno == EWOULDBLOCK {
                        if Date() >= deadline {
                            throw DaemonClientError.receiveFailed(
                                "recv timed out after \(Int(Self.rpcRecvDeadlineSeconds))s (daemon unresponsive)"
                            )
                        }
                        continue
                    }
                    throw DaemonClientError.receiveFailed(
                        "recv failed with errno \(savedErrno) (\(String(cString: strerror(savedErrno))))"
                    )
                }
                if bytesRead == 0 {
                    break
                }
                scanner.append(buffer, count: bytesRead)
                if scanner.hasNewline {
                    break
                }
            }

            // frameData is everything before the first newline; falls back to
            // the full buffer when no newline was received (connection closed).
            let responseData = scanner.frameData

            guard !responseData.isEmpty else {
                throw DaemonClientError.invalidResponse
            }

            // Probe is default-off; when off `startMeasurement()` reads no
            // clock and `record` returns on the nil start. The measurement is
            // NOT closed here — see `MeasuredResponse`.
            let started = RPCVolumeProbe.shared.startMeasurement()
            let decoder = JSONDecoder()
            let response = try decoder.decode(RPCResponse.self, from: responseData)
            return MeasuredResponse(
                response: response,
                method: request.method,
                bytes: responseData.count,
                start: started
            )
        }
    }

    /// Send an RPC request with typed params and decode a typed result.
    private func call<P: Encodable, R: Decodable>(
        method: String, params: P, resultType: R.Type
    ) throws -> R {
        let request = try RPCRequest(method: method, params: params)
        let measured = try sendRaw(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
        return try response.decodeResult(resultType)
    }

    /// Send an RPC request with typed params that returns no meaningful result.
    private func callVoid<P: Encodable>(method: String, params: P) throws {
        let request = try RPCRequest(method: method, params: params)
        let measured = try sendRaw(request)
        measured.finish()   // no typed result to wait for
        guard measured.response.success else {
            throw DaemonClientError.rpcError(
                measured.response.error ?? "Unknown error", code: measured.response.errorCode)
        }
    }

    /// Send an RPC request with no params and decode a typed result.
    private func callNoParams<R: Decodable>(method: String, resultType: R.Type) throws -> R {
        let request = RPCRequest(method: method)
        let measured = try sendRaw(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
        return try response.decodeResult(resultType)
    }

    // MARK: - Async RPC helpers (dispatch blocking recv off the cooperative thread pool)

    /// Wraps the blocking `sendRaw` in a detached task so it runs on a background thread.
    private func sendRawAsync(_ request: RPCRequest) async throws -> MeasuredResponse {
        try await Task.detached(priority: .userInitiated) { [self] in
            try self.sendRaw(request)
        }.value
    }

    private func callVoidAsync<P: Encodable>(method: String, params: P) async throws {
        let request = try RPCRequest(method: method, params: params)
        let measured = try await sendRawAsync(request)
        measured.finish()   // no typed result to wait for
        guard measured.response.success else {
            throw DaemonClientError.rpcError(
                measured.response.error ?? "Unknown error", code: measured.response.errorCode)
        }
    }

    private func callAsync<P: Encodable, R: Decodable>(
        method: String, params: P, resultType: R.Type
    ) async throws -> R {
        let request = try RPCRequest(method: method, params: params)
        let measured = try await sendRawAsync(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
        return try response.decodeResult(resultType)
    }

    private func callNoParamsAsync<R: Decodable>(method: String, resultType: R.Type) async throws -> R {
        let request = RPCRequest(method: method)
        let measured = try await sendRawAsync(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
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

    /// Rename a repo's display name.
    func renameRepo(id: UUID, displayName: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.repoRename,
            params: RepoRenameParams(repoID: id, displayName: displayName)
        )
    }

    /// Toggle whether a repo is hidden from the sidebar by default.
    func setRepoHidden(id: UUID, hidden: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.repoSetHidden,
            params: RepoSetHiddenParams(repoID: id, hidden: hidden)
        )
    }

    /// Toggle whether a repo section is expanded in the sidebar.
    func setRepoExpanded(id: UUID, expanded: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.repoSetExpanded,
            params: RepoSetExpandedParams(repoID: id, expanded: expanded)
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
    /// When `useExistingBranch` is true, `branch` MUST be set to an existing
    /// ref name (local like `foo` or remote like `origin/foo`) — the daemon
    /// checks it out instead of creating a new `tbd/*` branch.
    func createWorktree(repoID: UUID, folder: String? = nil, branch: String? = nil, displayName: String? = nil, cols: Int? = nil, rows: Int? = nil, parentWorktreeID: UUID? = nil, useExistingBranch: Bool = false, profileID: UUID? = nil, model: String? = nil, primaryAgentPreference: PrimaryAgentPreference? = nil, prNumber: Int? = nil, checkoutPRHead: Bool? = nil) async throws -> Worktree {
        return try await callAsync(
            method: RPCMethod.worktreeCreate,
            params: WorktreeCreateParams(repoID: repoID, folder: folder, branch: branch, displayName: displayName, cols: cols, rows: rows, parentWorktreeID: parentWorktreeID, useExistingBranch: useExistingBranch, profileID: profileID, model: model, primaryAgentPreference: primaryAgentPreference, prNumber: prNumber, checkoutPRHead: checkoutPRHead),
            resultType: Worktree.self
        )
    }

    func fetchCodexUsage() async throws -> CodexUsageResult {
        try await callNoParamsAsync(
            method: RPCMethod.codexUsageFetch,
            resultType: CodexUsageResult.self
        )
    }

    /// Create a repo-less scratch worktree.
    func createScratch(name: String? = nil) async throws -> Worktree {
        return try await callAsync(
            method: RPCMethod.scratchCreate,
            params: ScratchCreateParams(name: name),
            resultType: Worktree.self
        )
    }

    /// Delete a scratch worktree: closes its terminals and moves its folder to Trash.
    func deleteScratch(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.scratchDelete,
            params: ScratchDeleteParams(worktreeID: worktreeID)
        )
    }

    /// Archive a scratch worktree: closes its terminals, leaves the folder on disk.
    func archiveScratch(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.scratchArchive,
            params: ScratchArchiveParams(worktreeID: worktreeID)
        )
    }

    /// Revive an archived scratch worktree. Errors if its folder no longer exists on disk.
    func reviveScratch(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.scratchRevive,
            params: ScratchReviveParams(worktreeID: worktreeID)
        )
    }

    /// List local + `origin/*` branches for a repo. Used by the existing-
    /// branch picker on the sidebar `+` button.
    func listBranches(repoID: UUID) async throws -> [BranchInfo] {
        let result = try await callAsync(
            method: RPCMethod.repoListBranches,
            params: RepoListBranchesParams(repoID: repoID),
            resultType: RepoListBranchesResult.self
        )
        return result.branches
    }

    /// List open PRs for a repo (branch picker, two-phase load). Degrades to
    /// `[]` daemon-side on any `gh`/GraphQL failure — never an RPC error.
    func listOpenPRs(repoID: UUID) async throws -> [OpenPRInfo] {
        let result = try await callAsync(
            method: RPCMethod.repoListOpenPRs,
            params: RepoListOpenPRsParams(repoID: repoID),
            resultType: RepoListOpenPRsResult.self
        )
        return result.prs
    }

    /// List worktrees, optionally filtered by repo and/or status, with optional pagination.
    /// Pass `excludeArchived: true` to skip archived rows (used by the 2 s poll so
    /// the 87 % of payload that is immediately dropped client-side never crosses the wire).
    /// Pass `scratchOnly: true` to restrict the result to repo-less (scratch)
    /// worktrees — otherwise `repoID: nil` means "no repo filter" (i.e. every
    /// repo plus scratch), not "scratch only".
    func listWorktrees(
        repoID: UUID? = nil,
        status: WorktreeStatus? = nil,
        limit: Int? = nil,
        offset: Int? = nil,
        excludeArchived: Bool = false,
        scratchOnly: Bool = false,
        includeSessionCounts: Bool? = nil,
        nameQuery: String? = nil
    ) async throws -> [Worktree] {
        return try await callAsync(
            method: RPCMethod.worktreeList,
            params: WorktreeListParams(
                repoID: repoID,
                status: status,
                limit: limit,
                offset: offset,
                excludeArchived: excludeArchived,
                scratchOnly: scratchOnly,
                includeSessionCounts: includeSessionCounts,
                nameQuery: nameQuery
            ),
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

    /// Re-run the worktree's `preSession` hook in a fresh, non-focused tab.
    /// Returns as soon as the tab exists; the hook itself runs on in the daemon.
    func rerunPreSessionHook(worktreeID: UUID, cols: Int? = nil, rows: Int? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeRerunPreSession,
            params: WorktreeRerunPreSessionParams(worktreeID: worktreeID, cols: cols, rows: rows)
        )
    }

    /// Revive an archived worktree. Returns the revived worktree as the daemon
    /// sees it when the RPC completes — still `.creating` while a blocking
    /// `preSession` hook runs, `.active` otherwise.
    func reviveWorktree(id: UUID, cols: Int? = nil, rows: Int? = nil, preferredSessionID: String? = nil) async throws -> Worktree {
        try await callAsync(
            method: RPCMethod.worktreeRevive,
            params: WorktreeReviveParams(worktreeID: id, cols: cols, rows: rows, preferredSessionID: preferredSessionID),
            resultType: Worktree.self
        )
    }

    /// Revive an archived conversation in a newly created worktree branch.
    func reviveConversationOnFreshBranch(
        worktreeID: UUID,
        sessionID: String,
        cols: Int? = nil,
        rows: Int? = nil
    ) async throws -> WorktreeReviveConversationFreshResult {
        try await callAsync(
            method: RPCMethod.worktreeReviveConversationFresh,
            params: WorktreeReviveConversationFreshParams(
                archivedWorktreeID: worktreeID,
                sessionID: sessionID,
                cols: cols,
                rows: rows
            ),
            resultType: WorktreeReviveConversationFreshResult.self
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

    /// Move a worktree to a new parent (or top-level) and sortOrder.
    func moveWorktree(worktreeID: UUID, newParentID: UUID?, newSortOrder: Int) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeMove,
            params: WorktreeMoveParams(
                worktreeID: worktreeID,
                newParentID: newParentID,
                newSortOrder: newSortOrder
            )
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
    func createTerminal(worktreeID: UUID, cmd: String? = nil, type: TerminalCreateType? = nil, resumeSessionID: String? = nil, overrideProfileID: UUID? = nil, loginSession: Bool? = nil, cols: Int? = nil, rows: Int? = nil, colorFgBg: String? = nil) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.terminalCreate,
            params: TerminalCreateParams(worktreeID: worktreeID, cmd: cmd, type: type, resumeSessionID: resumeSessionID, overrideProfileID: overrideProfileID, loginSession: loginSession, cols: cols, rows: rows, colorFgBg: colorFgBg),
            resultType: Terminal.self
        )
    }

    /// Import one Claude terminal's native transcript into Codex and open the
    /// returned thread as an ordinary Codex terminal.
    func continueInCodex(terminalID: UUID) async throws
        -> TerminalContinueInCodexResult {
        try await callAsync(
            method: RPCMethod.terminalContinueInCodex,
            params: TerminalContinueInCodexParams(terminalID: terminalID),
            resultType: TerminalContinueInCodexResult.self)
    }

    /// Compose the shell command that attaches an external terminal emulator
    /// to one terminal's tmux window.
    ///
    /// The daemon is the composer, not the caller: the socket path has to come
    /// from the environment that created the tmux server, and the pane's
    /// `@tbd_terminal_id` is verified before the window is named, so a stale
    /// coordinate cannot yield a command aimed at another session's window.
    /// Throws rather than returning a partial command — a caller must not put
    /// a half-formed script on the pasteboard.
    func terminalAttachCommand(worktreeID: UUID, terminalID: UUID) async throws
        -> TerminalAttachCommandResult {
        return try await callAsync(
            method: RPCMethod.terminalAttachCommand,
            params: TerminalAttachCommandParams(
                worktreeID: worktreeID, terminalID: terminalID),
            resultType: TerminalAttachCommandResult.self
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

    /// Update COLORFGBG environment variable in all known tmux servers.
    /// This notifies running shells that the terminal color scheme has changed,
    /// allowing tools like vim, less, fzf to auto-adjust their output.
    func updateAppearanceColorFgBg(value: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.appearanceUpdateColorFgBg,
            params: AppearanceUpdateColorFgBgParams(value: value)
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

    /// Publish an explicit terminal activity state transition.
    func setTerminalActivity(
        terminalID: UUID,
        activityState: TerminalActivityState,
        origin: TerminalActivityEventOrigin? = nil
    ) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalActivityEvent,
            params: TerminalActivityEventParams(
                terminalID: terminalID,
                activityState: activityState,
                origin: origin
            )
        )
    }

    /// Send a notification.
    func notify(worktreeID: UUID?, type: NotificationType, message: String? = nil,
                terminalID: UUID? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.notify,
            params: NotifyParams(worktreeID: worktreeID, type: type, message: message,
                                 terminalID: terminalID)
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

    /// Unread summaries grouped by worktree (highest-severity type + most-recent
    /// unread timestamp). Falls back to a synthesized summary with
    /// `Date.distantPast` if the daemon is an older build that only returns
    /// the legacy `notifications` field.
    func listNotifications() async throws -> [UUID: UnreadSummary] {
        let result = try await callNoParamsAsync(
            method: RPCMethod.notificationsList,
            resultType: NotificationsListResult.self
        )
        if let summaries = result.summaries {
            return summaries
        }
        return result.notifications.mapValues {
            UnreadSummary(type: $0, mostRecentAt: .distantPast)
        }
    }

    /// Mark notifications as read for a worktree.
    func markNotificationsRead(worktreeID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.notificationsMarkRead,
            params: NotificationsMarkReadParams(worktreeID: worktreeID)
        )
    }

    /// Fetch the daemon's PR snapshot: the cached values, and the outcome of
    /// the last attempt to learn each. Both halves are returned because they
    /// disagree — a value the last attempt failed to reconfirm is still the
    /// newest anyone has, and a worktree with no value may have no PR or may be
    /// one nobody could ask about.
    func listPRStatuses() async throws -> (statuses: [UUID: PRStatus], observations: [UUID: PRObservation]) {
        let result = try await callNoParamsAsync(method: RPCMethod.prList, resultType: PRListResult.self)
        return (result.statuses, result.observations)
    }

    /// Fetch EVERY worktree's live PR bindings (tombstoned ones are excluded by
    /// the daemon), each with a count of how many of its bindings ARE
    /// tombstoned, in a single round trip — the app's poll.
    ///
    /// Deliberately not a per-worktree call fanned out. The app has no way to
    /// name the worktrees worth asking about: a hook-bound PR on a branch the
    /// worktree never checked out appears in no branch-derived status cache, so
    /// a targeted fetch reaches only worktrees already known to have PRs and the
    /// hook-bound case stays invisible. One call also has one outcome, which is
    /// what lets a failure keep the previous map wholesale.
    ///
    /// The whole result is returned rather than just the bindings, because an
    /// empty list means two different things and only the tombstone count
    /// separates them — see `PRBindingsResult.detachedCount`. The per-worktree
    /// `pr.bindings` remains for `tbd pr list`.
    func listAllPRBindings() async throws -> PRBindingsAllResult {
        try await callNoParamsAsync(
            method: RPCMethod.prBindingsAll,
            resultType: PRBindingsAllResult.self
        )
    }

    /// Untrack one PR from one worktree — the same tombstoning `tbd pr detach`
    /// performs, so the app inherits its durability rather than inventing one:
    /// a delete would be undone by the next poll or hook fire.
    ///
    /// The PR is named by **URL, with its number as the fallback**. A status-bar
    /// chip can be synthetic — lifted from a cached `Worktree.prStatus` with no
    /// row behind it — so there is no binding id to name, and the daemon
    /// tombstones by identity whether or not a row matched.
    ///
    /// Both are sent because a legacy cached status can carry a url that does
    /// not parse (or none at all), and a control that quietly declines is the
    /// thing this gesture exists to replace. `resolvePRRef` prefers a non-empty
    /// url and resolves a bare number against the worktree's own repo, so the
    /// pair costs nothing when the url is good and saves the click when it is
    /// not.
    ///
    /// `source` is `manual` because the gesture records nothing but a user's
    /// decision, and that is what makes `pr.attach` able to reverse it.
    ///
    /// `detached: false` in the result is NOT a failure: it means the PR was
    /// already tombstoned. Only a thrown error is.
    func detachPR(worktreeID: UUID, url: String?, number: Int) async throws -> PRDetachResult {
        try await callAsync(
            method: RPCMethod.prDetach,
            params: PRBindingRefParams(
                worktreeID: worktreeID,
                url: url,
                number: number,
                source: PRBindingSource.manual.rawValue
            ),
            resultType: PRDetachResult.self
        )
    }

    /// Push the user's Claude spawn-env setting overrides to the daemon.
    func setClaudeSpawnPreferences(_ preferences: ClaudeSpawnPreferences) async throws {
        try await callVoidAsync(
            method: RPCMethod.claudeSetSpawnPreferences,
            params: preferences
        )
    }

    /// Push the global free-form env overrides to the daemon.
    func setGlobalEnvOverrides(_ overrides: [String: String]) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetEnvOverrides,
            params: SetGlobalEnvOverridesParams(overrides: overrides)
        )
    }

    /// Push the machine-wide remote create-param defaults to the daemon.
    func setGlobalRemoteCreateDefaults(_ defaults: [String: String]) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetRemoteCreateDefaults,
            params: SetGlobalRemoteCreateDefaultsParams(defaults: defaults)
        )
    }

    /// Set or clear a repo's remote create-param defaults.
    func setRepoRemoteCreateDefaults(repoID: UUID, defaults: [String: String]) async throws {
        try await callVoidAsync(
            method: RPCMethod.repoSetRemoteCreateDefaults,
            params: SetRepoRemoteCreateDefaultsParams(repoID: repoID, defaults: defaults)
        )
    }

    /// Set the per-worktree auto-archive-on-PR-merge override.
    func setWorktreeAutoArchive(id: UUID, enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeSetAutoArchive,
            params: WorktreeSetAutoArchiveParams(worktreeID: id, enabled: enabled)
        )
    }

    /// Set the global default for auto-archive-on-PR-merge.
    func setAutoArchiveOnMergeDefault(_ enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoArchiveOnMergeDefault,
            params: ConfigSetAutoArchiveDefaultParams(enabled: enabled)
        )
    }

    /// Set the per-worktree auto-hibernate-on-PR-merge override.
    func setWorktreeAutoHibernate(id: UUID, enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeSetAutoHibernate,
            params: WorktreeSetAutoHibernateParams(worktreeID: id, enabled: enabled)
        )
    }

    /// Pin or unpin a worktree for the sidebar dock.
    func setWorktreePin(id: UUID, pinned: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeSetPin,
            params: WorktreeSetPinParams(worktreeID: id, pinned: pinned)
        )
    }

    /// Persist a new order for the sidebar dock's pinned worktrees.
    func reorderPinnedWorktrees(worktreeIDs: [UUID]) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeReorderPins,
            params: WorktreeReorderPinsParams(worktreeIDs: worktreeIDs)
        )
    }

    /// Set the global default for auto-hibernate-on-PR-merge.
    func setAutoHibernateOnMergeDefault(_ enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoHibernateOnMergeDefault,
            params: ConfigSetAutoHibernateDefaultParams(enabled: enabled)
        )
    }

    /// Set the global session-limit auto-resume gate.
    func setAutoResumeOnLimitReset(_ enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoResumeOnLimitReset,
            params: ConfigSetAutoResumeOnLimitResetParams(enabled: enabled)
        )
    }

    /// Set the global transient-API-error auto-continue gate.
    func setAutoResumeOnApiError(_ enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoResumeOnApiError,
            params: ConfigSetAutoResumeOnApiErrorParams(enabled: enabled)
        )
    }

    /// Set the global scratch-space system-prompt override. Nil or blank resets to the built-in default.
    func setScratchInstructions(_ instructions: String?) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetScratchInstructions,
            params: ConfigSetScratchInstructionsParams(instructions: instructions)
        )
    }

    /// Set the global scratch-space rename-nudge override. Nil or blank resets to the built-in default.
    func setScratchRenamePrompt(_ value: String?) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetScratchRenamePrompt,
            params: ConfigSetScratchRenamePromptParams(renamePrompt: value)
        )
    }

    /// Fetch the global daemon config (used to read the current effective scratch-instructions override).
    func getConfig() async throws -> Config {
        try await callNoParamsAsync(method: RPCMethod.configGet, resultType: Config.self)
    }

    /// List reaped `ReapRecord`s from the orphan GC, optionally scoped to one
    /// repo's path (`nil` == every repo, including scratch reap records).
    func listReapRecords(repoPath: String?) async throws -> [ReapRecord] {
        try await callAsync(
            method: RPCMethod.gcList,
            params: GCListParams(repoPath: repoPath),
            resultType: [ReapRecord].self
        )
    }

    /// Restore a swept `ReapRecord` (agent worktrees only — snapshot-first).
    func restoreReap(recordID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.gcRestore,
            params: GCRestoreParams(recordID: recordID)
        )
    }

    /// Set the orphan-GC master switch.
    func setGCEnabled(_ enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetGCEnabled,
            params: ConfigSetGCEnabledParams(enabled: enabled)
        )
    }

    /// Set whether ordinary new worktrees start with an empty Notes tab.
    func setAutoCreateNotes(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoCreateNotes,
            params: ConfigSetAutoCreateNotesParams(enabled: enabled)
        )
    }

    /// Persist supervision's fleet-wide authority switch (design 2026-07-26
    /// §3, §7). `enabled: true` releases the fleet brake; `false` engages it.
    /// Shipped OFF (braked); for now inert, since the rest of the supervision
    /// subsystem is landing in the same series of changes.
    func setSupervisionEnabled(_ enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetSupervisionEnabled,
            params: ConfigSetSupervisionEnabledParams(enabled: enabled)
        )
    }

    /// Persist the tmux control-mode opt-in (M5). Applies to newly created
    /// panes; a truthy TBD_TMUX_CONTROL_MODE in the daemon's env still forces
    /// the gate on regardless of this flag.
    func setControlMode(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetControlMode,
            params: ConfigSetControlModeParams(enabled: enabled)
        )
    }

    /// Persist the pending-input veto for auto-hibernate (machine-interface
    /// guard that prevents hibernation of sessions with typed-but-unsent input).
    /// Applies on the next hibernation sweep.
    func setHibernateInputVeto(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetHibernateInputVeto,
            params: ConfigSetHibernateInputVetoParams(enabled: enabled)
        )
    }

    /// Persist the auto-close-setup-tab soak flag (default OFF). Applies to
    /// the next worktree creation.
    func setAutoCloseSetup(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoCloseSetup,
            params: ConfigSetAutoCloseSetupParams(enabled: enabled)
        )
    }

    /// Persist the queued-prompt soak flag (default OFF). Read fresh at spawn
    /// time and on every `worktree.setPendingPrompt`, so no daemon restart is
    /// needed; sending either value is an explicit gesture that survives a
    /// later change to the shipped default.
    func setQueuedPrompt(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetQueuedPrompt,
            params: ConfigSetQueuedPromptParams(enabled: enabled)
        )
    }

    /// Persist the Claude cloud sessions gate (default OFF). The daemon builds
    /// its provider manager only at boot, so this takes effect on the next
    /// daemon restart rather than the next gesture.
    func setClaudeCloud(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetClaudeCloud,
            params: ConfigSetClaudeCloudParams(enabled: enabled)
        )
    }

    /// Park the prompt composed while a worktree was still being created, to be
    /// delivered to its primary agent whenever that agent turns up. `text: nil`
    /// unparks. A second call replaces the first — one prompt per worktree, not
    /// a queue.
    func setPendingPrompt(
        worktreeID: UUID, text: String?, submit: Bool
    ) async throws -> WorktreeSetPendingPromptResult {
        try await callAsync(
            method: RPCMethod.worktreeSetPendingPrompt,
            params: WorktreeSetPendingPromptParams(
                worktreeID: worktreeID, text: text, submit: submit),
            resultType: WorktreeSetPendingPromptResult.self
        )
    }

    /// Persist the worktree auto-trust switch (default ON). Applies to the
    /// next Claude spawn or wake.
    func setAutoTrustWorktrees(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoTrustWorktrees,
            params: ConfigSetAutoTrustWorktreesParams(enabled: enabled)
        )
    }

    /// Set or clear a repo's free-form env overrides.
    func setRepoEnvOverrides(repoID: UUID, overrides: [String: String]) async throws {
        try await callVoidAsync(
            method: RPCMethod.repoSetEnvOverrides,
            params: SetRepoEnvOverridesParams(repoID: repoID, overrides: overrides)
        )
    }

    /// Set or clear a model profile's free-form env overrides.
    func setProfileEnvOverrides(profileID: UUID, overrides: [String: String]) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileSetEnvOverrides,
            params: SetProfileEnvOverridesParams(profileID: profileID, overrides: overrides)
        )
    }

    // MARK: - Remote agent backends

    /// List every registered remote-agent provider's negotiated contract + current health.
    func remoteProviders() async throws -> RemoteProvidersResult {
        try await callNoParamsAsync(method: RPCMethod.remoteProviders, resultType: RemoteProvidersResult.self)
    }

    /// List the daemon's remote-session mirror across all providers.
    func remoteSessions() async throws -> RemoteSessionsResult {
        try await callNoParamsAsync(method: RPCMethod.remoteSessions, resultType: RemoteSessionsResult.self)
    }

    /// Create a new remote session via `provider`. `paramsJSON` is the raw JSON
    /// object of create-form values, passed through to the provider verbatim.
    ///
    /// `parentWorktreeID` is the worktree whose nested `+` started this — a
    /// TBD-local request to file the resulting lane under that row. It is not
    /// part of the provider contract and never reaches the provider; the daemon
    /// applies it when it adopts the created session.
    func remoteCreate(
        provider: String, paramsJSON: String, parentWorktreeID: UUID? = nil
    ) async throws -> RemoteSessionPayload {
        try await callAsync(
            method: RPCMethod.remoteCreate,
            params: RemoteCreateParams(
                provider: provider, paramsJSON: paramsJSON,
                parentWorktreeID: parentWorktreeID),
            resultType: RemoteSessionPayload.self
        )
    }

    /// Stop a remote session.
    func remoteStop(provider: String, sessionID: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.remoteStop,
            params: RemoteStopParams(provider: provider, sessionID: sessionID)
        )
    }

    /// Send text input to a remote session.
    func remoteSend(provider: String, sessionID: String, text: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.remoteSend,
            params: RemoteSendParams(provider: provider, sessionID: sessionID, text: text)
        )
    }

    /// Fetch recent log lines for a remote session. `lines` nil == provider default.
    func remoteLog(provider: String, sessionID: String, lines: Int? = nil) async throws -> RemoteLogResult {
        try await callAsync(
            method: RPCMethod.remoteLog,
            params: RemoteLogParams(provider: provider, sessionID: sessionID, lines: lines),
            resultType: RemoteLogResult.self
        )
    }

    /// Push a display-name rename to a provider that declares the `rename`
    /// capability (docs/remote-provider-contract.md § `rename`). Callers must
    /// check the capability themselves (`AppState.pushRemoteRenameIfSupported`)
    /// before calling — this method, like `remoteSend`/`remoteLog`, does not
    /// re-check it.
    func remoteRename(provider: String, sessionID: String, title: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.remoteRename,
            params: RemoteRenameParams(provider: provider, sessionID: sessionID, title: title)
        )
    }

    /// Dismiss a gone/errored remote session from the mirror.
    func remoteDismiss(provider: String, sessionID: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.remoteDismiss,
            params: RemoteDismissParams(provider: provider, sessionID: sessionID)
        )
    }

    /// Pin or unpin a remote session for the sidebar's pinned dock. The
    /// `pinnedAt` timestamp is stamped daemon-side, so pin ORDER is
    /// server-assigned — the client only says whether it wants the pin on or
    /// off (mirrors `setWorktreePin`).
    func setRemoteSessionPin(provider: String, sessionID: String, pinned: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.remoteSetPin,
            params: RemoteSetPinParams(provider: provider, sessionID: sessionID, pinned: pinned)
        )
    }

    /// Report the exit code of an `attach` process this app spawned, so the
    /// daemon can correlate an auth-class exit with provider health. The
    /// daemon ignores every non-auth class (transport failures are already
    /// handled app-side by reconnect backoff) — see
    /// `RemoteProviderManager.recordAttachExit`.
    func reportRemoteAttachExit(provider: String, sessionID: String, exitCode: Int32) async throws {
        try await callVoidAsync(
            method: RPCMethod.remoteReportAttachExit,
            params: RemoteReportAttachExitParams(provider: provider, sessionID: sessionID, exitCode: exitCode)
        )
    }

    /// Set the remote-agent-backends master switch.
    func setRemoteBackends(enabled: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetRemoteBackends,
            params: ConfigSetRemoteBackendsParams(enabled: enabled)
        )
    }

    /// Request a control-mode attach for one pane; the fd arrives separately
    /// on the sidecar (see `openAttach`).
    func attachRequest(
        worktreeID: UUID, paneID: String, windowID: String, attachID: UUID
    ) async throws -> AttachRequestResult {
        try await callAsync(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(
                worktreeID: worktreeID, paneID: paneID, windowID: windowID, attachID: attachID),
            resultType: AttachRequestResult.self
        )
    }

    /// Request an attach and receive the vended fd via the sidecar. Returns
    /// the read fd (ownership passes to the caller's reader) plus the attach
    /// generation the daemon minted (echo it back in `paneDetach` so a stale
    /// detach cannot kill a newer attach's sink; nil from older daemons).
    /// Does NOT send `attach.ready` — the caller does that after wiring the
    /// reader.
    ///
    /// Ordering: the sidecar expectation is registered BEFORE the RPC is
    /// issued, so the vended fd can never race past its waiter; the header
    /// demux (`FDSidecarClient`) is what keeps concurrent attaches for
    /// different panes from cross-delivering fds.
    func openAttach(
        worktreeID: UUID, paneID: String, windowID: String
    ) async throws -> (fd: Int32, generation: UInt64?) {
        // Fresh nonce per attach: the daemon echoes it in the vend header, so
        // a superseded attach's stale fd can never be delivered to this one.
        let attachID = UUID()
        let promise = fdSidecar.expectFD(worktreeID: worktreeID, paneID: paneID, attachID: attachID)
        let generation: UInt64?
        do {
            let result = try await attachRequest(
                worktreeID: worktreeID, paneID: paneID, windowID: windowID, attachID: attachID)
            guard result.status == "pending" else {
                promise.cancel()
                throw DaemonClientError.attachUnavailable(result.status)
            }
            generation = result.generation
        } catch {
            promise.cancel()
            throw error
        }
        do {
            return (try await promise.value(timeout: .seconds(5)), generation)
        } catch {
            // attach.request already succeeded, so the daemon-minted
            // generation is known — it must survive this throw (R6-H2): the
            // caller's failure teardown detaches by it, and losing it here
            // would force the unconditional nil-generation detach that can
            // kill a healthy racing re-attach.
            throw AttachFDVendError(generation: generation, underlying: error)
        }
    }

    /// Ack that the app's reader is draining the vended fd — opens the
    /// daemon-side write gate. Pass the `generation` from `openAttach` so the
    /// daemon runs the replay sequence only if this attach still owns the
    /// pane — a stale ready (superseded by a faster re-attach) must not
    /// pause/unpause the pane out from under the successor's sequence; nil
    /// (unknown generation) acks unchecked, as before.
    func attachReady(worktreeID: UUID, paneID: String, generation: UInt64? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(
                worktreeID: worktreeID, paneID: paneID, generation: generation)
        )
    }

    /// Tell the daemon this pane is no longer rendered; the daemon closes the
    /// pipe write end and the app-side reader sees EOF. Pass the `generation`
    /// from `openAttach` so the daemon detaches generation-checked — a stale
    /// detach from a closing view must not kill a newer attach's sink; nil
    /// (unknown generation) detaches unconditionally, as before.
    func paneDetach(worktreeID: UUID, paneID: String, generation: UInt64? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.paneDetach,
            params: PaneDetachParams(worktreeID: worktreeID, paneID: paneID, generation: generation)
        )
    }

    /// Tell the daemon the desired size for one control-mode window. Debounced
    /// by the caller; the daemon arbitrates the `resize-window` with echo
    /// suppression (addendum §4). Fire-and-forget from the app's view: errors
    /// are dropped because the resize is re-fired repeatedly and the next tick
    /// self-heals.
    func paneResize(worktreeID: UUID, windowID: String, cols: Int, rows: Int) async throws {
        try await callVoidAsync(
            method: RPCMethod.paneResize,
            params: PaneResizeParams(
                worktreeID: worktreeID, windowID: windowID, cols: cols, rows: rows)
        )
    }

    /// Fetch daemon feature flags (e.g. whether the tmux control-mode gate is
    /// on). The app cannot read the daemon's env itself — it is launched via
    /// `open`, which drops shell env.
    func daemonCapabilities() async throws -> DaemonCapabilitiesResult {
        try await callNoParamsAsync(
            method: RPCMethod.daemonCapabilities,
            resultType: DaemonCapabilitiesResult.self
        )
    }

    /// Read daemon-owned panel-surface state for a worktree (ungated —
    /// spec C §10.2). `tabID` narrows to one tab; nil returns every tab.
    func panelGet(worktreeID: UUID, tabID: UUID? = nil) async throws -> PanelGetResult {
        try await callAsync(
            method: RPCMethod.panelGet,
            params: PanelGetParams(worktreeID: worktreeID, tabID: tabID),
            resultType: PanelGetResult.self
        )
    }

    /// Apply one panel-surface operation. Gated daemon-side
    /// (`daemon_panel_surface_enabled` / `agent_panel_control_enabled`,
    /// spec C §7.2) — a gated rejection surfaces as `DaemonClientError.rpcError`
    /// naming the flag.
    func panelApply(_ envelope: PanelOperationEnvelope) async throws -> PanelApplyResult {
        try await callAsync(
            method: RPCMethod.panelApply,
            params: PanelApplyParams(envelope: envelope),
            resultType: PanelApplyResult.self
        )
    }

    /// One-time legacy-tab import into the daemon-owned panel surface.
    /// The daemon returns a "not implemented" error until Task 11 lands.
    func panelImportLegacy(_ params: PanelImportParams) async throws -> PanelImportResult {
        try await callAsync(
            method: RPCMethod.panelImportLegacy,
            params: params,
            resultType: PanelImportResult.self
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

    /// Manually hibernate one Claude terminal (kill its process, keep the
    /// tmux window). Honors the running/permission rails.
    func terminalHibernate(terminalID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalHibernate,
            params: TerminalHibernateParams(terminalID: terminalID)
        )
    }

    /// Wake a hibernated terminal: respawn `claude --resume` in its window.
    /// Idempotent — a double-call collapses to one respawn daemon-side.
    func terminalWake(terminalID: UUID, cols: Int? = nil, rows: Int? = nil, fallbackToDefaultProfile: Bool = false) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalWake,
            params: TerminalWakeParams(terminalID: terminalID, cols: cols, rows: rows, fallbackToDefaultProfile: fallbackToDefaultProfile)
        )
    }

    /// Pin/unpin a terminal against auto-hibernation.
    func terminalSetKeepWarm(terminalID: UUID, keepWarm: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalSetKeepWarm,
            params: TerminalSetKeepWarmParams(terminalID: terminalID, keepWarm: keepWarm)
        )
    }

    /// Set the auto-hibernate master switch + idle-timeout (minutes).
    func setAutoHibernate(enabled: Bool, idleMinutes: Int) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetAutoHibernate,
            params: ConfigSetAutoHibernateParams(enabled: enabled, idleMinutes: idleMinutes)
        )
    }

    /// Cancel a terminal's pending session-limit auto-resume.
    func cancelScheduledResume(terminalID: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.terminalCancelScheduledResume,
            params: CancelScheduledResumeParams(terminalID: terminalID)
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
    ///
    /// A nil `status` is not "no PR": it means nothing is cached, which the
    /// accompanying `observation` disambiguates (the forge said there is none,
    /// versus nobody could get an answer).
    func refreshPRStatus(worktreeID: UUID) async throws -> (status: PRStatus?, observation: PRObservation?) {
        let result = try await callAsync(
            method: RPCMethod.prRefresh,
            params: PRRefreshParams(worktreeID: worktreeID),
            resultType: PRRefreshResult.self
        )
        return (result.status, result.observation)
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
        let probe = RPCVolumeProbe.shared

        while !Task.isCancelled {
            let bytesRead = recv(fd, buffer, bufferSize, 0)
            if bytesRead < 0 {
                let e = errno
                // SO_RCVTIMEO idle tick (EAGAIN/EWOULDBLOCK) or signal (EINTR):
                // not a disconnect. Looping re-checks Task.isCancelled so a
                // cancelled/reconnecting subscription unwinds and closes its fd
                // (via the defer) instead of parking this thread in recv()
                // forever on a half-dead daemon socket.
                if e == EAGAIN || e == EWOULDBLOCK || e == EINTR { continue }
                break   // genuine socket error → disconnect; AppState reconnects
            }
            if bytesRead == 0 { break }   // EOF → daemon closed the stream

            accumulated.append(buffer, count: bytesRead)

            while let newlineIndex = accumulated.firstIndex(of: 0x0A) {
                let lineData = accumulated[accumulated.startIndex..<newlineIndex]
                accumulated = accumulated[accumulated.index(after: newlineIndex)...]

                // Measured from here so the recorded cost is the WHOLE frame's
                // decode, including the ack probe below that fails on every
                // real delta. That failed attempt is a genuine per-delta cost
                // of this path and hiding it would understate the total.
                let started = probe.startMeasurement()

                // Skip the initial ack from SocketServer's subscription handler.
                // This is the only RPC that sends an RPCResponse with success=true
                // and no result — all other RPCs include a result payload.
                if let response = try? decoder.decode(RPCResponse.self, from: Data(lineData)),
                   response.success && response.result == nil {
                    probe.record(start: started, kind: .delta, type: "(ack)", bytes: lineData.count)
                    continue
                }

                if let delta = try? decoder.decode(StateDelta.self, from: Data(lineData)) {
                    probe.record(
                        start: started,
                        kind: .delta,
                        type: delta.rpcVolumeTypeName,
                        bytes: lineData.count
                    )
                    onDelta(delta)
                } else {
                    // Bytes that cost two failed decodes and are then dropped:
                    // a delta case this app build does not know, or a response
                    // that carries a result. Counting them keeps the probe's
                    // byte total equal to what the socket actually delivered.
                    probe.record(start: started, kind: .delta, type: "(undecodable)", bytes: lineData.count)
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

    // MARK: - Tabs

    /// List per-tab metadata + stored tab order for a worktree.
    func listTabs(worktreeID: UUID) async throws -> TabListResponse {
        return try await callAsync(
            method: RPCMethod.tabList,
            params: TabListParams(worktreeID: worktreeID),
            resultType: TabListResponse.self
        )
    }

    /// Set or clear a tab's custom label. `label = nil` clears the override.
    func setTabLabel(tabID: UUID, worktreeID: UUID, label: String?) async throws {
        try await callVoidAsync(
            method: RPCMethod.tabSetLabel,
            params: TabSetLabelParams(tabID: tabID, worktreeID: worktreeID, label: label)
        )
    }

    /// Set the stored tab order for a worktree.
    func setTabOrder(worktreeID: UUID, tabIDs: [UUID]) async throws {
        try await callVoidAsync(
            method: RPCMethod.tabSetOrder,
            params: TabSetOrderParams(worktreeID: worktreeID, tabIDs: tabIDs)
        )
    }

    /// Persist the worktree's active tab so it survives app restart.
    /// `tabID = nil` clears the stored selection.
    func setActiveTab(worktreeID: UUID, tabID: UUID?) async throws {
        try await callVoidAsync(
            method: RPCMethod.worktreeSetActiveTab,
            params: WorktreeSetActiveTabParams(worktreeID: worktreeID, tabID: tabID)
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

    /// List closed-terminal capture metadata for a worktree (newest first).
    /// Captured content is read directly from the file at
    /// `TBDConstants.terminalHistoryPath` — not fetched over RPC.
    func listTerminalHistory(worktreeID: UUID) async throws -> [TerminalHistoryEntry] {
        return try await callAsync(
            method: RPCMethod.terminalHistoryList,
            params: TerminalHistoryListParams(worktreeID: worktreeID),
            resultType: [TerminalHistoryEntry].self
        )
    }

    /// Revive a closed terminal from its history entry into a new terminal in
    /// the same worktree. Returns the created terminal.
    func reviveTerminalHistory(worktreeID: UUID, id: UUID, cols: Int? = nil, rows: Int? = nil) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.terminalHistoryRevive,
            params: TerminalHistoryReviveParams(worktreeID: worktreeID, id: id, cols: cols, rows: rows),
            resultType: Terminal.self
        )
    }

    // MARK: - Model Profiles
    //
    // IMPORTANT: never log raw secret bytes. The `addModelProfile` wrapper is
    // the only place a secret crosses the actor boundary in the app process —
    // keep it out of any logger / print statement.

    /// List all model profiles with cached usage and the global default ID.
    func listModelProfiles() async throws -> ModelProfileListResult {
        return try await callNoParamsAsync(method: RPCMethod.modelProfileList, resultType: ModelProfileListResult.self)
    }

    /// Add a model profile. The raw secret string MUST NOT be logged.
    func addModelProfile(name: String,
                         kind: ModelProfileAddKind? = nil,
                         token: String? = nil,
                         baseURL: String? = nil,
                         model: String? = nil,
                         awsRegion: String? = nil,
                         awsProfile: String? = nil,
                         fallbackModels: [String]? = nil) async throws -> ModelProfileAddResult {
        return try await callAsync(
            method: RPCMethod.modelProfileAdd,
            params: ModelProfileAddParams(name: name, kind: kind, token: token, baseURL: baseURL, model: model, awsRegion: awsRegion, awsProfile: awsProfile, fallbackModels: fallbackModels),
            resultType: ModelProfileAddResult.self
        )
    }

    /// Delete a model profile by ID.
    func deleteModelProfile(id: UUID) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileDelete,
            params: ModelProfileDeleteParams(id: id)
        )
    }

    /// Rename a model profile.
    func renameModelProfile(id: UUID, name: String) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileRename,
            params: ModelProfileRenameParams(id: id, name: name)
        )
    }

    /// Update a model profile's proxy endpoint (baseURL + model) and fallback list.
    func updateModelProfileEndpoint(id: UUID, baseURL: String?, model: String?,
                                    fallbackModels: [String]? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileUpdateEndpoint,
            params: ModelProfileUpdateEndpointParams(id: id, baseURL: baseURL, model: model, fallbackModels: fallbackModels)
        )
    }

    /// Update a bedrock model profile's region, awsProfile, model, and fallback list.
    func updateModelProfileBedrock(id: UUID, awsRegion: String, awsProfile: String?, model: String,
                                   fallbackModels: [String]? = nil) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileUpdateBedrock,
            params: ModelProfileUpdateBedrockParams(id: id, awsRegion: awsRegion, awsProfile: awsProfile, model: model, fallbackModels: fallbackModels)
        )
    }

    /// Probe a proxy base URL for reachability.
    func healthCheckProfile(baseURL: String) async throws -> ModelProfileHealthCheckResult {
        return try await callAsync(
            method: RPCMethod.modelProfileHealthCheck,
            params: ModelProfileHealthCheckParams(baseURL: baseURL),
            resultType: ModelProfileHealthCheckResult.self
        )
    }

    /// Set or clear the global default model profile.
    func setDefaultProfile(id: UUID?) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileSetGlobalDefault,
            params: ModelProfileSetGlobalDefaultParams(id: id)
        )
    }

    /// Set the default primary agent used for newly-created worktrees.
    func setPrimaryAgentPreference(_ preference: PrimaryAgentPreference) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileSetPrimaryAgentPreference,
            params: ModelProfileSetAgentPreferenceParams(preference: preference)
        )
    }

    /// Set or clear a per-repo model profile override.
    func setRepoProfileOverride(repoID: UUID, profileID: UUID?) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileSetRepoOverride,
            params: ModelProfileSetRepoOverrideParams(repoID: repoID, profileID: profileID)
        )
    }

    /// Reorder model profiles.
    func reorderModelProfiles(profileIDs: [UUID]) async throws {
        try await callVoidAsync(
            method: RPCMethod.modelProfileReorder,
            params: ModelProfileReorderParams(profileIDs: profileIDs)
        )
    }

    /// Set or clear the global model-profile override applied to scratch terminal spawns.
    func setScratchProfileOverride(_ id: UUID?) async throws {
        try await callVoidAsync(
            method: RPCMethod.configSetScratchProfileOverride,
            params: ConfigSetScratchProfileOverrideParams(profileID: id)
        )
    }

    /// Set the nightwatch mode (off, daywatch, or nightwatch).
    func setNightwatchMode(_ mode: NightwatchMode) async throws {
        try await callVoidAsync(
            method: RPCMethod.nightwatchSetMode,
            params: NightwatchSetModeParams(mode: mode)
        )
    }

    /// Fetch fresh usage for a single profile (60s server-side dedupe).
    func fetchProfileUsage(id: UUID) async throws -> ModelProfileUsage {
        let result = try await callAsync(
            method: RPCMethod.modelProfileFetchUsage,
            params: ModelProfileFetchUsageParams(id: id),
            resultType: ModelProfileFetchUsageResult.self
        )
        return result.usage
    }

    /// Force an immediate usage sweep of the daemon's in-memory OAuth usage
    /// poller and return the post-sweep snapshots. `id == nil` sweeps every
    /// logged-in OAuth profile (the account picker's open-time refresh).
    func refreshProfileUsage(id: UUID? = nil) async throws -> ModelProfileUsageRefreshResult {
        return try await callAsync(
            method: RPCMethod.modelProfileUsageRefresh,
            params: ModelProfileUsageRefreshParams(id: id),
            resultType: ModelProfileUsageRefreshResult.self
        )
    }

    /// Swap the model profile associated with a running terminal.
    ///
    /// `.inPlace` (default) — seamless "Switch account": the daemon respawns the
    /// SAME tmux window/terminal row under the new profile and returns that
    /// (unchanged-id) row. `.fork` — the daemon forks the conversation into a
    /// NEW tab/terminal row and returns the new one.
    func swapTerminalProfile(
        terminalID: UUID,
        newProfileID: UUID?,
        mode: TerminalSwapMode = .inPlace,
        cols: Int? = nil,
        rows: Int? = nil
    ) async throws -> Terminal {
        return try await callAsync(
            method: RPCMethod.terminalSwapProfile,
            params: TerminalSwapProfileParams(
                terminalID: terminalID, newProfileID: newProfileID,
                cols: cols, rows: rows, mode: mode
            ),
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
    func sessionMessages(filePath: String) async throws -> [TranscriptItem] {
        perfTranscriptLog.debug("client.rpc.start method=sessionMessages")
        let start = ContinuousClock.now
        let request = try RPCRequest(
            method: RPCMethod.sessionMessages,
            params: SessionMessagesParams(filePath: filePath)
        )
        let measured = try await sendRawAsync(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
        let bytes = response.result?.utf8.count ?? 0
        let decodeStart = ContinuousClock.now
        let result = try response.decodeResult([TranscriptItem].self)
        let decodeElapsed = ContinuousClock.now - decodeStart
        let totalElapsed = ContinuousClock.now - start
        let ms = Int(totalElapsed.components.seconds * 1000 + totalElapsed.components.attoseconds / 1_000_000_000_000_000)
        let decodeMs = Int(decodeElapsed.components.seconds * 1000 + decodeElapsed.components.attoseconds / 1_000_000_000_000_000)
        perfTranscriptLog.debug("client.rpc.end method=sessionMessages elapsed_ms=\(ms, privacy: .public) bytes=\(bytes, privacy: .public) decode_ms=\(decodeMs, privacy: .public) items=\(result.count, privacy: .public)")
        return result
    }

    /// Load the full chat transcript for a terminal's current Claude session.
    /// Returns empty messages and nil sessionID if the terminal has no session yet;
    /// returns empty messages and a sessionID if the session JSONL doesn't exist yet.
    func terminalTranscript(terminalID: UUID, tailLimit: Int? = nil) async throws -> TerminalTranscriptResult {
        perfTranscriptLog.debug("client.rpc.start method=terminalTranscript")
        let start = ContinuousClock.now
        let request = try RPCRequest(
            method: RPCMethod.terminalTranscript,
            params: TerminalTranscriptParams(terminalID: terminalID, tailLimit: tailLimit)
        )
        let measured = try await sendRawAsync(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
        let bytes = response.result?.utf8.count ?? 0
        let decodeStart = ContinuousClock.now
        let result = try response.decodeResult(TerminalTranscriptResult.self)
        let decodeElapsed = ContinuousClock.now - decodeStart
        let totalElapsed = ContinuousClock.now - start
        let ms = Int(totalElapsed.components.seconds * 1000 + totalElapsed.components.attoseconds / 1_000_000_000_000_000)
        let decodeMs = Int(decodeElapsed.components.seconds * 1000 + decodeElapsed.components.attoseconds / 1_000_000_000_000_000)
        perfTranscriptLog.debug("client.rpc.end method=terminalTranscript elapsed_ms=\(ms, privacy: .public) bytes=\(bytes, privacy: .public) decode_ms=\(decodeMs, privacy: .public) items=\(result.messages.count, privacy: .public)")
        return result
    }

    /// Fetch the un-truncated body for a single transcript item (for
    /// "Show full output" expansion). Pass `includeBody: false` to fetch only
    /// the injection metadata, leaving a potentially huge body off the wire.
    func terminalTranscriptItemFullBody(
        terminalID: UUID, itemID: String, includeBody: Bool = true
    ) async throws -> TerminalTranscriptItemFullBodyResult {
        return try await callAsync(
            method: RPCMethod.terminalTranscriptItemFullBody,
            params: TerminalTranscriptItemFullBodyParams(
                terminalID: terminalID, itemID: itemID, includeBody: includeBody),
            resultType: TerminalTranscriptItemFullBodyResult.self
        )
    }

    /// Notify the daemon whether the app is in the foreground (drives usage poller).
    func setAppForegroundState(isForeground: Bool) async throws {
        try await callVoidAsync(
            method: RPCMethod.appSetForegroundState,
            params: AppSetForegroundStateParams(isForeground: isForeground)
        )
    }

    /// Read-only scan of the user's settings.json files for legacy TBD hook
    /// entries (the ones now superseded by the spawn-time --settings overlay).
    func legacyHooksStatus() async throws -> LegacyHooksStatusResult {
        return try await callNoParamsAsync(
            method: RPCMethod.daemonLegacyHooksStatus,
            resultType: LegacyHooksStatusResult.self
        )
    }

    /// Remove TBD's legacy entries from ~/.claude/settings.json. The daemon
    /// runs the write through SettingsJSONSafety (pristine backup, atomic,
    /// roundtrip-validated). Repo-level files are NEVER auto-modified.
    func removeLegacyGlobalHooks() async throws -> RemoveLegacyGlobalHooksResult {
        let request = RPCRequest(method: RPCMethod.daemonRemoveLegacyGlobalHooks)
        let measured = try await sendRawAsync(request)
        let response = measured.response
        guard response.success else {
            measured.finish()
            throw DaemonClientError.rpcError(response.error ?? "Unknown error", code: response.errorCode)
        }
        defer { measured.finish() }
        return try response.decodeResult(RemoveLegacyGlobalHooksResult.self)
    }
}
