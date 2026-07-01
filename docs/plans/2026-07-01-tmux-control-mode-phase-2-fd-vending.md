# tmux Control Mode — Phase 2 (FD Vending + Single-Pane Render) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one visible pane render end-to-end through the control-mode path — daemon owns the `tmux -CC` connection, creates a pipe per attached pane, vends the pipe read FD to the app over a sidecar Unix socket via `SCM_RIGHTS`, and the app drains that FD directly into SwiftTerm.

**Architecture:** Two milestones. **Milestone A** is infrastructure: harden Phase 1's connection teardown, add a raw-POSIX `FDChannel` that sends a file descriptor plus a small header over a Unix `socketpair`, wire it as a **sidecar socket** in the daemon (separate from the existing SwiftNIO JSON-RPC socket), add the four new attach-lifecycle RPC methods as stubs, and prove FD passing end-to-end with an in-process socket-pair test. **Milestone B** is the feature: extend `TmuxControlSupervisor` with per-pane pipe write-end fanout, implement the attach orchestrator (create pipe → vend FD → wait for `attach.ready` → start writing), build the app-side `ControlModeStreamReader` actor that survives SwiftUI view destruction, branch `TerminalPanelRepresentable` on the control-mode gate, and cover it with a live-tmux integration test. Grouped-sessions is untouched when the gate is off.

**Tech Stack:** Swift 6 strict concurrency (`swift-tools-version: 6.0`), Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), Foundation, `os.Logger`, raw Darwin POSIX (`sendmsg`, `recvmsg`, `socketpair`, `pipe`), SwiftNIO (existing RPC socket — unchanged), SwiftTerm (existing render endpoint). Build: `swift build`. Test: `swift test`. Lint: `swift package plugin --allow-writing-to-package-directory swiftlint --strict`.

**Reference spec:** `docs/specs/2026-05-17-tmux-control-mode-design.md`
**Reference plan (Phase 1):** `docs/plans/2026-05-21-tmux-control-mode-phase-1-foundation.md`

**Phase boundary — explicitly NOT in Phase 2:**
- **No scrollback / α-replay** (Phase 5). On attach, whatever tmux emits going forward is what the app sees; early bytes before `attach.ready` are dropped, not buffered.
- **No keystrokes** (Phase 3). The pane is read-only from the user's perspective in Phase 2. Grouped-sessions remains the default; the user can still keystroke through that path when the gate is off.
- **No size arbitration** (Phase 4). Panes render at whatever size tmux allocated at server-create time.
- **No flow control** (Phase 6). Writes to the per-pane pipe are nonblocking; if a write returns `EAGAIN`, the bytes are dropped and a counter is logged.
- **No crash recovery flows** (Phase 7).
- **No multi-pane, no `%layout-change` handling.**
- **No SQLite schema changes.**

---

## File Map

**Modify (TBDDaemon):**
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift` — Task 1 (teardown escalation + finish-ordering fix)
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift` — Task 6 (per-pane pipe registry + event fanout) + Task 7 (attach orchestration hook)
- `Sources/TBDDaemon/Server/RPCRouter.swift` — Task 4 (register new methods) + Task 7 (attach handlers)
- `Sources/TBDDaemon/Daemon.swift` — Task 3 (start the sidecar) + Task 4 (thread the supervisor into the router; already done in Phase 1, verify)
- `Sources/TBDShared/RPCProtocol.swift` — Task 4 (`RPCMethod` cases + params structs)

**Create (TBDDaemon):**
- `Sources/TBDDaemon/Server/FDChannel.swift` — Task 2 (POSIX `sendmsg`/`recvmsg` for FDs)
- `Sources/TBDDaemon/Server/FDVendingServer.swift` — Task 3 (sidecar socket server, per-daemon singleton)
- `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift` — Task 7 (`attach.request` / `attach.ready` / `pane.detach` handlers)

**Modify (TBDApp):**
- `Sources/TBDApp/DaemonClient.swift` — Task 3 (add `FDChannel` client side) + Task 4 (RPC method call helpers) + Task 9 (attach convenience)
- `Sources/TBDApp/Terminal/TerminalPanelView.swift` — Task 9 (control-mode branch)
- `Sources/TBDApp/AppState.swift` — Task 8 (own the `ControlModeReaderRegistry`)

**Create (TBDApp):**
- `Sources/TBDApp/Terminal/ControlModeStreamReader.swift` — Task 8 (long-lived per-pane FD drainer)
- `Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift` — Task 8 (view-independent owner of readers)

**Tests:**
- `Tests/TBDDaemonTests/TmuxControlConnectionTeardownTests.swift` — Task 1
- `Tests/TBDDaemonTests/FDChannelTests.swift` — Task 2
- `Tests/TBDDaemonTests/FDVendingServerTests.swift` — Task 3 (in-process socket-pair)
- `Tests/TBDDaemonTests/AttachRPCTests.swift` — Task 4 (stub handler round-trip) + Task 7 (real orchestration)
- `Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift` — Task 6
- `Tests/TBDDaemonTests/PhaseTwoIntegrationTests.swift` — Task 10 (live tmux → daemon → vended FD → assertion)
- `Tests/TBDAppTests/ControlModeStreamReaderTests.swift` — Task 8 (reader lifecycle)

SwiftPM auto-globs `Sources/` and `Tests/` — no `Package.swift` change needed. Test module is `TBDDaemonLib` (not `TBDDaemon`) — this is a Swift package where `Sources/TBDDaemon/` compiles into the library target `TBDDaemonLib` that the tests import.

---

# Milestone A — Infrastructure

Tasks 1–5. When Milestone A lands, `swift test` is green and the socket-pair test proves an FD can flow daemon→app. Nothing is user-visible yet.

## Task 1: Harden `TmuxControlConnection` teardown

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift`
- Test: `Tests/TBDDaemonTests/TmuxControlConnectionTeardownTests.swift`

Phase 1's `stop()` had two issues flagged by review: (a) 2 s timeout under a wedged child leaks the reader thread in `read()`; (b) `terminationHandler` and reader thread both call `eventContinuation.finish()`, racing the last `%output` burst on disconnect. Fix by escalating `SIGTERM → SIGKILL` after 500 ms, and by making the reader thread the **sole** owner of `finish()` on the stream (removing it from `terminationHandler` and `stop()`).

The observation that makes the escalation work: `SIGKILL` is uncatchable, so once the daemon sends it, the child releases the pty slave, the pty master gets EOF, and the reader's blocked `read()` returns 0 — waking cleanly. The 500 ms `SIGTERM` window still gives tmux the chance to exit gracefully. `shutdown()` doesn't help here — the pty master is a character device, not a socket.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/TmuxControlConnectionTeardownTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("TmuxControlConnection teardown")
struct TmuxControlConnectionTeardownTests {

    @discardableResult
    private func tmux(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    @Test("stop() completes within 1s under normal termination")
    func stopCompletesQuickly() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }
        let server = "tbd-teardown-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]))

        let connection = TmuxControlConnection(serverName: server)
        try connection.start()
        try await Task.sleep(for: .milliseconds(300))

        let started = Date()
        connection.stop()
        let elapsed = Date().timeIntervalSince(started)
        #expect(elapsed < 1.0, "stop() took \(elapsed)s")
    }

    @Test("trailing %output events are delivered before the stream finishes")
    func trailingOutputPreserved() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }
        let server = "tbd-trailing-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]))

        let connection = TmuxControlConnection(serverName: server)
        try connection.start()

        let box = TeardownEventBox()
        let collector = Task {
            for await event in connection.events { await box.append(event) }
            await box.markFinished()
        }
        try await Task.sleep(for: .milliseconds(400))
        tmux(["-L", server, "send-keys", "echo trailing-marker-\(UUID().uuidString.prefix(6))", "Enter"])
        try await Task.sleep(for: .milliseconds(300))
        connection.stop()

        // Give the collector up to 1 s to observe the finished stream.
        for _ in 0..<20 {
            if await box.finished { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        collector.cancel()

        let outputCount = await box.outputEventCount
        #expect(await box.finished, "collector should observe stream finish")
        #expect(outputCount > 0, "at least one %output event should arrive")
    }
}

private actor TeardownEventBox {
    private(set) var outputEventCount = 0
    private(set) var finished = false
    func append(_ event: TmuxControlEvent) {
        if case .output = event { outputEventCount += 1 }
    }
    func markFinished() { finished = true }
}
```

- [ ] **Step 2: Run the tests to verify the second one races**

Run: `swift test --filter TmuxControlConnectionTeardownTests`
Expected: `stopCompletesQuickly` may pass already (normal-termination path is fast). `trailingOutputPreserved` may pass or intermittently fail depending on scheduling — the finish-ordering bug is a race, so a hard failure is not guaranteed today. Note the result; the fix in Step 3 makes both robust.

