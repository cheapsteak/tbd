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

/// Manages tmux integration using **grouped sessions** and direct PTY attachment.
///
/// Instead of using tmux control mode (-CC) which requires complex protocol parsing,
/// each terminal panel gets its own tmux client via a grouped session. SwiftTerm
/// connects to the PTY natively — input, output, and resize all work through the
/// standard terminal driver.
///
/// Architecture:
/// - Daemon creates windows in tmux session "main" (one per repo server)
/// - When showing a terminal panel, we create a grouped session that shares
///   all windows but has an independent "current window" pointer
/// - SwiftTerm spawns `tmux attach -t <grouped-session>` in a PTY
/// - When the panel is hidden, we kill the grouped session
/// - The "main" session persists even when the app is closed
final class TmuxBridge: @unchecked Sendable {
    private let lock = NSLock()

    /// Tracks active grouped sessions: maps panel UUID -> grouped session name
    private var activeSessions: [UUID: String] = [:]

    /// Prepare a tmux grouped session for a specific panel.
    /// Creates a grouped session linked to "main", selects the right window,
    /// and returns the tmux arguments needed for SwiftTerm to attach.
    ///
    /// - Parameters:
    ///   - panelID: Unique ID for this terminal panel (used as session name suffix)
    ///   - server: tmux server socket name (e.g. "tbd-a1b2c3d4")
    ///   - windowID: tmux window ID to display (e.g. "@3")
    /// - Returns: Array of arguments for the tmux attach command, or nil on failure
    func prepareSession(panelID: UUID, server: String, windowID: String) -> [String]? {
        let sessionName = "tbd-view-\(panelID.uuidString.prefix(8).lowercased())"

        // Create a grouped session linked to "main"
        let createResult = runTmux(server: server, args: [
            "new-session", "-d", "-t", "main", "-s", sessionName
        ])

        // Hide tmux chrome — our app provides its own UI
        let _ = runTmux(server: server, args: ["set", "-t", sessionName, "status", "off"])
        let _ = runTmux(server: server, args: ["set", "-t", sessionName, "pane-border-style", "fg=black"])
        let _ = runTmux(server: server, args: ["set", "-t", sessionName, "pane-border-indicators", "off"])

        if !createResult.success {
            // Session might already exist, try to use it
            debugLog("PREPARE: new-session failed (may already exist): \(createResult.output)")
        }

        // Select the right window in the grouped session
        let selectResult = runTmux(server: server, args: [
            "select-window", "-t", "\(sessionName):\(windowID)"
        ])

        if !selectResult.success {
            debugLog("PREPARE: select-window failed: \(selectResult.output)")
            // Try without the session prefix
            let _ = runTmux(server: server, args: [
                "select-window", "-t", windowID
            ])
        }

        lock.lock()
        activeSessions[panelID] = sessionName
        lock.unlock()

        debugLog("PREPARE: panelID=\(panelID.uuidString.prefix(8)) server=\(server) window=\(windowID) session=\(sessionName)")

        // Return the tmux command args for SwiftTerm to attach
        return ["tmux", "-L", server, "attach", "-t", sessionName]
    }

    /// Clean up a grouped session when a panel is hidden.
    func cleanupSession(panelID: UUID, server: String) {
        lock.lock()
        guard let sessionName = activeSessions.removeValue(forKey: panelID) else {
            lock.unlock()
            return
        }
        lock.unlock()

        let _ = runTmux(server: server, args: ["kill-session", "-t", sessionName])
        debugLog("CLEANUP: panelID=\(panelID.uuidString.prefix(8)) session=\(sessionName)")
    }

    /// Clean up all grouped sessions for a server.
    func cleanupAllSessions(server: String) {
        lock.lock()
        let sessions = activeSessions
        lock.unlock()

        for (panelID, sessionName) in sessions {
            let _ = runTmux(server: server, args: ["kill-session", "-t", sessionName])
            lock.lock()
            activeSessions.removeValue(forKey: panelID)
            lock.unlock()
        }
        debugLog("CLEANUP ALL: server=\(server)")
    }

    // MARK: - Helpers

    private struct TmuxResult {
        let success: Bool
        let output: String
    }

    private func runTmux(server: String, args: [String]) -> TmuxResult {
        let process = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()

        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux", "-L", server] + args
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: outData + errData, encoding: .utf8) ?? ""
            return TmuxResult(success: process.terminationStatus == 0, output: output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return TmuxResult(success: false, output: error.localizedDescription)
        }
    }
}
