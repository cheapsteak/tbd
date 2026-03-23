# SSH Agent Resolver Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep `SSH_AUTH_SOCK` pointing to a live SSH agent in all TBD-managed tmux sessions, surviving macOS WindowServer crashes.

**Architecture:** A stable symlink (`~/.ssh/tbd-agent.sock`) that the daemon keeps pointed at the live SSH agent socket. Tmux sessions use the symlink path. A periodic background task detects staleness and re-probes.

**Tech Stack:** Swift, Foundation `Process`, POSIX sockets (`connect(2)`), `os.Logger`

**Spec:** `docs/superpowers/specs/2026-03-23-ssh-agent-resolver-design.md`

**Note on Package.swift:** The `SSH/` subdirectory does NOT need to be added to any exclude list. `TBDDaemonLib` picks up all `.swift` files under `Sources/TBDDaemon/` automatically (no `sources` key set). The `TBDDaemon` executable target already limits itself to `sources: ["main.swift"]`.

---

### Task 1: Create `SSHAgentResolver` with `isValid()`

**Files:**
- Create: `Sources/TBDDaemon/SSH/SSHAgentResolver.swift`
- Create: `Tests/TBDDaemonTests/SSHAgentResolverTests.swift`

- [ ] **Step 1: Write the failing test for `isValid()`**

Create `Tests/TBDDaemonTests/SSHAgentResolverTests.swift`:

```swift
import Foundation
import Testing
@testable import TBDDaemonLib

@Test func testIsValidReturnsFalseForNonexistentSymlink() {
    let resolver = SSHAgentResolver(
        symlinkPath: "/tmp/tbd-test-nonexistent-\(UUID().uuidString).sock"
    )
    #expect(!resolver.isValid())
}

@Test func testIsValidReturnsTrueForLiveSocket() throws {
    // Create a real Unix domain socket
    let socketPath = "/tmp/tbd-test-\(UUID().uuidString).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer {
        close(fd)
        unlink(socketPath)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
            rawPathPtr.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
        }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindResult == 0)
    listen(fd, 1)

    // Create symlink pointing to the socket
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: socketPath
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(symlinkPath: symlinkPath)
    #expect(resolver.isValid())
}

@Test func testIsValidReturnsFalseForStaleSocket() throws {
    // Create symlink pointing to a nonexistent socket
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: "/tmp/tbd-nonexistent-socket"
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(symlinkPath: symlinkPath)
    #expect(!resolver.isValid())
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter SSHAgentResolver 2>&1 | tail -20`
Expected: FAIL — `SSHAgentResolver` not found

- [ ] **Step 3: Write `SSHAgentResolver` with `isValid()`**

Create `Sources/TBDDaemon/SSH/SSHAgentResolver.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SSHAgent")

public struct SSHAgentResolver: Sendable {
    /// The stable symlink path: ~/.ssh/tbd-agent.sock
    public static let defaultSymlinkPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ssh/tbd-agent.sock"
    }()

    public let symlinkPath: String

    public init(symlinkPath: String = SSHAgentResolver.defaultSymlinkPath) {
        self.symlinkPath = symlinkPath
    }

    /// Check if the current symlink target is reachable via connect(2).
    public func isValid() -> Bool {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else {
            return false
        }
        return canConnect(to: target)
    }

    /// Attempt a connect(2) on a Unix domain socket path.
    /// Returns true if the connection succeeds (agent is alive).
    func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
                rawPathPtr.copyMemory(from: ptr, byteCount: min(strlen(ptr) + 1, MemoryLayout.size(ofValue: addr.sun_path)))
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SSHAgentResolver 2>&1 | tail -20`
Expected: All 3 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/SSH/SSHAgentResolver.swift Tests/TBDDaemonTests/SSHAgentResolverTests.swift
git commit -m "feat: add SSHAgentResolver with isValid() using connect(2)"
```

---

### Task 2: Add `resolve()` — probing with `ssh-add` and symlink update

**Files:**
- Modify: `Sources/TBDDaemon/SSH/SSHAgentResolver.swift`
- Modify: `Tests/TBDDaemonTests/SSHAgentResolverTests.swift`

- [ ] **Step 1: Write the failing test for `resolve()` with a mock socket**

Add to `SSHAgentResolverTests.swift`:

```swift
@Test func testResolveFindsLiveSocket() async throws {
    // Create a listening Unix domain socket (simulates SSH agent)
    let socketPath = "/tmp/tbd-test-agent-\(UUID().uuidString).sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(fd >= 0)
    defer {
        close(fd)
        unlink(socketPath)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    socketPath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
            rawPathPtr.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
        }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindResult == 0)
    listen(fd, 1)

    // Resolver with a fresh symlink path — inject known candidate
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(
        symlinkPath: symlinkPath,
        candidatePaths: [socketPath]
    )
    let result = await resolver.resolve()
    #expect(result)

    // Verify the symlink was created and points to the socket
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)
    #expect(target == socketPath)
    #expect(resolver.isValid())
}

