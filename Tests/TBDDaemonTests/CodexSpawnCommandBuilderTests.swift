import Testing
import Foundation
@testable import TBDDaemonLib
import TBDShared

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
    @Test("every launch selects the tbd profile with --profile")
    func launchUsesProfileFlag() {
        #expect(
            CodexSpawnCommandBuilder.build(initialPrompt: nil, executablePath: "codex")
                == "unset CODEX_CI CODEX_THREAD_ID; 'codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        )
        #expect(
            CodexSpawnCommandBuilder.command(executablePath: "/opt/bin/codex")
                == "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        )
    }

    @Test("the bare command reapplies the options a tab was launched with")
    func bareCommandReappliesLaunchOptions() {
        #expect(
            CodexSpawnCommandBuilder.command(
                executablePath: "/opt/bin/codex",
                launchOptions: CodexLaunchOptions(
                    model: "acme-model", disabledFeatures: ["computer_use"]))
                == #"unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd -c 'model="acme-model"' --disable 'computer_use' --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"#
        )
    }

    @Test("resolved executable is shell escaped in the spawn command")
    func shellEscapesResolvedExecutable() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                executablePath: "/Applications/ChatGPT Preview.app/Contents/Resources/codex"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; '/Applications/ChatGPT Preview.app/Contents/Resources/codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        )
    }

    @Test("initial prompt is appended as a shell-escaped trailing argument")
    func appendsInitialPrompt() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: "fix the failing test",
                executablePath: "codex"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; 'codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -- 'fix the failing test'"
        )
    }

    /// Codex parses an argument that starts with `-` as an option even when
    /// the shell passes it as one quoted word, so the prompt follows `--`:
    /// `- fix it` would fail to parse, and `--config=…` would set a
    /// configuration override for the session.
    @Test("a prompt that looks like an option follows the end of options")
    func optionLookingPromptFollowsEndOfOptions() {
        let base = "unset CODEX_CI CODEX_THREAD_ID; 'codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        #expect(CodexSpawnCommandBuilder.build(initialPrompt: "- fix it", executablePath: "codex")
            == "\(base) -- '- fix it'")
        #expect(CodexSpawnCommandBuilder.build(
            initialPrompt: #"--config=notify=["touch","x"]"#, executablePath: "codex")
            == #"\#(base) -- '--config=notify=["touch","x"]'"#)
        // No prompt, no marker.
        #expect(CodexSpawnCommandBuilder.build(initialPrompt: "", executablePath: "codex") == base)
        #expect(CodexSpawnCommandBuilder.build(initialPrompt: nil, executablePath: "codex") == base)
    }

    @Test("resume thread is appended without an initial prompt")
    func appendsResumeThread() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                resumeThreadID: "thread-123",
                executablePath: "/opt/bin/codex"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume 'thread-123'"
        )
    }

    /// A resumed session with a first message: the subcommand and its thread,
    /// then the message after `--`, so the message is never read as an
    /// option of `resume`.
    @Test("a prompt on a resumed session follows the thread and the end of options")
    func resumeWithPromptPutsThePromptAfterTheEndOfOptions() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: "fix the failing test",
                resumeThreadID: "thread-123",
                executablePath: "/opt/bin/codex"
            )
                == "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume 'thread-123' -- 'fix the failing test'"
        )
    }

    /// A first message that is exactly the name of a Codex subcommand stays
    /// the message: it lands after `--`, where Codex reads it as the prompt
    /// and never runs `completion` or `logout`.
    @Test("a prompt that names a subcommand follows the end of options", arguments: ["completion", "logout"])
    func subcommandNamedPromptFollowsEndOfOptions(_ prompt: String) {
        let base = "unset CODEX_CI CODEX_THREAD_ID; 'codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"
        #expect(CodexSpawnCommandBuilder.build(initialPrompt: prompt, executablePath: "codex")
            == "\(base) -- '\(prompt)'")
        #expect(CodexSpawnCommandBuilder.build(
            initialPrompt: prompt, resumeThreadID: "thread-123", executablePath: "codex")
            == "\(base) resume 'thread-123' -- '\(prompt)'")
    }

    @Test("nil resume thread preserves the ordinary launch command")
    func nilResumePreservesLaunch() {
        let ordinary = CodexSpawnCommandBuilder.build(
            initialPrompt: nil,
            executablePath: "/opt/bin/codex")
        let explicitNil = CodexSpawnCommandBuilder.build(
            initialPrompt: nil,
            resumeThreadID: nil,
            executablePath: "/opt/bin/codex")

        #expect(explicitNil == ordinary)
    }

    @Test("no model override is byte-identical to the existing launch command")
    func nilModelIsByteIdentical() {
        let expected = "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -- 'ship it'"
        #expect(CodexSpawnCommandBuilder.build(
            initialPrompt: "ship it",
            executablePath: "/opt/bin/codex") == expected)
        #expect(CodexSpawnCommandBuilder.build(
            initialPrompt: "ship it",
            executablePath: "/opt/bin/codex", model: nil) == expected)
        // An empty identifier is no override, never `-c 'model=""'`.
        #expect(CodexSpawnCommandBuilder.build(
            initialPrompt: "ship it",
            executablePath: "/opt/bin/codex", model: "") == expected)
    }

    @Test("a model override sits between the profile and the bypass flag, before the prompt")
    func modelOverridePlacement() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: "ship it",
                executablePath: "/opt/bin/codex",
                model: "acme-model"
            )
                == #"unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd -c 'model="acme-model"' --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -- 'ship it'"#
        )
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                resumeThreadID: "thread-123",
                executablePath: "/opt/bin/codex",
                model: "acme-model"
            )
                == #"unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd -c 'model="acme-model"' --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume 'thread-123'"#
        )
    }

    @Test("a model override is one shell argument holding a TOML string, whatever it contains")
    func modelOverrideEscaping() {
        // A single quote must not end the shell argument; a double quote or
        // backslash must not end the TOML string.
        #expect(
            CodexSpawnCommandBuilder.modelOverrideArgument(#"acme's "x"\y"#)
                == #"'model="acme'\''s \"x\"\\y"'"#
        )
        // A numeric-looking identifier stays a string rather than a TOML float.
        #expect(CodexSpawnCommandBuilder.modelOverrideArgument("1.5") == #"'model="1.5"'"#)
        #expect(CodexSpawnCommandBuilder.modelOverrideArgument("a\u{1}b") == #"'model="a\u0001b"'"#)
        #expect(CodexSpawnCommandBuilder.modelOverrideArgument(nil) == nil)
    }

    @Test("no disabled features is byte-identical to the existing launch command")
    func emptyDisabledFeaturesIsByteIdentical() {
        let expected = "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -- 'ship it'"
        #expect(CodexSpawnCommandBuilder.build(
            initialPrompt: "ship it",
            executablePath: "/opt/bin/codex", disabledFeatures: []) == expected)
    }

    @Test("each disabled feature is its own --disable argument, before the bypass flag and the prompt")
    func disabledFeaturePlacement() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: "ship it",
                executablePath: "/opt/bin/codex",
                disabledFeatures: ["computer_use", "browser_use"])
                == "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --disable 'computer_use' --disable 'browser_use' --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust -- 'ship it'"
        )
        // With a model: the model override comes first, then the features.
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                executablePath: "/opt/bin/codex", model: "acme-model",
                disabledFeatures: ["apps"])
                == #"unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd -c 'model="acme-model"' --disable 'apps' --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust"#
        )
    }

    @Test("disabled features precede the resume subcommand")
    func disabledFeaturesPrecedeResume() {
        #expect(
            CodexSpawnCommandBuilder.build(
                initialPrompt: nil,
                resumeThreadID: "thread-123",
                executablePath: "/opt/bin/codex",
                disabledFeatures: ["computer_use"])
                == "unset CODEX_CI CODEX_THREAD_ID; '/opt/bin/codex' --profile tbd --disable 'computer_use' --no-daemon --dangerously-bypass-approvals-and-sandbox --dangerously-bypass-hook-trust resume 'thread-123'"
        )
    }

    /// `--no-daemon` is a global Codex option, so it must come before the
    /// `resume` subcommand for Codex to parse it.
    @Test("--no-daemon precedes the resume subcommand")
    func noDaemonPrecedesResume() throws {
        let command = CodexSpawnCommandBuilder.build(
            initialPrompt: nil,
            resumeThreadID: "thread-1",
            executablePath: "/opt/bin/codex")
        #expect(command.contains(" --no-daemon "))
        let noDaemon = try #require(command.range(of: " --no-daemon "))
        let resume = try #require(command.range(of: " resume "))
        #expect(noDaemon.lowerBound < resume.lowerBound)
    }
}
