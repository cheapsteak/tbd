import Foundation
import TBDShared
import Testing
@testable import TBDApp

@Suite("TmuxBridge")
struct TmuxBridgeTests {
    @Test func sessionNameUsesStablePanelIDPrefix() {
        let panelID = UUID(uuidString: "4C4F1A61-F385-46AB-861D-42A425DB427B")!

        #expect(TmuxBridge.sessionName(for: panelID) == "tbd-view-4c4f1a61")
    }

    @Test func isolatedSessionPlanLinksOnlyTargetWindow() {
        let sessionName = "tbd-view-4c4f1a61"

        #expect(TmuxBridge.newIsolatedSessionArgs(sessionName: sessionName) == [
            "new-session", "-d", "-s", sessionName, "-c", "/tmp",
        ])
        #expect(TmuxBridge.linkWindowArgs(windowID: "@147", sessionName: sessionName) == [
            "link-window", "-s", "@147", "-t", "\(sessionName):",
        ])
        #expect(TmuxBridge.killInitialWindowArgs(sessionName: sessionName) == [
            "kill-window", "-t", "\(sessionName):0",
        ])
        #expect(TmuxBridge.selectWindowArgs(windowID: "@147", sessionName: sessionName) == [
            "select-window", "-t", "\(sessionName):@147",
        ])
        #expect(TmuxBridge.remainOnExitArgs(windowID: "@147") == [
            "set-option", "-wt", "@147", "remain-on-exit", "on",
        ])
        #expect(TmuxBridge.remainOnExitFormatArgs(windowID: "@147") == [
            "set-option", "-wt", "@147", "remain-on-exit-format", "",
        ])
        #expect(TmuxBridge.activeWindowQueryArgs(sessionName: sessionName) == [
            "display-message", "-p", "-t", sessionName, "#{window_id}",
        ])
        #expect(TmuxBridge.windowInventoryQueryArgs() == [
            "list-windows", "-a", "-F", "#{window_id}",
        ])
        #expect(TmuxBridge.clientSessionQueryArgs() == [
            "list-clients", "-F", "#{client_session}",
        ])
        #expect(TmuxBridge.killSessionArgs(sessionName: sessionName) == [
            "kill-session", "-t", sessionName,
        ])
        #expect(TmuxBridge.hasSessionArgs(sessionName: sessionName) == [
            "has-session", "-t", sessionName,
        ])
    }

    @Test func commandsObserveSavedFallbackAfterInitializationAndPathStillWins() throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let pathDirectory = try fixture.directory(named: "path")
        let savedExecutable = try fixture.executable(named: "saved-tmux", in: fixture.root)
        let resolver = TmuxExecutableResolver(
            environment: ["PATH": pathDirectory.path],
            configurationURL: fixture.configurationURL
        )
        let bridge = TmuxBridge(tmuxExecutableResolver: resolver)

        #expect(bridge.tmuxCommand(server: "tbd-repo", args: ["list-windows"]) == nil)

        try resolver.save(savedExecutable.path)

        let preparation = try #require(bridge.tmuxCommand(
            server: "tbd-repo",
            args: ["display-message", "-p", "#{window_id}"]
        ))
        let viewer = try #require(bridge.viewerAttachCommand(
            server: "tbd-repo",
            sessionName: "tbd-view-4c4f1a61"
        ))

        #expect(preparation == [
            savedExecutable.path, "-L", "tbd-repo", "display-message", "-p", "#{window_id}",
        ])
        #expect(viewer == [
            savedExecutable.path, "-u", "-L", "tbd-repo", "attach", "-t", "tbd-view-4c4f1a61",
        ])
        #expect(preparation.first == viewer.first)

        let pathExecutable = try fixture.executable(named: "tmux", in: pathDirectory)

        #expect(bridge.tmuxCommand(server: "tbd-repo", args: ["list-windows"])?.first == pathExecutable.path)
        #expect(bridge.viewerAttachCommand(
            server: "tbd-repo",
            sessionName: "tbd-view-4c4f1a61"
        )?.first == pathExecutable.path)
    }

    @Test func unresolvedExecutableProducesNoPreparationOrViewerCommand() throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let bridge = TmuxBridge(tmuxExecutableResolver: TmuxExecutableResolver(
            environment: ["PATH": ""],
            configurationURL: fixture.configurationURL
        ))

        #expect(bridge.tmuxCommand(server: "tbd-repo", args: ["list-windows"]) == nil)
        #expect(bridge.viewerAttachCommand(
            server: "tbd-repo",
            sessionName: "tbd-view-4c4f1a61"
        ) == nil)
    }

    @Test func clientInventoryConfirmsOnlyTheExpectedAttachedSession() {
        #expect(TmuxBridge.clientInventoryConfirmsAttachment(
            querySucceeded: true,
            output: "main\ntbd-view-4c4f1a61",
            expectedSessionName: "tbd-view-4c4f1a61"
        ))
        #expect(!TmuxBridge.clientInventoryConfirmsAttachment(
            querySucceeded: true,
            output: "main",
            expectedSessionName: "tbd-view-4c4f1a61"
        ))
        #expect(!TmuxBridge.clientInventoryConfirmsAttachment(
            querySucceeded: false,
            output: "tbd-view-4c4f1a61",
            expectedSessionName: "tbd-view-4c4f1a61"
        ))
    }

    @Test func preparedSessionCarriesViewerCommand() throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let executable = try fixture.executable(named: "saved-tmux", in: fixture.root)
        let resolver = TmuxExecutableResolver(
            environment: ["PATH": ""],
            configurationURL: fixture.configurationURL
        )
        try resolver.save(executable.path)
        let bridge = TmuxBridge(tmuxExecutableResolver: resolver)
        let prepared = try #require(bridge.preparedSession(
            server: "tbd-repo",
            sessionName: "tbd-view-4c4f1a61"
        ))
        #expect(prepared == TmuxPreparedSession(
            executablePath: executable.path,
            arguments: ["-u", "-L", "tbd-repo", "attach", "-t", "tbd-view-4c4f1a61"]
        ))
    }

    @Test func viewSessionCreationFailureIsGenericWithoutWindowProbe() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .createViewSession,
            output: "create failure",
            probeSucceeded: nil,
            probeOutput: nil,
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .createViewSession, output: "create failure"))
    }

    @Test func failedWindowStageWithInventoryContainingWindowRemainsGeneric() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: true,
            probeOutput: "@999\n@147",
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .linkWindow, output: "link failure"))
    }

    @Test func failedWindowStageWithFailedInventoryProbeRemainsGeneric() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: false,
            probeOutput: "",
            expectedWindowID: "@147"
        ) == .commandFailed(stage: .linkWindow, output: "link failure"))
    }

    @Test func failedWindowStageWithInventoryOmittingWindowMeansMissing() {
        #expect(TmuxBridge.classifyPreparationFailure(
            stage: .linkWindow,
            output: "link failure",
            probeSucceeded: true,
            probeOutput: "@999",
            expectedWindowID: "@147"
        ) == .windowMissing(failedStage: .linkWindow))
    }

    // Tier 2: real filesystem and subprocesses, all contained by the fixture.
    @Test func preparedSessionKeepsExecutableSnapshotForViewerAndCleanup() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let firstLog = fixture.root.appendingPathComponent("first.log")
        let secondLog = fixture.root.appendingPathComponent("second.log")
        let secondExecutable = try fixture.tmuxExecutable(named: "second-tmux", logURL: secondLog)
        let firstExecutable = try fixture.tmuxExecutable(
            named: "first-tmux",
            logURL: firstLog,
            replacement: (configurationURL: fixture.configurationURL, executable: secondExecutable),
            clientSessionName: "tbd-view-4c4f1a61"
        )
        let resolver = TmuxExecutableResolver(
            environment: ["PATH": ""],
            configurationURL: fixture.configurationURL
        )
        try resolver.save(firstExecutable.path)
        let bridge = TmuxBridge(tmuxExecutableResolver: resolver)
        let panelID = UUID(uuidString: "4C4F1A61-F385-46AB-861D-42A425DB427B")!

        let result = await bridge.prepareSession(
            panelID: panelID,
            server: "tbd-repo",
            windowID: "@147"
        )
        let prepared = try result.get()

        #expect(resolver.savedPath == secondExecutable.path)
        #expect(prepared.executablePath == firstExecutable.path)
        #expect(prepared.arguments == [
            "-u", "-L", "tbd-repo", "attach", "-t", TmuxBridge.sessionName(for: panelID),
        ])
        let firstInvocationCount = fixture.lineCount(at: firstLog)
        #expect(firstInvocationCount > 0)
        #expect(fixture.lineCount(at: secondLog) == 0)

        #expect(await bridge.hasAttachedClient(panelID: panelID, server: "tbd-repo"))
        let afterConfirmationInvocationCount = fixture.lineCount(at: firstLog)
        #expect(afterConfirmationInvocationCount == firstInvocationCount + 1)
        #expect(fixture.lineCount(at: secondLog) == 0)

        bridge.cleanupSession(panelID: panelID, server: "tbd-repo")
        try await fixture.waitForLineCount(afterConfirmationInvocationCount + 1, at: firstLog)

        #expect(fixture.lineCount(at: firstLog) == afterConfirmationInvocationCount + 1)
        #expect(fixture.lineCount(at: secondLog) == 0)
        #expect(bridge.tmuxCommand(server: "tbd-repo", args: ["list-windows"])?.first
            == secondExecutable.path)
    }

    @Test func unresolvableTmuxExecutableIsItsOwnFailure() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let resolver = TmuxExecutableResolver(
            environment: ["PATH": ""],
            configurationURL: fixture.root.appendingPathComponent("no-such-saved-path")
        )
        let bridge = TmuxBridge(tmuxExecutableResolver: resolver)

        let result = await bridge.prepareSession(
            panelID: UUID(),
            server: "tbd-repo",
            windowID: "@147"
        )

        guard case .failure(let failure) = result else {
            Issue.record("preparation should fail when no tmux executable resolves")
            return
        }
        #expect(failure == .tmuxExecutableUnavailable)
    }

    @Test func duplicateSessionCreateFailureIsRetriedAfterKillingTheLeftover() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let resolver = try fixture.resolvingResolver()
        let runner = ScriptedTmuxRunner(
            newSessionFailures: 1,
            failureOutput: "duplicate session: tbd-view-4c4f1a61",
            leftoverSessionExists: true
        )
        let bridge = TmuxBridge(
            tmuxExecutableResolver: resolver,
            commandRunner: { _, _, args in await runner.run(args) }
        )
        let panelID = UUID(uuidString: "4C4F1A61-F385-46AB-861D-42A425DB427B")!

        let prepared = try await bridge.prepareSession(
            panelID: panelID,
            server: "tbd-repo",
            windowID: "@147"
        ).get()

        #expect(prepared.arguments == [
            "-u", "-L", "tbd-repo", "attach", "-t", "tbd-view-4c4f1a61",
        ])
        #expect(await runner.verbs == [
            "kill-session",
            "new-session",
            "has-session",
            "kill-session",
            "new-session",
            "link-window",
            "kill-window",
            "select-window",
            "set-option",
            "set-option",
            "display-message",
        ])
    }

    @Test func createFailureWithoutALeftoverSessionIsNotRetried() async throws {
        let fixture = try TmuxBridgeFixture()
        defer { fixture.remove() }
        let resolver = try fixture.resolvingResolver()
        let runner = ScriptedTmuxRunner(
            newSessionFailures: 1,
            failureOutput: "no space left on device",
            leftoverSessionExists: false
        )
        let bridge = TmuxBridge(
            tmuxExecutableResolver: resolver,
            commandRunner: { _, _, args in await runner.run(args) }
        )

        let result = await bridge.prepareSession(
            panelID: UUID(uuidString: "4C4F1A61-F385-46AB-861D-42A425DB427B")!,
            server: "tbd-repo",
            windowID: "@147"
        )

        guard case .failure(let failure) = result else {
            Issue.record("preparation should fail when the view session cannot be created")
            return
        }
        #expect(failure == .commandFailed(
            stage: .createViewSession,
            output: "no space left on device"
        ))
        #expect(await runner.verbs == ["kill-session", "new-session", "has-session"])
    }
}