@Test func testResolveReturnsFalseWhenNoLiveSocket() async {
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(
        symlinkPath: symlinkPath,
        candidatePaths: ["/tmp/nonexistent-socket-1", "/tmp/nonexistent-socket-2"]
    )
    let result = await resolver.resolve()
    #expect(!result)
}

@Test func testResolveUpdatesStaleSymlink() async throws {
    // Create a live socket and a stale (nonexistent) path
    let stalePath = "/tmp/tbd-test-stale-\(UUID().uuidString).sock"
    let livePath = "/tmp/tbd-test-live-\(UUID().uuidString).sock"

    let liveFd = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(liveFd >= 0)
    defer {
        close(liveFd)
        unlink(livePath)
    }

    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    livePath.withCString { ptr in
        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
            rawPathPtr.copyMemory(from: ptr, byteCount: strlen(ptr) + 1)
        }
    }
    let bindResult = withUnsafePointer(to: &addr) { ptr in
        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
            bind(liveFd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    #expect(bindResult == 0)
    listen(liveFd, 1)

    // Create symlink pointing to stale path
    let symlinkPath = "/tmp/tbd-test-link-\(UUID().uuidString).sock"
    try FileManager.default.createSymbolicLink(
        atPath: symlinkPath,
        withDestinationPath: stalePath
    )
    defer { unlink(symlinkPath) }

    let resolver = SSHAgentResolver(
        symlinkPath: symlinkPath,
        candidatePaths: [stalePath, livePath]
    )
    let result = await resolver.resolve()
    #expect(result)

    // Verify symlink now points to the live socket
    let target = try FileManager.default.destinationOfSymbolicLink(atPath: symlinkPath)
    #expect(target == livePath)
}
```

Note: `resolve()` tests use `candidatePaths` injection to avoid depending on `ssh-add` in CI. The `canConnect(to:)` fast path is sufficient for test sockets. The production `discoverCandidates()` uses `ssh-add -l` to verify the SSH agent protocol (see Step 3).

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `swift test --filter SSHAgentResolver 2>&1 | tail -20`
Expected: New tests FAIL — `resolve()` and `candidatePaths` don't exist yet

- [ ] **Step 3: Implement `resolve()`, `discoverCandidates()`, and `updateSymlink()`**

Replace the full content of `SSHAgentResolver.swift`:

```swift
import Foundation
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "SSHAgent")

public struct SSHAgentResolver: Sendable {
    /// The stable symlink path: ~/.ssh/tbd-agent.sock
    public static let defaultSymlinkPath: String = {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return "\(home)/.ssh/tbd-agent.sock"
    }()

    public let symlinkPath: String
    private let candidatePaths: [String]?

    public init(
        symlinkPath: String = SSHAgentResolver.defaultSymlinkPath,
        candidatePaths: [String]? = nil
    ) {
        self.symlinkPath = symlinkPath
        self.candidatePaths = candidatePaths
    }