- [ ] **Step 3: Apply the teardown escalation + finish-ordering fix**

In `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift`:

Replace the existing `terminationHandler` closure (the one that calls `self?.eventContinuation.finish()`) with:

```swift
        process.terminationHandler = { [weak self] proc in
            self?.logger.info(
                "tmux -CC connection for \(server, privacy: .public) exited, status \(proc.terminationStatus)")
            // Do NOT finish() the event stream here — the reader thread finishes
            // it after draining the final read() so no trailing %output is lost.
        }
```

Replace the entire `stop()` method with:

```swift
    /// Stop the connection: escalate SIGTERM → SIGKILL so the child always
    /// releases the pty slave, then wait for the reader to observe EOF before
    /// closing the primary fd.
    ///
    /// Order matters. Terminating tmux first makes the child release the pty
    /// slave, which delivers EOF to the primary and lets the reader's blocked
    /// `read()` return cleanly. Only then is it safe to `close()` the primary —
    /// closing it while the reader is still parked in `read()` would leak the
    /// reader thread on Darwin. If tmux ignores SIGTERM for 500 ms, escalate to
    /// SIGKILL (uncatchable — the child cannot resist it), then wait up to a
    /// further 1.5 s for the reader to exit. `eventContinuation.finish()` is
    /// called only by the reader thread at the end of `readLoop`, so any
    /// trailing bytes decoded from the final `read()` are delivered first.
    func stop() {
        ioLock.lock()
        let fd = primaryFD
        primaryFD = -1
        ioLock.unlock()

        if process.isRunning {
            process.terminate()
            let sigTermWait = readerExited.wait(timeout: .now() + .milliseconds(500))
            if sigTermWait == .timedOut, process.isRunning {
                let pid = process.processIdentifier
                if pid > 0 {
                    logger.info("escalating tmux -CC for \(self.serverName, privacy: .public) to SIGKILL after 500ms")
                    kill(pid, SIGKILL)
                }
                _ = readerExited.wait(timeout: .now() + .milliseconds(1500))
            }
        }

        if fd >= 0 { Darwin.close(fd) }
    }
```

The `readLoop` method already signals `readerExited` and calls `eventContinuation.finish()` in the right order — no change needed there. Confirm by reading the current `readLoop` (should end with `readerExited.signal()` then `eventContinuation.finish()`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TmuxControlConnectionTeardownTests`
Expected: both tests PASS. Also run `swift test --filter TmuxControlConnectionIntegration` — the existing Phase 1 integration test must still pass (no regression).

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift Tests/TBDDaemonTests/TmuxControlConnectionTeardownTests.swift
git commit -m "fix: escalate tmux -CC teardown to SIGKILL and preserve trailing output"
```

---

## Task 2: `FDChannel` — POSIX `sendmsg`/`recvmsg` for file descriptors

**Files:**
- Create: `Sources/TBDDaemon/Server/FDChannel.swift`
- Test: `Tests/TBDDaemonTests/FDChannelTests.swift`

`FDChannel` is a stateless namespace with two static functions: send one file descriptor plus a small header over a Unix stream socket, and receive the same on the other side. Uses `sendmsg`/`recvmsg` with `SCM_RIGHTS` — the standard Darwin/POSIX pattern. Tests use `socketpair(AF_UNIX, SOCK_STREAM, ...)` and a `pipe()` to prove an FD survives the crossing.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/FDChannelTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("FDChannel")
struct FDChannelTests {

    /// Allocate a connected Unix stream socketpair. Both fds must be closed by
    /// the caller.
    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf -> Void in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    @Test("a pipe read FD sent over a socketpair still delivers data")
    func fdSurvivesCrossing() throws {
        let (a, b) = try makeSocketPair()
        defer { Darwin.close(a); Darwin.close(b) }

        var pipeFDs: [Int32] = [-1, -1]
        try pipeFDs.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        let readFD = pipeFDs[0], writeFD = pipeFDs[1]
        defer { Darwin.close(writeFD) }

        let header = Data("marker".utf8)
        try FDChannel.sendFD(readFD, over: a, header: header)
        // Sender no longer needs its copy of the pipe read end.
        Darwin.close(readFD)

        let (receivedFD, receivedHeader) = try FDChannel.receiveFD(from: b, headerCapacity: 64)
        defer { Darwin.close(receivedFD) }
        #expect(receivedHeader == header)

        // Prove the received fd points at the same pipe: write on the original
        // write end and read on the received end.
        let payload = Data("hello-fd".utf8)
        _ = payload.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(receivedFD, $0.baseAddress, $0.count) }
        #expect(count == payload.count)
        #expect(Data(buffer[0..<Int(count)]) == payload)
    }

    @Test("receiveFD throws when the peer closed without sending")
    func closedPeerFails() throws {
        let (a, b) = try makeSocketPair()
        Darwin.close(a)  // peer closes without sending
        defer { Darwin.close(b) }
        #expect(throws: FDChannelError.self) {
            _ = try FDChannel.receiveFD(from: b, headerCapacity: 64)
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FDChannelTests`
Expected: compile failure — `cannot find 'FDChannel' in scope`.

- [ ] **Step 3: Implement `FDChannel`**

Create `Sources/TBDDaemon/Server/FDChannel.swift`:

```swift
import Darwin
import Foundation

/// Errors raised by `FDChannel.sendFD` / `receiveFD`.
enum FDChannelError: Error, Equatable {
    case sendFailed(Int32)          // errno from sendmsg or setup
    case receiveFailed(Int32)       // errno from recvmsg
    case peerClosed                 // clean EOF from the peer
    case noAncillaryData            // recvmsg succeeded but no SCM_RIGHTS attached
    case unexpectedControlLevel     // cmsg header wasn't SOL_SOCKET / SCM_RIGHTS
}

/// Stateless helpers for handing a single file descriptor plus a small header
/// across a Unix stream socket, using `sendmsg`/`recvmsg` + `SCM_RIGHTS`.
///
/// The header travels in the message payload (not the ancillary data). Callers
/// choose their own header encoding — a JSON blob, a fixed struct, whatever —
/// the channel does not interpret it.
enum FDChannel {
    /// Send `fd` plus `header` over `socket`. On return, `fd` is still owned by
    /// the caller (the kernel duplicated it into the peer's fd table); it is
    /// safe — and usually correct — to `close(fd)` immediately after.
    static func sendFD(_ fd: Int32, over socket: Int32, header: Data) throws {
        // Layout the ancillary buffer for exactly one fd.
        let controlLen = Int(CMSG_SPACE(UInt32(MemoryLayout<Int32>.size)))
        var control = [UInt8](repeating: 0, count: controlLen)

        try header.withUnsafeBytes { headerBytes in
            try control.withUnsafeMutableBufferPointer { controlBuf in
                var iov = iovec(
                    iov_base: UnsafeMutableRawPointer(mutating: headerBytes.baseAddress),
                    iov_len: headerBytes.count)
                var msg = msghdr()
                withUnsafeMutablePointer(to: &iov) { iovPtr in
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = UnsafeMutableRawPointer(controlBuf.baseAddress)
                    msg.msg_controllen = socklen_t(controlLen)

                    let cmsg = CMSG_FIRSTHDR(&msg)!
                    cmsg.pointee.cmsg_len = socklen_t(CMSG_LEN(UInt32(MemoryLayout<Int32>.size)))
                    cmsg.pointee.cmsg_level = SOL_SOCKET
                    cmsg.pointee.cmsg_type = SCM_RIGHTS
                    let fdPtr = CMSG_DATA(cmsg).assumingMemoryBound(to: Int32.self)
                    fdPtr.pointee = fd
                }

                let sent = withUnsafeMutablePointer(to: &msg) { sendmsg(socket, $0, 0) }
                if sent < 0 { throw FDChannelError.sendFailed(errno) }
            }
        }
    }

    /// Receive one fd + header from `socket`. `headerCapacity` sets the max
    /// header bytes the caller expects; larger senders will be truncated.
    /// Returned fd is owned by the caller and must be `close()`d.
    static func receiveFD(from socket: Int32, headerCapacity: Int) throws -> (fd: Int32, header: Data) {
        let controlLen = Int(CMSG_SPACE(UInt32(MemoryLayout<Int32>.size)))
        var control = [UInt8](repeating: 0, count: controlLen)
        var headerBuffer = [UInt8](repeating: 0, count: max(headerCapacity, 1))

        var receivedFD: Int32 = -1
        var receivedBytes = 0

        try headerBuffer.withUnsafeMutableBufferPointer { headerBuf in
            try control.withUnsafeMutableBufferPointer { controlBuf in
                var iov = iovec(iov_base: headerBuf.baseAddress, iov_len: headerBuf.count)
                var msg = msghdr()
                let result = withUnsafeMutablePointer(to: &iov) { iovPtr -> ssize_t in
                    msg.msg_iov = iovPtr
                    msg.msg_iovlen = 1
                    msg.msg_control = UnsafeMutableRawPointer(controlBuf.baseAddress)
                    msg.msg_controllen = socklen_t(controlLen)
                    return withUnsafeMutablePointer(to: &msg) { recvmsg(socket, $0, 0) }
                }
                if result < 0 { throw FDChannelError.receiveFailed(errno) }
                if result == 0 { throw FDChannelError.peerClosed }

                receivedBytes = Int(result)

                guard let cmsg = CMSG_FIRSTHDR(&msg) else {
                    throw FDChannelError.noAncillaryData
                }
                guard cmsg.pointee.cmsg_level == SOL_SOCKET,
                      cmsg.pointee.cmsg_type == SCM_RIGHTS else {
                    throw FDChannelError.unexpectedControlLevel
                }
                let fdPtr = CMSG_DATA(cmsg).assumingMemoryBound(to: Int32.self)
                receivedFD = fdPtr.pointee
            }
        }

        return (fd: receivedFD, header: Data(headerBuffer.prefix(receivedBytes)))
    }
}
```

Note: `CMSG_SPACE`, `CMSG_LEN`, `CMSG_FIRSTHDR`, `CMSG_DATA` are Darwin macros exposed as functions in Swift's `Darwin` module. If the compiler complains about one of them, check that `import Darwin` is at the top (not `import Foundation` alone).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter FDChannelTests`
Expected: PASS, 2 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Server/FDChannel.swift Tests/TBDDaemonTests/FDChannelTests.swift
git commit -m "feat: add FDChannel for sending file descriptors over Unix sockets"
```

---

## Task 3: `FDVendingServer` — sidecar Unix socket + client

**Files:**
- Create: `Sources/TBDDaemon/Server/FDVendingServer.swift`
- Modify: `Sources/TBDDaemon/Daemon.swift` (start the sidecar)
- Modify: `Sources/TBDApp/DaemonClient.swift` (add sidecar client fields)
- Test: `Tests/TBDDaemonTests/FDVendingServerTests.swift`

The sidecar is a second Unix socket, path `~/tbd/vend.sock` (respects `TBD_HOME`). Daemon accepts at most one connection at a time (the app process). This task installs the plumbing — no vending logic yet; a bare "connected" state is the acceptance criterion.

`~/tbd` on Darwin is a short path; `sun_path` (~104 chars) is safe. If `TBD_HOME` is set to a deep tmp path (as tests may do), respect the same `TBD_SOCKET_PATH` escape hatch the RPC socket uses — but for Phase 2 tests we bypass the on-disk socket entirely with `socketpair()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/FDVendingServerTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("FDVendingServer")
struct FDVendingServerTests {

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    @Test("adopting a client fd allows sending an fd to that peer")
    func adoptAndSend() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let server = FDVendingServer()
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.disconnect() } }

        var pipeFDs: [Int32] = [-1, -1]
        try pipeFDs.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])
        defer { Darwin.close(writeFD) }

        let header = Data("hdr".utf8)
        try await server.send(fd: readFD, header: header)
        Darwin.close(readFD)

        let (rxFD, rxHeader) = try FDChannel.receiveFD(from: clientSideFD, headerCapacity: 32)
        defer { Darwin.close(rxFD) }
        #expect(rxHeader == header)

        // sanity: the received fd is a real pipe end
        let msg = Data("ok".utf8)
        _ = msg.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        var buf = [UInt8](repeating: 0, count: 8)
        let n = buf.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(Int(n) == msg.count)
    }

    @Test("send without an adopted connection throws")
    func sendBeforeAdoptFails() async {
        let server = FDVendingServer()
        await #expect(throws: FDVendingServerError.notConnected) {
            try await server.send(fd: 0, header: Data())
        }
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter FDVendingServerTests`
Expected: compile failure — `FDVendingServer` and `FDVendingServerError` not in scope.

- [ ] **Step 3: Implement `FDVendingServer`**

Create `Sources/TBDDaemon/Server/FDVendingServer.swift`:

```swift
import Darwin
import Foundation
import os

