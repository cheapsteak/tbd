# tmux Control Mode — Phase 2 (FD Vending + Single-Pane Render) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make one visible pane render end-to-end through the control-mode path — daemon owns the `tmux -CC` connection, creates a pipe per attached pane, vends the pipe read FD to the app over a sidecar Unix socket via `SCM_RIGHTS`, and the app drains that FD directly into SwiftTerm.

**Architecture:** Two milestones. **Milestone A** is infrastructure: harden Phase 1's connection teardown, add a raw-POSIX `FDChannel` (in **`TBDShared`** — both processes link it; `TBDApp` does not depend on `TBDDaemonLib`) that sends a file descriptor plus a small JSON `FDVendHeader` over a Unix `socketpair`, wire it as a **sidecar socket** in the daemon (separate from the existing SwiftNIO JSON-RPC socket — a documented deviation from the spec, see Self-Review), add the attach-lifecycle RPC methods as stubs plus a real `daemon.capabilities` RPC (how the app learns the gate state — the app is launched via `open`, which does not inherit shell env), and prove FD passing end-to-end with an in-process socket-pair test. **Milestone B** is the feature: add a lock-guarded `PaneFanout` that routes decoded `%output` bytes into per-pane pipe write ends **synchronously on the connection's reader thread** (per the spec's data-flow — render bytes never hop through an actor or queue in an unbounded `AsyncStream`), keyed by composite `(server, paneID)` (bare pane IDs collide across per-repo tmux servers); implement the attach orchestrator (resolve worktree → server, create pipe → vend FD → wait for `attach.ready` with a 5 s cancel timeout → gate writes); build the app-side `ControlModeStreamReader` that survives SwiftUI view destruction, with a header-demuxed sidecar receive loop so concurrent attaches can't cross-deliver FDs; branch `TerminalPanelRepresentable` on the daemon-reported capability; cover it with a live-tmux integration test. Grouped-sessions is untouched when the gate is off.

**Tech Stack:** Swift 6 strict concurrency (`swift-tools-version: 6.0`), Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), Foundation, `os.Logger`, raw Darwin POSIX (`sendmsg`, `recvmsg`, `socketpair`, `pipe`), SwiftNIO (existing RPC socket — unchanged), SwiftTerm (existing render endpoint). Build: `swift build`. Test: `swift test`. Lint: `swiftlint --strict` (Homebrew binary; the SwiftPM plugin form is retired).

**Reference spec:** `docs/specs/2026-05-17-tmux-control-mode-design.md`
**Reference plan (Phase 1):** `docs/plans/2026-05-21-tmux-control-mode-phase-1-foundation.md`

> **Revision 2 (2026-07-01).** Reworked after review: `FDChannel` moved to `TBDShared` (B1 — the app target cannot import `TBDDaemonLib`); app-side gate now reads a `daemon.capabilities` RPC instead of mirroring an env var LaunchServices never delivers (B2); the sidecar client demuxes vended FDs by `FDVendHeader` so concurrent attaches can't cross wires (B3); all pane maps key by `(server, paneID)` and attach RPCs carry `worktreeID` for server resolution (B4); output fanout runs on the reader thread via `PaneFanout`, not through the supervisor actor (A1). Also folded: partial-pipe-write handling, the spec's 5 s ready-ack cancel timeout, reader-owns-fd teardown on the app side, `AttachConfiguration` dropped in favor of extending `TmuxControlModeBridge`, sidecar accept on a dedicated thread + eager app-side connect, and RPC code samples corrected to the repo's actual idioms (`RPCMethod` static-string namespace, `RPCResponse(result:)`/`(error:)`/`.ok()`, `callAsync`/`callVoidAsync`).

**Phase boundary — explicitly NOT in Phase 2:**
- **No scrollback / α-replay** (Phase 5). On attach, whatever tmux emits going forward is what the app sees; early bytes before `attach.ready` are dropped, not buffered.
- **No keystrokes** (Phase 3). The pane is read-only from the user's perspective in Phase 2. Grouped-sessions remains the default; the user can still keystroke through that path when the gate is off.
- **No size arbitration** (Phase 4). Panes render at whatever size tmux allocated at server-create time.
- **No flow control** (Phase 6). Writes to the per-pane pipe are nonblocking; if a write returns `EAGAIN` — including mid-chunk, after a partial write — the *remaining* bytes are dropped and counted distinctly (a partial write silently treated as success would corrupt the escape-sequence stream, which is worse than a visible whole-chunk drop).
- **No crash recovery flows** (Phase 7).
- **No multi-pane, no `%layout-change` handling.**
- **No SQLite schema changes.**

---

## File Map

**Create (TBDShared — both processes link these):**
- `Sources/TBDShared/FDChannel.swift` — Task 2 (POSIX `sendmsg`/`recvmsg` for FDs + `FDVendHeader`; `public` — `TBDApp` does NOT depend on `TBDDaemonLib`, so anything both sides need lives here)

**Modify (TBDShared):**
- `Sources/TBDShared/RPCProtocol.swift` — Task 4 (`RPCMethod` constants + params/result structs, incl. `daemon.capabilities`)
- The `TBDConstants` file (locate the existing `socketPath` definition under `Sources/TBDShared/`) — Task 3 (`vendSocketPath`)

**Modify (TBDDaemon):**
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift` — Task 1 (teardown escalation + finish-ordering fix) + Task 6 (`outputSink` fast path)
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift` — Task 6 (own the `PaneFanout`, wire the sink, thin attach/detach/ready wrappers)
- `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlModeBridge.swift` — Task 3 (gains `environment`, `fdVending`, `readyTimeout`)
- `Sources/TBDDaemon/Server/RPCRouter.swift` — Task 4 (register new methods + capabilities handler) + Task 7 (delegate to attach handlers)
- `Sources/TBDDaemon/Daemon.swift` — Task 3 (own + start the sidecar, extend the bridge construction)

**Create (TBDDaemon):**
- `Sources/TBDDaemon/Server/FDVendingServer.swift` — Task 3 (sidecar socket server, per-daemon singleton; accept on a dedicated `Thread`)
- `Sources/TBDDaemon/Tmux/ControlMode/PaneFanout.swift` — Task 6 (`PaneKey` + lock-guarded reader-thread fanout)
- `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift` — Task 7 (`attach.request` / `attach.ready` / `pane.detach` handlers)

**Modify (TBDApp):**
- `Sources/TBDApp/DaemonClient.swift` — Task 3 (own the `FDSidecarClient`, connect it eagerly) + Task 4 (RPC method call helpers) + Task 9 (`openAttach` convenience)
- `Sources/TBDApp/Terminal/TerminalPanelView.swift` — Task 9 (control-mode branch)
- `Sources/TBDApp/AppState.swift` — Task 4 (store `daemonCapabilities`) + Task 8 (own the `ControlModeReaderRegistry`)

**Create (TBDApp):**
- `Sources/TBDApp/Terminal/FDSidecarClient.swift` — Task 3 (sidecar connect + header-demuxed FD receive loop)
- `Sources/TBDApp/Terminal/ControlModeStreamReader.swift` — Task 8 (long-lived per-pane FD drainer)
- `Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift` — Task 8 (view-independent owner of readers)

