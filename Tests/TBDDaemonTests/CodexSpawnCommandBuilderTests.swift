import Testing
@testable import TBDDaemonLib

@Suite("CodexSpawnCommandBuilder")
struct CodexSpawnCommandBuilderTests {
    @Test("Codex 0.134 and newer use the renamed --profile flag")
    func modernCodexUsesProfileFlag() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                codexHelpOutput: "  -p, --profile <CONFIG_PROFILE_V2>",
                codexVersionOutput: "codex-cli 0.134.0"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox"
        )
        #expect(
            CodexSpawnCommandBuilder.build(initialPrompt: nil, codexVersionOutput: "codex-cli 0.135.0-alpha.1")
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox"
        )
    }

    @Test("profile-v2 help takes precedence because older Codex uses --profile for legacy profiles")
    func helpWithProfileV2UsesProfileV2EvenWhenProfileAlsoExists() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                codexHelpOutput: """
                  -p, --profile <CONFIG_PROFILE>
                      --profile-v2 <CONFIG_PROFILE_V2>
                """,
                codexVersionOutput: nil
            )
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox"
        )
    }

    @Test("Codex before 0.134 uses the legacy --profile-v2 flag")
    func olderCodexUsesProfileV2Flag() {
        #expect(
            CodexSpawnCommandBuilder.build(initialPrompt: nil, codexVersionOutput: "codex-cli 0.133.0")
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile-v2 tbd --dangerously-bypass-approvals-and-sandbox"
        )
    }

    @Test("missing Codex version output falls back to the current --profile flag")
    func missingVersionFallsBackToProfileFlag() {
        #expect(
            CodexSpawnCommandBuilder.build(initialPrompt: nil, codexVersionOutput: nil)
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox"
        )
    }

    @Test("initial prompt is appended as a shell-escaped trailing argument")
    func appendsInitialPrompt() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: "fix the failing test",
                codexVersionOutput: "codex-cli 0.134.0"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; codex --profile tbd --dangerously-bypass-approvals-and-sandbox 'fix the failing test'"
        )
    }
}
