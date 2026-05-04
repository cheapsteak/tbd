import SwiftUI
import AppKit
import Darwin
import ObjectiveC.runtime
import TBDShared
import os

internal let lifecycleLogger = Logger(subsystem: "com.tbd.app", category: "lifecycle")

// MARK: - Crash diagnostics

/// Directory where on-disk crash forensics are written.
/// `~/Library/Logs/TBD` — survives restarts, no sudo or logd config required.
private func tbdCrashLogDirectory() -> URL? {
    guard let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else {
        return nil
    }
    return libraryURL.appendingPathComponent("Logs/TBD")
}

private let tbdExceptionsLogMaxBytes: UInt64 = 5 * 1024 * 1024

/// Best-effort persisted append of an exception report. Never throws; never crashes.
/// Called from the Obj-C exception preprocessor on whatever thread raised.
private func tbdPersistException(_ ns: NSException) {
    do {
        guard let dir = tbdCrashLogDirectory() else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date())

        let name = ns.name.rawValue
        let reason = ns.reason ?? "<no reason>"
        let userInfoDump: String = {
            guard let info = ns.userInfo else { return "<nil>" }
            return String(describing: info)
        }()

        var windowDescription = "<none>"
        if let info = ns.userInfo,
           let window = info.values.first(where: { $0 is NSWindow }) as? NSWindow {
            // Best-effort — NSWindow properties are MainActor-isolated, so
            // gate on a main-thread runtime check and use assumeIsolated to
            // satisfy the Swift concurrency checker.
            if Thread.isMainThread {
                windowDescription = MainActor.assumeIsolated {
                    let frame = window.frame
                    let title = window.title
                    let cls = String(describing: type(of: window))
                    let contentCls = window.contentView.map { String(describing: type(of: $0)) } ?? "<nil>"
                    return "class=\(cls) title=\"\(title)\" frame=\(frame) contentView=\(contentCls)"
                }
            } else {
                windowDescription = "<NSWindow present in userInfo, not on main thread — skipped introspection>"
            }
        }

        let stack = ns.callStackSymbols.joined(separator: "\n")

        var report = ""
        report += "=== \(timestamp) ===\n"
        report += "name: \(name)\n"
        report += "reason: \(reason)\n"
        report += "userInfo: \(userInfoDump)\n"
        report += "window: \(windowDescription)\n"
        report += "callStackSymbols:\n\(stack)\n"
        report += "===\n\n"

        let appendURL = dir.appendingPathComponent("exceptions.log")
        let latestURL = dir.appendingPathComponent("last-exception.txt")

        // Latest — atomic overwrite.
        if let data = report.data(using: .utf8) {
            try? data.write(to: latestURL, options: [.atomic])
        }

        // Append log — rotate if it would exceed the size cap.
        let fm = FileManager.default
        if fm.fileExists(atPath: appendURL.path) {
            if let attrs = try? fm.attributesOfItem(atPath: appendURL.path),
               let size = attrs[.size] as? UInt64,
               size > tbdExceptionsLogMaxBytes {
                let rotatedURL = dir.appendingPathComponent("exceptions.log.1")
                try? fm.removeItem(at: rotatedURL)
                try? fm.moveItem(at: appendURL, to: rotatedURL)
            }
        }
        if !fm.fileExists(atPath: appendURL.path) {
            let header = "=== TBDApp exceptions log ===\n".data(using: .utf8) ?? Data()
            try? header.write(to: appendURL)
        }

        if let handle = try? FileHandle(forWritingTo: appendURL) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            if let data = report.data(using: .utf8) {
                try? handle.write(contentsOf: data)
            }
        }
    } catch {
        // Swallow — preprocessor must never throw.
    }
}

/// Top-level free function so it's usable as a C function pointer for
/// NSSetUncaughtExceptionHandler.
private func tbdUncaughtExceptionHandler(_ exception: NSException) {
    let name = exception.name.rawValue
    let reason = exception.reason ?? "<no reason>"
    let stack = exception.callStackSymbols.joined(separator: "\n")
    lifecycleLogger.fault("Uncaught NSException name=\(name, privacy: .public) reason=\(reason, privacy: .public)\n\(stack, privacy: .public)")
}

/// Objective-C exception preprocessor — fires the instant `[NSException raise]`
/// is called, before any unwinding or AppKit catch logic. We need this because
/// AppKit's `NSApplicationCrashOnExceptions` path calls
/// `+[NSApplication _crashOnException:]`, which raises SIGTRAP directly without
/// going through `NSSetUncaughtExceptionHandler`. The preprocessor lets us log
/// the reason before the process dies.
///
/// NOTE: This fires for ALL NSExceptions, including ones that are caught
/// internally (e.g. some AppKit/NSColor parsing paths throw and catch as
/// flow control). That's expected and not a bug — we only care about the
/// final crashing one, and fault-level entries are cheap.
///
/// Returns the exception unchanged so normal handling continues.
///
/// The `objc_exception_preprocessor` typedef is `id _Nonnull (*)(id _Nonnull)`,
/// which Swift imports as `@convention(c) (Any) -> Any`. We accept/return `Any`
/// and cast internally.
let tbdExceptionPreprocessor: @convention(c) (Any) -> Any = { exception in
    if let ns = exception as? NSException {
        let name = ns.name.rawValue
        let reason = ns.reason ?? "<no reason>"
        let stack = ns.callStackSymbols.joined(separator: "\n")
        lifecycleLogger.fault("Preprocessed NSException name=\(name, privacy: .public) reason=\(reason, privacy: .public) stack=\(stack, privacy: .public)")
        tbdPersistException(ns)
    }
    return exception
}

