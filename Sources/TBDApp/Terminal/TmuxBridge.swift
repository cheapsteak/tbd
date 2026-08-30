import Foundation
import Darwin
import TBDShared
import os

private let bridgeLogger = Logger(subsystem: "com.tbd.app", category: "TmuxBridge")

struct TmuxPreparedSession: Equatable, Sendable {
    let executablePath: String
    let arguments: [String]
}

/// One successful `TmuxBridge.prepareSession`: how the viewer attaches, plus
/// the generation that scopes the reclaim of the view session it created.
///
/// The generation exists because `panelID` alone does not identify a
/// preparation. It is the *terminal's* id and survives SwiftUI view rebuilds,
/// so the same panel can be prepared again — waking a parked terminal flips
/// `isParked`, re-keying the view and minting a fresh `Coordinator` — while
/// the previous coordinator is still alive and yet to be torn down. Handing
/// the generation back lets each coordinator reclaim only the view session its
/// own preparation created, so a stale teardown cannot kill a fresher session.
/// Same shape, and same reason, as the control-mode attach generation in
/// `TerminalPanelView`.
struct TmuxSessionPreparation: Equatable, Sendable {
    let session: TmuxPreparedSession
    let generation: UInt64
}

enum TmuxPreparationStage: String, Equatable, Sendable {
    case createViewSession
    case linkWindow
    case selectWindow
    case preserveExitedOutput
    case suppressExitedMarker
    case verifySelection
}

enum TmuxPreparationFailure: LocalizedError, Equatable, Sendable {
    case windowMissing(failedStage: TmuxPreparationStage)
    case commandFailed(stage: TmuxPreparationStage, output: String)
    /// No tmux executable could be resolved, so nothing ran. This is not a
    /// tmux failure and retrying cannot help: the remedy is to locate the
    /// binary (Settings -> Terminal), which is why it is a case of its own
    /// rather than a `commandFailed` carrying a synthetic output string.
    case tmuxExecutableUnavailable

    var errorDescription: String? {
        switch self {
        case .windowMissing(let stage):
            return "tmux window is missing (failed at stage: \(stage.rawValue))"
        case .commandFailed(let stage, let output):
            return "tmux command failed at stage \(stage.rawValue): \(output)"
        case .tmuxExecutableUnavailable:
            return "tmux executable unavailable: not found in PATH and no saved fallback is set"
        }
    }
}

/// Outcome of one tmux subprocess invocation.
struct TmuxCommandOutcome: Equatable, Sendable {
    let success: Bool
    let output: String
}

/// Runs one tmux command: executable path, server socket name, arguments.
///
/// Injectable so tests can drive command sequences a live tmux server cannot
/// be made to produce on demand — notably a `new-session` that fails once
/// with `duplicate session:` and succeeds on the retry.
typealias TmuxCommandRunner = @Sendable (String, String, [String]) async -> TmuxCommandOutcome

/// File-based debug log for diagnostics
func debugLog(_ msg: String) {
    let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
    if let data = line.data(using: .utf8) {
        if let fh = FileHandle(forWritingAtPath: "/tmp/tbd-bridge.log") {
            fh.seekToEndOfFile()
            fh.write(data)
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: "/tmp/tbd-bridge.log", contents: data)
        }
    }
}

// MARK: - TmuxBridge

/// Manages tmux integration using isolated tmux view sessions and direct PTY attachment.
///
/// Instead of using tmux control mode (-CC) which requires complex protocol parsing,
/// each terminal panel gets its own tmux client via an isolated view session. SwiftTerm
/// connects to the PTY natively — input, output, and resize all work through the
/// standard terminal driver.
///
/// Architecture:
/// - Daemon creates windows in tmux session "main" (one per repo server)
/// - When showing a terminal panel, we create a standalone view session and
///   link only the requested window into it
/// - SwiftTerm spawns `tmux attach -t <view-session>` in a PTY
/// - When the panel is hidden, we kill the view session
/// - The "main" session persists even when the app is closed
final class TmuxBridge: @unchecked Sendable {
    private struct ActiveSession: Sendable {
        let name: String
        let tmuxExecutablePath: String
        /// The tmux server socket this view session lives on. Recorded so a
        /// teardown that holds no per-panel context — app termination — can
        /// kill every tracked session on the server that actually owns it.
        let server: String
        /// The preparation that created this session. `cleanupSession` kills
        /// only a session whose generation matches the one its caller was
        /// handed, so a superseded coordinator cannot kill the entry a newer
        /// preparation put here under the same `panelID`.
        let generation: UInt64
    }

