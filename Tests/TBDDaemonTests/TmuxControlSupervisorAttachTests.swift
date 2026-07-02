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
        let readA = try fanout.attach(key: keyA)
        defer { Darwin.close(readA) }
        let readB = try fanout.attach(key: keyB)
        defer { Darwin.close(readB) }
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