**Tests:**
- `Tests/TBDDaemonTests/TmuxControlConnectionTeardownTests.swift` — Task 1
- `Tests/TBDDaemonTests/FDChannelTests.swift` — Task 2 (`import TBDShared` — the API is public, no `@testable` needed)
- `Tests/TBDDaemonTests/FDVendingServerTests.swift` — Task 3 (in-process socket-pair)
- `Tests/TBDAppTests/FDSidecarClientTests.swift` — Task 3 (header demux + timeout)
- `Tests/TBDDaemonTests/AttachRPCTests.swift` — Task 4 (stub handler round-trip) + Task 7 (real orchestration + ready-timeout)
- `Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift` — Task 6 (fanout attach/ready/detach + cross-server isolation + partial-write drop)
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
            if readerExited.wait(timeout: .now() + .milliseconds(500)) == .timedOut {
                if process.isRunning {
                    let pid = process.processIdentifier
                    if pid > 0 {
                        logger.info("escalating tmux -CC for \(self.serverName, privacy: .public) to SIGKILL after 500ms")
                        kill(pid, SIGKILL)
                    }
                }
                // Wait again even when the child exited during the first
                // window: exit delivers EOF, but the reader may not have left
                // `read()` yet, and closing the fd under a still-blocked
                // reader is exactly the leak this dance avoids.
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
- Create: `Sources/TBDShared/FDChannel.swift`
- Test: `Tests/TBDDaemonTests/FDChannelTests.swift`

`FDChannel` is a stateless namespace with two static functions: send one file descriptor plus a small header over a Unix stream socket, and receive the same on the other side. Uses `sendmsg`/`recvmsg` with `SCM_RIGHTS` — the standard Darwin/POSIX pattern. Tests use `socketpair(AF_UNIX, SOCK_STREAM, ...)` and a `pipe()` to prove an FD survives the crossing.

**Why `TBDShared`, and why `public`:** the daemon sends (`FDVendingServer`) and the app receives (`FDSidecarClient` in `DaemonClient`'s orbit) — and `TBDApp` does **not** depend on `TBDDaemonLib` (check `Package.swift`), so a daemon-target `FDChannel` would not compile on the app side. Everything in this file is `public`. The same file defines `FDVendHeader`, the structured header every vended FD travels with — it's what lets the app-side receive loop demux concurrent attaches (Task 3/9).

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDDaemonTests/FDChannelTests.swift`:

```swift
import Darwin
import Foundation
import Testing
import TBDShared

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

Create `Sources/TBDShared/FDChannel.swift`:

```swift
import Darwin
import Foundation

/// Errors raised by `FDChannel.sendFD` / `receiveFD`.
public enum FDChannelError: Error, Equatable {
    case sendFailed(Int32)          // errno from sendmsg or setup
    case receiveFailed(Int32)       // errno from recvmsg
    case peerClosed                 // clean EOF from the peer
    case noAncillaryData            // recvmsg succeeded but no SCM_RIGHTS attached
    case unexpectedControlLevel     // cmsg header wasn't SOL_SOCKET / SCM_RIGHTS
}

/// Structured header accompanying every vended pane fd (JSON-encoded into the
/// `sendmsg` payload). The composite (worktreeID, paneID) identity is what the
/// app-side receive loop uses to route a received fd to the right waiter —
/// bare pane IDs are only unique within one tmux server, and concurrent
/// attaches for different panes interleave on the single sidecar socket.
public struct FDVendHeader: Codable, Sendable, Equatable {
    public let worktreeID: UUID
    public let paneID: String
    public init(worktreeID: UUID, paneID: String) {
        self.worktreeID = worktreeID
        self.paneID = paneID
    }
    /// Stable key used by both sides' demux maps.
    public var routingKey: String { "\(worktreeID.uuidString)/\(paneID)" }
}

/// Stateless helpers for handing a single file descriptor plus a small header
/// across a Unix stream socket, using `sendmsg`/`recvmsg` + `SCM_RIGHTS`.
///
/// The header travels in the message payload (not the ancillary data). Callers
/// choose their own header encoding — Phase 2 uses JSON `FDVendHeader` —
/// the channel itself does not interpret it.
public enum FDChannel {
    /// Send `fd` plus `header` over `socket`. On return, `fd` is still owned by
    /// the caller (the kernel duplicated it into the peer's fd table); it is
    /// safe — and usually correct — to `close(fd)` immediately after.
    public static func sendFD(_ fd: Int32, over socket: Int32, header: Data) throws {
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
    public static func receiveFD(from socket: Int32, headerCapacity: Int) throws -> (fd: Int32, header: Data) {
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
git add Sources/TBDShared/FDChannel.swift Tests/TBDDaemonTests/FDChannelTests.swift
git commit -m "feat: add FDChannel for sending file descriptors over Unix sockets"
```

---

## Task 3: `FDVendingServer` — sidecar Unix socket + client

**Files:**
- Create: `Sources/TBDDaemon/Server/FDVendingServer.swift`
- Create: `Sources/TBDApp/Terminal/FDSidecarClient.swift`
- Modify: `Sources/TBDDaemon/Daemon.swift` (own + start the sidecar; extend the bridge)
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlModeBridge.swift` (gains `environment`, `fdVending`, `readyTimeout`)
- Modify: `Sources/TBDApp/DaemonClient.swift` (own the `FDSidecarClient`, connect it eagerly)
- Modify: the `TBDConstants` file in `Sources/TBDShared/` (add `vendSocketPath`)
- Test: `Tests/TBDDaemonTests/FDVendingServerTests.swift`, `Tests/TBDAppTests/FDSidecarClientTests.swift`

The sidecar is a second Unix socket, path `~/tbd/vend.sock` (respects `TBD_HOME`). Daemon accepts at most one connection at a time (the app process). This task installs the plumbing — no vending logic yet.

Two ordering rules baked in here:
- **The app connects the sidecar eagerly**, right after the RPC socket connects — not lazily on first attach. `connect()` returns once the connection is *queued*, not accepted; connecting early gives the daemon's accept loop ample time before any `attach.request` needs `send()` to work.
- **`send(fd:header:)` retries briefly** (10 × 50 ms) while no client has been adopted, absorbing any residual connect-vs-accept race as belt-and-suspenders.

`~/tbd` on Darwin is a short path; `sun_path` (~104 chars) is safe. If `TBD_HOME` is set to a deep tmp path (as tests may do), that's fine — Phase 2 tests bypass the on-disk socket entirely with `socketpair()`.

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
import TBDShared
import os

enum FDVendingServerError: Error, Equatable {
    case notConnected
    case bindFailed(Int32)
    case listenFailed(Int32)
}

/// A tiny per-daemon service that holds the sidecar socket the app connects to
/// for receiving file descriptors. Phase 2 has exactly one client (the app), so
/// at most one connection is adopted at a time; a new adoption replaces the
/// old one.
///
/// Phase 2's uses: after the attach orchestrator gets a per-pane pipe read end
/// from the supervisor, it calls `send(fd:header:)` here to hand it to the app.
///
/// The accept loop runs on a dedicated `Thread` — the house pattern for
/// indefinitely-blocking syscalls (see `TmuxControlConnection`'s reader).
/// Parking a cooperative-pool task in blocking `accept()` would permanently
/// eat one of the pool's threads.
actor FDVendingServer {
    private let logger = Logger(subsystem: "com.tbd.daemon", category: "fdVending")
    private var clientFD: Int32 = -1
    /// Path of the listening socket, when one is bound. Nil when the server is
    /// running purely off adopted fds (unit tests).
    private var socketPath: String?
    private var listenerFD: Int32 = -1

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

        // Dedicated accept thread: blocks in accept(); hands each connection
        // back into the actor. Exits when the listener fd is closed (accept
        // returns -1/EBADF after stop()).
        let listener = fd
        let thread = Thread { [weak self] in
            while true {
                var peer = sockaddr()
                var len = socklen_t(MemoryLayout<sockaddr>.size)
                let accepted = accept(listener, &peer, &len)
                guard accepted >= 0 else { return }   // listener closed (stop) or fatal
                Task { [weak self] in await self?.adoptConnection(fd: accepted) }
            }
        }
        thread.name = "fd-vending-accept"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Adopt a pre-connected socket fd. Ownership transfers here — do not
    /// close it in the caller. Replaces any prior connection.
    func adoptConnection(fd: Int32) {
        if clientFD >= 0 { Darwin.close(clientFD) }
        clientFD = fd
        logger.info("FD vending client connected (fd \(fd))")
    }

    /// Close the current client connection (if any) without stopping the
    /// listener.
    func disconnect() {
        if clientFD >= 0 {
            Darwin.close(clientFD)
            clientFD = -1
        }
    }

    /// Stop the listener and drop any active client. Idempotent. Closing the
    /// listener fd makes the accept thread's blocked `accept()` return -1,
    /// which exits the thread.
    func stop() {
        if listenerFD >= 0 { Darwin.close(listenerFD); listenerFD = -1 }
        if let path = socketPath { _ = unlink(path); socketPath = nil }
        disconnect()
    }

    /// Send `fd` plus `header` to the currently connected app client. Retries
    /// briefly while no client is adopted — the app connects eagerly at
    /// startup, so this only papers over a connect-vs-accept race measured in
    /// milliseconds.
    func send(fd: Int32, header: Data) async throws {
        for attempt in 0..<10 {
            if clientFD >= 0 {
                try FDChannel.sendFD(fd, over: clientFD, header: header)
                return
            }
            if attempt < 9 { try? await Task.sleep(for: .milliseconds(50)) }
        }
        throw FDVendingServerError.notConnected
    }
}
```

- [ ] **Step 4: Wire the sidecar into `Daemon` and extend the bridge**

First add `vendSocketPath` to `TBDConstants` (locate the file in `Sources/TBDShared/` that defines `socketPath` and follow its style — derive from the same `TBD_HOME`-honoring base directory):

```swift
    /// Sidecar Unix socket over which the daemon vends file descriptors to
    /// the app (SCM_RIGHTS). Sibling of `socketPath`.
    public static var vendSocketPath: String { /* configDir + "/vend.sock", matching socketPath's derivation */ }
```

Read `Sources/TBDDaemon/Daemon.swift`. It already owns `let controlModeSupervisor = TmuxControlSupervisor()` (~line 67), detects `tmuxVersion` in `start()` (~line 217), and constructs `TmuxControlModeBridge` (~line 218) handed to `lifecycle.controlMode` and `rpcRouter.controlMode`. Changes:

1. Add a stored `let fdVendingServer = FDVendingServer()` alongside `controlModeSupervisor`.
2. In `start()`, after the RPC socket is up:

```swift
        do {
            try await fdVendingServer.listen(on: TBDConstants.vendSocketPath)
        } catch {
            logger.error("failed to start FD vending sidecar: \(error.localizedDescription, privacy: .public)")
        }
```

3. Extend `TmuxControlModeBridge` (this replaces the reviewed-out `AttachConfiguration` — the router keeps using its existing `controlMode` property, ONE config bag):

```swift
struct TmuxControlModeBridge: Sendable {
    let supervisor: TmuxControlSupervisor
    let tmuxVersion: TmuxVersion?
    /// Environment the gate reads. Injectable so tests can flip the gate.
    let environment: [String: String]
    /// Sidecar over which attach handlers vend pane fds.
    let fdVending: FDVendingServer
    /// How long an attach may sit un-acked before the daemon cancels it
    /// (spec, pane lifecycle: "App fails to send attach.ready within timeout
    /// (e.g. 5 s) → daemon cancels attach"). Injectable for tests.
    let readyTimeout: Duration

    init(supervisor: TmuxControlSupervisor,
         tmuxVersion: TmuxVersion?,
         environment: [String: String] = ProcessInfo.processInfo.environment,
         fdVending: FDVendingServer,
         readyTimeout: Duration = .seconds(5)) { ... }

    func enableIfGated(serverName: String) async {
        guard ControlModeGate.shouldEnable(environment: environment, tmuxVersion: tmuxVersion) else { return }
        await supervisor.ensureConnection(serverName: serverName)
    }
}
```

Update `Daemon.start()`'s bridge construction to pass `fdVending: fdVendingServer` (environment and readyTimeout use their defaults). In the daemon's shutdown/teardown hook (where `controlModeSupervisor.stopAll()` already runs, ~line 405), add `await fdVendingServer.stop()`.

- [ ] **Step 5: Add the app-side `FDSidecarClient` and connect it eagerly**

Create `Sources/TBDApp/Terminal/FDSidecarClient.swift`. It owns the sidecar socket and a dedicated receive `Thread` that demuxes every incoming FD by its `FDVendHeader` routing key — this is what makes concurrent attaches safe (two panes attaching at once must not swap FDs).

```swift
import Darwin
import Foundation
import TBDShared
import os

enum FDSidecarError: Error {
    case connectFailed(Int32)
    case notConnected
    case timedOut
    case superseded      // a newer expectation for the same key replaced this one
    case disconnected    // sidecar socket EOF'd with waiters pending
}

/// App-side sidecar client: connects to the daemon's FD-vending socket and
/// runs one receive loop on a dedicated `Thread`. Each received fd carries a
/// JSON `FDVendHeader`; the loop delivers it to the waiter registered under
/// `header.routingKey`. Unmatched fds are closed and logged (stale vend after
/// a timed-out attach).
final class FDSidecarClient: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tbd.app", category: "fdVending")
    private let lock = NSLock()
    private var socketFD: Int32 = -1
    private var waiters: [String: (Int32?, Error?) -> Void] = [:]

    var isConnected: Bool { lock.lock(); defer { lock.unlock() }; return socketFD >= 0 }

    /// Connect to `path` and start the receive thread. Idempotent.
    func connect(path: String) throws {
        lock.lock()
        if socketFD >= 0 { lock.unlock(); return }
        lock.unlock()
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        if fd < 0 { throw FDSidecarError.connectFailed(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
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
        if result < 0 { Darwin.close(fd); throw FDSidecarError.connectFailed(errno) }
        lock.lock(); socketFD = fd; lock.unlock()

        let thread = Thread { [weak self] in self?.receiveLoop(fd) }
        thread.name = "fd-sidecar-receive"
        thread.stackSize = 256 * 1024
        thread.start()
    }

    /// Adopt a pre-connected socket (unit tests use a socketpair end).
    func adopt(fd: Int32) { /* same as connect() minus socket()/connect(); starts the thread */ }

    /// Register interest in the fd for (worktreeID, paneID) and return a
    /// promise. Registration is SYNCHRONOUS — call this BEFORE issuing
    /// `attach.request`, so the vended fd can never race past the waiter.
    /// A second expectation for the same key supersedes (fails) the first.
    func expectFD(worktreeID: UUID, paneID: String) -> FDPromise {
        let key = FDVendHeader(worktreeID: worktreeID, paneID: paneID).routingKey
        let promise = FDPromise()
        lock.lock()
        if let old = waiters[key] { old(nil, FDSidecarError.superseded) }
        waiters[key] = { fd, error in promise.settle(fd: fd, error: error) }
        lock.unlock()
        promise.onCancelOrTimeout = { [weak self] in self?.removeWaiter(key) }
        return promise
    }

    private func removeWaiter(_ key: String) {
        lock.lock(); waiters[key] = nil; lock.unlock()
    }

    private func receiveLoop(_ fd: Int32) {
        while true {
            guard let (rxFD, header) = try? FDChannel.receiveFD(from: fd, headerCapacity: 256) else { break }
            guard let hdr = try? JSONDecoder().decode(FDVendHeader.self, from: header) else {
                logger.error("sidecar: undecodable vend header, closing fd")
                Darwin.close(rxFD)
                continue
            }
            lock.lock()
            let waiter = waiters.removeValue(forKey: hdr.routingKey)
            lock.unlock()
            if let waiter {
                waiter(rxFD, nil)
            } else {
                logger.info("sidecar: no waiter for \(hdr.routingKey, privacy: .public) (stale vend), closing fd")
                Darwin.close(rxFD)
            }
        }
        // EOF: fail everything pending, mark disconnected (reconnect is a
        // Phase 7 crash-recovery concern).
        lock.lock()
        let pending = waiters; waiters = [:]
        socketFD = -1
        lock.unlock()
        for (_, waiter) in pending { waiter(nil, FDSidecarError.disconnected) }
        logger.info("sidecar receive loop exited")
    }
}

/// One-shot settlement cell bridging the receive thread to an async caller.
/// `settle` may be called from any thread; `value(timeout:)` is awaited once.
final class FDPromise: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: Result<Int32, Error>?
    private var continuation: CheckedContinuation<Int32, Error>?
    var onCancelOrTimeout: (() -> Void)?

    func settle(fd: Int32?, error: Error?) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            if let fd { Darwin.close(fd) }   // settled twice: drop the extra fd
            return
        }
        let result: Result<Int32, Error> = fd.map { .success($0) } ?? .failure(error ?? FDSidecarError.disconnected)
        outcome = result
        let cont = continuation; continuation = nil
        lock.unlock()
        cont?.resume(with: result)
    }

    /// Await the fd with a deadline. On timeout the waiter is deregistered and
    /// `FDSidecarError.timedOut` is thrown; a late-arriving fd is then closed
    /// by the receive loop's no-waiter path.
    func value(timeout: Duration) async throws -> Int32 {
        let timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            self?.onCancelOrTimeout?()
            self?.settle(fd: nil, error: FDSidecarError.timedOut)
        }
        defer { timeoutTask.cancel() }
        return try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let outcome {
                lock.unlock()
                cont.resume(with: outcome)
                return
            }
            continuation = cont
            lock.unlock()
        }
    }

    func cancel() {
        onCancelOrTimeout?()
        settle(fd: nil, error: FDSidecarError.timedOut)
    }
}
```

Then in `Sources/TBDApp/DaemonClient.swift` (an `actor`), add the client and connect it eagerly wherever the RPC socket connection is established (locate the connect path used by `AppState.connectAndLoadInitialState`):

```swift
    /// Sidecar for receiving vended pane fds. Connected eagerly right after
    /// the RPC socket, so the daemon's accept has completed long before the
    /// first attach needs it. Failure is non-fatal: control-mode attaches
    /// will fail and fall back to grouped sessions.
    let fdSidecar = FDSidecarClient()
```

```swift
        // After the RPC connection succeeds:
        do { try fdSidecar.connect(path: TBDConstants.vendSocketPath) }
        catch { logger.warning("FD sidecar connect failed (control-mode attach unavailable): \(error)") }
```

Create `Tests/TBDAppTests/FDSidecarClientTests.swift` covering, over an adopted `socketpair()` end: (a) an expected fd is delivered to the right waiter when the header matches; (b) two interleaved expectations for different panes each receive their own fd regardless of vend order (the B3 regression test — send pane B's fd first, then pane A's; assert each promise resolves to the fd whose pipe carries its marker bytes); (c) `value(timeout:)` throws `timedOut` when nothing is vended and a late vend is closed without crashing; (d) socket EOF fails pending waiters with `disconnected`.

- [ ] **Step 6: Run tests + build**

Run: `swift test --filter FDVendingServerTests` — PASS (note `sendBeforeAdoptFails` now takes ~500 ms — the send retry loop).
Run: `swift test --filter FDSidecarClientTests` — PASS.
Run: `swift build` — clean.
Run: `swiftlint --strict` — 0 violations.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Server/FDVendingServer.swift \
        Sources/TBDDaemon/Daemon.swift \
        Sources/TBDDaemon/Tmux/ControlMode/TmuxControlModeBridge.swift \
        Sources/TBDApp/Terminal/FDSidecarClient.swift \
        Sources/TBDApp/DaemonClient.swift \
        Sources/TBDShared/<constants file> \
        Tests/TBDDaemonTests/FDVendingServerTests.swift \
        Tests/TBDAppTests/FDSidecarClientTests.swift
git commit -m "feat: add sidecar FD-vending socket with header-demuxed app client"
```

---

## Task 4: New RPC methods (attach stubs + real `daemon.capabilities`)

**Files:**
- Modify: `Sources/TBDShared/RPCProtocol.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift`
- Modify: `Sources/TBDApp/DaemonClient.swift`
- Modify: `Sources/TBDApp/AppState.swift` (store the fetched capabilities)
- Test: `Tests/TBDDaemonTests/AttachRPCTests.swift` (stub-round-trip only; real orchestration lands in Task 7)

Add the three attach-lifecycle RPC methods with stub handlers that log + acknowledge, plus a fourth method — `daemon.capabilities` — implemented for real immediately (it's one gate read). Capabilities exist because the app **cannot** mirror the `TBD_TMUX_CONTROL_MODE` env var: `scripts/restart.sh` starts the daemon directly (env inherited) but the app via `open` (LaunchServices — shell env NOT inherited). The daemon is the single source of gate truth; the app asks.

House idioms (verified against the repo — do NOT use case-enum/dot syntax):
- `RPCMethod` is a **namespace of `public static let` String constants**, not a case-enum.
- The router's `handle(_:)` switches on `request.method` with `case RPCMethod.terminalSuspend:`-style cases; handlers take `request.paramsData` and decode via the router's `decoder`.
- Responses: `try RPCResponse(result: encodable)`, `RPCResponse(error: "…")`, or `.ok()`. There is no memberwise `(success:result:error:)` init. Clients decode with `response.decodeResult(_:)`.
- Client helpers: `callAsync(method:params:resultType:)`, `callVoidAsync(method:params:)`, `callNoParamsAsync(method:resultType:)` — `method` is a `String` (pass the `RPCMethod.x` constant).

- [ ] **Step 1: Write the failing test**

Create `Tests/TBDDaemonTests/AttachRPCTests.swift`. Mirror how existing router tests construct an `RPCRouter` (grep `RPCRouter(` under `Tests/` — the pattern is in-memory `TBDDatabase`, `TmuxManager(dryRun: true)`, a real `WorktreeLifecycle`) and how they build an `RPCRequest` (method + JSON-encoded params). Copy that factory into this file as `makeRouter()` / `makeRequest(method:params:)` helpers.

```swift
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

@Suite("Attach RPC stubs")
struct AttachRPCStubTests {
    @Test("attach.request returns a placeholder acknowledgment")
    func requestRoundTrip() async throws {
        let router = try await makeRouter()
        let request = try makeRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: UUID(), paneID: "%0", windowID: "@0"))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending")
    }

    @Test("attach.ready accepts the ack")
    func readyRoundTrip() async throws {
        let router = try await makeRouter()
        let request = try makeRequest(
            method: RPCMethod.attachReady,
            params: AttachReadyParams(worktreeID: UUID(), paneID: "%0"))
        let response = await router.handle(request)
        #expect(response.success)
    }

    @Test("pane.detach accepts the detach")
    func detachRoundTrip() async throws {
        let router = try await makeRouter()
        let request = try makeRequest(
            method: RPCMethod.paneDetach,
            params: PaneDetachParams(worktreeID: UUID(), paneID: "%0"))
        let response = await router.handle(request)
        #expect(response.success)
    }

    @Test("daemon.capabilities reports control mode off when no bridge is set")
    func capabilitiesDefaultOff() async throws {
        let router = try await makeRouter()   // no controlMode bridge injected
        let request = try makeRequest(method: RPCMethod.daemonCapabilities)
        let response = await router.handle(request)
        let result = try response.decodeResult(DaemonCapabilitiesResult.self)
        #expect(result.controlModeEnabled == false)
    }
}
```

(Note: the stub handlers accept any `worktreeID` without a DB lookup — resolution arrives with the real orchestration in Task 7, whose tests create real repo/worktree rows.)

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter AttachRPCStubTests`
Expected: compile failure — `AttachRequestParams`, `RPCMethod.attachRequest`, etc. not in scope.

- [ ] **Step 3: Add the RPC method constants + param structs**

In `Sources/TBDShared/RPCProtocol.swift`, add to the `RPCMethod` namespace (alongside the existing `public static let` constants):

```swift
    public static let attachRequest = "attach.request"
    public static let attachReady = "attach.ready"
    public static let paneDetach = "pane.detach"
    public static let daemonCapabilities = "daemon.capabilities"
```

And add the `Codable` structs (alongside the other `*Params` structs). Every attach param carries `worktreeID` — pane IDs are only unique per tmux server, and the daemon resolves worktree → `tmuxServer` to build composite keys (B4):

```swift
public struct AttachRequestParams: Codable, Sendable {
    public let worktreeID: UUID
    public let paneID: String
    public let windowID: String
    public init(worktreeID: UUID, paneID: String, windowID: String) {
        self.worktreeID = worktreeID; self.paneID = paneID; self.windowID = windowID
    }
}

public struct AttachRequestResult: Codable, Sendable {
    /// One of "pending" (fd vended; waiting for attach.ready) or
    /// "unavailable" (control mode off / not configured).
    public let status: String
    public init(status: String) { self.status = status }
}

public struct AttachReadyParams: Codable, Sendable {
    public let worktreeID: UUID
    public let paneID: String
    public init(worktreeID: UUID, paneID: String) {
        self.worktreeID = worktreeID; self.paneID = paneID
    }
}

public struct PaneDetachParams: Codable, Sendable {
    public let worktreeID: UUID
    public let paneID: String
    public init(worktreeID: UUID, paneID: String) {
        self.worktreeID = worktreeID; self.paneID = paneID
    }
}

/// Result of `daemon.capabilities` — feature flags the app cannot derive
/// locally (it is launched via `open`, which drops shell env).
public struct DaemonCapabilitiesResult: Codable, Sendable {
    public let controlModeEnabled: Bool
    public init(controlModeEnabled: Bool) { self.controlModeEnabled = controlModeEnabled }
}
```

- [ ] **Step 4: Add the handlers to `RPCRouter`**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, extend the `handle(_:)` switch (near the other terminal/worktree cases):

```swift
            case RPCMethod.attachRequest:
                let params = try decoder.decode(AttachRequestParams.self, from: request.paramsData)
                routerLogger.info("attach.request pane \(params.paneID, privacy: .public) — stub")
                return try RPCResponse(result: AttachRequestResult(status: "pending"))
            case RPCMethod.attachReady:
                _ = try decoder.decode(AttachReadyParams.self, from: request.paramsData)
                return .ok()
            case RPCMethod.paneDetach:
                _ = try decoder.decode(PaneDetachParams.self, from: request.paramsData)
                return .ok()
            case RPCMethod.daemonCapabilities:
                return try handleDaemonCapabilities()
```

And the real capabilities handler (small enough to live in `RPCRouter.swift` or the Task 7 extension file — implementer's choice):

```swift
    func handleDaemonCapabilities() throws -> RPCResponse {
        let enabled: Bool
        if let bridge = controlMode {
            enabled = ControlModeGate.shouldEnable(
                environment: bridge.environment, tmuxVersion: bridge.tmuxVersion)
        } else {
            enabled = false
        }
        return try RPCResponse(result: DaemonCapabilitiesResult(controlModeEnabled: enabled))
    }
```

(This uses the bridge's `environment` field added in Task 3. If Task 3 hasn't landed yet in your ordering, gate on `ControlModeGate.shouldEnable(tmuxVersion: controlMode?.tmuxVersion)` and switch to the injectable environment when the bridge grows it.)

- [ ] **Step 5: Add matching client helpers to `DaemonClient` and store capabilities on `AppState`**

In `Sources/TBDApp/DaemonClient.swift` (an `actor`), add:

```swift
    func attachRequest(worktreeID: UUID, paneID: String, windowID: String) async throws -> AttachRequestResult {
        try await callAsync(method: RPCMethod.attachRequest,
                            params: AttachRequestParams(worktreeID: worktreeID, paneID: paneID, windowID: windowID),
                            resultType: AttachRequestResult.self)
    }

    func attachReady(worktreeID: UUID, paneID: String) async throws {
        try await callVoidAsync(method: RPCMethod.attachReady,
                                params: AttachReadyParams(worktreeID: worktreeID, paneID: paneID))
    }

    func paneDetach(worktreeID: UUID, paneID: String) async throws {
        try await callVoidAsync(method: RPCMethod.paneDetach,
                                params: PaneDetachParams(worktreeID: worktreeID, paneID: paneID))
    }

    func daemonCapabilities() async throws -> DaemonCapabilitiesResult {
        try await callNoParamsAsync(method: RPCMethod.daemonCapabilities,
                                    resultType: DaemonCapabilitiesResult.self)
    }
```

In `Sources/TBDApp/AppState.swift`, add a stored property (match the file's style for daemon-derived state) and populate it in `connectAndLoadInitialState()` after the connection succeeds:

```swift
    /// Feature flags fetched from the daemon at connect time. Nil until the
    /// first successful fetch — treated as "control mode off".
    var daemonCapabilities: DaemonCapabilitiesResult?
```

```swift
            // in connectAndLoadInitialState(), alongside the other post-connect loads:
            daemonCapabilities = try? await daemonClient.daemonCapabilities()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter AttachRPCStubTests` — 4 PASS.
Run: `swift build` — clean.

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDShared/RPCProtocol.swift \
        Sources/TBDDaemon/Server/RPCRouter.swift \
        Sources/TBDApp/DaemonClient.swift \
        Sources/TBDApp/AppState.swift \
        Tests/TBDDaemonTests/AttachRPCTests.swift
git commit -m "feat: attach lifecycle RPC stubs and daemon.capabilities gate reporting"
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

        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: "%42"))
        try await server.send(fd: readFD, header: header)
        Darwin.close(readFD)

        let (rxFD, rxHeader) = try FDChannel.receiveFD(from: clientSideFD, headerCapacity: 256)
        defer { Darwin.close(rxFD) }
        #expect(try JSONDecoder().decode(FDVendHeader.self, from: rxHeader) ==
                (try JSONDecoder().decode(FDVendHeader.self, from: header)))

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

