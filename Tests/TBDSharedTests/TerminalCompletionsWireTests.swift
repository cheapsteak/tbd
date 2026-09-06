import Foundation
import Testing
@testable import TBDShared

/// The `terminal.completions` payload. Everything about it is designed for one
/// property: the app treats a probe result and a filesystem-scan result
/// identically, so a fallback needs no second code path in the UI.
@Suite("terminal.completions wire")
struct TerminalCompletionsWireTests {

    @Test func aCommandWithNoAliasesDecodesToAnEmptyList() throws {
        let json = #"{"name":"compact","description":"Compact the conversation"}"#
        let command = try JSONDecoder().decode(
            CompletionCommand.self, from: Data(json.utf8))
        #expect(command.aliases.isEmpty)
        #expect(command.argumentHint == nil)
    }

    @Test func aCommandRoundTripsEveryField() throws {
        let command = CompletionCommand(
            name: "code-review", description: "Review the current diff",
            argumentHint: "[low|medium|high]", aliases: ["review"])
        let decoded = try JSONDecoder().decode(
            CompletionCommand.self, from: JSONEncoder().encode(command))
        #expect(decoded == command)
    }

    @Test func theResultRoundTripsWithItsMarkers() throws {
        let result = TerminalCompletionsResult(
            commands: [CompletionCommand(name: "compact", description: "d")],
            agents: [CompletionAgent(name: "Explore", description: "d")],
            freshness: .fallback, source: .scan)
        let decoded = try JSONDecoder().decode(
            TerminalCompletionsResult.self, from: JSONEncoder().encode(result))
        #expect(decoded == result)
        #expect(decoded.freshness == .fallback)
        #expect(decoded.source == .scan)
    }

    @Test func theMarkersHaveStableRawValues() {
        #expect(CompletionFreshness.fresh.rawValue == "fresh")
        #expect(CompletionFreshness.stale.rawValue == "stale")
        #expect(CompletionFreshness.fallback.rawValue == "fallback")
        #expect(CompletionSource.probe.rawValue == "probe")
        #expect(CompletionSource.scan.rawValue == "scan")
    }
}