    private let lock = NSLock()
    private let tmuxExecutableResolver: TmuxExecutableResolver

    /// Tracks each grouped session with the executable snapshotted for its lifecycle.
    private var activeSessions: [UUID: ActiveSession] = [:]

    /// Next generation to mint. Monotonic across the whole bridge — the values
    /// only ever need to be compared for equality — and guarded by `lock`.
    /// Starts at 1 so no valid generation is zero.
    private var nextGeneration: UInt64 = 1

    /// Runs each tmux command. Defaults to the real subprocess runner.
    private let commandRunner: TmuxCommandRunner

    init(
        tmuxExecutableResolver: TmuxExecutableResolver = TmuxExecutableResolver(),
        commandRunner: TmuxCommandRunner? = nil
    ) {
        self.tmuxExecutableResolver = tmuxExecutableResolver
        self.commandRunner = commandRunner ?? { executablePath, server, args in
            await TmuxBridge.runTmuxProcess(
                tmuxExecutablePath: executablePath,
                server: server,
                args: args
            )
        }
    }

    static func sessionName(for panelID: UUID) -> String {
        "tbd-view-\(panelID.uuidString.prefix(8).lowercased())"
    }

    static func newIsolatedSessionArgs(sessionName: String) -> [String] {
        ["new-session", "-d", "-s", sessionName, "-c", "/tmp"]
    }

    static func linkWindowArgs(windowID: String, sessionName: String) -> [String] {
        ["link-window", "-s", windowID, "-t", "\(sessionName):"]
    }

    static func killInitialWindowArgs(sessionName: String) -> [String] {
        ["kill-window", "-t", "\(sessionName):0"]
    }

    static func selectWindowArgs(windowID: String, sessionName: String) -> [String] {
        ["select-window", "-t", "\(sessionName):\(windowID)"]
    }

    static func remainOnExitArgs(windowID: String) -> [String] {
        ["set-option", "-wt", windowID, "remain-on-exit", "on"]
    }

    static func remainOnExitFormatArgs(windowID: String) -> [String] {
        ["set-option", "-wt", windowID, "remain-on-exit-format", ""]
    }

    static func activeWindowQueryArgs(sessionName: String) -> [String] {
        ["display-message", "-p", "-t", sessionName, "#{window_id}"]
    }

    static func windowInventoryQueryArgs() -> [String] {
        ["list-windows", "-a", "-F", "#{window_id}"]
    }

    static func clientSessionQueryArgs() -> [String] {
        ["list-clients", "-F", "#{client_session}"]
    }

    static func killSessionArgs(sessionName: String) -> [String] {
        ["kill-session", "-t", sessionName]
    }

    static func hasSessionArgs(sessionName: String) -> [String] {
        ["has-session", "-t", sessionName]
    }

    /// Complete command used for a tmux preparation subprocess.
    func tmuxCommand(server: String, args: [String]) -> [String]? {
        guard let tmuxExecutablePath = tmuxExecutableResolver.resolve()?.path else { return nil }
        return Self.tmuxCommand(tmuxExecutablePath: tmuxExecutablePath, server: server, args: args)
    }

    /// Command used by the SwiftTerm PTY to attach its viewer client.
    ///
    /// `-u` is required even when the app environment normally has a UTF-8
    /// locale. tmux otherwise may classify this bare PTY client as non-UTF-8
    /// and substitute Unicode punctuation (notably curly apostrophes) with
    /// underscores when it redraws the pane.
    func viewerAttachCommand(server: String, sessionName: String) -> [String]? {
        guard let tmuxExecutablePath = tmuxExecutableResolver.resolve()?.path else { return nil }
        return viewerAttachCommand(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            sessionName: sessionName
        )
    }

