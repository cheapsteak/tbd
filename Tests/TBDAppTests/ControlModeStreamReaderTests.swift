import Darwin
import Foundation
import Testing
@testable import TBDApp

@Suite("ControlModeStreamReader")
struct ControlModeStreamReaderTests {

    @Test("bytes written to the pipe reach the on-chunk callback; EOF ends the reader")
    func deliversChunks() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            guard pipe(buf.baseAddress) == 0 else { throw NSError(domain: "pipe", code: 0) }
        }
        let (readFD, writeFD) = (fds[0], fds[1])
        // NOTE: no defer-close of readFD — the reader thread owns it and
        // closes it when the loop exits (double-closing a reused fd number
        // is a cross-test hazard under `swift test --parallel`).

        let inbox = ChunkInbox()
        let reader = ControlModeStreamReader(routingKey: "wt/%1", fd: readFD) { data in
            Task { await inbox.append(data) }
        }
        reader.start()

        _ = Data("hello".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        _ = Data("world".utf8).withUnsafeBytes { Darwin.write(writeFD, $0.baseAddress, $0.count) }
        try await Task.sleep(for: .milliseconds(200))
        Darwin.close(writeFD)   // EOF → reader exits and closes readFD itself
        try await Task.sleep(for: .milliseconds(200))

        let combined = await inbox.combined
        #expect(combined == Data("helloworld".utf8))
    }

    @Test("registry hands out a single reader per routing key")
    func registryIdempotent() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            _ = pipe(buf.baseAddress)
        }
        let writeFD = fds[1]

        let registry = ControlModeReaderRegistry()
        let one = await registry.registerReader(routingKey: "wt/%1", fd: fds[0]) { _ in }
        let two = await registry.reader(for: "wt/%1")
        #expect(one === two)
        await registry.remove(routingKey: "wt/%1")   // flags stop; fd stays with the reader
        let none = await registry.reader(for: "wt/%1")
        #expect(none == nil)

        // Close the write end so the flagged reader unblocks via EOF and
        // closes its own fd (mirrors the daemon-side pane.detach).
        Darwin.close(writeFD)
        try await Task.sleep(for: .milliseconds(200))
    }

    @Test("registry removal is generation-scoped: a stale remove cannot stop a successor's reader (R10-4)")
    func registryRemoveIsGenerationScoped() async throws {
        var fds: [Int32] = [-1, -1]
        try fds.withUnsafeMutableBufferPointer { buf in
            _ = pipe(buf.baseAddress)
        }
        let writeFD = fds[1]

        let registry = ControlModeReaderRegistry()
        let fresh = await registry.registerReader(
            routingKey: "wt/%1", fd: fds[0], generation: 2) { _ in }

        // A stale cleanup (attach generation 1) lands after the fresh
        // registration: it must NOT stop or forget the successor.
        await registry.remove(routingKey: "wt/%1", generation: 1)
        let survivor = await registry.reader(for: "wt/%1")
        #expect(survivor === fresh, "stale remove stopped the successor's reader")

        // The matching generation removes; a repeat is a no-op.
        await registry.remove(routingKey: "wt/%1", generation: 2)
        #expect(await registry.reader(for: "wt/%1") == nil)
        await registry.remove(routingKey: "wt/%1", generation: 2)

        // Generation-less registrations cannot be discriminated: any remove
        // clears them (back-compat with attaches that vended no generation).
        var fds2: [Int32] = [-1, -1]
        try fds2.withUnsafeMutableBufferPointer { buf in
            _ = pipe(buf.baseAddress)
        }
        let writeFD2 = fds2[1]
        await registry.registerReader(routingKey: "wt/%2", fd: fds2[0]) { _ in }
        await registry.remove(routingKey: "wt/%2", generation: 7)
        #expect(await registry.reader(for: "wt/%2") == nil)

        Darwin.close(writeFD)
        Darwin.close(writeFD2)
        try await Task.sleep(for: .milliseconds(200))
    }
}

private actor ChunkInbox {
    private(set) var combined = Data()
    func append(_ chunk: Data) { combined.append(chunk) }
}