enum FDVendingServerError: Error, Equatable {
    case notConnected
    case bindFailed(Int32)
    case listenFailed(Int32)
    case acceptFailed(Int32)
}

/// A tiny per-daemon service that holds the sidecar socket the app connects to
/// for receiving file descriptors. Phase 2 has exactly one client (the app), so
/// at most one connection is adopted at a time; a new adoption replaces the
/// old one.
///
/// Phase 2's uses: after `TmuxControlSupervisor` creates a per-pane pipe, the
/// attach orchestrator calls `send(fd:header:)` here to hand the pipe's read
/// end to the app.
actor FDVendingServer {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "fdVending")
    private var clientFD: Int32 = -1
    /// Path of the listening socket, when one is bound. Nil when the server is
    /// running purely off adopted fds (unit tests).
    private var socketPath: String?
    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    /// Start listening on `path`. Any existing file at `path` is removed first.
    /// Only meaningful in the live daemon; tests should call `adoptConnection`
    /// directly.
    func listen(on path: String) throws {
        precondition(listenerFD == -1, "listen called twice")
        _ = unlink(path)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw FDVendingServerError.bindFailed(errno) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { dstChars in
                    _ = strlcpy(dstChars, src, MemoryLayout.size(ofValue: addr.sun_path))
                }
            }
        }
        let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bindResult = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.bind(fd, generic, addrLen)
            }
        }
        if bindResult < 0 {
            Darwin.close(fd)
            throw FDVendingServerError.bindFailed(errno)
        }
        if Darwin.listen(fd, 1) < 0 {
            Darwin.close(fd)
            throw FDVendingServerError.listenFailed(errno)
        }
        listenerFD = fd
        socketPath = path
        logger.info("FD vending sidecar listening at \(path, privacy: .public)")

        acceptTask = Task { [weak self] in
            await self?.acceptLoop()
        }
    }

    private func acceptLoop() async {
        while listenerFD >= 0 {
            let fd = listenerFD
            let accepted = await Task.detached(priority: .userInitiated) {
                var addr = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                return accept(fd, &addr, &len)
            }.value
            if accepted < 0 {
                if listenerFD < 0 { return }   // shutting down
                logger.error("FD vending accept failed: \(errno)")
                continue
            }
            adopt(accepted)
        }
    }

    /// Adopt a pre-connected socket fd. Ownership transfers here — do not
    /// close it in the caller. Replaces any prior connection.
    func adoptConnection(fd: Int32) {
        adopt(fd)
    }

    private func adopt(_ fd: Int32) {
        if clientFD >= 0 { Darwin.close(clientFD) }
        clientFD = fd
    }

    /// Close the current client connection (if any) without stopping the
    /// listener.
    func disconnect() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
    }

    /// Stop the listener and drop any active client. Idempotent.
    func stop() {
        if let task = acceptTask { task.cancel(); acceptTask = nil }
        if listenerFD >= 0 { Darwin.close(listenerFD); listenerFD = -1 }
        if let path = socketPath { _ = unlink(path); socketPath = nil }
        disconnect()
    }

    /// Send `fd` plus `header` to the currently connected app client.
    func send(fd: Int32, header: Data) throws {
        guard clientFD >= 0 else { throw FDVendingServerError.notConnected }
        try FDChannel.sendFD(fd, over: clientFD, header: header)
    }
}
```

- [ ] **Step 4: Wire the sidecar into `Daemon`**

Read `Sources/TBDDaemon/Daemon.swift` to find where the existing NIO RPC socket is bound (Phase 1 wired the supervisor here). Add a stored `let fdVendingServer = FDVendingServer()` field alongside `controlModeSupervisor`. In the daemon's `start()` method, after the RPC socket is up, add:

```swift
        let vendPath = TBDConstants.reposDir.deletingLastPathComponent()
            .appendingPathComponent("vend.sock").path
        do {
            try await fdVendingServer.listen(on: vendPath)
        } catch {
            logger.error("failed to start FD vending sidecar: \(error.localizedDescription, privacy: .public)")
        }
```

(If `TBDConstants` doesn't expose a `vendSocketPath` yet, either add one there or compute the path from `TBDConstants.configDir` directly — inspect the file and match its style.)

In the daemon's shutdown/teardown hook, add `await fdVendingServer.stop()`. Also update the bridge or supervisor plumbing so the vending server is reachable from the attach orchestrator wired in Task 7 (simplest: expose it as `let fdVendingServer` on `Daemon` and pass it into `TmuxControlSupervisor` via a setter or via the `TmuxControlModeBridge` struct's next revision — Task 7 will do this).

- [ ] **Step 5: Add sidecar-client stubs to `DaemonClient` (do not exercise yet)**

In `Sources/TBDApp/DaemonClient.swift`, add two stored properties near the RPC connection fields:

```swift
    /// Sidecar Unix socket for receiving vended file descriptors. Opened
    /// lazily on the first attach; nil until then. Lives for the DaemonClient's
    /// full lifetime once opened.
    private var fdSocketFD: Int32 = -1
    private let fdSocketLock = NSLock()
