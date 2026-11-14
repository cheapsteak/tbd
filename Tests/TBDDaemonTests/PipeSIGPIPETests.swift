import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib

/// `PipeSIGPIPE.suppress(on:)` marks a pipe's write end `F_SETNOSIGPIPE`, so a
/// write after the reader has gone fails with EPIPE and raises no SIGPIPE.
/// Tier 1: pipes in this process, nothing spawned.
///
/// Like `SocketSIGPIPETests`, these read the flag back and never touch the
/// process-wide disposition, which every suite in the process shares. They
/// cover the helper. The production call sites are covered by a read-back
/// through each one's own descriptor, in the suites for the bounded runner,
/// the peer link, the shadow peer helper, the Codex session importer and the
/// Codex usage fetcher (`Tests/CLAUDE.md`, the SIGPIPE entry, lists them).
@Suite("PipeSIGPIPE")
struct PipeSIGPIPETests {

    private func makePipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [-1, -1]
        let created = fds.withUnsafeMutableBufferPointer { buffer in pipe(buffer.baseAddress) == 0 }
        try #require(created, "pipe() failed with errno \(errno)")
        return (fds[0], fds[1])
    }

    @Test("suppress sets F_SETNOSIGPIPE on the write end it is given, and on nothing else")
    func suppressSetsTheFlag() throws {
        let ends = try makePipe()
        defer { Darwin.close(ends.read); Darwin.close(ends.write) }
        let fresh = fcntl(ends.write, F_GETNOSIGPIPE)
        #expect(fresh == 0, "the flag is off on a fresh pipe, so the read-back below can tell")

        #expect(PipeSIGPIPE.suppress(on: ends.write))
        let marked = fcntl(ends.write, F_GETNOSIGPIPE)
        let readEnd = fcntl(ends.read, F_GETNOSIGPIPE)
        #expect(marked == 1)
        #expect(readEnd == 0, "the read end is a separate open file and keeps its own flag")
    }

    /// Through the seam that does not report: the public call would log the
    /// process's one refusal `.fault`, and spending it here would hide the
    /// first real refusal in the same process, besides writing a fault on
    /// every run.
    @Test("suppress reports a descriptor it could not mark")
    func suppressReportsARefusal() {
        #expect(!PipeSIGPIPE.suppress(on: -1, reportRefusal: false))
    }

    /// The mechanism the call sites rely on: with the flag set, the write that
    /// finds the reader gone returns EPIPE. The `#require` is what ties this to
    /// the helper. The write alone cannot: the test host catches SIGPIPE with a
    /// handler (`Tests/TestProcessDefaults/SIGPIPEHandler.c`), so an unmarked
    /// pipe would return the same EPIPE here, and `suppressSetsTheFlag` is what
    /// asserts the flag itself.
    @Test("a write to a marked pipe whose reader has closed fails with EPIPE")
    func writeAfterTheReaderClosesFailsWithEPIPE() throws {
        let ends = try makePipe()
        defer { Darwin.close(ends.write) }
        try #require(PipeSIGPIPE.suppress(on: ends.write))
        Darwin.close(ends.read)

        let byte: [UInt8] = [0x41]
        let written = byte.withUnsafeBytes { buffer in Darwin.write(ends.write, buffer.baseAddress, buffer.count) }
        let failure = errno
        #expect(written == -1)
        #expect(failure == EPIPE)
    }
}
