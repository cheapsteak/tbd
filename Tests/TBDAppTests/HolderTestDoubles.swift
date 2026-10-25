import Clocks
import Darwin
import Foundation
import TBDShared
import Testing

@testable import TBDApp

/// Plays the daemon's three holder RPCs for a panel test, each from a script
/// indexed by its own call number, and logs every RPC in order.
///
/// The resend pacing is the stub's, as it is any client's
/// (`HolderAttaching.resendDelays`, `clock`); the defaults resend on the
/// production schedule with waits that return at once.
final class ScriptedHolderDaemon: HolderAttaching, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var attachCount = 0
    private var readyCount = 0
    private var detachCount = 0
    private let attachScript: @Sendable (Int) async throws -> HolderAttachment
    private let readyScript: @Sendable (Int) async throws -> Void
    private let detachScript: @Sendable (Int) async throws -> Void
    let resendDelays: [Duration]
    let clock: any Clock<Duration>

    init(
        attach: @escaping @Sendable (Int) async throws -> HolderAttachment = { _ in
            throw DaemonClientError.attachUnavailable("unavailable")
        },
        ready: @escaping @Sendable (Int) async throws -> Void = { _ in },
        detach: @escaping @Sendable (Int) async throws -> Void = { _ in },
        resendDelays: [Duration] = HolderAttachRetry.handbackResendDelays,
        clock: any Clock<Duration> = ImmediateClock<Duration>()
    ) {
        attachScript = attach
        readyScript = ready
        detachScript = detach
        self.resendDelays = resendDelays
        self.clock = clock
    }

    var events: [String] { lock.withLock { log } }
    var attaches: Int { lock.withLock { attachCount } }
    var readies: Int { lock.withLock { readyCount } }
    var detaches: Int { lock.withLock { detachCount } }

    func attach(
        worktreeID: UUID, paneID: String, terminalID: UUID
    ) async throws -> HolderAttachment {
        let call = lock.withLock {
            log.append("attach")
            attachCount += 1
            return attachCount - 1
        }
        return try await attachScript(call)
    }

    func ready(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64
    ) async throws {
        let call = lock.withLock {
            log.append("ready")
            readyCount += 1
            return readyCount - 1
        }
        try await readyScript(call)
    }

    func detach(
        worktreeID: UUID, paneID: String, terminalID: UUID, generation: UInt64,
        snapshotPreamble: Data
    ) async throws {
        let call = lock.withLock {
            log.append("detach")
            detachCount += 1
            return detachCount - 1
        }
        try await detachScript(call)
    }
}

/// Holds whatever awaits it until the test opens it. Suspension-based, so no
/// thread blocks.
actor HolderTestGate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        opened = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A flag any thread can raise and read — whether a claim has cleared at the
/// daemon, say.
final class HolderTestLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    var isSet: Bool { lock.withLock { raised } }

    func set() { lock.withLock { raised = true } }
}

/// One `socketpair` standing in for a vended pty: `vended` goes to the panel,
/// whose reader owns and closes it; `far` stays with the test, where a `read`
/// returning 0 means every copy of `vended` in this process is closed.
///
/// Both ends are close-on-exec from creation, for `HolderDetachHandbackTests`'
/// reason: a sibling suite's child spawned before the attach's own `fcntl`
/// would otherwise inherit the session for the whole run. Both are
/// `O_NONBLOCK`, as the real vend is: the flag lives on the pty's shared open
/// file description and rides the `dup`.
final class HolderTestPTY {
    let vended: Int32
    let far: Int32

    init() {
        var pair: [Int32] = [-1, -1]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        vended = pair[0]
        far = pair[1]
        for fd in [vended, far] {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
    }

    /// Whether every copy of `vended` in this process is closed.
    var vendedIsClosed: Bool {
        var byte: UInt8 = 0
        return Darwin.read(far, &byte, 1) == 0
    }

    func closeFar() { Darwin.close(far) }

    func attachment(generation: UInt64) -> HolderAttachment {
        HolderAttachment(ptyFD: vended, generation: generation, snapshotPreamble: Data())
    }
}
