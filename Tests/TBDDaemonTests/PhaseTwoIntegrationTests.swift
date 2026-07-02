import Darwin
import Foundation
import Testing
@testable import TBDDaemonLib
import TBDShared

/// Proves the full Phase 2 data path against a real tmux server: live tmux
/// output → control-mode connection (reader thread) → PaneFanout pipe →
/// sidecar-vended fd → assertion. Bypasses RPCRouter wiring (covered by
/// AttachRPCOrchestrationTests) and drives the pieces directly.
@Suite("Phase 2 end-to-end")
struct PhaseTwoIntegrationTests {

    @discardableResult
    private func tmux(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["tmux"] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }

    private func makeSocketPair() throws -> (Int32, Int32) {
        var pair: [Int32] = [-1, -1]
        try pair.withUnsafeMutableBufferPointer { buf in
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, buf.baseAddress) == 0 else {
                throw FDChannelError.sendFailed(errno)
            }
        }
        return (pair[0], pair[1])
    }

    @Test("live tmux output reaches a socketpair-vended read fd after attach.ready")
    func liveOutputReachesVendedFD() async throws {
        guard let version = await TmuxVersion.detect(),
              version >= TmuxVersion.controlModeMinimum else {
            return  // tmux missing or too old — skip
        }

        let server = "tbd-e2e-\(UUID().uuidString.prefix(8))"
        defer { tmux(["-L", server, "kill-server"]) }
        try #require(
            tmux(["-L", server, "new-session", "-d", "-s", "main", "-x", "80", "-y", "24"]),
            "failed to bootstrap test tmux server")

        // Ask tmux for the pane id we'll attach against.
        let listOutput = Pipe()
        let listProc = Process()
        listProc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        listProc.arguments = ["tmux", "-L", server, "list-panes", "-F", "#{pane_id}"]
        listProc.standardOutput = listOutput
        try listProc.run()
        listProc.waitUntilExit()
        let listData = listOutput.fileHandleForReading.readDataToEndOfFile()
        let paneID = (String(bytes: listData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(paneID.hasPrefix("%"))

        // Wire the daemon-side pieces manually.
        let supervisor = TmuxControlSupervisor()
        await supervisor.ensureConnection(serverName: server)
        try await Task.sleep(for: .milliseconds(300))  // let the -CC connection settle

        let (readFD, _) = try await supervisor.attach(server: server, paneID: paneID)

        let (daemonSideSocket, appSideSocket) = try makeSocketPair()
        defer { Darwin.close(appSideSocket) }
        let vending = FDVendingServer()
        await vending.adoptConnection(fd: daemonSideSocket)
        let header = try JSONEncoder().encode(FDVendHeader(worktreeID: UUID(), paneID: paneID, attachID: UUID()))
        try await vending.send(fd: readFD, header: header)
        Darwin.close(readFD)  // daemon can drop its copy

        let (rxFD, _) = try FDChannel.receiveFD(from: appSideSocket, headerCapacity: 256)
        defer { Darwin.close(rxFD) }

        // Now signal ready and drive a marker through tmux.
        await supervisor.markReady(server: server, paneID: paneID)
        let marker = "TBDPHASE2-\(UUID().uuidString.prefix(6))"
        tmux(["-L", server, "send-keys", "printf %s '\(marker)'", "Enter"])

        // Read from the vended fd (nonblocking) until the marker shows up or
        // we time out. The pipe read end blocks by default; flip it so the
        // poll loop can interleave sleeps.
        let flags = fcntl(rxFD, F_GETFL)
        _ = fcntl(rxFD, F_SETFL, flags | O_NONBLOCK)
        let deadline = ContinuousClock.now + .seconds(5)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while ContinuousClock.now < deadline {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(rxFD, $0.baseAddress, $0.count) }
            if n > 0 { received.append(contentsOf: buffer[0..<Int(n)]) }
            if received.range(of: Data(marker.utf8)) != nil { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            received.range(of: Data(marker.utf8)) != nil,
            "expected marker \(marker) on the vended read fd; got \(received.count) bytes")

        await supervisor.stopAll()
        await vending.stop()
    }
}
