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
    /// Both ends are closed exactly once, and a test may close the session end
    /// early (`closeSessionEnd()`) to make the master return `EIO`. Without
    /// these flags the `close()` in a `defer` would close a number the kernel
    /// has already reissued — and every test target compiles into one process,
    /// so the new owner would be another suite's socket or file.
    private var sessionEndIsOpen = true
    private var ptyIsOpen = true

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
        // And the session end, so a read that finds nothing returns instead of
        // parking the caller. `drainSessionFully` polls first and would be
        // fine either way, but `drainAll`/`drainUntil` read until the queue is
        // empty — on a blocking slave that last read never returns, and on the
        // main actor it takes the drain notifier's own queue down with it.
        // Nothing about the 1,022-byte ceiling depends on this flag: it is a
        // property of the line discipline, not of how the reader waits.
        _ = fcntl(s, F_SETFL, fcntl(s, F_GETFL, 0) | O_NONBLOCK)
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

    /// Reads everything the slave has right now and reports how much that was.
    ///
    /// Used to learn *this* kernel's ceiling rather than hard-coding 1,022: the
    /// number is measured on one arm64 macOS and a test that asserts on it
    /// turns a kernel change into a red run instead of a finding.
    @discardableResult
    func drainAll() -> Int {
        var total = 0
        while true {
            let chunk = drainSession(64 * 1024)
            if chunk.isEmpty { return total }
            total += chunk.count
        }
    }

    /// Reads the slave until `byteCount` bytes have arrived, yielding the main
    /// actor between reads so the panel's drain notifier — a `DispatchSource`
    /// on the main queue — can run and write the next slice.
    ///
    /// The yield is the point. A synchronous poll loop on the main actor would
    /// block the very queue that delivers write-readiness, and the remainder
    /// would never move; this is why the helper is `async` and `@MainActor`
    /// rather than a sibling of `drainSessionFully`.
    ///
    /// A deadline that passes throws `DrainTimeout` carrying what was expected
    /// and what actually arrived, so "the remainder never landed" is a named
    /// failure with the observed prefix length in it rather than a hang.
    @MainActor
    func drainUntil(byteCount: Int, within: Duration = .seconds(5)) async throws -> Data {
        var out = Data()
        let deadline = ContinuousClock.now.advanced(by: within)
        while out.count < byteCount {
            let chunk = drainSession(64 * 1024)
            if !chunk.isEmpty {
                out.append(chunk)
                continue
            }
            guard ContinuousClock.now < deadline else {
                throw DrainTimeout(expected: byteCount, observed: out.count)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        return out
    }

    /// Closes the slave and leaves the master open, so every later write to the
    /// master returns `EIO` — the line discipline's report that the child is
    /// gone. `close()` stays correct over it.
    func closeSessionEnd() {
        guard sessionEndIsOpen else { return }
        sessionEndIsOpen = false
        Darwin.close(sessionEnd)
    }

    func close() {
        closeSessionEnd()
        guard ptyIsOpen else { return }
        ptyIsOpen = false
        Darwin.close(ptyFD)
    }
}

/// What `drainUntil` throws when the session end never saw the bytes it was
/// promised. Carries observed against expected, because the count that did
/// arrive is what tells a truncation from a stall.
struct DrainTimeout: Error, CustomStringConvertible {
    let expected: Int
    let observed: Int

    var description: String {
        "the session end never received \(expected) bytes; \(observed) arrived"
    }
}
