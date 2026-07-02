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
        try pair.withUnsafeMutableBufferPointer { buf in
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
