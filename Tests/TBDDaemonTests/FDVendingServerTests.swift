import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

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
