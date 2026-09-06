import Foundation
import Testing
@testable import TBDApp
import TBDShared

/// The app has never passed `terminal.wake`'s `prompt`, though the CLI, the RPC
/// params, the handler, the coordinator and the spawn builder all carry it. This
/// pins the parameter all the way to the encoded params.
@MainActor
@Suite("wake carries a prompt")
struct WakePromptTests {

    @Test func theParamsCarryThePromptToTheWire() throws {
        let terminalID = UUID()
        let params = TerminalWakeParams(
            terminalID: terminalID, cols: 120, rows: 40,
            fallbackToDefaultProfile: nil, prompt: "ship it")
        let json = try #require(String(
            data: try JSONEncoder().encode(params), encoding: .utf8))
        #expect(json.contains("\"prompt\":\"ship it\""))
    }

    /// A wake with no prompt must encode no `prompt` key at all — an empty string
    /// would become a trailing empty argv on `claude --resume`.
    @Test func anAbsentPromptEncodesNoKey() throws {
        let params = TerminalWakeParams(terminalID: UUID())
        let json = try #require(String(
            data: try JSONEncoder().encode(params), encoding: .utf8))
        #expect(!json.contains("prompt"))
    }

    /// The app-level seam: `wakeTerminal` hands the prompt to the client.
    @Test func appStateForwardsThePrompt() async throws {
        let suiteName = "WakePromptTests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }
        let state = AppState(userDefaults: UserDefaults(suiteName: suiteName)!)

        let recorded = Recorder()
        state.terminalWakeSender = { _, _, _, _, prompt in
            await recorded.record(prompt)
        }

        _ = await state.wakeTerminal(
            terminalID: UUID(), worktreeID: UUID(), userInitiated: true, prompt: "ship it")

        #expect(await recorded.value == "ship it")
    }

    private actor Recorder {
        private(set) var value: String?
        func record(_ prompt: String?) { value = prompt }
    }
}
