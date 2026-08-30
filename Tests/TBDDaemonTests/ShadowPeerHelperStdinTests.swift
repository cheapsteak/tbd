import Darwin
import Foundation
import Testing

@testable import TBDDaemonLib
@testable import TBDShared

/// The handle every fixture below publishes under, so an error's payload is
/// assertable without reaching into the fixture.
private let stdinTestHandle = "h-stdin"

/// One `ShadowPeerHelperProcess` writing into a pipe the test owns both ends
/// of, so the pipe can be filled, drained by an exact amount, and refilled.
private final class ShadowPeerStdinFixture {
    let helper: ShadowPeerHelperProcess
    let pipe = Pipe()
    private let stdoutPipe = Pipe()
    private let reader: ShadowPeerLineReader

    init() throws {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let reader = ShadowPeerLineReader(continuation: continuation)
        self.reader = reader

        // A real, already-exited process: `Process.processIdentifier` is only
        // meaningful once something has been launched, and nothing here reads
        // the pid or terminates the helper. `/usr/bin/true` leaves nothing
        // behind for a reconciler to own.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        // Constructed before anything is written: the initializer is what puts
        // the write end into `O_NONBLOCK`, which is the whole premise.
        helper = ShadowPeerHelperProcess(
            handle: stdinTestHandle,
            process: process,
            stdin: pipe.fileHandleForWriting,
            stdoutHandle: stdoutPipe.fileHandleForReading,
            reader: reader,
            lines: lines,
            socketPath: "/nonexistent/\(UUID().uuidString).sock",
            recordPath: "/nonexistent/\(UUID().uuidString).json",
            exitGrace: .milliseconds(1),
            clock: ContinuousClock())

        // The read end too, so `drainAll` cannot park the test on an empty pipe.
        let readFD = pipe.fileHandleForReading.fileDescriptor
        let flags = fcntl(readFD, F_GETFL)
        if flags >= 0 { _ = fcntl(readFD, F_SETFL, flags | O_NONBLOCK) }
    }

    /// Writes until the pipe refuses more, and returns how many bytes went in.
    /// Bounded so a kernel that never says `EAGAIN` fails the test rather than
    /// hanging it.
    func fillToCapacity() -> Int {
        let fd = pipe.fileHandleForWriting.fileDescriptor
        let chunk = [UInt8](repeating: 0x2E, count: 4096)
        var total = 0
        for _ in 0..<1024 {
            let written = chunk.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress, raw.count)
            }
            if written > 0 {
                total += written
                continue
            }
            if written < 0 && errno == EINTR { continue }
            break
        }
        return total
    }

    /// Frees room for up to `bytes` more, so the next frame is written in part
    /// rather than refused outright.
    func drain(bytes: Int) -> Int {
        let fd = pipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: bytes)
        return buffer.withUnsafeMutableBytes { raw -> Int in
            Darwin.read(fd, raw.baseAddress, raw.count)
        }
    }

    /// Empties the pipe.
    func drainAll() {
        while drain(bytes: 65_536) > 0 {}
    }

    /// A message frame whose encoded line is far larger than any pipe buffer,
    /// so a write into a nearly-full pipe is guaranteed to stop part-way
    /// through it. Well under `maxFrameBytes`, so the codec does not refuse it
    /// first.
    static func oversizedFrame() -> PeerBridgeFrame {
        .message(PeerBridgeMessage(
            id: UUID().uuidString, to: stdinTestHandle, from: "h-remote",
            content: String(repeating: "x", count: 300_000)))
    }

    /// Under `PIPE_BUF`, so a full pipe refuses it whole rather than in part.
    static func smallFrame() -> PeerBridgeFrame {
        .message(PeerBridgeMessage(
            id: "m-1", to: stdinTestHandle, from: "h-remote", content: "ack"))
    }
}

/// What `ShadowPeerHelperProcess.send` does when the helper's stdin pipe fills
/// **mid-frame**.
///
/// The seam is a real pipe rather than an injected writer: the production path
/// writes to an fd it set `O_NONBLOCK` in its own initializer, and the behavior
/// under test is a property of that fd — a non-blocking pipe accepts a *prefix*
/// of a large write. A fake writer would have to model that, which is the bug
/// pretending to be the test. Nothing here binds a socket, spawns a helper, or
/// touches `~/tbd`.
@Suite("Shadow peer helper stdin")
struct ShadowPeerHelperStdinTests {

    /// **A frame that reached the pipe only in part kills the stream.**
    ///
    /// The bytes already committed are the head of an NDJSON line that will
    /// never get its newline, and they cannot be taken back. Before the fix
    /// `closed` stayed `false` after a short write, so the next `send` appended
    /// a whole frame directly onto the truncated line: the helper parsed one
    /// merged line and every frame after it was misaligned.
    @Test func aPartiallyWrittenFrameRetiresStdin() async throws {
        let fixture = try ShadowPeerStdinFixture()
        #expect(fixture.fillToCapacity() > 0, "the pipe never accepted anything")
        // Room for some of the next frame, but nothing like all of it.
        #expect(fixture.drain(bytes: 4096) > 0, "the pipe never gave anything back")

        do {
            try await fixture.helper.send(ShadowPeerStdinFixture.oversizedFrame())
            Issue.record("a 300 KB frame cannot fit in a nearly-full pipe")
        } catch let error as ShadowPeerHelperError {
            #expect(error == .stdinWouldBlock(handle: stdinTestHandle))
        }

        // The discriminator. Draining the pipe completely makes room for the
        // next frame, so a stream that had merely "been busy" would take it —
        // and splice it onto the truncated line already on the pipe.
        fixture.drainAll()
        do {
            try await fixture.helper.send(ShadowPeerStdinFixture.smallFrame())
            Issue.record(
                "a send after a partial write must fail fast rather than splice onto a truncated line")
        } catch let error as ShadowPeerHelperError {
            #expect(error == .stdinGone(handle: stdinTestHandle))
        }
    }

    /// **The negative half.** A frame refused *before any of it landed* leaves
    /// the stream intact: nothing is on the pipe to splice onto, so this is the
    /// ordinary "the helper is not draining" drop, and the channel recovers
    /// once it does. Without this case the fix could be "close stdin on every
    /// `EAGAIN`", which would retire a healthy helper's stdin the first time it
    /// fell behind.
    @Test func aFrameRefusedWholeLeavesStdinUsable() async throws {
        let fixture = try ShadowPeerStdinFixture()
        #expect(fixture.fillToCapacity() > 0, "the pipe never accepted anything")

        do {
            try await fixture.helper.send(ShadowPeerStdinFixture.smallFrame())
            Issue.record("a full pipe cannot take another frame")
        } catch let error as ShadowPeerHelperError {
            #expect(error == .stdinWouldBlock(handle: stdinTestHandle))
        }

        fixture.drainAll()
        // No throw: the stream was never poisoned, so the helper is addressable
        // again the moment it drains.
        try await fixture.helper.send(ShadowPeerStdinFixture.smallFrame())
    }
}
