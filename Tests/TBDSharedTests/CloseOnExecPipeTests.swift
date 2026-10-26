import Darwin
import Foundation
import Testing
@testable import TBDShared

/// `Pipe.closeOnExec()` marks both ends `FD_CLOEXEC`, and a plain `Pipe()`
/// marks neither — the second fact is what keeps the first from being vacuous.
@Suite struct CloseOnExecPipeTests {
    private func isCloseOnExec(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFD)
        return flags >= 0 && (flags & FD_CLOEXEC) != 0
    }

    @Test func aPlainPipeLeavesBothEndsInheritable() {
        let pipe = Pipe()
        #expect(!isCloseOnExec(pipe.fileHandleForReading.fileDescriptor))
        #expect(!isCloseOnExec(pipe.fileHandleForWriting.fileDescriptor))
    }

    @Test func closeOnExecMarksBothEnds() throws {
        let pipe = try Pipe.closeOnExec()
        #expect(isCloseOnExec(pipe.fileHandleForReading.fileDescriptor))
        #expect(isCloseOnExec(pipe.fileHandleForWriting.fileDescriptor))
    }
}