    private static func tmuxCommand(
        tmuxExecutablePath: String,
        server: String,
        args: [String]
    ) -> [String] {
        [tmuxExecutablePath, "-L", server] + args
    }

    private func viewerAttachCommand(
        tmuxExecutablePath: String,
        server: String,
        sessionName: String
    ) -> [String] {
        return [tmuxExecutablePath, "-u", "-L", server, "attach", "-t", sessionName]
    }

    /// Prepare a tmux view session for a specific panel.
    /// Creates an isolated session, links only the requested window into it,
    /// verifies the selected window, and returns the tmux arguments needed for
    /// SwiftTerm to attach.
    ///
    /// Async to keep the main thread responsive: the underlying `Process`
    /// invocations no longer use `waitUntilExit` and instead suspend on
    /// `terminationHandler` via `withCheckedContinuation`. Callers should
    /// invoke this from a `Task`, not synchronously from `makeNSView`.
    ///
    /// - Parameters:
    ///   - panelID: Unique ID for this terminal panel (used as session name suffix)
    ///   - server: tmux server socket name (e.g. "tbd-a1b2c3d4")
    ///   - windowID: tmux window ID to display (e.g. "@3")
    /// - Returns: A prepared viewer attachment — carrying the generation its
    ///   caller must pass back to `cleanupSession` — or a classified failure.
    func prepareSession(
        panelID: UUID,
        server: String,
        windowID: String
    ) async -> Result<TmuxSessionPreparation, TmuxPreparationFailure> {
        let sessionName = Self.sessionName(for: panelID)
        guard let tmuxExecutablePath = tmuxExecutableResolver.resolve()?.path else {
            bridgeLogger.error(
                "Preparation failed: tmux executable unavailable (not in PATH, no saved fallback) session=\(sessionName, privacy: .public) server=\(server, privacy: .public)"
            )
            debugLog("PREPARE: tmux executable unavailable (not in PATH, no saved fallback) session=\(sessionName) server=\(server)")
            return .failure(.tmuxExecutableUnavailable)
        }
        let preparedSession = preparedSession(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            sessionName: sessionName
        )

        let _ = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.killSessionArgs(sessionName: sessionName)
        )

        let createResult = await createViewSession(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            sessionName: sessionName
        )
        guard createResult.success else {
            debugLog("PREPARE: failed to create view session \(sessionName) on server \(server): \(createResult.output)")
            return .failure(Self.classifyPreparationFailure(
                stage: .createViewSession,
                output: createResult.output,
                probeSucceeded: nil,
                probeOutput: nil,
                expectedWindowID: windowID
            ))
        }