## Task 6: `PaneFanout` — reader-thread per-pane pipe fanout

**Files:**
- Create: `Sources/TBDDaemon/Tmux/ControlMode/PaneFanout.swift`
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift` (`outputSink` fast path)
- Modify: `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift` (own the fanout, wire the sink, thin wrappers)
- Test: `Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift`

**Where the bytes flow (A1).** The spec's data-flow example is explicit: `%output → daemon parser → decode → write bytes → pipe`, with "no user-space byte routing in the daemon beyond decode-and-write" — the parser runs on a real `Thread` precisely because actor scheduling starved the v1 hot path. So the fanout is a **lock-guarded class called synchronously on the connection's reader thread**, not a supervisor-actor method fed by the `AsyncStream`. Two failure modes this avoids: (a) an unbounded `AsyncStream` silently buffering megabytes of render bytes behind the logging actor during a burst, and (b) Phase 6's `EAGAIN`-driven flow control losing its meaning (`EAGAIN` is only an authoritative "reader can't keep up" signal if bytes hit the pipe the moment they're decoded, instead of queueing upstream).

Mechanics:
- `TmuxControlConnection` gains an `outputSink` closure, set **before** `start()`. When installed, `.output`/`.extendedOutput` events are handed to it synchronously on the reader thread and are **not** yielded into the `events` stream; every other event still flows to the supervisor's logging loop unchanged.
- `PaneFanout` keys everything by `PaneKey(server:paneID:)` (B4 — bare `%N` collides across per-repo tmux servers), holds pipe write ends + a per-sink `ready` flag (the attach handshake's write gate), and writes with a **partial-write loop**: a nonblocking `write()` of a 16 KB chunk into a nearly-full 64 KB pipe legally returns a short count, and treating that as success would drop bytes mid-escape-sequence and garble the terminal. On `EAGAIN` the remainder is dropped and counted; drop logging is rate-limited.
- Events for unattached or not-yet-ready panes are dropped and counted (the Phase 2 boundary: no replay, no buffering).
- The supervisor keeps ownership (one fanout per daemon) and exposes thin async wrappers so RPC handlers stay actor-friendly.

Nonblocking writes are the right shape because Phase 6 layers flow control on top; for Phase 2 we log-and-drop on `EAGAIN`.

- [ ] **Step 1: Write the failing test**

Create `Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift`. The fanout is directly constructible, so most coverage drives `PaneFanout` itself; one test goes through the supervisor wrappers to pin their signatures.

```swift
import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib

