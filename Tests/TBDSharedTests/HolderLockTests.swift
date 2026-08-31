import Foundation
import Testing
@testable import TBDShared

@Suite("Holder creation lock")
struct HolderLockTests {
    private func scratchPath() -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("holder-lock-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session.lock").path
    }

    @Test func acquiresAnUncontendedLock() throws {
        let path = scratchPath()
        let lock = try HolderLock.acquire(path: path)
        defer { lock.release() }
        #expect(lock.fileDescriptor >= 0)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    /// The whole point: a second spawner must learn that a live holder owns
    /// this UUID *without connecting to it*, and back off.
    @Test func secondAcquisitionFailsWhileFirstIsHeld() throws {
        let path = scratchPath()
        let first = try HolderLock.acquire(path: path)
        defer { first.release() }
        #expect(throws: HolderLock.Error.alreadyHeld(path: path)) {
            _ = try HolderLock.acquire(path: path)
        }
    }

    @Test func lockIsReacquirableAfterRelease() throws {
        let path = scratchPath()
        let first = try HolderLock.acquire(path: path)
        first.release()
        let second = try HolderLock.acquire(path: path)
        defer { second.release() }
        #expect(second.fileDescriptor >= 0)
    }

    /// The holder inherits the lock across exec, so FD_CLOEXEC must be clear.
    @Test func canBeMadeInheritableAcrossExec() throws {
        let path = scratchPath()
        let lock = try HolderLock.acquire(path: path)
        defer { lock.release() }
        try lock.makeInheritableAcrossExec()
        let flags = fcntl(lock.fileDescriptor, F_GETFD)
        #expect(flags >= 0)
        #expect((flags & FD_CLOEXEC) == 0)
    }

    /// THE CLAIM THE WHOLE DESIGN RESTS ON, and the only one no in-process test
    /// can reach: the kernel drops the lock when the holding *process* dies, so
    /// a holder that crashes or is SIGKILLed leaves behind an empty file and
    /// nothing else. Every reclaim story in the spec — a spawner retrying a
    /// session whose holder died, OrphanGC sweeping the file — depends on it,
    /// and `release()` returning the lock proves only that `close(2)` works.
    ///
    /// The child holds the lock by INHERITING the descriptor: the lock lives on
    /// the open file description, so passing the fd across `exec` passes the
    /// lock with it. That is also how the real holder gets it, which makes this
    /// the same mechanism rather than a stand-in for it. `fork()` is
    /// unavailable to Swift on Darwin ("please use threads or posix_spawn"), so
    /// the child is a real `posix_spawn`ed `/bin/sh`.
    ///
    /// The sequencing is what makes the assertion mean anything:
    ///
    ///   1. the child writes a marker THROUGH the inherited fd, so a
    ///      descriptor that never arrived is caught rather than passing
    ///      vacuously,
    ///   2. the parent drops its own fd while the child is still alive, so the
    ///      child is the sole holder,
    ///   3. only the child's exit can free the lock.
    ///
    /// Deliberately asserts NOTHING about contention: that belongs to
    /// `secondAcquisitionFailsWhileFirstIsHeld`, and a `LOCK_NB` regression
    /// should redden that test rather than park this one in a blocking `flock`
    /// forever.
    @Test func lockIsReacquirableAfterTheHoldingProcessExits() throws {
        let path = scratchPath()
        let lock = try HolderLock.acquire(path: path)
        var parentStillHoldsLock = true
        defer { if parentStillHoldsLock { lock.release() } }

        // `echo K >&9` proves the descriptor arrived; `echo R` tells the parent
        // that write already happened; `read` parks the child until the parent
        // closes the pipe, so the parent can drop its own fd first.
        let script = "echo K >&9; echo R; read line"
        var toChild: [Int32] = [-1, -1]
        var fromChild: [Int32] = [-1, -1]
        try #require(pipe(&toChild) == 0)
        try #require(pipe(&fromChild) == 0)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The dup2 file action is what hands the lock over, and deliberately
        // NOT `makeInheritableAcrossExec()`. `dup2` clears FD_CLOEXEC on the
        // new descriptor in the child by definition, so the parent's fd keeps
        // its O_CLOEXEC — whereas clearing it here would expose this lock to
        // every OTHER `posix_spawn` in the process, and a suite running in
        // parallel spawns children constantly. A child of an unrelated test
        // would then inherit this lock and hold it past our own child's exit,
        // reddening the reacquire below. That is a measured flake, not a
        // hypothetical.
        //
        // The lock's dup2 goes first so a later stdio dup2 cannot land on the
        // descriptor it is reading from. Every fd here is above 2 in a test
        // process, but the ordering costs nothing and the failure would be
        // baffling.
        try #require(lock.fileDescriptor > 2)
        // `dup2(fd, fd)` is a no-op that succeeds WITHOUT clearing FD_CLOEXEC,
        // so if the lock already sits on the target number the descriptor is
        // closed at exec, `echo K >&9` fails, and the child dies before it can
        // report — read() then returns EOF and this test fails for a reason
        // that has nothing to do with locking. Whether the lock lands on 9
        // depends on how many descriptors sibling tests hold open at the time,
        // which is why this only reddens when the suite runs together.
        //
        // `F_DUPFD_CLOEXEC` hands back the lowest free number at or above its
        // argument, which is past the target, and keeps the duplicate
        // close-on-exec — a plain `dup` would clear FD_CLOEXEC and expose this
        // lock to every other concurrent `posix_spawn` in the process.
        //
        // **The duplicate must be closed before the reacquire below, not by a
        // trailing `defer`.** `flock` lives on the open file description, and a
        // `dup` shares one: while this descriptor is open, the parent still
        // holds the child's lock, so the reacquire throws `.alreadyHeld`
        // against a claim userspace never dropped. That is a measured flake,
        // and its trigger is that `lock.fileDescriptor` happened to land on 9 —
        // which depends on how many descriptors sibling suites hold open, so it
        // fires only when the suite runs alongside others.
        var lockSource = lock.fileDescriptor
        var duplicated: Int32 = -1
        if lockSource == 9 {
            duplicated = fcntl(lockSource, F_DUPFD_CLOEXEC, 10)
            try #require(duplicated >= 0, "could not move the lock off the target descriptor")
            lockSource = duplicated
        }
        defer { if duplicated >= 0 { close(duplicated) } }
        // File actions run IN ORDER, and the ordering here is load-bearing.
        //
        // The closes come first: pipe fds are handed out by number, and under a
        // parallel suite either unwanted end can land on 9. Closing after the
        // lock's dup2 would then destroy the descriptor we just placed there —
        // `echo K >&9` fails, a non-interactive shell exits on a redirection
        // error, and the parent sees EOF instead of the ready byte. That is a
        // fd-numbering coincidence, so it reddens only when siblings run
        // alongside and hold enough descriptors open.
        //
        // The stdio dup2s come next, before the lock's, so that if a pipe end
        // occupies 9 it has already been copied to its final home by the time
        // the lock overwrites it.
        posix_spawn_file_actions_addclose(&actions, toChild[1])
        posix_spawn_file_actions_addclose(&actions, fromChild[0])
        posix_spawn_file_actions_adddup2(&actions, toChild[0], 0)
        posix_spawn_file_actions_adddup2(&actions, fromChild[1], 1)
        posix_spawn_file_actions_adddup2(&actions, lockSource, 9)

        var pid: pid_t = 0
        let arguments = ["sh", "-c", script]
        var argv = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for arg in argv { free(arg) } }
        let spawned = posix_spawn(&pid, "/bin/sh", &actions, nil, &argv, nil)
        close(toChild[0])
        close(fromChild[1])
        try #require(spawned == 0, "posix_spawn failed with code \(spawned)")
        // A child parked in `read` never exits on its own, and an orphan here
        // compounds across runs. Guarded on `reaped` so a pid this test already
        // waited on can never be signalled after the number is recycled.
        var reaped = false
        defer {
            if !reaped {
                kill(pid, SIGKILL)
                var discarded: Int32 = 0
                _ = waitpid(pid, &discarded, 0)
            }
        }

        var ready = [UInt8](repeating: 0, count: 1)
        try #require(read(fromChild[0], &ready, 1) == 1, "child never reported that it was up")
        #expect(ready[0] == UInt8(ascii: "R"))

        // The inherited descriptor is the lock. If fd 9 never reached the
        // child, this file is empty and everything below would pass vacuously.
        let marker = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(
            marker == Data("K\n".utf8),
            "the lock descriptor did not survive exec, so the child never held the lock")

        // From here the child is the sole holder — which means dropping EVERY
        // descriptor this process has on that open file description, not just
        // the one `release()` knows about.
        lock.release()
        parentStillHoldsLock = false
        if duplicated >= 0 {
            close(duplicated)
            duplicated = -1
        }
        close(toChild[1])

        var status: Int32 = 0
        for _ in 0..<500 where !reaped {
            if waitpid(pid, &status, WNOHANG) == pid {
                reaped = true
            } else {
                usleep(10_000)
            }
        }
        close(fromChild[0])
        try #require(reaped, "child did not exit within 5s of losing its stdin")

        // Nothing in userspace released that lock. If the kernel did not drop
        // it when the process died, this throws `.alreadyHeld` against a pid
        // that no longer exists — a session UUID unreclaimable for the life of
        // the machine.
        let reacquired = try HolderLock.acquire(path: path)
        reacquired.release()
        #expect(reacquired.fileDescriptor >= 0)
    }
}