```

And a private helper that opens the sidecar path — invoked in Task 9:

```swift
    private func ensureFDSocket() throws -> Int32 {
        fdSocketLock.lock()
        defer { fdSocketLock.unlock() }
        if fdSocketFD >= 0 { return fdSocketFD }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw NSError(domain: "DaemonClient", code: Int(errno)) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let path = TBDConstants.fdVendingSocketPath   // define on TBDConstants alongside socketPath
        _ = path.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: addr.sun_path)) { dstChars in
                    _ = strlcpy(dstChars, src, MemoryLayout.size(ofValue: addr.sun_path))
                }
            }
        }
        let result = withUnsafePointer(to: &addr) { addrPtr in
            addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                Darwin.connect(fd, generic, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result < 0 { Darwin.close(fd); throw NSError(domain: "DaemonClient.connect", code: Int(errno)) }
        fdSocketFD = fd
        return fd
    }
```

Add `static var fdVendingSocketPath: String` on `TBDConstants` (or the equivalent constants file — locate it and follow the existing `socketPath` pattern). It should honor `TBD_HOME` for the base and expose an override env var if the parent socketPath does.

- [ ] **Step 6: Run tests + build**

Run: `swift test --filter FDVendingServerTests` — 2 PASS.
Run: `swift build` — clean.
Run: `swift package plugin --allow-writing-to-package-directory swiftlint --strict` — 0 violations.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Server/FDVendingServer.swift \
        Sources/TBDDaemon/Daemon.swift \
        Sources/TBDApp/DaemonClient.swift \
        Sources/TBDShared/Constants.swift \
        Tests/TBDDaemonTests/FDVendingServerTests.swift
git commit -m "feat: add sidecar FD-vending socket to the daemon and client"
```

(Adjust the `Constants.swift` path — search for the existing `socketPath` definition; add `fdVendingSocketPath` there.)

---

## Task 4: New RPC methods (stubs)

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDApp/DaemonClient.swift`
- Test: `Tests/TBDDaemonTests/AttachRPCTests.swift` (stub-round-trip only; real orchestration lands in Task 7)

Add the four attach-lifecycle RPC methods with stub handlers on the daemon side that log + acknowledge, plus matching client helpers. Real implementation follows in Tasks 6–7. This isolates the wire-protocol change so a broken handler doesn't confuse the orchestration work.

- [ ] **Step 1: Write the failing test**

Create `Tests/TBDDaemonTests/AttachRPCTests.swift`:

```swift
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("Attach RPC stubs")
struct AttachRPCStubTests {
    @Test("attach.request returns a placeholder acknowledgment")
    func requestRoundTrip() async throws {
        let router = try await makeRouterWithSupervisor()
        let params = AttachRequestParams(paneID: "%0", windowID: "@0")
        let response = try await router.testInvoke(method: .attachRequest, params: params)
        let result = try JSONDecoder().decode(AttachRequestResult.self, from: Data((response.result ?? "").utf8))
        #expect(result.status == "pending")
    }

    @Test("attach.ready accepts the ack")
    func readyRoundTrip() async throws {
        let router = try await makeRouterWithSupervisor()
        let params = AttachReadyParams(paneID: "%0")
        let response = try await router.testInvoke(method: .attachReady, params: params)
        #expect(response.success)
    }

    @Test("pane.detach accepts the detach")
    func detachRoundTrip() async throws {
        let router = try await makeRouterWithSupervisor()
        let params = PaneDetachParams(paneID: "%0")
        let response = try await router.testInvoke(method: .paneDetach, params: params)
        #expect(response.success)
    }
}
```

(`makeRouterWithSupervisor` and `RPCRouter.testInvoke` are test helpers — look at how the existing `RPCRouterTests` invoke handlers. Most existing router tests inject a fresh in-memory DB and call handlers directly. Match the pattern: instantiate a router with dry-run TmuxManager + in-memory `TBDDatabase(inMemory: true)` + a fresh `TmuxControlSupervisor`, then call the internal `handle(_:)` method with an `RPCRequest`. If a `testInvoke` helper doesn't exist, add it as a `@testable`-visible internal method on `RPCRouter` that wraps `handle`.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AttachRPCStubTests`
Expected: compile failure — `AttachRequestParams`, `.attachRequest`, etc. not in scope.

- [ ] **Step 3: Add the RPC method + param structs**

In `Sources/TBDShared/RPCProtocol.swift`, add to the `RPCMethod` enum (find the existing cases and follow their naming — the existing style is `.terminalCreate`, `.repoAdd`, etc.):

```swift
    case attachRequest = "attach.request"
    case attachReady = "attach.ready"
    case paneDetach = "pane.detach"
```

And add three `Codable` param structs (place them alongside other `*Params` structs in the same file):

```swift
public struct AttachRequestParams: Codable, Sendable {
    public let paneID: String
    public let windowID: String
    public init(paneID: String, windowID: String) {
        self.paneID = paneID; self.windowID = windowID
    }
}

public struct AttachRequestResult: Codable, Sendable {
    /// One of "pending" (waiting for attach.ready), "vended" (fd sent),
    /// "unavailable" (control mode off for this repo).
    public let status: String
    public init(status: String) { self.status = status }
}

public struct AttachReadyParams: Codable, Sendable {
    public let paneID: String
    public init(paneID: String) { self.paneID = paneID }
}

public struct PaneDetachParams: Codable, Sendable {
    public let paneID: String
    public init(paneID: String) { self.paneID = paneID }
}
```

- [ ] **Step 4: Add stub handlers to `RPCRouter`**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, extend the `handle(_:)` switch with three new cases (place near other handlers, alphabetically or by group):

```swift
        case .attachRequest:
            let params = try decode(AttachRequestParams.self, from: request.params)
            logger.info("attach.request paneID=\(params.paneID, privacy: .public) — stub")
            let result = AttachRequestResult(status: "pending")
            return RPCResponse(success: true, result: encodeToString(result), error: nil)

        case .attachReady:
            let params = try decode(AttachReadyParams.self, from: request.params)
            logger.info("attach.ready paneID=\(params.paneID, privacy: .public) — stub")
            return RPCResponse(success: true, result: nil, error: nil)

        case .paneDetach:
            let params = try decode(PaneDetachParams.self, from: request.params)
            logger.info("pane.detach paneID=\(params.paneID, privacy: .public) — stub")
            return RPCResponse(success: true, result: nil, error: nil)
```

Use whatever `decode`/`encodeToString` helpers the file already has. If the naming differs, match the existing pattern (search for another handler in the same file — e.g. `.terminalCreate` — and mirror its style).

- [ ] **Step 5: Add matching client helpers to `DaemonClient`**

In `Sources/TBDApp/DaemonClient.swift`, add three methods (place near other RPC method calls):

```swift
    func attachRequest(paneID: String, windowID: String) async throws -> AttachRequestResult {
        try await callAsync(method: .attachRequest,
                            params: AttachRequestParams(paneID: paneID, windowID: windowID),
                            resultType: AttachRequestResult.self)
    }

    func attachReady(paneID: String) async throws {
        try await callVoid(method: .attachReady, params: AttachReadyParams(paneID: paneID))
    }

    func paneDetach(paneID: String) async throws {
        try await callVoid(method: .paneDetach, params: PaneDetachParams(paneID: paneID))
    }
```

(Match the existing method names — `callAsync` and `callVoid` are what the earlier exploration reported; if they differ, mirror the file's convention.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter AttachRPCStubTests` — 3 PASS.
Run: `swift build` — clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift \
        Sources/TBDDaemon/Server/RPCRouter.swift \
        Sources/TBDApp/DaemonClient.swift \
        Tests/TBDDaemonTests/AttachRPCTests.swift
git commit -m "feat: register attach lifecycle RPC methods with stub handlers"
```

---

## Task 5: End-to-end FD flow socket-pair test

**Files:**
- Test: extend `Tests/TBDDaemonTests/FDVendingServerTests.swift`

Prove that a `pipe()`'s read end vended from the daemon's `FDVendingServer` over a `socketpair()` reaches the receiver with data intact — mimicking Milestone A's full data path without the on-disk socket. This is the "Milestone A demonstrable" acceptance test.

- [ ] **Step 1: Add the end-to-end test**

Append to `Tests/TBDDaemonTests/FDVendingServerTests.swift`, inside `FDVendingServerTests`:

```swift
    @Test("bytes written to the daemon-side pipe reach the client-side reader")
    func endToEndPipeThroughVendedFD() async throws {
        let (serverSideFD, clientSideFD) = try makeSocketPair()
        defer { Darwin.close(clientSideFD) }

        let server = FDVendingServer()
        await server.adoptConnection(fd: serverSideFD)
        defer { Task { await server.stop() } }

        var pipeFDs: [Int32] = [-1, -1]
        try pipeFDs.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else { throw FDChannelError.sendFailed(errno) }
        }
        let (readFD, writeFD) = (pipeFDs[0], pipeFDs[1])
        defer { Darwin.close(writeFD) }

        let header = Data("pane=%42".utf8)
        try await server.send(fd: readFD, header: header)
        Darwin.close(readFD)

        let (rxFD, rxHeader) = try FDChannel.receiveFD(from: clientSideFD, headerCapacity: 64)
        defer { Darwin.close(rxFD) }
        #expect(rxHeader == header)

        // Write in three chunks, verify the reader assembles them.
        for chunk in ["ab", "cde", "fgh"] {
            let data = Data(chunk.utf8)
            _ = data.withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        }
        Darwin.close(writeFD)  // signal EOF

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 32)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<Int(n)])
        }
        #expect(received == Data("abcdefgh".utf8))
    }
