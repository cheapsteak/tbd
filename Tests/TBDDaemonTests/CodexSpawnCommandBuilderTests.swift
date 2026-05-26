import Testing
@testable import TBDDaemonLib

@Suite("CodexSpawnCommandBuilder")
struct CodexSpawnCommandBuilderTests {
    @Test("base command remains unchanged when no prompt is supplied")
    func baseCommand() {
        #expect(
            CodexSpawnCommandBuilder.build(initialPrompt: nil)
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox"
        )
    }

    @Test("initial prompt is appended as a shell-escaped trailing argument")
    func appendsInitialPrompt() {
        #expect(
            CodexSpawnCommandBuilder.build(initialPrompt: "fix the failing test")
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox 'fix the failing test'"
        )
    }
}
