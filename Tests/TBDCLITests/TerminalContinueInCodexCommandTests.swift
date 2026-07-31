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
}