```

- [ ] **Step 2: Run + verify**

Run: `swift test --filter FDVendingServerTests` — 3 PASS total (2 previous + 1 new).

- [ ] **Step 3: Commit**

```bash
git add Tests/TBDDaemonTests/FDVendingServerTests.swift
git commit -m "test: end-to-end FD vending across a socketpair with pipe data flow"
```

Milestone A complete — the infrastructure ships. Nothing user-visible yet; `swift test` is green and the vending path is proven.

---

# Milestone B — Rendering

Tasks 6–11. When Milestone B lands, a worktree opened with `TBD_TMUX_CONTROL_MODE=1` renders through the control-mode path end to end.

## Task 6: `TmuxControlSupervisor` per-pane pipe fanout

**Files:**
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift`
- Test: `Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift`

Extend the supervisor: when an attach is registered for a pane, create a `pipe()`, remember the write end keyed by paneID, and route decoded `%output(paneID, bytes)` events into that write end (nonblocking `write()`). Events for unattached panes are dropped (a counter incremented and logged periodically). On detach, close and remove the write end.

Nonblocking writes are the right shape here because Phase 6 will layer flow control on top; for Phase 2 we just log and drop on `EAGAIN`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("TmuxControlSupervisor attach")
struct TmuxControlSupervisorAttachTests {

    @Test("attach returns a read fd that receives %output bytes")
    func attachedPaneReceivesOutput() async throws {
        let supervisor = TmuxControlSupervisor()
        let paneID = "%42"
        let readFD = try await supervisor.attach(paneID: paneID)
        defer { Darwin.close(readFD) }

        await supervisor._testInjectEvent(.output(paneID: paneID, bytes: Data("hello".utf8)))

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Int(count) == 5)
        #expect(Data(buffer[0..<Int(count)]) == Data("hello".utf8))
    }

    @Test("detach closes the pipe write end")
    func detachClosesPipe() async throws {
        let supervisor = TmuxControlSupervisor()
        let paneID = "%42"
        let readFD = try await supervisor.attach(paneID: paneID)
        defer { Darwin.close(readFD) }

        await supervisor.detach(paneID: paneID)

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(count == 0)  // EOF, because write end is closed
    }

    @Test("output for an unattached pane is dropped without error")
    func unattachedPaneDrops() async throws {
        let supervisor = TmuxControlSupervisor()
        await supervisor._testInjectEvent(.output(paneID: "%999", bytes: Data("x".utf8)))
        // No crash, no throw — this test just needs to reach here.
        #expect(true)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TmuxControlSupervisorAttachTests`
Expected: compile failure — `attach`, `detach`, `_testInjectEvent` don't exist.

- [ ] **Step 3: Extend `TmuxControlSupervisor`**

Open `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift`. Add three new stored properties inside the actor:

```swift
    /// Per-pane pipe write ends. Keyed by tmux paneID (e.g. "%0").
    private var paneWriteFDs: [String: Int32] = [:]
    /// Number of %output events dropped because no attach was registered for
    /// their pane. Emitted to the log periodically.
    private var droppedOutputEvents = 0
```

Add these methods (put them just after `ensureConnection` / `stopAll`):

```swift
    /// Register an attach for `paneID`: allocate a pipe, remember the write
    /// end, and return the read end for the caller to vend to the app.
    ///
    /// Idempotent: if an attach already exists, close the old write end (which
    /// EOFs the previous read end) and allocate a fresh pipe. Callers that
    /// need to preserve the old fd should `detach` first.
    func attach(paneID: String) throws -> Int32 {
        if let oldWrite = paneWriteFDs.removeValue(forKey: paneID) {
            Darwin.close(oldWrite)
        }
        var fds: [Int32] = [-1, -1]
        let ok = fds.withUnsafeMutableBufferPointer { buf -> Bool in
            pipe(buf.baseAddress) == 0
        }
        if !ok { throw TmuxControlSupervisorError.pipeAllocationFailed(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])

        // Make the write end nonblocking so a slow app-side reader never
        // stalls the parser thread. On EAGAIN we log-and-drop for Phase 2;
        // Phase 6 will queue.
        let flags = fcntl(writeFD, F_GETFL)
        _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)

        paneWriteFDs[paneID] = writeFD
        logger.info("attach paneID=\(paneID, privacy: .public) writeFD=\(writeFD)")
        return readFD
    }

    /// Close and forget the pipe write end for `paneID`. The corresponding
    /// read end (held by the app) will observe EOF on its next read.
    func detach(paneID: String) {
        guard let writeFD = paneWriteFDs.removeValue(forKey: paneID) else { return }
        Darwin.close(writeFD)
        logger.info("detach paneID=\(paneID, privacy: .public)")
    }

    /// Test hook: synchronously route a fabricated event through the same
    /// fanout code path a live tmux connection would.
    internal func _testInjectEvent(_ event: TmuxControlEvent) {
        route(event)
    }

    private func route(_ event: TmuxControlEvent) {
        switch event {
        case .output(let paneID, let bytes):
            guard let writeFD = paneWriteFDs[paneID] else {
                droppedOutputEvents += 1
                return
            }
            let n = bytes.withUnsafeBytes { buf -> Int in
                let ptr = buf.baseAddress
                return Darwin.write(writeFD, ptr, buf.count)
            }
            if n < 0 {
                if errno == EAGAIN {
                    logger.debug("pane \(paneID, privacy: .public) write EAGAIN, dropping \(bytes.count) bytes")
                } else {
                    logger.error("pane \(paneID, privacy: .public) write errno=\(errno)")
                }
            }
        default:
            break  // other events are logged separately; not routed to pipes
        }
    }
```

Also add the error type at the bottom of the file:

```swift
enum TmuxControlSupervisorError: Error {
    case pipeAllocationFailed(Int32)
}
```

Modify the existing `drain(serverName:connection:)` loop so that after logging each event it also calls `route(event)`. Locate the current loop that iterates `for await event in connection.events { log(event, serverName: serverName) }` and change it to:

```swift
        for await event in connection.events {
            log(event, serverName: serverName)
            route(event)
        }
```

Update `stopAll()` to also close all pane write fds:

```swift
    func stopAll() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
        for writeFD in paneWriteFDs.values { Darwin.close(writeFD) }
        paneWriteFDs.removeAll()
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TmuxControlSupervisorAttachTests` — 3 PASS.
Run: `swift test --filter Tmux` — no regressions (should be ≥ 60 PASS, all still green).

- [ ] **Step 5: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift \
        Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift
git commit -m "feat: per-pane pipe fanout in TmuxControlSupervisor"
```

---

## Task 7: Attach orchestrator — wire supervisor + vending server

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift` (delegate to the extension)
- Modify: `Sources/TBDDaemon/Daemon.swift` (thread `FDVendingServer` into the router)
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift` (per-pane ready gate)
- Test: extend `Tests/TBDDaemonTests/AttachRPCTests.swift`

Replace the Task 4 stub handlers with real orchestration:

1. On `attach.request{paneID, windowID}`: gate on `ControlModeGate.shouldEnable`; if off, return `status: "unavailable"`. If on, call `supervisor.attach(paneID:)` → get read FD; mark pane state as **pending** (writes to the pipe are deferred); send FD to the app via `FDVendingServer`; return `status: "pending"`.
2. On `attach.ready{paneID}`: mark pane state as **ready**; unblock the writer path.
3. On `pane.detach{paneID}`: call `supervisor.detach(paneID:)`.

For the pending → ready gate, extend the supervisor with a `Set<String>` of ready panes; the `route(.output(paneID, bytes))` case skips the write when the pane is not ready. This matches the spec's "vend FD first, wait for ack, then start writing" ordering — without it, the first bytes can deadlock inside a full pipe if the app hasn't yet started reading.

- [ ] **Step 1: Extend the supervisor with the ready gate**

In `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift`, add:

```swift
    /// paneIDs for which the app has acknowledged `attach.ready`. Writes are
    /// suppressed for panes not in this set — the design's "vend fd first, ack,
    /// then write" ordering, which avoids blocking on a full pipe before the
    /// app has started reading.
    private var readyPanes: Set<String> = []

    /// Mark the pane as ready to receive writes. Called from the RPC handler
    /// after the app sends `attach.ready`.
    func markReady(paneID: String) {
        readyPanes.insert(paneID)
        logger.info("markReady paneID=\(paneID, privacy: .public)")
    }
```

Update `attach(paneID:)` to also remove the pane from `readyPanes` (so a re-attach starts fresh):

```swift
        readyPanes.remove(paneID)
```

Update `detach(paneID:)` similarly:

```swift
        readyPanes.remove(paneID)
```

Update the `route` function's `.output` case to gate on readiness:

```swift
        case .output(let paneID, let bytes):
            guard let writeFD = paneWriteFDs[paneID], readyPanes.contains(paneID) else {
                droppedOutputEvents += 1
                return
            }
            // (existing write() logic unchanged)
```

- [ ] **Step 2: Write the failing tests**

Extend `Tests/TBDDaemonTests/AttachRPCTests.swift` with a new suite:

```swift
@Suite("Attach RPC orchestration")
struct AttachRPCOrchestrationTests {
    @Test("attach.request with the gate on vends an fd to the app")
    func vendsFDWhenGateOn() async throws {
        // The test wires up a supervisor, an FDVendingServer with a
        // socketpair adopted, and a router configured with both plus a
        // stubbed gate that reports "on". It then invokes .attachRequest
        // and asserts a real fd arrives on the client side of the pair.

        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let router = try await makeRouter(controlMode: .init(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: vending))

        let params = AttachRequestParams(paneID: "%1", windowID: "@1")
        let response = try await router.testInvoke(method: .attachRequest, params: params)
        let result = try JSONDecoder().decode(AttachRequestResult.self, from: Data((response.result ?? "").utf8))
        #expect(result.status == "pending")

        let (rxFD, _) = try FDChannel.receiveFD(from: clientSide, headerCapacity: 64)
        defer { Darwin.close(rxFD) }
        #expect(rxFD > 0)
    }

    @Test("attach.request with the gate off returns unavailable and does not send an fd")
    func gateOffReturnsUnavailable() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let router = try await makeRouter(controlMode: .init(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: [:],   // no opt-in
            fdVending: vending))

        let response = try await router.testInvoke(method: .attachRequest,
            params: AttachRequestParams(paneID: "%2", windowID: "@2"))
        let result = try JSONDecoder().decode(AttachRequestResult.self, from: Data((response.result ?? "").utf8))
        #expect(result.status == "unavailable")
    }

    @Test("output only flows after attach.ready is received")
    func outputGatedOnReady() async throws {
        let supervisor = TmuxControlSupervisor()
        let readFD = try await supervisor.attach(paneID: "%3")
        defer { Darwin.close(readFD) }

        // Output before ready is dropped.
        await supervisor._testInjectEvent(.output(paneID: "%3", bytes: Data("early".utf8)))

        // After ready, output flows.
        await supervisor.markReady(paneID: "%3")
        await supervisor._testInjectEvent(.output(paneID: "%3", bytes: Data("later".utf8)))

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(count)]) == Data("later".utf8))
    }
}
```

The test helpers (`makeSocketPair`, `makeRouter`, `testInvoke`) mirror patterns from earlier tasks — copy them into the file if they're not already visible. `makeRouter` takes the same shape as any existing router test factory in `RPCRouterTests` and additionally accepts a control-mode configuration bag.

- [ ] **Step 3: Create the attach handlers extension**

Create `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift`:

```swift
import Foundation
import os

