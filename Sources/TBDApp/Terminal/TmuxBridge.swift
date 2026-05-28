import Foundation
import Darwin
import os

private let bridgeLogger = Logger(subsystem: "com.tbd.app", category: "TmuxBridge")

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
    private let lock = NSLock()

    /// Tracks active grouped sessions: maps panel UUID -> grouped session name
    private var activeSessions: [UUID: String] = [:]

    /// Serial background queue retained for any future synchronous teardown
    /// needs. Today cleanup is fire-and-forget via `Task { ... }` invoking
    /// the async `runTmux`, which uses `Process.terminationHandler` (no
    /// `waitUntilExit`) so it doesn't pump the main runloop.
    private let cleanupQueue = DispatchQueue(label: "com.tbd.app.tmux-cleanup", qos: .utility)

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
    /// - Returns: Array of arguments for the tmux attach command, or nil on failure
    func prepareSession(panelID: UUID, server: String, windowID: String) async -> [String]? {
        let sessionName = Self.sessionName(for: panelID)

        let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])

        let createResult = await runTmux(server: server, args: Self.newIsolatedSessionArgs(sessionName: sessionName))
        guard createResult.success else {
            debugLog("PREPARE: failed to create view session \(sessionName) on server \(server): \(createResult.output)")
            return nil
        }

        let linkResult = await runTmux(server: server, args: Self.linkWindowArgs(windowID: windowID, sessionName: sessionName))
        guard linkResult.success else {
            debugLog("PREPARE: window \(windowID) is dead on server \(server)")
            let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            return nil
        }

        let _ = await runTmux(server: server, args: Self.killInitialWindowArgs(sessionName: sessionName))

        let selectResult = await runTmux(server: server, args: Self.selectWindowArgs(windowID: windowID, sessionName: sessionName))
        guard selectResult.success else {
            debugLog("PREPARE: failed to select window \(windowID) in session \(sessionName): \(selectResult.output)")
            let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            return nil
        }

        let remainOnExitResult = await runTmux(server: server, args: Self.remainOnExitArgs(windowID: windowID))
        guard remainOnExitResult.success else {
            debugLog("PREPARE: failed to preserve exited output for window \(windowID): \(remainOnExitResult.output)")
            let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            return nil
        }

        let remainOnExitFormatResult = await runTmux(server: server, args: Self.remainOnExitFormatArgs(windowID: windowID))
        guard remainOnExitFormatResult.success else {
            debugLog("PREPARE: failed to suppress exited pane marker for window \(windowID): \(remainOnExitFormatResult.output)")
            let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            return nil
        }

        let activeResult = await runTmux(server: server, args: Self.activeWindowQueryArgs(sessionName: sessionName))
        guard activeResult.success, activeResult.output == windowID else {
            debugLog("PREPARE: session \(sessionName) selected \(activeResult.output), expected \(windowID)")
            let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            return nil
        }

        lock.withLock {
            activeSessions[panelID] = sessionName
        }

        debugLog("PREPARE: panelID=\(panelID.uuidString.prefix(8)) server=\(server) window=\(windowID) session=\(sessionName)")

        // Return the tmux command args for SwiftTerm to attach
        return ["tmux", "-L", server, "attach", "-t", sessionName]
    }

    /// Clean up a view session when a panel is hidden.
    ///
    /// Fire-and-forget: the kill-session call runs on a background queue so
    /// callers can return immediately. Safe to call from the main thread
    /// during SwiftUI dismantle.
    func cleanupSession(panelID: UUID, server: String) {
        lock.lock()
        guard let sessionName = activeSessions.removeValue(forKey: panelID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        Task.detached { [self] in
            let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            debugLog("CLEANUP: panelID=\(panelID.uuidString.prefix(8)) session=\(sessionName)")
        }
    }

    /// Clean up all grouped sessions for a server.
    func cleanupAllSessions(server: String) {
        lock.lock()
        let sessions = activeSessions
        activeSessions.removeAll()
        lock.unlock()

        Task.detached { [self] in
            for (_, sessionName) in sessions {
                let _ = await runTmux(server: server, args: ["kill-session", "-t", sessionName])
            }
            debugLog("CLEANUP ALL: server=\(server)")
        }
    }

    // MARK: - Helpers

    private struct TmuxResult {
        let success: Bool
        let output: String
    }

    /// Run a tmux subprocess without blocking the calling thread.
    ///
    /// Uses `Process.terminationHandler` + `withCheckedContinuation` instead of
    /// `waitUntilExit`. Calling this from the main thread used to dominate
    /// `makeNSView` for tens to hundreds of ms per panel (tmux fork+exec +
    /// new-session/select-window), starving SwiftUI's render loop so newly
    /// inserted terminal panels never displayed content.
    private func runTmux(server: String, args: [String]) async -> TmuxResult {
        await withCheckedContinuation { continuation in
            let process = Process()
            let outPipe = Pipe()
            let errPipe = Pipe()

            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "-L", server] + args
            process.standardOutput = outPipe
            process.standardError = errPipe

            process.terminationHandler = { _ in
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData + errData, encoding: .utf8) ?? ""
                continuation.resume(returning: TmuxResult(
                    success: process.terminationStatus == 0,
                    output: output.trimmingCharacters(in: .whitespacesAndNewlines)
                ))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(returning: TmuxResult(
                    success: false,
                    output: error.localizedDescription
                ))
            }
        }
    }
}
