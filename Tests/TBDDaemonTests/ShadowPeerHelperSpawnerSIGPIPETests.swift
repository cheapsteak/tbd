import Darwin
import Foundation
import Testing
import TestSupport

@testable import TBDDaemonLib
import TBDKernel

/// `ShadowPeerHelperProcessSpawner.spawn` marks the helper's stdin write end
/// `F_SETNOSIGPIPE`: `send` writes frames into it, and a helper that exits
/// under a write fails it with EPIPE, which must raise no SIGPIPE.
///
/// The spawner keeps the write end to itself, so the test reaches it as the
/// pipe peer of the child's stdin (`pipeWriteEnd(peerOf:inProcess:)`) while
/// the child holds that stdin open, and reads the flag back. The child is a
/// stub script in place of `TBDPeerHelper`, which this target does not build:
/// the spawner runs whatever executable it is given, and the flag is set before
/// the child starts. The stdout pipe the stub writes to is not marked, and is
/// not what this reads.
///
/// Tier 2: it spawns one short-lived child, which exits on its stdin's end of
/// file when `terminate()` closes the write end.
@Suite("Shadow peer helper spawner SIGPIPE")
struct ShadowPeerHelperSpawnerSIGPIPETests {

    @Test("spawn marks the helper's stdin write end F_SETNOSIGPIPE")
    func spawnMarksTheStdinWriteEndNoSIGPIPE() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shadow-peer-sigpipe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        // `exec cat` keeps fd 0, the pipe's read end, open until the write end
        // closes, and then exits on the end of file.
        let stub = dir.appendingPathComponent("peer-helper-stub")
        try "#!/bin/sh\nexec cat > /dev/null\n".write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let spawner = ShadowPeerHelperProcessSpawner(
            executablePath: stub.path, exitGrace: .milliseconds(200))
        let helper = try await spawner.spawn(ShadowPeerHelperInvocation(
            handle: "h-sigpipe", name: "acme-laptop:sigpipe %1", status: "working",
            peerProtocol: PeerBridgeFrameCodec.peerProtocol, cwd: dir.path,
            socketDirectory: dir, sessionsDirectory: dir, sessionID: UUID().uuidString))

        let writeEnd = pipeWriteEnd(peerOf: STDIN_FILENO, inProcess: helper.pid)
        let noSIGPIPE = writeEnd.map { fcntl($0, F_GETNOSIGPIPE) }
        await helper.terminate()

        let readBack = noSIGPIPE.map { "F_GETNOSIGPIPE read \($0)" }
            ?? "no descriptor in this process was the pipe peer of the helper's stdin"
        #expect(
            noSIGPIPE == 1,
            "spawn must mark the helper's stdin write end F_SETNOSIGPIPE; \(readBack)")
    }
}