    /// Ensure the symlink points to a live SSH agent socket.
    /// Returns true if a live agent was found and the symlink was updated.
    public func resolve() async -> Bool {
        // Fast path: current symlink target is still alive
        if isValid() {
            logger.debug("SSH agent symlink is valid")
            return true
        }

        // Slow path: probe candidates
        let candidates: [String]
        if let injected = candidatePaths {
            // Test injection: use connect(2) instead of ssh-add
            candidates = injected
            logger.info("SSH agent stale, probing \(candidates.count) injected candidates")
            for path in candidates {
                if canConnect(to: path) {
                    return applySymlink(to: path)
                }
            }
        } else {
            // Production: discover and probe with ssh-add -l
            candidates = discoverCandidates()
            logger.info("SSH agent stale, probing \(candidates.count) candidates")
            for path in candidates {
                if await probeWithSSHAdd(socketPath: path) {
                    return applySymlink(to: path)
                }
            }
        }

        logger.warning("No live SSH agent found among \(candidates.count) candidates")
        return false
    }

    /// Check if the current symlink target is reachable via connect(2).
    public func isValid() -> Bool {
        let fm = FileManager.default
        guard let target = try? fm.destinationOfSymbolicLink(atPath: symlinkPath) else {
            return false
        }
        return canConnect(to: target)
    }

    // MARK: - Private

