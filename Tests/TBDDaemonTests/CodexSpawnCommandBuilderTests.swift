import Testing
import Foundation
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

    @Test("runtime detection skips version probe when help identifies the profile flag")
    func detectionSkipsVersionProbeWhenHelpIsEnough() {
        var probedArguments: [[String]] = []

        let flag = CodexSpawnCommandBuilder.detectProfileFlag { arguments in
            probedArguments.append(arguments)
            return "  -p, --profile <CONFIG_PROFILE_V2>"
        }

        #expect(flag == "--profile")
        #expect(probedArguments == [["codex", "--help"]])
    }

    @Test("runtime detection uses version probe only when help is inconclusive")
    func detectionUsesVersionProbeWhenHelpIsInconclusive() {
        var probedArguments: [[String]] = []

        let flag = CodexSpawnCommandBuilder.detectProfileFlag { arguments in
            probedArguments.append(arguments)
            if arguments == ["codex", "--version"] {
                return "codex-cli 0.133.0"
            }
            return "Codex CLI"
        }

        #expect(flag == "--profile-v2")
        #expect(probedArguments == [["codex", "--help"], ["codex", "--version"]])
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

    @Test("command output helper returns stdout and stderr")
    func commandOutputCapturesStdoutAndStderr() {
        let output = CodexSpawnCommandBuilder.commandOutput(
            executable: "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2"],
            timeout: 1
        )

        #expect(output?.contains("stdout") == true)
        #expect(output?.contains("stderr") == true)
    }

    @Test("command output helper times out instead of blocking indefinitely")
    func commandOutputTimesOut() {
        let start = Date()
        let output = CodexSpawnCommandBuilder.commandOutput(
            executable: "/bin/sh",
            arguments: ["-c", "sleep 5"],
            timeout: 0.1
        )

        #expect(output == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