        let linkResult = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.linkWindowArgs(windowID: windowID, sessionName: sessionName)
        )
        guard linkResult.success else {
            return await failureAfterViewSessionCreation(
                stage: .linkWindow,
                output: linkResult.output,
                tmuxExecutablePath: tmuxExecutablePath,
                server: server,
                windowID: windowID,
                sessionName: sessionName
            )
        }

        let _ = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.killInitialWindowArgs(sessionName: sessionName)
        )

        let selectResult = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.selectWindowArgs(windowID: windowID, sessionName: sessionName)
        )
        guard selectResult.success else {
            return await failureAfterViewSessionCreation(
                stage: .selectWindow,
                output: selectResult.output,
                tmuxExecutablePath: tmuxExecutablePath,
                server: server,
                windowID: windowID,
                sessionName: sessionName
            )
        }

        let remainOnExitResult = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.remainOnExitArgs(windowID: windowID)
        )
        guard remainOnExitResult.success else {
            return await failureAfterViewSessionCreation(
                stage: .preserveExitedOutput,
                output: remainOnExitResult.output,
                tmuxExecutablePath: tmuxExecutablePath,
                server: server,
                windowID: windowID,
                sessionName: sessionName
            )
        }

        let remainOnExitFormatResult = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.remainOnExitFormatArgs(windowID: windowID)
        )
        guard remainOnExitFormatResult.success else {
            return await failureAfterViewSessionCreation(
                stage: .suppressExitedMarker,
                output: remainOnExitFormatResult.output,
                tmuxExecutablePath: tmuxExecutablePath,
                server: server,
                windowID: windowID,
                sessionName: sessionName
            )
        }

        let activeResult = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.activeWindowQueryArgs(sessionName: sessionName)
        )
        guard activeResult.success, activeResult.output == windowID else {
            return await failureAfterViewSessionCreation(
                stage: .verifySelection,
                output: activeResult.output,
                tmuxExecutablePath: tmuxExecutablePath,
                server: server,
                windowID: windowID,
                sessionName: sessionName
            )
        }

        let generation: UInt64 = lock.withLock {
            let generation = nextGeneration
            nextGeneration &+= 1
            activeSessions[panelID] = ActiveSession(
                name: sessionName,
                tmuxExecutablePath: tmuxExecutablePath,
                server: server,
                generation: generation
            )
            return generation
        }

        debugLog("PREPARE: panelID=\(panelID.uuidString.prefix(8)) server=\(server) window=\(windowID) session=\(sessionName) generation=\(generation)")

        return .success(TmuxSessionPreparation(session: preparedSession, generation: generation))
    }

    /// Clean up a view session when a panel is hidden.
    ///
    /// Fire-and-forget: the kill-session call runs on a background queue so
    /// callers can return immediately. Safe to call from the main thread
    /// during SwiftUI dismantle, and from a non-isolated `deinit`.
    ///
    /// Scoped to `generation`, which the caller was handed by the
    /// `prepareSession` whose session it is reclaiming. A teardown whose
    /// generation no longer matches the tracked entry is a **no-op**: it
    /// neither forgets the entry nor issues `kill-session`. That is what stops
    /// a superseded coordinator — SwiftUI rebuilds the terminal view when a
    /// parked terminal wakes, so a second `prepareSession` for the same
    /// `panelID` runs while the first coordinator is still awaiting teardown —
    /// from killing the freshly woken terminal's session.
    ///
    /// Still idempotent: the matching call removes the entry, so a second
    /// teardown for the same generation finds nothing and returns.
    ///
    /// Takes no server: the tracked `ActiveSession` is the authority on which
    /// socket its session lives on. A caller-supplied server could disagree
    /// with the entry it just removed — a panel whose coordinator recorded one
    /// server while the preparation ran against another — and the kill would
    /// then go to a socket that has no such session, leaking the tracked one
    /// with no path left to reclaim it.
    func cleanupSession(panelID: UUID, generation: UInt64) {
        lock.lock()
        guard let session = activeSessions[panelID], session.generation == generation else {
            lock.unlock()
            return
        }
        activeSessions.removeValue(forKey: panelID)
        lock.unlock()

        Task.detached { [self] in
            let _ = await runTmux(
                tmuxExecutablePath: session.tmuxExecutablePath,
                server: session.server,
                args: Self.killSessionArgs(sessionName: session.name)
            )
            debugLog("CLEANUP: panelID=\(panelID.uuidString.prefix(8)) session=\(session.name)")
        }
    }

    /// Clean up every view session on one server.
    ///
    /// Fire-and-forget like `cleanupSession`. Sessions belonging to other
    /// servers are left alone: `activeSessions` spans every server the app
    /// currently shows a panel on.
    ///
    /// Deliberately not generation-scoped. This reclaims *everything* tracked
    /// on the server rather than one panel's preparation, so there is no
    /// stale-teardown race to guard against — filtering by generation here
    /// could only leave a session behind.
    func cleanupAllSessions(server: String) {
        let sessions = takeSessions { $0.server == server }
        guard !sessions.isEmpty else { return }

        Task.detached { [self] in
            await killSessions(sessions)
            debugLog("CLEANUP ALL: server=\(server) sessions=\(sessions.count)")
        }
    }

    /// Reclaim every tracked view session, each on the server that owns it,
    /// blocking the caller until the kills have run.
    ///
    /// This is the app-termination path, and blocking is the whole point:
    /// `cleanupAllSessions(server:)` hands its kills to a detached task, and
    /// nothing scheduled that way outlives the process — on
    /// `applicationWillTerminate` the task would be enqueued and then die with
    /// the app, having killed nothing. A view session that outlives the app
    /// keeps its linked worktree window alive (tmux destroys a window only
    /// when the last session referencing it goes away), and with it that
    /// window's pane process and the whole tmux server.
    ///
    /// Bounded rather than open-ended: a wedged tmux may delay quitting by
    /// `timeout` at most, and one leaked session is the lesser harm.
    ///
    /// - Returns: the number of sessions this call took ownership of.
    @discardableResult
    func cleanupAllSessionsBlocking(timeout: TimeInterval = 2.0) -> Int {
        let sessions = takeSessions { _ in true }
        guard !sessions.isEmpty else { return 0 }

        let finished = DispatchSemaphore(value: 0)
        Task.detached { [self] in
            await killSessions(sessions)
            finished.signal()
        }
        let outcome = finished.wait(timeout: .now() + timeout)
        debugLog("CLEANUP ALL (blocking): sessions=\(sessions.count) timedOut=\(outcome == .timedOut)")
        return sessions.count
    }

    /// Removes the matching sessions from the tracking table and returns them,
    /// so a caller owns exactly what it is about to kill and no second caller
    /// can kill the same session twice.
    private func takeSessions(matching predicate: (ActiveSession) -> Bool) -> [ActiveSession] {
        lock.lock()
        defer { lock.unlock() }
        let taken = activeSessions.filter { predicate($0.value) }
        for panelID in taken.keys {
            activeSessions.removeValue(forKey: panelID)
        }
        return Array(taken.values)
    }

    private func killSessions(_ sessions: [ActiveSession]) async {
        for session in sessions {
            let _ = await runTmux(
                tmuxExecutablePath: session.tmuxExecutablePath,
                server: session.server,
                args: Self.killSessionArgs(sessionName: session.name)
            )
        }
    }

    // MARK: - Helpers

    /// Create the isolated view session, replacing any same-named leftover.
    ///
    /// `prepareSession` kills a same-named session before creating one, but
    /// that kill's result is advisory: it can fail transiently (a momentarily
    /// unavailable or wedged server). `new-session` then fails with
    /// `duplicate session:` and the panel is bricked for good, because the
    /// session name is derived from the panel UUID and never changes. So when
    /// the create fails, probe for the session — and only when the probe
    /// affirms it exists, kill it and retry the create exactly once. A failed
    /// probe is ambiguous (same reason `classifyPreparationFailure` refuses to
    /// act on one) and does not justify a retry.
    ///
    /// Replacement, never adoption: `prepareSession` unconditionally runs
    /// `kill-window -t <session>:0` after linking, and tmux's `kill-window`
    /// destroys the window globally rather than unlinking it from one session,
    /// so adopting a leftover session whose index 0 holds a real linked window
    /// would destroy a live agent window.
    private func createViewSession(
        tmuxExecutablePath: String,
        server: String,
        sessionName: String
    ) async -> TmuxCommandOutcome {
        let createArgs = Self.newIsolatedSessionArgs(sessionName: sessionName)
        let firstAttempt = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: createArgs
        )
        guard !firstAttempt.success else { return firstAttempt }

        debugLog("PREPARE: create failed for \(sessionName) on server \(server): \(firstAttempt.output)")
        let probe = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.hasSessionArgs(sessionName: sessionName)
        )
        guard probe.success else {
            debugLog("PREPARE: no leftover session \(sessionName) on server \(server); not retrying create")
            return firstAttempt
        }

        debugLog("PREPARE: leftover session \(sessionName) still present on server \(server); killing it and retrying create")
        let _ = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.killSessionArgs(sessionName: sessionName)
        )
        let retry = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: createArgs
        )
        debugLog("PREPARE: create retry for \(sessionName) on server \(server) succeeded=\(retry.success) output=\(retry.output)")
        return retry
    }

    func preparedSession(server: String, sessionName: String) -> TmuxPreparedSession? {
        guard let tmuxExecutablePath = tmuxExecutableResolver.resolve()?.path else { return nil }
        return preparedSession(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            sessionName: sessionName
        )
    }

    private func preparedSession(
        tmuxExecutablePath: String,
        server: String,
        sessionName: String
    ) -> TmuxPreparedSession {
        let viewerCommand = viewerAttachCommand(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            sessionName: sessionName
        )
        return TmuxPreparedSession(
            executablePath: viewerCommand[0],
            arguments: Array(viewerCommand.dropFirst())
        )
    }

    static func clientInventoryConfirmsAttachment(
        querySucceeded: Bool,
        output: String,
        expectedSessionName: String
    ) -> Bool {
        guard querySucceeded else { return false }
        let clientSessions = Set(output.split(whereSeparator: { $0.isNewline }).map(String.init))
        return clientSessions.contains(expectedSessionName)
    }

    func hasAttachedClient(panelID: UUID, server: String) async -> Bool {
        guard let session = lock.withLock({ activeSessions[panelID] }) else { return false }
        let result = await runTmux(
            tmuxExecutablePath: session.tmuxExecutablePath,
            server: server,
            args: Self.clientSessionQueryArgs()
        )
        return Self.clientInventoryConfirmsAttachment(
            querySucceeded: result.success,
            output: result.output,
            expectedSessionName: session.name
        )
    }

    static func classifyPreparationFailure(
        stage: TmuxPreparationStage,
        output: String,
        probeSucceeded: Bool?,
        probeOutput: String?,
        expectedWindowID: String
    ) -> TmuxPreparationFailure {
        guard stage != .createViewSession, let probeSucceeded else {
            return .commandFailed(stage: stage, output: output)
        }
        // A failed probe is ambiguous: the server or subprocess may be
        // transiently unavailable, so it cannot justify recreating a window.
        guard probeSucceeded else {
            return .commandFailed(stage: stage, output: output)
        }
        // Only a successful server-wide inventory that omits the requested
        // identity is affirmative evidence that the window is missing.
        let windowIDs = Set((probeOutput ?? "").split(whereSeparator: { $0.isNewline }).map(String.init))
        guard !windowIDs.contains(expectedWindowID) else {
            return .commandFailed(stage: stage, output: output)
        }
        return .windowMissing(failedStage: stage)
    }

    private func failureAfterViewSessionCreation(
        stage: TmuxPreparationStage,
        output: String,
        tmuxExecutablePath: String,
        server: String,
        windowID: String,
        sessionName: String
    ) async -> Result<TmuxSessionPreparation, TmuxPreparationFailure> {
        let probeResult = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.windowInventoryQueryArgs()
        )
        let failure = Self.classifyPreparationFailure(
            stage: stage,
            output: output,
            probeSucceeded: probeResult.success,
            probeOutput: probeResult.output,
            expectedWindowID: windowID
        )

        bridgeLogger.debug(
            "Preparation failed at \(stage.rawValue, privacy: .public): \(output, privacy: .public)"
        )
        let _ = await runTmux(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: Self.killSessionArgs(sessionName: sessionName)
        )
        return .failure(failure)
    }

    /// Run one tmux command through the injected runner.
    private func runTmux(
        tmuxExecutablePath: String,
        server: String,
        args: [String]
    ) async -> TmuxCommandOutcome {
        await commandRunner(tmuxExecutablePath, server, args)
    }

    /// Run a tmux subprocess without blocking the calling thread.
    ///
    /// Uses `Process.terminationHandler` + `withCheckedContinuation` instead of
    /// `waitUntilExit`. Calling this from the main thread used to dominate
    /// `makeNSView` for tens to hundreds of ms per panel (tmux fork+exec +
    /// new-session/select-window), starving SwiftUI's render loop so newly
    /// inserted terminal panels never displayed content.
    private static func runTmuxProcess(
        tmuxExecutablePath: String,
        server: String,
        args: [String]
    ) async -> TmuxCommandOutcome {
        let command = tmuxCommand(
            tmuxExecutablePath: tmuxExecutablePath,
            server: server,
            args: args
        )

        return await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: command[0])
            process.arguments = Array(command.dropFirst())
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { _ in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData + errData, encoding: .utf8) ?? ""
                continuation.resume(returning: TmuxCommandOutcome(
                    success: process.terminationStatus == 0,
                    output: output.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: TmuxCommandOutcome(
                    success: false,
                    output: error.localizedDescription
                ))
            }
        }
    }
}