/// Replies to tmux invocations from a script, so a test can drive a sequence a
/// live server cannot be made to produce on demand — a `new-session` that
/// fails once with `duplicate session:` and succeeds on the retry.
private actor ScriptedTmuxRunner {
    private var invocations: [[String]] = []
    private var remainingNewSessionFailures: Int
    private let failureOutput: String
    private let leftoverSessionExists: Bool

    init(newSessionFailures: Int, failureOutput: String, leftoverSessionExists: Bool) {
        self.remainingNewSessionFailures = newSessionFailures
        self.failureOutput = failureOutput
        self.leftoverSessionExists = leftoverSessionExists
    }

    var verbs: [String] { invocations.compactMap(\.first) }

    func run(_ args: [String]) -> TmuxCommandOutcome {
        invocations.append(args)
        switch args.first {
        case "new-session":
            guard remainingNewSessionFailures > 0 else {
                return TmuxCommandOutcome(success: true, output: "")
            }
            remainingNewSessionFailures -= 1
            return TmuxCommandOutcome(success: false, output: failureOutput)
        case "has-session":
            return TmuxCommandOutcome(
                success: leftoverSessionExists,
                output: leftoverSessionExists ? "" : "can't find session"
            )
        case "display-message":
            return TmuxCommandOutcome(success: true, output: "@147")
        default:
            return TmuxCommandOutcome(success: true, output: "")
        }
    }
}

