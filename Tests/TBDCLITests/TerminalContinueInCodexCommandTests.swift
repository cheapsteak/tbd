import ArgumentParser
import Foundation
import TBDShared
import Testing
@testable import TBDCLI

@Suite("tbd terminal continue-in-codex")
struct TerminalContinueInCodexCommandTests {
    private func capture(truncated: Bool = false) -> TerminalContinueInCodexCaptureMetadata {
        TerminalContinueInCodexCaptureMetadata(
            transcriptBytesRead: 65_536,
            transcriptBytesRendered: 8_192,
            handoffBytesOutput: 12_288,
            transcriptTailTruncated: truncated
        )
    }

    @Test func commandIsRegisteredUnderTerminal() {
        let names = TerminalCommand.configuration.subcommands.map {
            $0.configuration.commandName
        }
        #expect(names.contains("continue-in-codex"))
    }

    @Test func parsesRequiredTerminalAndJSONFlag() throws {
        let id = UUID()
        let command = try TerminalContinueInCodex.parse([
            "--terminal", id.uuidString, "--json",
        ])

        #expect(command.terminal == id.uuidString)
        #expect(command.json)
    }

    @Test func requiresTerminal() {
        #expect(throws: (any Error).self) {
            _ = try TerminalContinueInCodex.parse([])
        }
    }

    @Test func createdSummaryIncludesTerminalAndHandoff() {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex
        )
        let result = TerminalContinueInCodexResult(
            terminal: terminal,
            handoffPath: "/private/tmp/CODEX_HANDOFF.md",
            created: true,
            warnings: [],
            capture: capture(truncated: true)
        )

        let summary = continueInCodexSummary(result)
        #expect(summary.contains("Codex takeover launched."))
        #expect(summary.contains("may still be starting while MCPs initialize"))
        #expect(summary.contains(terminal.id.uuidString))
        #expect(summary.contains(result.handoffPath))
        #expect(summary.contains("65536 B read · 8192 B rendered · 12288 B handoff"))
        #expect(summary.contains("tail truncated"))
        #expect(!summary.contains("Warnings:"))
    }

    @Test func reusedSummaryIsExplicit() {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex
        )
        let result = TerminalContinueInCodexResult(
            terminal: terminal,
            handoffPath: "/private/tmp/CODEX_HANDOFF.md",
            created: false,
            warnings: [],
            capture: capture()
        )

        #expect(continueInCodexSummary(result).contains("Existing Codex takeover found."))
    }

    @Test func summarySurfacesReturnedWarnings() {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex
        )
        let result = TerminalContinueInCodexResult(
            terminal: terminal,
            handoffPath: "/private/tmp/CODEX_HANDOFF.md",
            created: true,
            warnings: [
                TerminalContinueInCodexWarning(
                    code: "prompt_ack_timeout",
                    message: "Prompt acknowledgment timed out; Codex may still start."
                ),
                TerminalContinueInCodexWarning(
                    code: "context_reference_missing",
                    message: "One referenced skill path was unavailable."
                ),
            ],
            capture: capture()
        )

        let summary = continueInCodexSummary(result)
        #expect(summary.contains(
            "[prompt_ack_timeout] Prompt acknowledgment timed out; Codex may still start."
        ))
        #expect(summary.contains(
            "[context_reference_missing] One referenced skill path was unavailable."
        ))
    }

    @Test func jsonResultKeepsMachineReadableOutcomeWarningsAndCapture() throws {
        let terminal = Terminal(
            worktreeID: UUID(), tmuxWindowID: "@1", tmuxPaneID: "%1",
            label: TerminalLabel.codex, kind: .codex
        )
        let result = TerminalContinueInCodexResult(
            terminal: terminal,
            handoffPath: "/private/tmp/CODEX_HANDOFF.md",
            created: false,
            warnings: [
                TerminalContinueInCodexWarning(
                    code: "readiness_pending",
                    message: "Codex readiness is pending."
                ),
            ],
            capture: capture(truncated: true)
        )

        // `--json` passes this result directly to `printJSON`; assert the
        // public wire fields scripting clients receive, independently of the
        // human summary wording.
        let data = try JSONEncoder().encode(result)
        let object = try #require(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let terminalObject = try #require(object["terminal"] as? [String: Any])
        let warnings = try #require(object["warnings"] as? [[String: Any]])
        let capture = try #require(object["capture"] as? [String: Any])
        let target = try #require(object["target"] as? [String: Any])

        #expect(object["created"] as? Bool == false)
        #expect(object["handoffPath"] as? String == result.handoffPath)
        #expect(terminalObject["id"] as? String == terminal.id.uuidString)
        #expect(warnings.first?["code"] as? String == "readiness_pending")
        #expect(capture["transcriptBytesRead"] as? Int == 65_536)
        #expect(capture["transcriptTailTruncated"] as? Bool == true)
        #expect(target["kind"] as? String == "local_codex")
    }
}