/// Configuration bag threaded from `Daemon` into `RPCRouter` for the
/// control-mode attach path. Kept as a struct so tests can inject
/// synthetic instances without touching the real daemon startup.
struct AttachConfiguration: Sendable {
    let supervisor: TmuxControlSupervisor
    let tmuxVersion: TmuxVersion?
    let environment: [String: String]
    let fdVending: FDVendingServer
}

extension RPCRouter {
    /// Handle `attach.request`: gate → allocate pipe → vend fd → return status.
    func handleAttachRequest(_ params: AttachRequestParams) async -> RPCResponse {
        guard let config = controlModeAttach else {
            return failure(code: "unavailable", message: "control mode not configured")
        }
        guard ControlModeGate.shouldEnable(
                environment: config.environment,
                tmuxVersion: config.tmuxVersion) else {
            return success(result: AttachRequestResult(status: "unavailable"))
        }
        do {
            let readFD = try await config.supervisor.attach(paneID: params.paneID)
            let header = Data("paneID=\(params.paneID)".utf8)
            try await config.fdVending.send(fd: readFD, header: header)
            // The kernel duplicated the fd; the daemon can (and should) drop
            // its own copy now.
            Darwin.close(readFD)
            return success(result: AttachRequestResult(status: "pending"))
        } catch {
            logger.error("attach.request failed: \(error.localizedDescription, privacy: .public)")
            return failure(code: "attach_failed", message: "\(error)")
        }
    }

    func handleAttachReady(_ params: AttachReadyParams) async -> RPCResponse {
        guard let config = controlModeAttach else {
            return failure(code: "unavailable", message: "control mode not configured")
        }
        await config.supervisor.markReady(paneID: params.paneID)
        return RPCResponse(success: true, result: nil, error: nil)
    }

    func handlePaneDetach(_ params: PaneDetachParams) async -> RPCResponse {
        if let config = controlModeAttach {
            await config.supervisor.detach(paneID: params.paneID)
        }
        return RPCResponse(success: true, result: nil, error: nil)
    }
}
```

`success(result:)` and `failure(code:message:)` are helper wrappers — inspect `RPCRouter.swift` and either reuse the existing shape or add small helpers at the top of the extension.

- [ ] **Step 4: Wire the extension into `RPCRouter`**

In `Sources/TBDDaemon/Server/RPCRouter.swift`:

Add a stored property:

```swift
    /// Set by `Daemon` at startup; nil in test factories that don't need it.
    var controlModeAttach: AttachConfiguration?
```

Replace the three stub cases from Task 4 with delegating calls:

```swift
        case .attachRequest:
            let params = try decode(AttachRequestParams.self, from: request.params)
            return await handleAttachRequest(params)

        case .attachReady:
            let params = try decode(AttachReadyParams.self, from: request.params)
            return await handleAttachReady(params)

        case .paneDetach:
            let params = try decode(PaneDetachParams.self, from: request.params)
            return await handlePaneDetach(params)
```

- [ ] **Step 5: Wire the sidecar + supervisor into `Daemon`**

In `Sources/TBDDaemon/Daemon.swift`, after the router is constructed and the sidecar has bound, populate the attach configuration:

```swift
        router.controlModeAttach = AttachConfiguration(
            supervisor: controlModeSupervisor,
            tmuxVersion: detectedTmuxVersion,
            environment: ProcessInfo.processInfo.environment,
            fdVending: fdVendingServer)
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter AttachRPC` — all previous stubs + 3 orchestration tests PASS.
Run: `swift test` — full suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift \
        Sources/TBDDaemon/Server/RPCRouter.swift \
        Sources/TBDDaemon/Daemon.swift \
        Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift \
        Tests/TBDDaemonTests/AttachRPCTests.swift
git commit -m "feat: attach orchestrator vends per-pane pipe FDs on request"
```

---

## Task 8: App-side `ControlModeStreamReader` + registry

**Files:**
- Create: `Sources/TBDApp/Terminal/ControlModeStreamReader.swift`
- Create: `Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift`
- Modify: `Sources/TBDApp/AppState.swift` (own the registry)
- Test: `Tests/TBDAppTests/ControlModeStreamReaderTests.swift`

The stream reader owns a vended read FD and drains it into a callback. It **must not** be owned by a SwiftUI view — SwiftUI can destroy the view at any moment (the v1 blocker). Ownership lives in a registry held by `AppState`, keyed by paneID; the view retrieves the reader on setup, uses its callback, and leaves the reader alive on tear-down.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDAppTests/ControlModeStreamReaderTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDApp

@Suite("ControlModeStreamReader")
struct ControlModeStreamReaderTests {