private struct TmuxBridgeFixture {
    let root: URL
    let configurationURL: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("TmuxBridgeTests-\(UUID().uuidString)", isDirectory: true)
        configurationURL = root.appendingPathComponent("tmux-executable-path")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }

    func directory(named name: String) throws -> URL {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }

    func executable(named name: String, in directory: URL) throws -> URL {
        let executable = directory.appendingPathComponent(name)
        try Data("fixture".utf8).write(to: executable)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func tmuxExecutable(
        named name: String,
        logURL: URL,
        replacement: (configurationURL: URL, executable: URL)? = nil,
        clientSessionName: String? = nil
    ) throws -> URL {
        let executable = root.appendingPathComponent(name)
        let replacementScript: String
        if let replacement {
            replacementScript = "printf '%s' '\(replacement.executable.path)' > '\(replacement.configurationURL.path)'"
        } else {
            replacementScript = ":"
        }
        let clientSessionScript = clientSessionName.map { "printf '%s\\n' '\($0)'" } ?? ":"
        let script = """
        #!/bin/sh
        printf '%s\\n' "$*" >> '\(logURL.path)'
        case "$*" in
          *display-message*)
            \(replacementScript)
            printf '%s\\n' '@147'
            ;;
          *list-clients*)
            \(clientSessionScript)
            ;;
        esac
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: executable.path
        )
        return executable
    }

    /// A resolver that resolves to a stub executable the test never runs
    /// (every command goes through an injected runner instead).
    func resolvingResolver() throws -> TmuxExecutableResolver {
        let resolver = TmuxExecutableResolver(
            environment: ["PATH": ""],
            configurationURL: configurationURL
        )
        try resolver.save(executable(named: "stub-tmux", in: root).path)
        return resolver
    }

    func lineCount(at url: URL) -> Int {
        let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return contents.split(separator: "\n").count
    }

    func waitForLineCount(_ expectedCount: Int, at url: URL) async throws {
        for _ in 0..<100 {
            if lineCount(at: url) >= expectedCount { return }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}
