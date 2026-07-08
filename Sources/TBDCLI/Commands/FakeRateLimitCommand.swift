import ArgumentParser
import Foundation
import TBDShared

/// `tbd hooks fake-rate-limit` — debug/test seam (spec Testing §End-to-end
/// seam): fabricate a `claude.rateLimitDetected` with a near-future reset so
/// schedule → actuate → verify can be exercised without burning a real limit.
/// Run inside a TBD-managed Claude pane (TBD_TERMINAL_ID set) with the
/// Settings toggle ON, then watch the pane get `continue` typed into it
/// ~1-2 minutes after the fake reset.
struct FakeRateLimitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fake-rate-limit",
        abstract: "Debug: fabricate a rate-limit detection with a near-future reset",
        shouldDisplay: false
    )

    @Option(name: .long, help: "Seconds until the fake reset (default 60)")
    var resetsIn: Int = 60

    @Option(name: .long, help: "Terminal ID (defaults to TBD_TERMINAL_ID)")
    var terminal: String?

    @Flag(
        name: .long,
        help: "Fabricate a transient API error instead of a usage limit (--resets-in is ignored — the daemon owns the retry delay)")
    var apiError = false

    mutating func run() async throws {
        let idString = terminal
            ?? ProcessInfo.processInfo.environment["TBD_TERMINAL_ID"]
        guard let idString, let terminalID = UUID(uuidString: idString) else {
            print("fake-rate-limit: no terminal ID (pass --terminal or run inside a TBD pane)")
            return
        }
        let client = SocketClient()
        guard client.isDaemonRunning else {
            print("fake-rate-limit: daemon is not running")
            return
        }

        if apiError {
            let result = try client.call(
                method: RPCMethod.claudeTransientApiErrorDetected,
                params: TransientApiErrorDetectedParams(
                    terminalID: terminalID,
                    errorClass: "debug",
                    rawMessage: "debug: fake transient API error"),
                resultType: TransientApiErrorDetectedResult.self)
            print("fake-rate-limit: transient API error reported; handled=\(result.handled)")
            return
        }

        let resetsAt = Date().addingTimeInterval(TimeInterval(resetsIn))
        try client.callVoid(
            method: RPCMethod.claudeRateLimitDetected,
            params: RateLimitDetectedParams(
                terminalID: terminalID,
                resetsAt: resetsAt,
                limitType: "debug",
                rawMessage: "debug: fake session limit · resets in \(resetsIn)s"))
        print("fake-rate-limit: reported; resetsAt=\(resetsAt) (fire ≈ +60-90s later)")
    }
}