@Suite("PaneFanout")
struct PaneFanoutTests {
    private let server = "tbd-test-server"

    @Test("attach + markReady routes %output bytes into the pipe")
    func attachedReadyPaneReceivesOutput() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%42")
        let readFD = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        fanout.markReady(key: key)

        fanout.route(server: server, event: .output(paneID: "%42", bytes: Data("hello".utf8)))

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(count)]) == Data("hello".utf8))
    }

    @Test("output before markReady is dropped; output after flows")
    func outputGatedOnReady() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%3")
        let readFD = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        fanout.route(server: server, event: .output(paneID: "%3", bytes: Data("early".utf8)))
        fanout.markReady(key: key)
        fanout.route(server: server, event: .output(paneID: "%3", bytes: Data("later".utf8)))

        var buffer = [UInt8](repeating: 0, count: 32)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(count)]) == Data("later".utf8))
    }

    @Test("same paneID on a different server does not cross streams")
    func crossServerIsolation() throws {
        let fanout = PaneFanout()
        let keyA = PaneKey(server: "server-a", paneID: "%0")
        let keyB = PaneKey(server: "server-b", paneID: "%0")
        let readA = try fanout.attach(key: keyA); defer { Darwin.close(readA) }
        let readB = try fanout.attach(key: keyB); defer { Darwin.close(readB) }
        fanout.markReady(key: keyA)
        fanout.markReady(key: keyB)

        fanout.route(server: "server-a", event: .output(paneID: "%0", bytes: Data("for-a".utf8)))

        var buffer = [UInt8](repeating: 0, count: 32)
        let countA = buffer.withUnsafeMutableBytes { Darwin.read(readA, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(countA)]) == Data("for-a".utf8))
        // B's pipe must be empty: nonblocking read returns EAGAIN, not data.
        let flags = fcntl(readB, F_GETFL)
        _ = fcntl(readB, F_SETFL, flags | O_NONBLOCK)
        let countB = buffer.withUnsafeMutableBytes { Darwin.read(readB, $0.baseAddress, $0.count) }
        #expect(countB < 0 && errno == EAGAIN)
    }

    @Test("detach closes the pipe write end (reader sees EOF)")
    func detachClosesPipe() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%42")
        let readFD = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        fanout.detach(key: key)

        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(count == 0)  // EOF, because write end is closed
    }

    @Test("output for an unattached pane is dropped without error")
    func unattachedPaneDrops() {
        let fanout = PaneFanout()
        fanout.route(server: server, event: .output(paneID: "%999", bytes: Data("x".utf8)))
        // No crash, no throw — this test just needs to reach here.
        #expect(true)
    }

    @Test("a chunk larger than the pipe buffer delivers an intact prefix and drops the rest")
    func partialWriteDropsTailNotMiddle() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%7")
        let readFD = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        fanout.markReady(key: key)

        // 256 KB into a ~64 KB pipe with no reader: the write must stop at
        // EAGAIN and drop the tail — never skip bytes in the middle.
        let big = Data(repeating: UInt8(ascii: "z"), count: 256 * 1024)
        fanout.route(server: server, event: .output(paneID: "%7", bytes: big))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let flags = fcntl(readFD, F_GETFL)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
            if n <= 0 { break }
            received.append(contentsOf: buffer[0..<Int(n)])
        }
        #expect(!received.isEmpty)
        #expect(received.count < big.count)
        #expect(received.allSatisfy { $0 == UInt8(ascii: "z") }, "prefix must be intact, no holes")
    }
}