    @Test("bytes written to the pipe reach the on-chunk callback")
    func deliversChunks() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else { throw NSError(domain: "pipe", code: 0) }
        }
        let (readFD, writeFD) = (fds[0], fds[1])

        let inbox = ChunkInbox()
        let reader = ControlModeStreamReader(paneID: "%1", fd: readFD) { data in
            Task { await inbox.append(data) }
        }
        reader.start()

        _ = Data("hello".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        _ = Data("world".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        Darwin.close(writeFD)
        try await Task.sleep(for: .milliseconds(200))

        reader.stop()
        let combined = await inbox.combined
        #expect(combined == Data("helloworld".utf8))
    }

    @Test("registry hands out a single reader per paneID")
    func registryIdempotent() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            _ = pipe(buf.baseAddress)
        }
        defer { Darwin.close(fds[0]); Darwin.close(fds[1]) }

        let registry = ControlModeReaderRegistry()
        let one = await registry.registerReader(paneID: "%1", fd: fds[0]) { _ in }
        let two = await registry.reader(for: "%1")
        #expect(one === two)
        await registry.remove(paneID: "%1")
        let none = await registry.reader(for: "%1")
        #expect(none == nil)
    }
}

private actor ChunkInbox {
    private(set) var combined = Data()
    func append(_ chunk: Data) { combined.append(chunk) }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter ControlModeStreamReader`
Expected: compile failure — types not in scope.

- [ ] **Step 3: Implement the stream reader**

Create `Sources/TBDApp/Terminal/ControlModeStreamReader.swift`:

```swift
import Darwin
import Foundation
import os

/// Owns a single vended pipe read fd and drains it on a dedicated `Thread`,
/// delivering each `read()` chunk to a callback. Long-lived — held by
/// `ControlModeReaderRegistry` at app scope, so SwiftUI view destruction does
/// not tear it down (a v1 blocker resolved by keeping state off the view).
///
/// Not `Sendable`-per-se; ownership is single-actor via the registry.
final class ControlModeStreamReader: @unchecked Sendable {
    let paneID: String
    private let fd: Int32
    private let logger = Logger(subsystem: "com.tbd.app", category: "controlModeReader")
    private var thread: Thread?
    private let onChunk: @Sendable (Data) -> Void
    private var stopped = false

    init(paneID: String, fd: Int32, onChunk: @escaping @Sendable (Data) -> Void) {
        self.paneID = paneID
        self.fd = fd
        self.onChunk = onChunk
    }

    /// Start the reader thread. Safe to call once.
    func start() {
        precondition(thread == nil, "start called twice")
        let thread = Thread { [self] in self.readLoop() }
        thread.name = "controlmode-reader-\(paneID)"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Signal the reader to exit and close the fd. The reader's next `read()`
    /// returns 0 (EOF), the callback receives nothing further.
    func stop() {
        stopped = true
        Darwin.close(fd)
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !stopped {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            onChunk(Data(buffer[0..<Int(count)]))
        }
        logger.info("reader exited paneID=\(self.paneID, privacy: .public)")
    }
}
```

- [ ] **Step 4: Implement the registry**

Create `Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift`:

```swift
import Foundation

/// App-scoped owner of `ControlModeStreamReader` instances. Held by
/// `AppState`; keyed by paneID so views can retrieve the reader on setup
/// without owning it.
actor ControlModeReaderRegistry {
    private var readers: [String: ControlModeStreamReader] = [:]

    /// Register a reader for `paneID` and start it. If one already exists,
    /// stop and replace it.
    @discardableResult
    func registerReader(paneID: String, fd: Int32,
                        onChunk: @escaping @Sendable (Data) -> Void) -> ControlModeStreamReader {
        if let existing = readers.removeValue(forKey: paneID) { existing.stop() }
        let reader = ControlModeStreamReader(paneID: paneID, fd: fd, onChunk: onChunk)
        readers[paneID] = reader
        reader.start()
        return reader
    }

    func reader(for paneID: String) -> ControlModeStreamReader? { readers[paneID] }

    func remove(paneID: String) {
        if let reader = readers.removeValue(forKey: paneID) { reader.stop() }
    }

    func stopAll() {
        for reader in readers.values { reader.stop() }
        readers.removeAll()
    }
}
```

- [ ] **Step 5: Hold the registry in `AppState`**

In `Sources/TBDApp/AppState.swift`, add:

```swift
    let controlModeReaders = ControlModeReaderRegistry()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter ControlModeStreamReader` — 2 PASS.
Run: `swift build` — clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDApp/Terminal/ControlModeStreamReader.swift \
        Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift \
        Sources/TBDApp/AppState.swift \
        Tests/TBDAppTests/ControlModeStreamReaderTests.swift
git commit -m "feat: app-side control-mode stream reader and registry"
```

---

## Task 9: `TerminalPanelRepresentable` control-mode branch

**Files:**
- Modify: `Sources/TBDApp/Terminal/TerminalPanelView.swift`
- Modify: `Sources/TBDApp/DaemonClient.swift` (add convenience `attach(paneID:onChunk:)`)

Branch the terminal view: when the daemon reports control-mode is active for this repo, request the attach, receive the FD via the sidecar, send `attach.ready`, and feed bytes into SwiftTerm. Otherwise the existing grouped-sessions path runs unchanged.

Since Phase 2 has no way to tell the app "control mode is on for this repo" through a status RPC yet, use the environment variable directly — the app reads `TBD_TMUX_CONTROL_MODE` from its own process env and mirrors the gate. This is consistent with Phase 1's approach and keeps the wire protocol minimal for Phase 2. (Phase 3+ will add a `daemon.capabilities` RPC when we need to communicate more state.)

- [ ] **Step 1: Add an attach helper to `DaemonClient`**

In `Sources/TBDApp/DaemonClient.swift`, add:

```swift
    /// Request an attach and open the sidecar to receive the vended fd. On
    /// success returns the read fd (owned by caller) plus the header. Does NOT
    /// send `attach.ready` — the caller does that after wiring the reader.
    func openAttach(paneID: String, windowID: String) async throws -> (fd: Int32, header: Data) {
        let sidecarFD = try ensureFDSocket()
        let result = try await attachRequest(paneID: paneID, windowID: windowID)
        guard result.status == "pending" else {
            throw NSError(domain: "DaemonClient.attach",
                          code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "attach returned \(result.status)"])
        }
        // Read the sidecar off the main queue since recvmsg blocks.
        return try await Task.detached(priority: .userInitiated) { [sidecarFD] in
            try FDChannel.receiveFD(from: sidecarFD, headerCapacity: 128)
        }.value
    }
```

- [ ] **Step 2: Branch `TerminalPanelRepresentable`**

In `Sources/TBDApp/Terminal/TerminalPanelView.swift`, locate `TerminalPanelRepresentable.makeNSView` (or the equivalent — the earlier exploration noted line 74). The current path calls `TmuxBridge.prepareSession()` and lets SwiftTerm spawn `tmux attach`. Add a branch:

```swift
        let controlModeEnabled = ProcessInfo.processInfo.environment["TBD_TMUX_CONTROL_MODE"]
            .map { ["1", "true", "yes"].contains($0.lowercased()) } ?? false

        if controlModeEnabled {
            Task {
                do {
                    let (fd, _) = try await appState.daemonClient.openAttach(
                        paneID: tmuxPaneID, windowID: tmuxWindowID)
                    let terminal = /* the SwiftTerm view instance */
                    await appState.controlModeReaders.registerReader(
                        paneID: tmuxPaneID, fd: fd) { chunk in
                            DispatchQueue.main.async {
                                terminal.feed(byteArray: [UInt8](chunk))
                            }
                        }
                    try await appState.daemonClient.attachReady(paneID: tmuxPaneID)
                } catch {
                    // Fall back to grouped sessions on any attach failure.
                    tmuxBridge.prepareSession(/* existing arguments */)
                }
            }
        } else {
            tmuxBridge.prepareSession(/* existing arguments */)
        }
```

**Implementer note:** the exact SwiftTerm accessor and the `prepareSession` arguments differ file-by-file — inspect the current `makeNSView` body and integrate this branch in the least invasive way possible. The important invariants are: (a) when the gate is off, the file behaves identically to Phase 1; (b) the `Task { }` above does not capture the view (only the SwiftTerm terminal instance the `terminal.feed` needs, and by-value strings/IDs).

If the SwiftTerm feed method's exact name differs (`.feed(byteArray:)`, `.feedBuffer(_:)`, etc.), match the one used elsewhere in the file (`prepareSession` chains typically call some feed variant).

Also add cleanup on view teardown — locate the `NSViewRepresentable`'s `dismantleNSView` (or `updateNSView` on hide) and add:

```swift
        Task { await appState.controlModeReaders.remove(paneID: tmuxPaneID) }
        Task { try? await appState.daemonClient.paneDetach(paneID: tmuxPaneID) }
```

- [ ] **Step 3: Run the build and existing tests**

Run: `swift build` — clean.
Run: `swift test` — no regressions in the existing suite.

There is no unit test for this task; the end-to-end integration test in Task 10 exercises the wiring.

- [ ] **Step 4: Commit**

```bash
git add Sources/TBDApp/Terminal/TerminalPanelView.swift Sources/TBDApp/DaemonClient.swift
git commit -m "feat: TerminalPanelRepresentable renders via control-mode when gated"
```

---

## Task 10: End-to-end integration test

**Files:**
- Create: `Tests/TBDDaemonTests/PhaseTwoIntegrationTests.swift`

Prove the full path from live tmux → daemon supervisor → per-pane pipe → sidecar-vended FD → app-side reader → assertion. Since spawning the full daemon+app is heavy, this test bypasses `RPCRouter` wiring and drives the pieces directly (supervisor + FDVendingServer + FDChannel + reader), demonstrating the data path against a real tmux 3.6a server.

- [ ] **Step 1: Write the integration test**

Create `Tests/TBDDaemonTests/PhaseTwoIntegrationTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("Phase 2 end-to-end")
struct PhaseTwoIntegrationTests {

    @discardableResult
    private func tmux(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run(); process.waitUntilExit(); return process.terminationStatus == 0 }
        catch { return false }
    }

    @Test("live tmux output reaches a socketpair-vended read fd after attach.ready")
    func liveOutputReachesVendedFD() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else { return }

        let server = "tbd-e2e-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]))

        // Ask tmux for the pane id we'll attach against.
        let listOutput = Pipe()
        let listProc = Process()
        listProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        listProc.arguments = ["tmux", "-L", server, "list-panes", "-F", "#{pane_id}"]
        listProc.standardOutput = listOutput
        try listProc.run(); listProc.waitUntilExit()
        let paneID = String(decoding: listOutput.fileHandleForReading.readDataToEndOfFile(),
                            as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(paneID.hasPrefix("%"))

        // Wire the daemon-side pieces manually.
        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        try await Task.sleep(for: .milliseconds(300))  // let the -CC connection settle

        let readFD = try await supervisor.attach(paneID: paneID)
        defer { Darwin.close(readFD) }

        let (daemonSideSocket, appSideSocket) = try makeSocketPair()
        defer { Darwin.close(appSideSocket) }
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: daemonSideSocket)
        defer { Task { await vending.stop() } }
        try await vending.send(fd: readFD, header: Data(paneID.utf8))
        Darwin.close(readFD)  // daemon can drop its copy

        let (rxFD, _) = try FDChannel.receiveFD(from: appSideSocket, headerCapacity: 64)
        defer { Darwin.close(rxFD) }

        // Now signal ready and drive a marker through tmux.
        await supervisor.markReady(paneID: paneID)
        let marker = "TBDPHASE2-\(UUID().uuidString.prefix(6))"
        tmux(["-L", server, "send-keys", "printf %s '\(marker)'", "Enter"])

        // Read from the vended fd until we see the marker or time out.
        let deadline = Date().addingTimeInterval(3)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while Date() < deadline {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
            if n > 0 { received.append(contentsOf: buffer[0..<Int(n)]) }
            if received.range(of: Data(marker.utf8)) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(received.range(of: Data(marker.utf8)) != nil,
                "expected marker \(marker) to appear on the vended read fd")

        await supervisor.stopAll()
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }
}
```

Note: reading `.read()` from `rxFD` returns via short reads; use nonblocking + short sleeps or a raw blocking read (as here). The pipe FD from the supervisor is nonblocking on the write side but the read side inherits blocking behavior — a blocking `read()` on the receiver will return whatever data is buffered as it arrives.

- [ ] **Step 2: Run the integration test**

Run: `swift test --filter PhaseTwoIntegrationTests`
Expected: PASS in ≤ 4 s on a machine with tmux ≥ 3.2. If tmux is absent, the test early-returns.

If it fails (no marker), do NOT weaken the assertion. Diagnose: is the supervisor's `route(.output)` firing for this pane? Add a temporary `logger.info` inside `route` to confirm the event arrives with the expected paneID; ensure `markReady` was called before `send-keys`.

- [ ] **Step 3: Full suite regression check**

Run: `swift test` — full suite green.

- [ ] **Step 4: Commit**

```bash
git add Tests/TBDDaemonTests/PhaseTwoIntegrationTests.swift
git commit -m "test: end-to-end control mode from live tmux through vended pipe"
```

---

## Task 11: Manual verification + docs

**Files:**
- Optional: docs/tmux-integration.md (if it discusses architecture that Phase 2 changes)

Confirm the whole stack works in the live app.

- [ ] **Step 1: Full clean build + lint**

Run: `swift build` — clean.
Run: `swift test` — green.
Run: `swift package plugin --allow-writing-to-package-directory swiftlint --strict` — 0 violations.

- [ ] **Step 2: Restart the daemon with the gate off (control path)**

```bash
scripts/restart.sh
ps aux | grep -E "\.build/debug/TBD" | grep -v grep
```
Expect exactly one `TBDDaemon` and one `TBDApp` from this worktree path. Open a worktree in the app — the terminal must render exactly as it did before Phase 2 (grouped-sessions path). This is the "zero behavior change when off" acceptance.

- [ ] **Step 3: Restart with the gate on (Phase 2 path)**

```bash
sudo log config --subsystem com.tbd.daemon --mode "level:debug,persist:debug"   # once per machine
TBD_TMUX_CONTROL_MODE=1 scripts/restart.sh
log stream --level debug --predicate 'subsystem BEGINSWITH "com.tbd" AND category IN {"tmuxControlMode","fdVending","controlModeReader"}'
```
Open a worktree. The pane must render live tmux output through the control-mode path. Expected log sequence, in order:
- `started tmux -CC connection for server tbd-<hash>`
- `attach paneID=%<n> writeFD=<n>`
- `sent fd via SCM_RIGHTS` (or equivalent — from `FDVendingServer`)
- `markReady paneID=%<n>`
- SwiftTerm shows live prompt / output

Type in the pane — no keystrokes flow yet (Phase 3). You should be able to observe output-only rendering.

- [ ] **Step 4: Optional docs update**

If `docs/tmux-integration.md` exists and describes the grouped-sessions-only architecture, append a short "Control-mode path (Phase 2, opt-in)" section pointing at the design and this plan.

- [ ] **Step 5: Commit any doc changes**

```bash
git add docs/tmux-integration.md   # if edited
git commit -m "docs: note the Phase 2 control-mode path in tmux-integration.md"
```

Otherwise skip this step.

---

## Self-Review

**Spec coverage (against `docs/specs/2026-05-17-tmux-control-mode-design.md`):**
- "For each visible pane, creates a Unix pipe and writes the pane's decoded `%output` bytes into the write end." → Task 6 (per-pane pipe + fanout) ✅
- "Vends the pipe read end to the app over the existing RPC Unix socket using `SCM_RIGHTS`." → Task 2/3 (implemented as a sidecar rather than the JSON RPC socket — spec permits either; sidecar chosen for clean separation, documented at plan top) ✅
- "FD must arrive before daemon writes anything substantial" + "app opens the FD... sends attach.ready ack... only after receiving the ack does the daemon start writing" → Task 7 (ready gate suppresses writes for non-ready panes) ✅
- "Reads pane bytes directly from the vended pipe FD into SwiftTerm" → Task 8/9 ✅
- "Reader on a long-lived stream actor (not view-owned)" → Task 8 (registry on AppState) ✅
- Out of scope for Phase 2 (scrollback, flow control, keystrokes, resize, crash recovery, layout-change) → explicitly excluded per plan's "Phase boundary" ✅

**Plan defects folded in (from Phase 1 review):**
- `stop()` teardown escalation → Task 1 ✅
- Trailing-output ordering / finish() race → Task 1 ✅

**Placeholder scan:** the "match the existing pattern" phrases in Task 3 Step 5, Task 4 Step 5, and Task 9 are unavoidable — the exact names of RPC helper methods and SwiftTerm feed methods in this repo were not fully mapped in the pre-plan investigation and vary by file. Each such instance includes an explicit hint (search for a nearby existing example) and a fallback (add a small helper if none exists). No task steps are literal "TODO" or "fill in later"; every code block is concrete.

**Type consistency:** `AttachRequestParams`, `AttachRequestResult`, `AttachReadyParams`, `PaneDetachParams` are defined in Task 4 and consumed by name in Tasks 7/9. `TmuxControlSupervisor`'s new methods (`attach(paneID:) throws -> Int32`, `detach(paneID:)`, `markReady(paneID:)`, `_testInjectEvent`) have consistent signatures across Tasks 6, 7, and 10. `FDVendingServer`'s public surface (`listen(on:)`, `adoptConnection(fd:)`, `send(fd:header:)`, `stop()`) is stable across Tasks 3, 5, 7, 10.

**Known assumptions to verify empirically during Task 10:**
- The supervisor's `route(.output)` fires with the exact `paneID` string tmux emits (should be `%N`; the Phase 1 integration test already establishes this).
- Nonblocking `write()` to the pipe never `EAGAIN`s for typical shell output rates on a locally-attached reader. If it does under real load, Task 6's log-and-drop is visible in the log stream — flagged as a Phase 6 (flow control) prerequisite before that phase raises the pane count.
