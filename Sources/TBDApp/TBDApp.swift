import SwiftUI
import AppKit
import Darwin
import TBDShared
import os

private let lifecycleLogger = Logger(subsystem: "com.tbd.app", category: "lifecycle")

// Write-end of the SIGUSR1 → main-queue bridge pipe.
// Set once in applicationDidFinishLaunching; read only by the C signal handler
// via Darwin.write (async-signal-safe).
nonisolated(unsafe) private var _relaunchPipeWriteEnd: Int32 = -1

class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var cachedIcon: NSImage = generateAppIcon(worktreeName: detectWorktreeName())
    private var relaunchSource: (any DispatchSourceRead)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        NSApp.applicationIconImage = cachedIcon

        // SwiftUI scene creation runs after this method returns and can reset
        // applicationIconImage. Re-apply on the next run loop tick and again
        // when the app becomes active so the dock/cmd-tab tile actually sticks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.applicationIconImage = self.cachedIcon
        }

        installSelfRelaunchHandler()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        if NSApp.applicationIconImage !== cachedIcon {
            NSApp.applicationIconImage = cachedIcon
        }
    }

    // MARK: - Self-relaunch

    /// Installs a SIGUSR1 handler that causes the app to relaunch itself.
    ///
    /// restart.sh sends SIGUSR1 instead of killing TBDApp and launching a new
    /// process directly. A process spawned by the running app inherits its GUI
    /// session context and can connect to the window server — something a process
    /// launched from a tmux pane (background service context) cannot do.
    ///
    /// Signal → pipe → DispatchSource → main queue (signal handlers can't dispatch
    /// directly; only async-signal-safe Darwin.write is used in the handler itself).
    private func installSelfRelaunchHandler() {
        var fds = [Int32](repeating: -1, count: 2)
        guard pipe(&fds) == 0 else {
            lifecycleLogger.warning("Failed to create relaunch signal pipe")
            return
        }
        // Close-on-exec so spawned children don't inherit the pipe ends.
        fcntl(fds[0], F_SETFD, FD_CLOEXEC)
        fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        _relaunchPipeWriteEnd = fds[1]

        signal(SIGUSR1) { _ in
            var byte: UInt8 = 1
            Darwin.write(_relaunchPipeWriteEnd, &byte, 1)
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fds[0], queue: .main)
        source.setEventHandler { [weak self] in
            // Drain the byte so the source doesn't fire again immediately.
            var byte: UInt8 = 0
            Darwin.read(fds[0], &byte, 1)
            self?.performSelfRelaunch()
        }
        source.resume()
        relaunchSource = source
    }

    private func performSelfRelaunch() {
        // Cancel the source so a second signal during the 0.5s window can't
        // spawn an additional child.
        relaunchSource?.cancel()
        relaunchSource = nil

        let execURL = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0])
        lifecycleLogger.info("Self-relaunch triggered — launching \(execURL.path, privacy: .public)")
        let process = Process()
        process.executableURL = execURL
        do {
            try process.run()
        } catch {
            lifecycleLogger.error("Self-relaunch failed: \(error)")
            return
        }
        // Brief delay so the new process has time to start before we exit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            NSApp.terminate(nil)
        }
    }
}

@main
struct TBDAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        Window("TBD", id: "main") {
            ContentView()
                .environmentObject(appState)
                .onOpenURL { url in
                    DeepLinkHandler.handle(url, appState: appState)
                }
        }
        .defaultSize(width: 1200, height: 800)
        .commands {
            TBDCommands(appState: appState)
            ClaudeTokenMenu(appState: appState)
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
        }
    }
}
