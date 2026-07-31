import Testing
import Foundation
@testable import TBDDaemonLib

@Suite("CodexExecutableResolver")
struct CodexExecutableResolverTests {
    @Test("configured absolute executable override wins before PATH and fallback")
    func configuredOverrideWins() throws {
        var checked: [String] = []

        let result = try CodexExecutableResolver.resolve(
            configuredOverride: "/opt/tbd/bin/codex",
            searchPath: "/first/bin:/second/bin",
            currentDirectory: "/worktree",
            fallbackPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
            isExecutable: { candidate in
                checked.append(candidate)
                return true
            }
        )

        #expect(result == "/opt/tbd/bin/codex")
        #expect(checked == ["/opt/tbd/bin/codex"])
    }

    @Test("relative configured override fails without falling back to PATH")
    func relativeConfiguredOverrideFails() {
        var checked: [String] = []

        do {
            _ = try CodexExecutableResolver.resolve(
                configuredOverride: "tools/codex",
                searchPath: "/usr/bin:/bin",
                currentDirectory: "/worktree",
                isExecutable: { candidate in
                    checked.append(candidate)
                    return true
                }
            )
            Issue.record("Expected relative Codex executable override to fail")
        } catch let error as CodexExecutableResolutionError {
            #expect(error == .invalidOverride(
                environmentKey: CodexExecutableResolver.executableOverrideEnvironmentKey,
                value: "tools/codex",
                reason: "the path must be absolute"
            ))
            #expect(error.localizedDescription.contains("absolute"))
            #expect(error.localizedDescription.contains("unset it"))
            #expect(error.localizedDescription.contains("restart TBD"))
            #expect(checked.isEmpty)
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("non-executable configured override fails without falling back")
    func nonExecutableConfiguredOverrideFails() {
        var checked: [String] = []

        do {
            _ = try CodexExecutableResolver.resolve(
                configuredOverride: "/missing/codex",
                searchPath: "/usr/bin:/bin",
                currentDirectory: "/worktree",
                isExecutable: { candidate in
                    checked.append(candidate)
                    return candidate == "/usr/bin/codex"
                }
            )
            Issue.record("Expected non-executable Codex override to fail")
        } catch let error as CodexExecutableResolutionError {
            #expect(error == .invalidOverride(
                environmentKey: CodexExecutableResolver.executableOverrideEnvironmentKey,
                value: "/missing/codex",
                reason: "the path is not executable"
            ))
            #expect(error.localizedDescription.contains("TBD_CODEX_EXECUTABLE"))
            #expect(error.localizedDescription.contains("executable"))
            #expect(checked == ["/missing/codex"])
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("empty configured override behaves as unset")
    func emptyConfiguredOverrideUsesPath() throws {
        let result = try CodexExecutableResolver.resolve(
            configuredOverride: "",
            searchPath: "/usr/bin",
            currentDirectory: "/worktree",
            isExecutable: { $0 == "/usr/bin/codex" }
        )

        #expect(result == "/usr/bin/codex")
    }

    @Test("an executable directory is rejected as an override")
    func executableDirectoryIsRejected() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "tbd-codex-directory-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        do {
            _ = try CodexExecutableResolver.resolve(
                configuredOverride: directory.path,
                searchPath: "",
                currentDirectory: directory.deletingLastPathComponent().path)
            Issue.record("Expected a directory override to be rejected")
        } catch let error as CodexExecutableResolutionError {
            #expect(error == .invalidOverride(
                environmentKey: CodexExecutableResolver.executableOverrideEnvironmentKey,
                value: directory.path,
                reason: "the path is not executable"
            ))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("PATH entries win over the ChatGPT.app fallback")
    func pathEntriesWinInOrder() throws {
        var checked: [String] = []

        let result = try CodexExecutableResolver.resolve(
            searchPath: "/first/bin:/second/bin",
            currentDirectory: "/worktree",
            fallbackPath: "/Applications/ChatGPT.app/Contents/Resources/codex",
            isExecutable: { candidate in
                checked.append(candidate)
                return candidate == "/second/bin/codex"
            }
        )

        #expect(result == "/second/bin/codex")
        #expect(checked == ["/first/bin/codex", "/second/bin/codex"])
    }

    @Test("ChatGPT.app CLI is used when PATH has no executable Codex")
    func fallsBackToChatGPTBundle() throws {
        let result = try CodexExecutableResolver.resolve(
            searchPath: "/usr/bin:/bin",
            currentDirectory: "/worktree",
            isExecutable: { $0 == CodexExecutableResolver.chatGPTBundlePath }
        )

        #expect(result == CodexExecutableResolver.chatGPTBundlePath)
    }

    @Test("relative and empty PATH entries cannot resolve a worktree-local executable")
    func relativeAndEmptyPathEntriesAreIgnored() throws {
        var checked: [String] = []
        let result = try CodexExecutableResolver.resolve(
            searchPath: "tools::/usr/bin",
            currentDirectory: "/tmp/project",
            isExecutable: { candidate in
                checked.append(candidate)
                return candidate == CodexExecutableResolver.chatGPTBundlePath
            }
        )

        #expect(result == CodexExecutableResolver.chatGPTBundlePath)
        #expect(!checked.contains("/tmp/project/tools/codex"))
        #expect(!checked.contains("/tmp/project/codex"))
        #expect(checked.contains("/usr/bin/codex"))
    }

    @Test("non-executable candidates produce an actionable error")
    func missingExecutableIsActionable() {
        do {
            _ = try CodexExecutableResolver.resolve(
                searchPath: "/usr/bin:/bin",
                currentDirectory: "/worktree",
                isExecutable: { _ in false }
            )
            Issue.record("Expected Codex executable resolution to fail")
        } catch let error as CodexExecutableResolutionError {
            #expect(error == .notFound(
                searchPath: "/usr/bin:/bin",
                fallbackPath: CodexExecutableResolver.chatGPTBundlePath
            ))
            let message = error.localizedDescription
            #expect(message.contains("ChatGPT.app"))
            #expect(message.contains("PATH"))
            #expect(message.contains("TBD_CODEX_EXECUTABLE"))
            #expect(message.contains("restart TBD"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

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

    @Test("runtime detection probes the resolved absolute executable")
    func detectionUsesResolvedExecutable() {
        var probedArguments: [[String]] = []
        let executable = "/Applications/ChatGPT.app/Contents/Resources/codex"

        let flag = CodexSpawnCommandBuilder.detectProfileFlag(
            executablePath: executable
        ) { arguments in
            probedArguments.append(arguments)
            return "  -p, --profile <CONFIG_PROFILE_V2>"
        }

        #expect(flag == "--profile")
        #expect(probedArguments == [[executable, "--help"]])
    }

    @Test("resolved executable is shell escaped in the spawn command")
    func shellEscapesResolvedExecutable() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                codexHelpOutput: "  -p, --profile <CONFIG_PROFILE_V2>",
                executablePath: "/Applications/ChatGPT Preview.app/Contents/Resources/codex"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; '/Applications/ChatGPT Preview.app/Contents/Resources/codex' --profile tbd --dangerously-bypass-approvals-and-sandbox"
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