    /// Attempt a connect(2) on a Unix domain socket path.
    func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        path.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let rawPathPtr = UnsafeMutableRawPointer(pathPtr)
                rawPathPtr.copyMemory(from: ptr, byteCount: min(strlen(ptr) + 1, MemoryLayout.size(ofValue: addr.sun_path)))
            }
        }
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        } == 0
    }

    /// Probe a socket with `ssh-add -l` to verify it speaks SSH agent protocol.
    /// Exit code 0 or 1 = live agent. Exit code 2 = not an SSH agent.
    /// Times out after 2 seconds.
    private func probeWithSSHAdd(socketPath: String) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-add")
                process.arguments = ["-l"]
                process.environment = ["SSH_AUTH_SOCK": socketPath]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice

                do {
                    try process.run()
                    process.waitUntilExit()
                    // Exit 0 = keys listed, Exit 1 = agent has no keys, Exit 2 = not an agent
                    return process.terminationStatus != 2
                } catch {
                    return false
                }
            }

            group.addTask {
                try? await Task.sleep(for: .seconds(2))
                return false  // Timeout sentinel
            }

            // Take whichever finishes first
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }

    /// Discover candidate SSH agent socket paths from launchd.
    /// Sorted newest first by mtime, capped at 10 to bound probe time.
    private func discoverCandidates() -> [String] {
        let fm = FileManager.default
        let baseDir = "/private/tmp"
        guard let entries = try? fm.contentsOfDirectory(atPath: baseDir) else { return [] }

        var candidates: [(path: String, mtime: Date)] = []
        for dir in entries where dir.hasPrefix("com.apple.launchd.") {
            let path = "\(baseDir)/\(dir)/Listeners"
            var statBuf = stat()
            guard stat(path, &statBuf) == 0,
                  (statBuf.st_mode & S_IFMT) == S_IFSOCK else {
                continue
            }
            let mtime = Date(timeIntervalSince1970: TimeInterval(statBuf.st_mtimespec.tv_sec))
            candidates.append((path: path, mtime: mtime))
        }

        return candidates
            .sorted { $0.mtime > $1.mtime }
            .prefix(10)
            .map(\.path)
    }

    /// Apply the symlink update and log the change.
    private func applySymlink(to target: String) -> Bool {
        do {
            try updateSymlink(to: target)
            return true
        } catch {
            logger.error("Failed to update symlink: \(error)")
            return false
        }
    }

    /// Atomically update the symlink to point to a new target.
    private func updateSymlink(to target: String) throws {
        let fm = FileManager.default

        // Ensure ~/.ssh/ exists with correct permissions
        let sshDir = (symlinkPath as NSString).deletingLastPathComponent
        if !fm.fileExists(atPath: sshDir) {
            try fm.createDirectory(atPath: sshDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        // Read old target BEFORE the rename for logging
        let old = (try? fm.destinationOfSymbolicLink(atPath: symlinkPath)) ?? "(none)"

        // Remove existing non-symlink file/directory at the path
        var pathStat = stat()
        if lstat(symlinkPath, &pathStat) == 0 {
            let fileType = pathStat.st_mode & S_IFMT
            if fileType != S_IFLNK {
                try fm.removeItem(atPath: symlinkPath)
            }
        }

        // Atomic update: create temp symlink, then rename over target
        let tempPath = symlinkPath + ".tmp.\(ProcessInfo.processInfo.processIdentifier)"
        unlink(tempPath)
        guard symlink(target, tempPath) == 0 else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard Darwin.rename(tempPath, symlinkPath) == 0 else {
            unlink(tempPath)
            throw CocoaError(.fileWriteUnknown)
        }

        logger.info("SSH agent symlink updated: \(old) → \(target)")
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter SSHAgentResolver 2>&1 | tail -20`
Expected: All 6 tests PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/SSH/SSHAgentResolver.swift Tests/TBDDaemonTests/SSHAgentResolverTests.swift
git commit -m "feat: add SSHAgentResolver.resolve() with ssh-add probing and atomic symlink"
```

---

### Task 3: Integrate into `TmuxManager.ensureServer`

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/TmuxManager.swift:59-76`

- [ ] **Step 1: Add `setenv` call in `ensureServer`**

After the `set -g mouse on` line (line 74), add:

```swift
            // Set SSH_AUTH_SOCK to stable symlink so shells get a resilient path
            try? await runTmux(["-L", server, "setenv", "-g", "SSH_AUTH_SOCK", SSHAgentResolver.defaultSymlinkPath])
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Commit**

```bash
git add Sources/TBDDaemon/Tmux/TmuxManager.swift
git commit -m "feat: set SSH_AUTH_SOCK to stable symlink in tmux server env"
```

---

### Task 4: Integrate into daemon startup and periodic refresh

**Files:**
- Modify: `Sources/TBDDaemon/Daemon.swift`

This consolidates both the spec's `main.swift` startup integration and the `Daemon.swift` periodic refresh into `Daemon.swift` (the lifecycle owner), since `main.swift` only calls `daemon.start()`.

- [ ] **Step 1: Add SSH agent resolve at startup and periodic refresh**

In `Daemon.swift`, add an `sshRefreshTask` property:

```swift
    public nonisolated(unsafe) var sshRefreshTask: Task<Void, Never>?
```

In `start()`, after step 4 (Write PID file) and before step 5 (Initialize database), add:

```swift
        // 4a. Resolve SSH agent symlink and update daemon's own environment
        let sshResolver = SSHAgentResolver()
        if await sshResolver.resolve() {
            setenv("SSH_AUTH_SOCK", sshResolver.symlinkPath, 1)
            print("[Daemon] SSH agent symlink resolved: \(sshResolver.symlinkPath)")
        }

        // 4b. Start periodic SSH agent refresh (every 60s)
        self.sshRefreshTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if !sshResolver.isValid() {
                    if await sshResolver.resolve() {
                        print("[Daemon] SSH agent symlink refreshed")
                    }
                }
            }
        }
```

In `stop()`, before "Stop servers", add:

```swift
        // Cancel SSH refresh
        sshRefreshTask?.cancel()
```

- [ ] **Step 2: Build to verify it compiles**

Run: `swift build 2>&1 | tail -5`
Expected: Build complete

- [ ] **Step 3: Run full test suite**

Run: `swift test 2>&1 | tail -20`
Expected: All tests pass

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDDaemon/Daemon.swift
git commit -m "feat: resolve SSH agent at startup and refresh every 60s"
```

---

### Task 5: End-to-end verification

- [ ] **Step 1: Rebuild and restart the daemon**

Run: `scripts/restart.sh`
Expected: Daemon starts successfully

- [ ] **Step 2: Verify symlink was created**

Run: `ls -la ~/.ssh/tbd-agent.sock`
Expected: Symlink pointing to a `/private/tmp/com.apple.launchd.*/Listeners` path

- [ ] **Step 3: Verify the symlink target is the live agent**

Run: `SSH_AUTH_SOCK=~/.ssh/tbd-agent.sock ssh-add -l`
Expected: Shows the ed25519 key

- [ ] **Step 4: Verify git signing works through the symlink**

Run (in a TBD-managed tmux session):
```bash
echo $SSH_AUTH_SOCK  # should be ~/.ssh/tbd-agent.sock
git log --show-signature -1  # should work without errors
```

- [ ] **Step 5: Commit any final adjustments**

```bash
git commit -m "fix: adjust SSH agent resolver based on e2e testing"
```
(Only if changes were needed.)
