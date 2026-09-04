import Darwin
import Foundation

/// A real pty pair whose slave is in raw mode and never read, so the master
/// refuses at `TTYHOG − 2` (measured: 1,022 bytes on arm64 macOS) exactly as a
/// session whose agent has stopped draining does.
///
/// **No child process.** All test targets compile into one process and Swift
/// Testing runs suites in parallel, so `fork`/`forkpty` here would be a
/// multithreaded fork and a stray process on a shared box. The kernel path
/// under test — `ptcwrite` refusing once the slave's queues hold `TTYHOG − 2`
/// with `ICANON` off — is a property of the line discipline, not of who owns
/// the slave, so holding the slave in-process exercises the same code.
///
/// `posix_openpt` rather than `openpty`: the latter lives in `util.h`, which
/// is not reliably in Darwin's module map from Swift.
///
/// The two ends are spelled `ptyFD` and `sessionEnd` rather than by their
/// POSIX names, for the reason `HolderProtocol.swift` gives for the holder's
/// verbs: SwiftLint's `inclusive_language` rule refuses those words in a
/// *declaration*, and a suppression is worse than a name whose doc comment
/// says which end it is. `ptyFD` matches what production holds
/// (`HolderAttachment.ptyFD`, a dup of the master); `sessionEnd` matches what
/// the sibling panel fixture calls the far end. Prose below still says
/// "master" and "slave", because that is what the kernel calls them.
final class RawPTYPair {
    /// The master end — what a panel writes through.
    let ptyFD: Int32
    /// The slave end, held open and unread so the master's queue stays full.
    let sessionEnd: Int32

    init() throws {
        let m = posix_openpt(O_RDWR | O_NOCTTY)
        guard m >= 0, grantpt(m) == 0, unlockpt(m) == 0,
              let name = ptsname(m)
        else { throw Failure.openFailed(errno) }
        let s = Darwin.open(name, O_RDWR | O_NOCTTY)
        guard s >= 0 else { Darwin.close(m); throw Failure.openFailed(errno) }
        // Raw mode is the whole point: the 1,022-byte ceiling binds only with
        // ICANON off. In canonical mode a MiB goes through with no short write
        // and every assertion below passes vacuously.
        var t = termios()
        tcgetattr(s, &t)
        cfmakeraw(&t)
        tcsetattr(s, TCSANOW, &t)
        // The vended descriptor is O_NONBLOCK in production and the flag rides
        // the dup; a blocking master here would hang the test rather than
        // refuse.
        _ = fcntl(m, F_SETFL, fcntl(m, F_GETFL, 0) | O_NONBLOCK)
        ptyFD = m
        sessionEnd = s
    }

    enum Failure: Error { case openFailed(Int32) }

    /// Writes until the kernel refuses, and reports how many bytes it took.
    /// Never assert on the number: 1,022 is measured on one kernel, and a
    /// hard-coded ceiling turns a kernel change into a red test rather than a
    /// finding.
    @discardableResult
    func fillPTY() -> Int {
        var total = 0
        let chunk = [UInt8](repeating: 0x61, count: 4096)
        while true {
            let n = chunk.withUnsafeBytes { Darwin.write(ptyFD, $0.baseAddress, $0.count) }
            if n > 0 { total += n; continue }
            if n < 0 && errno == EINTR { continue }
            return total
        }
    }

    /// Reads up to `maxBytes` off the slave, which is what makes room on the
    /// master — the child draining, in one call.
    func drainSession(_ maxBytes: Int) -> Data {
        var buffer = [UInt8](repeating: 0, count: maxBytes)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(sessionEnd, $0.baseAddress, maxBytes) }
        return n > 0 ? Data(buffer[0..<n]) : Data()
    }

    /// Reads everything the slave has, in bounded slices. Used to reassemble a
    /// payload the panel wrote across several drains.
    func drainSessionFully(within milliseconds: Int32 = 2000) -> Data {
        var out = Data()
        var remaining = milliseconds
        while remaining > 0 {
            var watched = pollfd(fd: sessionEnd, events: Int16(POLLIN), revents: 0)
            guard poll(&watched, 1, 10) > 0 else { remaining -= 10; continue }
            let chunk = drainSession(64 * 1024)
            if chunk.isEmpty { break }
            out.append(chunk)
        }
        return out
    }

    func close() {
        Darwin.close(sessionEnd)
        Darwin.close(ptyFD)
    }
}