/// Async-signal-safe signal handler: writes a short literal C string to stderr
/// then resets disposition and re-raises so the OS produces the real crash report.
private func tbdSignalHandler(_ sig: Int32) {
    // Literal C strings only — no Swift interpolation, no os.Logger.
    switch sig {
    case SIGABRT:
        let msg = "TBDApp: caught SIGABRT\n"
        _ = msg.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
    case SIGSEGV:
        let msg = "TBDApp: caught SIGSEGV\n"
        _ = msg.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
    case SIGBUS:
        let msg = "TBDApp: caught SIGBUS\n"
        _ = msg.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
    case SIGILL:
        let msg = "TBDApp: caught SIGILL\n"
        _ = msg.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
    case SIGTRAP:
        let msg = "TBDApp: caught SIGTRAP\n"
        _ = msg.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
    default:
        let msg = "TBDApp: caught signal\n"
        _ = msg.withCString { Darwin.write(STDERR_FILENO, $0, strlen($0)) }
    }
    signal(sig, SIG_DFL)
    raise(sig)
}

// Write-end of the SIGUSR1 → main-queue bridge pipe.
// Set once in applicationDidFinishLaunching; read only by the C signal handler
// via Darwin.write (async-signal-safe).
nonisolated(unsafe) private var _relaunchPipeWriteEnd: Int32 = -1

class AppDelegate: NSObject, NSApplicationDelegate {
    private lazy var cachedIcon: NSImage = generateAppIcon(worktreeName: detectWorktreeName())
    private var relaunchSource: (any DispatchSourceRead)?
    private var heartbeatTimer: Timer?

    func applicationWillFinishLaunching(_ notification: Notification) {
        lifecycleLogger.info("willFinishLaunching")

        // Install crash handlers before any AppKit/SwiftUI code can throw or trap.
        // The Obj-C exception preprocessor must come first — it's our only chance
        // to capture the reason for exceptions that AppKit converts to SIGTRAP via
        // +[NSApplication _crashOnException:], which bypasses NSSetUncaughtExceptionHandler.
        _ = objc_setExceptionPreprocessor(tbdExceptionPreprocessor)
        NSSetUncaughtExceptionHandler(tbdUncaughtExceptionHandler)
        for sig in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP] {
            signal(sig, tbdSignalHandler)
        }

        if let dir = tbdCrashLogDirectory() {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            lifecycleLogger.info("Crash forensics writing to \(dir.path, privacy: .public)")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.activate(ignoringOtherApps: true)

        lifecycleLogger.info("didFinishLaunching activationPolicy=\(NSApp.activationPolicy().rawValue, privacy: .public)")

        NSApp.applicationIconImage = cachedIcon

        // SwiftUI scene creation runs after this method returns and can reset
        // applicationIconImage. Re-apply on the next run loop tick and again
        // when the app becomes active so the dock/cmd-tab tile actually sticks.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            NSApp.applicationIconImage = self.cachedIcon
        }

        installSelfRelaunchHandler()

        // Lifetime heartbeat — surfaces silent disappearances of windows / dock tile.
        let timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            MainActor.assumeIsolated {
                let policy = NSApp.activationPolicy().rawValue
                let count = NSApp.windows.count
                let active = NSApp.isActive
                let hasKey = NSApp.keyWindow != nil
                lifecycleLogger.info("heartbeat policy=\(policy, privacy: .public) windows=\(count, privacy: .public) active=\(active, privacy: .public) keyWindow=\(hasKey, privacy: .public)")
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        heartbeatTimer = timer
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        lifecycleLogger.info("didBecomeActive windows=\(NSApp.windows.count, privacy: .public)")
        if NSApp.applicationIconImage !== cachedIcon {
            NSApp.applicationIconImage = cachedIcon
        }
    }

    func applicationDidResignActive(_ notification: Notification) {
        lifecycleLogger.info("didResignActive")
    }

    func applicationWillTerminate(_ notification: Notification) {
        lifecycleLogger.info("willTerminate")
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

    init() {
        lifecycleLogger.info("TBDApp launching pid=\(getpid(), privacy: .public)")
    }

    var body: some Scene {
        Window("TBD", id: "main") {
            ContentView()
                .environmentObject(appState)
                .onAppear {
                    lifecycleLogger.info("scene main onAppear")
                }
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