@Suite("TmuxControlSupervisor attach wrappers")
struct TmuxControlSupervisorAttachTests {
    @Test("supervisor wrappers delegate to the fanout")
    func wrappersDelegate() async throws {
        let supervisor = TmuxControlSupervisor()
        let readFD = try await supervisor.attach(server: "srv", paneID: "%1")
        defer { Darwin.close(readFD) }
        #expect(await supervisor.isReady(server: "srv", paneID: "%1") == false)
        await supervisor.markReady(server: "srv", paneID: "%1")
        #expect(await supervisor.isReady(server: "srv", paneID: "%1") == true)
        await supervisor.detach(server: "srv", paneID: "%1")
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(count == 0)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "PaneFanout|TmuxControlSupervisorAttach"`
Expected: compile failure — `PaneFanout`, `PaneKey`, and the supervisor wrappers don't exist.

- [ ] **Step 3: Implement `PaneFanout`**

Create `Sources/TBDDaemon/Tmux/ControlMode/PaneFanout.swift`:

```swift
import Darwin
import Foundation
import os

/// Composite pane identity. tmux pane IDs ("%0", "%1", …) are only unique
/// within one tmux server, and TBD runs one server per repo — so every
/// control-mode map keys by (server, paneID), never bare paneID.
struct PaneKey: Hashable {
    let server: String
    let paneID: String
}

enum PaneFanoutError: Error {
    case pipeAllocationFailed(Int32)
}

/// Routes decoded `%output`/`%extended-output` bytes into per-pane pipe write
/// ends. `route(server:event:)` is called SYNCHRONOUSLY on each connection's
/// reader thread — the spec's data-flow keeps the render hot path off actors
/// (the v1 starvation blocker) and out of unbounded AsyncStream buffering.
/// The lock makes attach/markReady/detach (called from the supervisor actor)
/// safe against concurrent routing from reader threads.
final class PaneFanout: @unchecked Sendable {
    private struct Sink {
        var writeFD: Int32
        /// The attach handshake's write gate: false between `attach` (fd
        /// vended) and the app's `attach.ready` ack. Output routed while not
        /// ready is dropped — Phase 2 has no replay/buffering.
        var ready = false
        var droppedEvents = 0
        var droppedBytes = 0
        var lastDropLog = Date.distantPast
    }

    private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")
    private let lock = NSLock()
    private var sinks: [PaneKey: Sink] = [:]
    /// %output events dropped because no attach was registered for their pane.
    private var unattachedDrops = 0

    /// Allocate a pipe for `key`, remember the (nonblocking) write end, and
    /// return the read end for the caller to vend. Replaces — and EOFs — any
    /// existing attach for the same key; the fresh sink starts NOT ready.
    func attach(key: PaneKey) throws -> Int32 {
        var fds: [Int32] = [-1, -1]
        let ok = fds.withUnsafeMutableBufferPointer { buf in pipe(buf.baseAddress) == 0 }
        if !ok { throw PaneFanoutError.pipeAllocationFailed(errno) }
        let (readFD, writeFD) = (fds[0], fds[1])
        // Nonblocking write end: a slow app-side reader must never stall the
        // reader thread. EAGAIN → drop-and-count (Phase 6 adds flow control).
        let flags = fcntl(writeFD, F_GETFL)
        _ = fcntl(writeFD, F_SETFL, flags | O_NONBLOCK)

        lock.lock()
        let old = sinks[key]
        sinks[key] = Sink(writeFD: writeFD)
        lock.unlock()
        if let old { Darwin.close(old.writeFD) }

        logger.info("fanout attach \(key.server, privacy: .public)/\(key.paneID, privacy: .public) writeFD=\(writeFD)")
        return readFD
    }

    /// Open the write gate — called when the app's `attach.ready` ack arrives.
    func markReady(key: PaneKey) {
        lock.lock()
        sinks[key]?.ready = true
        lock.unlock()
        logger.info("fanout ready \(key.server, privacy: .public)/\(key.paneID, privacy: .public)")
    }

    func isReady(key: PaneKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return sinks[key]?.ready ?? false
    }

    /// Close and forget the write end for `key`; the app-held read end sees
    /// EOF on its next read.
    func detach(key: PaneKey) {
        lock.lock()
        let sink = sinks.removeValue(forKey: key)
        lock.unlock()
        if let sink { Darwin.close(sink.writeFD) }
        logger.info("fanout detach \(key.server, privacy: .public)/\(key.paneID, privacy: .public)")
    }

    /// Close every sink (daemon shutdown / supervisor stopAll).
    func closeAll() {
        lock.lock()
        let all = sinks
        sinks.removeAll()
        lock.unlock()
        for sink in all.values { Darwin.close(sink.writeFD) }
    }

    /// Hot path — called on the reader thread for every output event.
    func route(server: String, event: TmuxControlEvent) {
        let paneID: String
        let bytes: Data
        switch event {
        case .output(let p, let b): paneID = p; bytes = b
        case .extendedOutput(let p, _, let b): paneID = p; bytes = b
        default: return
        }
        let key = PaneKey(server: server, paneID: paneID)

        lock.lock()
        defer { lock.unlock() }
        guard var sink = sinks[key], sink.ready else {
            if sinks[key] != nil { sinks[key]!.droppedEvents += 1 } else { unattachedDrops += 1 }
            return
        }

        // Partial-write loop: nonblocking write() may legally return a short
        // count. Stopping mid-chunk and dropping the REMAINDER keeps the
        // delivered prefix intact; skipping bytes in the middle would corrupt
        // the escape-sequence stream.
        let buf = [UInt8](bytes)
        var offset = 0
        while offset < buf.count {
            let n = buf[offset...].withUnsafeBytes { Darwin.write(sink.writeFD, $0.baseAddress, $0.count) }
            if n > 0 { offset += n; continue }
            if n < 0 && errno == EAGAIN {
                sink.droppedEvents += 1
                sink.droppedBytes += buf.count - offset
                if Date().timeIntervalSince(sink.lastDropLog) > 1 {
                    sink.lastDropLog = Date()
                    logger.debug("fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) EAGAIN — dropped \(sink.droppedBytes) bytes total (\(sink.droppedEvents) events)")
                }
            } else {
                logger.error("fanout \(key.server, privacy: .public)/\(key.paneID, privacy: .public) write errno=\(errno)")
            }
            break
        }
        sinks[key] = sink
    }
}
```

- [ ] **Step 4: Add the `outputSink` fast path to `TmuxControlConnection`**

In `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift`:

Add the property (document it in the class's thread-safety comment: set once before `start()`, read only by the reader thread):

```swift
    /// Fast-path consumer for render output. When set (BEFORE `start()`),
    /// `.output`/`.extendedOutput` events are delivered synchronously on the
    /// reader thread and NOT yielded into `events` — render bytes must not
    /// queue behind the logging actor in an unbounded AsyncStream, and Phase
    /// 6's EAGAIN-driven flow control needs writes to hit the pipe the moment
    /// they are decoded.
    var outputSink: (@Sendable (TmuxControlEvent) -> Void)?
```

And split delivery in `readLoop`:

```swift
            for event in parser.feed(Data(buffer[0..<count])) {
                switch event {
                case .output, .extendedOutput:
                    if let sink = outputSink { sink(event) } else { eventContinuation.yield(event) }
                default:
                    eventContinuation.yield(event)
                }
            }
```

- [ ] **Step 5: Wire the fanout into `TmuxControlSupervisor`**

In `Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift`:

```swift
    /// Shared per-daemon fanout. Reader threads call `route` directly; the
    /// actor only mediates attach/ready/detach.
    private let fanout = PaneFanout()
```

In `ensureConnection(serverName:)`, install the sink before `start()`:

```swift
        let connection = TmuxControlConnection(serverName: serverName)
        let fanout = self.fanout
        connection.outputSink = { [fanout] event in
            fanout.route(server: serverName, event: event)
        }
```

Add the thin wrappers (used by the Task 7 RPC handlers and Task 10 integration test):

```swift
    func attach(server: String, paneID: String) throws -> Int32 {
        try fanout.attach(key: PaneKey(server: server, paneID: paneID))
    }
    func markReady(server: String, paneID: String) {
        fanout.markReady(key: PaneKey(server: server, paneID: paneID))
    }
    func isReady(server: String, paneID: String) -> Bool {
        fanout.isReady(key: PaneKey(server: server, paneID: paneID))
    }
    func detach(server: String, paneID: String) {
        fanout.detach(key: PaneKey(server: server, paneID: paneID))
    }
    /// Cancel an attach the app never acked (spec: 5 s ready timeout).
    func detachIfNotReady(server: String, paneID: String) {
        let key = PaneKey(server: server, paneID: paneID)
        if !fanout.isReady(key: key) { fanout.detach(key: key) }
    }
```

Update `stopAll()`:

```swift
    func stopAll() {
        for connection in connections.values { connection.stop() }
        connections.removeAll()
        fanout.closeAll()
    }
```

(The supervisor's `log` switch keeps its `.output`/`.extendedOutput` cases — they still fire for connections with no sink installed, e.g. if a future caller opts out — but with the sink installed those events never reach the stream; per-pane byte accounting now lives in the fanout's counters.)

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "PaneFanout|TmuxControlSupervisorAttach"` — all PASS.
Run: `swift test --filter Tmux` — no regressions (the Phase 1 integration test must still pass: it installs no sink, so events keep flowing through the stream).

- [ ] **Step 7: Commit**

```bash
git add Sources/TBDDaemon/Tmux/ControlMode/PaneFanout.swift \
        Sources/TBDDaemon/Tmux/ControlMode/TmuxControlConnection.swift \
        Sources/TBDDaemon/Tmux/ControlMode/TmuxControlSupervisor.swift \
        Tests/TBDDaemonTests/TmuxControlSupervisorAttachTests.swift
git commit -m "feat: reader-thread PaneFanout with composite pane keys and partial-write handling"
```

---

## Task 7: Attach orchestrator — wire supervisor + vending server

**Files:**
- Create: `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift`
- Modify: `Sources/TBDDaemon/Server/RPCRouter.swift` (delegate to the extension)
- Test: extend `Tests/TBDDaemonTests/AttachRPCTests.swift`

Replace the Task 4 stub handlers with real orchestration through the **existing** `controlMode: TmuxControlModeBridge?` router property (Task 3 already extended the bridge with `environment`, `fdVending`, `readyTimeout` — there is deliberately no second config bag):

1. On `attach.request{worktreeID, paneID, windowID}`: gate on `ControlModeGate.shouldEnable(environment:tmuxVersion:)` from the bridge; if off, return `status: "unavailable"`. Resolve `worktreeID → worktree.tmuxServer` via the DB (error if missing). Call `supervisor.attach(server:paneID:)` → read FD (sink starts NOT ready — writes gated); vend the FD with a JSON `FDVendHeader`; close the daemon's copy; schedule the **ready-timeout cancel** (spec, pane lifecycle: an attach the app never acks is torn down after `readyTimeout`, default 5 s); return `status: "pending"`.
2. On `attach.ready{worktreeID, paneID}`: resolve the server, `supervisor.markReady(server:paneID:)` — opens the write gate.
3. On `pane.detach{worktreeID, paneID}`: resolve the server, `supervisor.detach(server:paneID:)`.

The write gate itself lives in `PaneFanout` (Task 6). The "vend fd first, ack, then write" ordering is the spec's non-negotiable handshake; the gate is why early `%output` can't land in a pipe nobody reads.

- [ ] **Step 1 (was ready-gate plumbing): already done in Task 6**

The fanout's `ready` flag, `markReady`, and `detachIfNotReady` landed with Task 6. Nothing to do here — this step exists so the step numbering below matches the original plan revision.

- [ ] **Step 2: Write the failing tests**

Extend `Tests/TBDDaemonTests/AttachRPCTests.swift` with a new suite. The factory grows an optional bridge parameter: `makeRouter(controlMode: TmuxControlModeBridge? = nil)` sets `router.controlMode` after construction. Each test that needs a resolvable worktree creates a repo + worktree row in the in-memory DB first (mirror `SuspendResumeCoordinatorTests.setupSuspendedTerminal` — `db.repos.create` + `db.worktrees.create(tmuxServer: "tbd-attach-test")`).

```swift
@Suite("Attach RPC orchestration")
struct AttachRPCOrchestrationTests {
    @Test("attach.request with the gate on vends an fd whose header carries the pane identity")
    func vendsFDWhenGateOn() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, worktreeID) = try await makeRouterWithWorktree(controlMode: TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: vending))

        let request = try makeRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%1", windowID: "@1"))
        let response = await router.handle(request)
        #expect(response.success)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "pending")

        let (rxFD, rxHeader) = try FDChannel.receiveFD(from: clientSide, headerCapacity: 256)
        defer { Darwin.close(rxFD) }
        let header = try JSONDecoder().decode(FDVendHeader.self, from: rxHeader)
        #expect(header.worktreeID == worktreeID)
        #expect(header.paneID == "%1")
    }

    @Test("attach.request with the gate off returns unavailable and does not send an fd")
    func gateOffReturnsUnavailable() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(serverSide); Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        let (router, worktreeID) = try await makeRouterWithWorktree(controlMode: TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: [:],   // no opt-in
            fdVending: vending))

        let request = try makeRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%2", windowID: "@2"))
        let response = await router.handle(request)
        let result = try response.decodeResult(AttachRequestResult.self)
        #expect(result.status == "unavailable")
    }

    @Test("attach.request for an unknown worktree fails")
    func unknownWorktreeFails() async throws {
        let (serverSide, _) = try makeSocketPair()
        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let router = try await makeRouter(controlMode: TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: vending))

        let request = try makeRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: UUID(), paneID: "%9", windowID: "@9"))
        let response = await router.handle(request)
        #expect(!response.success)
    }

    @Test("an attach the app never acks is torn down after readyTimeout")
    func unackedAttachTornDownAfterTimeout() async throws {
        let (serverSide, clientSide) = try makeSocketPair()
        defer { Darwin.close(clientSide) }

        let supervisor = TmuxControlSupervisor()
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: serverSide)
        let (router, worktreeID) = try await makeRouterWithWorktree(controlMode: TmuxControlModeBridge(
            supervisor: supervisor,
            tmuxVersion: TmuxVersion(major: 3, minor: 6),
            environment: ["TBD_TMUX_CONTROL_MODE": "1"],
            fdVending: vending,
            readyTimeout: .milliseconds(100)))

        let request = try makeRequest(
            method: RPCMethod.attachRequest,
            params: AttachRequestParams(worktreeID: worktreeID, paneID: "%5", windowID: "@5"))
        _ = await router.handle(request)

        let (rxFD, _) = try FDChannel.receiveFD(from: clientSide, headerCapacity: 256)
        defer { Darwin.close(rxFD) }

        // No attach.ready is ever sent. After the timeout, the daemon must
        // detach — closing the write end, so the vended read fd sees EOF.
        try await Task.sleep(for: .milliseconds(400))
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
        #expect(count == 0, "un-acked attach must be torn down (EOF on the vended fd)")
    }
}
```

(`outputGatedOnReady` coverage lives in Task 6's `PaneFanoutTests` — no duplicate here.)

- [ ] **Step 3: Create the attach handlers extension**

Create `Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift` (no config bag — the bridge on `controlMode` already carries everything after Task 3):

```swift
import Darwin
import Foundation
import TBDShared
import os

private let logger = Logger(subsystem: "com.tbd.daemon", category: "tmuxControlMode")

extension RPCRouter {
    /// Handle `attach.request`: gate → resolve worktree → allocate pipe →
    /// vend fd → schedule the ready-timeout cancel → return status.
    func handleAttachRequest(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachRequestParams.self, from: paramsData)
        guard let bridge = controlMode,
              ControlModeGate.shouldEnable(
                  environment: bridge.environment, tmuxVersion: bridge.tmuxVersion) else {
            return try RPCResponse(result: AttachRequestResult(status: "unavailable"))
        }
        guard let worktree = try? await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }
        let server = worktree.tmuxServer
        let paneID = params.paneID
        do {
            let readFD = try await bridge.supervisor.attach(server: server, paneID: paneID)
            let header = try JSONEncoder().encode(
                FDVendHeader(worktreeID: params.worktreeID, paneID: paneID))
            do {
                try await bridge.fdVending.send(fd: readFD, header: header)
            } catch {
                // Vend failed — undo the attach so no orphan pipe lingers.
                Darwin.close(readFD)
                await bridge.supervisor.detach(server: server, paneID: paneID)
                throw error
            }
            // The kernel duplicated the fd into the app's table; drop ours.
            Darwin.close(readFD)

            // Spec (pane lifecycle): "App fails to send attach.ready within
            // timeout (e.g. 5 s) → daemon cancels attach" — otherwise an app
            // that died mid-attach leaks the pipe and a permanently-gated sink.
            let timeout = bridge.readyTimeout
            Task { [supervisor = bridge.supervisor] in
                try? await Task.sleep(for: timeout)
                await supervisor.detachIfNotReady(server: server, paneID: paneID)
            }
            return try RPCResponse(result: AttachRequestResult(status: "pending"))
        } catch {
            logger.error("attach.request failed for \(server, privacy: .public)/\(paneID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return RPCResponse(error: "attach failed: \(error.localizedDescription)")
        }
    }

    func handleAttachReady(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(AttachReadyParams.self, from: paramsData)
        guard let bridge = controlMode else {
            return RPCResponse(error: "control mode not configured")
        }
        guard let worktree = try? await db.worktrees.get(id: params.worktreeID) else {
            return RPCResponse(error: "Worktree not found")
        }
        await bridge.supervisor.markReady(server: worktree.tmuxServer, paneID: params.paneID)
        return .ok()
    }

    func handlePaneDetach(_ paramsData: Data) async throws -> RPCResponse {
        let params = try decoder.decode(PaneDetachParams.self, from: paramsData)
        if let bridge = controlMode,
           let worktree = try? await db.worktrees.get(id: params.worktreeID) {
            await bridge.supervisor.detach(server: worktree.tmuxServer, paneID: params.paneID)
        }
        return .ok()
    }
}
```

- [ ] **Step 4: Delegate from the router switch**

In `Sources/TBDDaemon/Server/RPCRouter.swift`, replace the three stub cases from Task 4:

```swift
            case RPCMethod.attachRequest:
                return try await handleAttachRequest(request.paramsData)
            case RPCMethod.attachReady:
                return try await handleAttachReady(request.paramsData)
            case RPCMethod.paneDetach:
                return try await handlePaneDetach(request.paramsData)
```

(`daemon.capabilities` from Task 4 stays as-is. No `Daemon.swift` change here — the bridge was fully wired in Task 3.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter AttachRPC` — stub suite (updated where behavior became real: `requestRoundTrip` now needs a worktree row or asserts the unknown-worktree error) + 4 orchestration tests PASS.
Run: `swift test` — full suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/TBDDaemon/Server/RPCRouter+AttachHandlers.swift \
        Sources/TBDDaemon/Server/RPCRouter.swift \
        Tests/TBDDaemonTests/AttachRPCTests.swift
git commit -m "feat: attach orchestrator vends per-pane pipe FDs with ready-timeout cancel"
```

---

## Task 8: App-side `ControlModeStreamReader` + registry

**Files:**
- Create: `Sources/TBDApp/Terminal/ControlModeStreamReader.swift`
- Create: `Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift`
- Modify: `Sources/TBDApp/AppState.swift` (own the registry)
- Test: `Tests/TBDAppTests/ControlModeStreamReaderTests.swift`

The stream reader owns a vended read FD and drains it into a callback. It **must not** be owned by a SwiftUI view — SwiftUI can destroy the view at any moment (the v1 blocker). Ownership lives in a registry held by `AppState`, keyed by the same `FDVendHeader.routingKey` composite (worktreeID/paneID) used everywhere else; the view retrieves the reader on setup, uses its callback, and leaves the reader alive on tear-down.

**Teardown shape (important):** `stop()` only sets a flag. It must NOT `close(fd)` out from under the reader thread — on Darwin, `close()` neither wakes a thread blocked in `read()` nor is it safe (the fd number can be reused by a concurrent `open`/`pipe` and the blocked reader would then read a stranger's stream). This is the same reasoning documented on `TmuxControlConnection.stop()`. The fd is closed BY the reader thread when its loop exits, and the loop exits because teardown always pairs with the `pane.detach` RPC: the daemon closes the pipe's write end → the reader sees EOF → exits → closes its own fd.

- [ ] **Step 1: Write the failing tests**

Create `Tests/TBDAppTests/ControlModeStreamReaderTests.swift`:

```swift
import Darwin
import Foundation
import Testing
@testable import TBDApp

@Suite("ControlModeStreamReader")
struct ControlModeStreamReaderTests {

    @Test("bytes written to the pipe reach the on-chunk callback; EOF ends the reader")
    func deliversChunks() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else { throw NSError(domain: "pipe", code: 0) }
        }
        let (readFD, writeFD) = (fds[0], fds[1])
        // NOTE: no defer-close of readFD — the reader thread owns it and
        // closes it when the loop exits (double-closing a reused fd number
        // is a cross-test hazard under `swift test --parallel`).

        let inbox = ChunkInbox()
        let reader = ControlModeStreamReader(routingKey: "wt/%1", fd: readFD) { data in
            Task { await inbox.append(data) }
        }
        reader.start()

        _ = Data("hello".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        _ = Data("world".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        Darwin.close(writeFD)   // EOF → reader exits and closes readFD itself
        try await Task.sleep(for: .milliseconds(200))

        let combined = await inbox.combined
        #expect(combined == Data("helloworld".utf8))
    }

    @Test("registry hands out a single reader per routing key")
    func registryIdempotent() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            _ = pipe(buf.baseAddress)
        }
        let writeFD = fds[1]

        let registry = ControlModeReaderRegistry()
        let one = await registry.registerReader(routingKey: "wt/%1", fd: fds[0]) { _ in }
        let two = await registry.reader(for: "wt/%1")
        #expect(one === two)
        await registry.remove(routingKey: "wt/%1")   // flags stop; fd stays with the reader
        let none = await registry.reader(for: "wt/%1")
        #expect(none == nil)

        // Close the write end so the flagged reader unblocks via EOF and
        // closes its own fd (mirrors the daemon-side pane.detach).
        Darwin.close(writeFD)
        try await Task.sleep(for: .milliseconds(200))
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
/// The reader thread OWNS the fd: it closes it when the loop exits. `stop()`
/// only sets a flag — on Darwin, `close()`ing an fd under a thread blocked in
/// `read()` does not wake it and races fd-number reuse (same reasoning as
/// `TmuxControlConnection.stop()` on the daemon side). The loop exits via EOF,
/// which teardown guarantees by always pairing `stop()` with the `pane.detach`
/// RPC (the daemon closes the pipe's write end).
final class ControlModeStreamReader: @unchecked Sendable {
    /// Composite worktreeID/paneID key (matches `FDVendHeader.routingKey`).
    let routingKey: String
    private let fd: Int32
    private let logger = Logger(subsystem: "com.tbd.app", category: "controlModeReader")
    private var thread: Thread?
    private let onChunk: @Sendable (Data) -> Void
    private let stateLock = NSLock()
    private var stopped = false

    private var isStopped: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return stopped
    }

    init(routingKey: String, fd: Int32, onChunk: @escaping @Sendable (Data) -> Void) {
        self.routingKey = routingKey
        self.fd = fd
        self.onChunk = onChunk
    }

    /// Start the reader thread. Safe to call once.
    func start() {
        precondition(thread == nil, "start called twice")
        let thread = Thread { [self] in self.readLoop() }
        thread.name = "controlmode-reader-\(routingKey)"
        thread.stackSize = 512 * 1024
        self.thread = thread
        thread.start()
    }

    /// Ask the reader to stop delivering chunks. Does NOT close the fd (the
    /// reader thread does, on exit). Callers must also send `pane.detach` so
    /// the daemon EOFs the pipe and unblocks the reader.
    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
    }

    private func readLoop() {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while !isStopped {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count <= 0 { break }
            if isStopped { break }
            onChunk(Data(buffer[0..<Int(count)]))
        }
        Darwin.close(fd)
        logger.info("reader exited \(self.routingKey, privacy: .public)")
    }
}
```

- [ ] **Step 4: Implement the registry**

Create `Sources/TBDApp/Terminal/ControlModeReaderRegistry.swift`:

```swift
import Foundation

/// App-scoped owner of `ControlModeStreamReader` instances. Held by
/// `AppState`; keyed by `FDVendHeader.routingKey` (worktreeID/paneID) so
/// views can retrieve the reader on setup without owning it.
actor ControlModeReaderRegistry {
    private var readers: [String: ControlModeStreamReader] = [:]

    /// Register a reader for `routingKey` and start it. If one already
    /// exists, flag it stopped and replace it (the old reader's fd is closed
    /// by its own thread once the daemon-side detach EOFs it).
    @discardableResult
    func registerReader(routingKey: String, fd: Int32,
                        onChunk: @escaping @Sendable (Data) -> Void) -> ControlModeStreamReader {
        if let existing = readers.removeValue(forKey: routingKey) { existing.stop() }
        let reader = ControlModeStreamReader(routingKey: routingKey, fd: fd, onChunk: onChunk)
        readers[routingKey] = reader
        reader.start()
        return reader
    }

    func reader(for routingKey: String) -> ControlModeStreamReader? { readers[routingKey] }

    func remove(routingKey: String) {
        if let reader = readers.removeValue(forKey: routingKey) { reader.stop() }
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
- Modify: `Sources/TBDApp/DaemonClient.swift` (add convenience `openAttach(worktreeID:paneID:windowID:)`)

Branch the terminal view: when the daemon reports control-mode is active (via the `daemon.capabilities` fetch from Task 4 — the app **cannot** read the env var, it's launched by LaunchServices), request the attach, receive the FD via the sidecar's demuxed promise, send `attach.ready`, and feed bytes into SwiftTerm. Otherwise the existing grouped-sessions path runs unchanged.

- [ ] **Step 1: Add an attach helper to `DaemonClient`**

In `Sources/TBDApp/DaemonClient.swift`, add:

```swift
    /// Request an attach and receive the vended fd via the sidecar. Returns
    /// the read fd (ownership passes to the caller's reader). Does NOT send
    /// `attach.ready` — the caller does that after wiring the reader.
    ///
    /// Ordering: the sidecar expectation is registered BEFORE the RPC is
    /// issued, so the vended fd can never race past its waiter; the header
    /// demux (FDSidecarClient) is what keeps concurrent attaches for
    /// different panes from cross-delivering fds.
    func openAttach(worktreeID: UUID, paneID: String, windowID: String) async throws -> Int32 {
        let promise = fdSidecar.expectFD(worktreeID: worktreeID, paneID: paneID)
        do {
            let result = try await attachRequest(worktreeID: worktreeID, paneID: paneID, windowID: windowID)
            guard result.status == "pending" else {
                promise.cancel()
                throw DaemonClientError.attachUnavailable(result.status)
            }
        } catch {
            promise.cancel()
            throw error
        }
        return try await promise.value(timeout: .seconds(5))
    }
```

(Add `case attachUnavailable(String)` to the client's error enum, or use the file's existing error convention.)

- [ ] **Step 2: Branch `TerminalPanelRepresentable`**

In `Sources/TBDApp/Terminal/TerminalPanelView.swift`, locate `TerminalPanelRepresentable.makeNSView` (~line 177). The current path calls `TmuxBridge.prepareSession()` and lets SwiftTerm spawn `tmux attach`. Add a branch. The representable already has (or can be handed) the terminal's `worktreeID` — the `Terminal` model carries it; thread it through the same way `tmuxPaneID` reaches the view.

```swift
        let controlModeEnabled = appState.daemonCapabilities?.controlModeEnabled == true

        if controlModeEnabled {
            let routingKey = "\(worktreeID.uuidString)/\(tmuxPaneID)"
            Task {
                do {
                    let fd = try await appState.daemonClient.openAttach(
                        worktreeID: worktreeID, paneID: tmuxPaneID, windowID: tmuxWindowID)
                    let terminal = /* the SwiftTerm view instance */
                    await appState.controlModeReaders.registerReader(
                        routingKey: routingKey, fd: fd) { chunk in
                            DispatchQueue.main.async {
                                terminal.feed(byteArray: [UInt8](chunk))
                            }
                        }
                    try await appState.daemonClient.attachReady(
                        worktreeID: worktreeID, paneID: tmuxPaneID)
                } catch {
                    // Fall back to grouped sessions on any attach failure.
                    tmuxBridge.prepareSession(/* existing arguments */)
                }
            }
        } else {
            tmuxBridge.prepareSession(/* existing arguments */)
        }
```

**Implementer note:** the exact SwiftTerm accessor and the `prepareSession` arguments differ file-by-file — inspect the current `makeNSView` body and integrate this branch in the least invasive way possible. The important invariants: (a) when the gate is off, the file behaves identically to Phase 1; (b) the `Task { }` above does not capture the view (only the SwiftTerm terminal instance `terminal.feed` needs, plus by-value IDs). The feed method is `feed(byteArray:)` — already used at ~line 541 of this file.

Also add cleanup on view teardown — in `dismantleNSView` (~line 255). **Order matters** (see Task 8's teardown shape): send `pane.detach` so the daemon EOFs the pipe, and flag the reader stopped; the reader closes its own fd when the EOF lands.

```swift
        Task {
            try? await appState.daemonClient.paneDetach(worktreeID: worktreeID, paneID: tmuxPaneID)
            await appState.controlModeReaders.remove(routingKey: routingKey)
        }
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

        let readFD = try await supervisor.attach(server: server, paneID: paneID)
        defer { Darwin.close(readFD) }

        let (daemonSideSocket, appSideSocket) = try makeSocketPair()
        defer { Darwin.close(appSideSocket) }
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: daemonSideSocket)
        defer { Task { await vending.stop() } }
        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: paneID))
        try await vending.send(fd: readFD, header: header)
        Darwin.close(readFD)  // daemon can drop its copy

        let (rxFD, _) = try FDChannel.receiveFD(from: appSideSocket, headerCapacity: 256)
        defer { Darwin.close(rxFD) }

        // Now signal ready and drive a marker through tmux.
        await supervisor.markReady(server: server, paneID: paneID)
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

If it fails (no marker), do NOT weaken the assertion. Diagnose: is the fanout's `route` firing for this pane? Confirm the connection's `outputSink` was installed (the supervisor sets it in `ensureConnection`), that the event's server tag matches the attach's `server:` argument (composite-key mismatch = silent drop), and that `markReady` ran before `send-keys`.

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
Run: `swiftlint --strict` — 0 violations.

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

(The env var only needs to reach the **daemon** — `restart.sh` starts it directly, so the shell env is inherited. The app is launched via `open` and never sees the variable; it learns the gate from the `daemon.capabilities` RPC at connect time. Use `/usr/bin/log`, not `log` — `log` is a zsh builtin here.)

Open a worktree. The pane must render live tmux output through the control-mode path. Expected log sequence, in order:
- `started tmux -CC connection for server tbd-<hash>`
- `fanout attach tbd-<hash>/%<n> writeFD=<n>`
- `FD vending client connected` (at app startup) and a vend on attach
- `fanout ready tbd-<hash>/%<n>`
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
- "For each visible pane, creates a Unix pipe and writes the pane's decoded `%output` bytes into the write end." → Task 6 (`PaneFanout`, per-pane pipe) ✅
- "No user-space byte routing in the daemon beyond decode-and-write" / parser on a real `Thread` → Task 6: fanout runs synchronously on the reader thread via `outputSink`; render bytes never enter the AsyncStream or the supervisor actor ✅
- "Vends the pipe read end to the app … using `SCM_RIGHTS`." → Tasks 2/3. **Deviation, stated plainly:** the spec says the FDs travel "over the existing RPC Unix socket"; this plan uses a *sidecar* socket instead, because the RPC socket's fd is owned by SwiftNIO and raw `sendmsg`+`SCM_RIGHTS` is not accessible through its channel abstraction. The consequence — vended FDs are no longer serialized with RPC responses — is handled by the `FDVendHeader` demux (B3): every fd is routed by (worktreeID, paneID), never by arrival order.
- "FD must arrive before daemon writes anything substantial" + "only after receiving the ack does the daemon start writing" → Task 6/7 (per-sink `ready` gate) ✅
- "App fails to send `attach.ready` ack within timeout (e.g. 5 s) → daemon cancels attach" (pane lifecycle, error transitions) → Task 7 (`readyTimeout` + `detachIfNotReady`, injectable for tests) ✅
- "Reads pane bytes directly from the vended pipe FD into SwiftTerm" → Tasks 8/9 ✅
- "Reader on a long-lived stream actor (not view-owned)" → Task 8 (registry on AppState; reader thread owns and closes the fd) ✅
- Out of scope for Phase 2 (scrollback, flow control, keystrokes, resize, crash recovery, layout-change) → explicitly excluded per "Phase boundary" ✅

**Plan defects folded in (from Phase 1 review):**
- `stop()` teardown escalation (SIGTERM→SIGKILL) with an unconditional second reader wait → Task 1 ✅
- Trailing-output ordering / `finish()` race — reader thread is the sole finisher → Task 1 ✅

**Review findings folded in (2026-07-01 review of this plan):**
- B1: `FDChannel`/`FDVendHeader` in `TBDShared`, `public` (TBDApp ↛ TBDDaemonLib) → Task 2
- B2: `daemon.capabilities` RPC; app never reads the env var (LaunchServices drops it) → Tasks 4/9/11
- B3: sidecar receive loop demuxes by `FDVendHeader.routingKey`; expectation registered before the RPC; 5 s waiter timeout → Tasks 3/9
- B4: composite `PaneKey(server:paneID:)` everywhere; attach RPCs carry `worktreeID`, daemon resolves `tmuxServer` → Tasks 4/6/7
- A1: fanout on the reader thread; output events bypass the AsyncStream → Task 6
- Partial pipe writes handled (intact prefix, counted tail drop) → Task 6
- App reader never closes its fd from another thread; teardown pairs `pane.detach` + flag → Tasks 8/9
- `AttachConfiguration` dropped; `TmuxControlModeBridge` extended instead (one config bag on the router) → Tasks 3/7
- Sidecar accept on a dedicated `Thread`; app connects eagerly; `send` retries briefly → Task 3

**Placeholder scan:** the remaining "match the existing pattern" hedges (router test factory in Task 4, `prepareSession` arguments in Task 9) are genuinely file-local details; each names a concrete nearby example to copy. All RPC code samples use the verified house idioms (`RPCMethod` static-string namespace; `try RPCResponse(result:)` / `RPCResponse(error:)` / `.ok()`; `request.paramsData` + router `decoder`; `callAsync`/`callVoidAsync`/`callNoParamsAsync`).

**Type consistency:** `AttachRequestParams`/`AttachReadyParams`/`PaneDetachParams` (all with `worktreeID`), `AttachRequestResult`, `DaemonCapabilitiesResult` are defined in Task 4 and consumed by name in Tasks 7/9. `PaneKey`, `PaneFanout.{attach,markReady,isReady,detach,closeAll,route}` and the supervisor wrappers `attach(server:paneID:)`/`markReady(server:paneID:)`/`detach(server:paneID:)`/`detachIfNotReady(server:paneID:)` are consistent across Tasks 6, 7, 10. `FDVendingServer`'s surface (`listen(on:)`, `adoptConnection(fd:)`, `send(fd:header:)` — async, retrying — `stop()`) is stable across Tasks 3, 5, 7, 10. `FDSidecarClient.{connect,adopt,expectFD}` + `FDPromise.{value(timeout:),cancel}` are consistent across Tasks 3 and 9.

**Known assumptions to verify empirically during Task 10:**
- The fanout's `route` fires with the exact `paneID` string tmux emits (should be `%N`; the Phase 1 integration test already establishes this) and the `server` tag the supervisor closed over matches the attach's — a mismatch is a silent drop, which the Task 10 diagnosis note covers.
- Nonblocking `write()` to the pipe rarely `EAGAIN`s for typical shell output with a locally-attached reader. When it does, Task 6's counters make it visible in the log stream — flagged as a Phase 6 (flow control) prerequisite before that phase raises the pane count.
