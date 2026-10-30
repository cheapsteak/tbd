import ArgumentParser
import Foundation
import Testing

@testable import TBDCLI
@testable import TBDShared

/// Tier 1. An RPC the daemon answered with `startHeld` becomes
/// `held: <reason>` on stderr and exit 75, whichever command asked.
@Suite("StartHeld CLI mapping")
struct StartHeldMappingTests {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }

    @Test func aHeldStartPrintsTheReasonAndExits75() {
        let sink = Lines()
        let response = RPCResponse(
            error: "camera in use", code: RPCErrorCode.startHeld.rawValue)

        do {
            try SocketClient.requireSuccess(response, stderr: sink.append)
            Issue.record("a held start must throw")
        } catch let exit as ExitCode {
            #expect(exit.rawValue == 75)
        } catch {
            Issue.record("expected an ExitCode, got \(error)")
        }
        #expect(sink.all == ["held: camera in use\n"])
    }

    @Test func exitCodeIsEXTempFail() {
        #expect(StartHeld.exitCode == 75)
    }

    @Test func anyOtherFailureKeepsItsErrorAndPrintsNothing() {
        let sink = Lines()
        for response in [
            RPCResponse(error: "Terminal not found"),
            RPCResponse(error: "busy", code: RPCErrorCode.terminalBusy.rawValue),
        ] {
            do {
                try SocketClient.requireSuccess(response, stderr: sink.append)
                Issue.record("a failure must throw")
            } catch CLIError.rpcError(let message) {
                #expect(message == response.error)
            } catch {
                Issue.record("expected CLIError.rpcError, got \(error)")
            }
        }
        #expect(sink.all.isEmpty)
    }

    @Test func aSuccessThrowsNothing() throws {
        let sink = Lines()
        try SocketClient.requireSuccess(.ok(), stderr: sink.append)
        #expect(sink.all.isEmpty)
    }

    @Test func theCodeDecidesNotTheProse() {
        let prose = RPCResponse(error: "held: looks like a hold but carries no code")
        #expect(StartHeld.stderrLine(for: prose) == nil)
    }
}
