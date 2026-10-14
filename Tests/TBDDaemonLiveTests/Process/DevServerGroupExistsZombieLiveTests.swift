import Darwin
import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
@testable import TBDShared

/// Tier 3: a real child in a process group of its own. `kill(-pgid, 0)`
/// succeeds while a dead leader waits to be reaped, so a group that died on
/// SIGKILL would read as surviving it; `groupExists` must not count a zombie.
@Suite("Dev server group liveness (live)")
struct DevServerGroupExistsZombieLiveTests {
    private struct SpawnFailed: Error, CustomStringConvertible {
        let code: Int32
        var description: String { "posix_spawn failed: \(code)" }
    }

    private struct NeverBecameAZombie: Error, CustomStringConvertible {
        let pid: pid_t
        var description: String { "pid \(pid) was not an unreaped zombie within the deadline" }
    }

    /// `/bin/sleep 60` leading a group of its own (`POSIX_SPAWN_SETPGROUP`, 0).
    private func spawnGroupLeader() throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)
        var pid: pid_t = 0
        let arguments: [String] = ["/bin/sleep", "60"]
        var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) }
        argv.append(nil)
        defer { for arg in argv { free(arg) } }
        let code = posix_spawn(&pid, "/bin/sleep", nil, &attributes, &argv, nil)
        guard code == 0 else { throw SpawnFailed(code: code) }
        return pid
    }

    /// Exited and still waitable: `WNOWAIT` probes without reaping.
    private func isUnreapedZombie(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT | WNOHANG) == 0 && info.si_pid == pid
    }

    @Test func aZombieLeaderDoesNotKeepItsGroupAlive() async throws {
        let pid = try spawnGroupLeader()
        var reaped = false
        defer {
            if !reaped {
                _ = kill(pid, SIGKILL)
                var status: Int32 = 0
                _ = waitpid(pid, &status, 0)
            }
        }
        let signalling = ProductionDevServerSignalling()
        #expect(signalling.groupExists(pid), "a running leader's group exists")

        _ = kill(pid, SIGKILL)
        guard case .satisfied = await pollUntilTrue(timeout: TestDeadlines.saturatedPass, { isUnreapedZombie(pid) })
        else { throw NeverBecameAZombie(pid: pid) }
        // Darwin answers ESRCH to kill(-pgid, 0) for a zombie-only group, so
        // the membership read must agree with it rather than outlive it.
        #expect(!signalling.groupExists(pid), "a zombie-only group must read as gone")

        var status: Int32 = 0
        _ = waitpid(pid, &status, 0)
        reaped = true
        #expect(!signalling.groupExists(pid))
    }
}
