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
        let (readFD, _) = try fanout.attach(key: key)
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
        let (readFD, _) = try fanout.attach(key: key)
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
        let (readA, _) = try fanout.attach(key: keyA)
        defer { Darwin.close(readA) }
        let (readB, _) = try fanout.attach(key: keyB)
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
        let (readFD, _) = try fanout.attach(key: key)
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

    @Test("a stale ready-timeout from a superseded attach does not kill the fresh attach")
    func staleTimeoutIsGenerationScoped() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%11")

        // Attach #1 (its ready-timeout timer would hold generation g1)…
        let (read1, gen1) = try fanout.attach(key: key)
        defer { Darwin.close(read1) }
        // …superseded by attach #2 before #1's timer fires.
        let (read2, gen2) = try fanout.attach(key: key)
        defer { Darwin.close(read2) }
        #expect(gen2 > gen1)

        // #1's stale timer fires while #2 is still un-acked: must be a no-op.
        fanout.detachIfNotReady(key: key, generation: gen1)
        fanout.markReady(key: key)
        fanout.route(server: server, event: .output(paneID: "%11", bytes: Data("alive".utf8)))
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(read2, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<Int(count)]) == Data("alive".utf8), "fresh attach must survive the stale timer")

        // A CURRENT-generation timer on an un-acked sink still tears down.
        let key2 = PaneKey(server: server, paneID: "%12")
        let (read3, gen3) = try fanout.attach(key: key2)
        defer { Darwin.close(read3) }
        fanout.detachIfNotReady(key: key2, generation: gen3)
        var eofBuffer = [UInt8](repeating: 0, count: 8)
        let eof = eofBuffer.withUnsafeMutableBytes { Darwin.read(read3, $0.baseAddress, $0.count) }
        #expect(eof == 0, "un-acked attach with a live timer must be torn down (EOF)")
    }

    @Test("detachIfGeneration removes on match, no-ops on mismatch or missing sink")
    func generationCheckedDetach() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%30")
        let (read1, gen1) = try fanout.attach(key: key)
        defer { Darwin.close(read1) }
        // A newer attach replaces the sink (gen2 > gen1).
        let (read2, gen2) = try fanout.attach(key: key)
        defer { Darwin.close(read2) }

        // Mismatch (a stale attach's failure cleanup): no-op — the fresh
        // sink survives and still routes.
        #expect(fanout.detachIfGeneration(key: key, generation: gen1) == false)
        fanout.markReady(key: key)
        fanout.route(server: server, event: .output(paneID: "%30", bytes: Data("alive".utf8)))
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(read2, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<max(count, 0)]) == Data("alive".utf8),
                "newer sink must survive a stale generation-checked detach")

        // Match (the failed attach still owns the sink): removes + closes.
        #expect(fanout.detachIfGeneration(key: key, generation: gen2) == true)
        var eofBuffer = [UInt8](repeating: 0, count: 8)
        let eof = eofBuffer.withUnsafeMutableBytes { Darwin.read(read2, $0.baseAddress, $0.count) }
        #expect(eof == 0, "matching generation must detach (EOF)")

        // Missing sink: no-op, false.
        #expect(fanout.detachIfGeneration(key: key, generation: gen2) == false)
    }

    @Test("an ACKED attach survives the ready-timeout even while not yet ready (replay in flight)")
    func ackedAttachSurvivesReadyTimeout() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%20")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }

        // attach.ready arrived (M4.3 step 2) — the replay is still in flight,
        // so the gate is NOT open yet…
        #expect(fanout.acknowledge(key: key) == .acknowledged(generation: gen))
        #expect(fanout.isReady(key: key) == false)

        // …and the ready-timeout firing NOW must not tear the attach down.
        fanout.detachIfNotReady(key: key, generation: gen)

        // Still alive: no EOF (nonblocking read yields EAGAIN, not 0), and
        // the replay path still reaches the pipe.
        let flags = fcntl(readFD, F_GETFL)
        _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK)
        var buffer = [UInt8](repeating: 0, count: 8)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(n < 0 && errno == EAGAIN, "acked attach must survive the timer")
        try fanout.writeReplay(key: key, generation: gen, bytes: Data("replay".utf8))
        let m = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<max(m, 0)]) == Data("replay".utf8))
    }

    @Test("acknowledge reports noSink for a pane with no live attach")
    func acknowledgeUnattachedReturnsNoSink() {
        let fanout = PaneFanout()
        #expect(fanout.acknowledge(key: PaneKey(server: server, paneID: "%404")) == .noSink)
    }

    @Test("a mismatched expectedGeneration is superseded and leaves the successor un-acked")
    func acknowledgeMismatchedGenerationIsSuperseded() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%22")
        let (read1, gen1) = try fanout.attach(key: key)
        defer { Darwin.close(read1) }
        let (read2, gen2) = try fanout.attach(key: key)   // successor
        defer { Darwin.close(read2) }

        // The stale ack (echoing gen 1) must not touch the gen-2 sink…
        #expect(fanout.acknowledge(key: key, expectedGeneration: gen1) == .superseded)
        // …not even its acknowledged flag: the successor's ready-timeout must
        // still stand guard, so detachIfNotReady still tears it down.
        fanout.detachIfNotReady(key: key, generation: gen2)
        var buffer = [UInt8](repeating: 0, count: 8)
        let n = buffer.withUnsafeMutableBytes { Darwin.read(read2, $0.baseAddress, $0.count) }
        #expect(n == 0, "successor must still be un-acked (timer detach EOFs it)")

        // A MATCHING expectedGeneration acknowledges normally.
        let (read3, gen3) = try fanout.attach(key: key)
        defer { Darwin.close(read3) }
        #expect(fanout.acknowledge(key: key, expectedGeneration: gen3)
                == .acknowledged(generation: gen3))
    }

    @Test("markReady implies acknowledged: a ready sink survives the timer too")
    func readySinkSurvivesTimer() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%21")
        let (readFD, gen) = try fanout.attach(key: key)
        defer { Darwin.close(readFD) }
        fanout.markReady(key: key)
        fanout.detachIfNotReady(key: key, generation: gen)
        fanout.route(server: server, event: .output(paneID: "%21", bytes: Data("alive".utf8)))
        var buffer = [UInt8](repeating: 0, count: 16)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(Data(buffer[0..<max(count, 0)]) == Data("alive".utf8))
    }

    @Test("a chunk larger than the pipe buffer delivers an intact prefix and drops the rest")
    func partialWriteDropsTailNotMiddle() throws {
        let fanout = PaneFanout()
        let key = PaneKey(server: server, paneID: "%7")
        let (readFD, _) = try fanout.attach(key: key)
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
        let (readFD, generation) = try await supervisor.attach(server: "srv", paneID: "%1")
        defer { Darwin.close(readFD) }
        #expect(await supervisor.isReady(server: "srv", paneID: "%1") == false)
        // acknowledgeAttach returns the attach's current generation (M4.3).
        #expect(await supervisor.acknowledgeAttach(server: "srv", paneID: "%1")
                == .acknowledged(generation: generation))
        await supervisor.markReady(server: "srv", paneID: "%1")
        #expect(await supervisor.isReady(server: "srv", paneID: "%1") == true)
        await supervisor.detach(server: "srv", paneID: "%1")
        var buffer = [UInt8](repeating: 0, count: 8)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(readFD, $0.baseAddress, $0.count) }
        #expect(count == 0)
    }
}
