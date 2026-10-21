import Foundation
import Testing
import TestSupport
@testable import TBDDaemonLib
import TBDShared

/// The guard the whole design decision rests on: the statusline tee is
/// installed on desk sessions and on nothing else.
///
/// TBD's per-session `--settings` file outranks the operator's `statusLine` in
/// every scope they can write, so a leak here would silently take over a
/// display slot the operator owns in every session they open. The non-desk case
/// is therefore asserted as **byte-identical** to the overlay produced without
/// the parameter at all, not merely as "no statusLine key" — a weaker assertion
/// would let some other difference ride along unnoticed.
///
/// Nested under `TBDHomeSerialized`: the per-session overlay writes go through
/// the process-global `TBD_HOME`.
extension TBDHomeSerialized {
@Suite struct StatuslineTeeOverlayGateTests {

    private struct Scratch {
        let home: URL
        let prior: String?
        init() {
            home = FileManager.default.temporaryDirectory
                .appendingPathComponent("tbd-tee-gate-\(UUID().uuidString)")
            prior = setTBDHome(home.path)
        }
        func cleanUp() {
            restoreTBDHome(prior)
            try? FileManager.default.removeItem(at: home)
        }
    }

    private func statusLine(inOverlayAt path: String) throws -> [String: Any]? {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        return parsed?["statusLine"] as? [String: Any]
    }

    @Test func deskSpawnGetsTheTeeStatusLine() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: key,
            watchDeskRole: .readOnlyCoordinator,
            worktreePath: nil
        )

        // A desk with no fallback models and no fragments still gets a
        // per-session overlay, because the tee's capture path is per session.
        #expect(path != ClaudeHookOverlay.overlayPath)
        let entry = try #require(try statusLine(inOverlayAt: path))
        #expect(entry["type"] as? String == "command")
        let command = try #require(entry["command"] as? String)
        #expect(command.contains(StatuslineTee.scriptPath))
        #expect(command.contains(StatuslineTee.capturePath(sessionKey: key)))
    }

    @Test func judgeRoleAlsoCountsAsADesk() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: UUID().uuidString, watchDeskRole: .judge)
        #expect(try statusLine(inOverlayAt: path) != nil)
    }

    @Test func nonDeskSpawnOverlayIsByteIdenticalToTodays() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let models = ["claude-haiku-4-5-20251001"]
        let fragment = #"{"skillOverrides":{"x":"off"}}"#

        // Explicit nil role, and the parameter omitted entirely: both must
        // produce exactly the bytes the overlay had before the tee existed.
        let withNilRole = try ClaudeHookOverlay.generateBody(
            fallbackModels: models,
            extraSettings: ["skillOverrides": ["x": "off"]],
            statusLineCommand: nil
        )
        let withoutParameter = try ClaudeHookOverlay.generateBody(
            fallbackModels: models,
            extraSettings: ["skillOverrides": ["x": "off"]]
        )
        #expect(withNilRole == withoutParameter)

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: models,
            sessionKey: UUID().uuidString,
            extraSettingsJSON: fragment
        )
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == withoutParameter)
        #expect(try statusLine(inOverlayAt: path) == nil)
    }

    @Test func nonDeskSpawnWithNothingElseStillUsesTheSharedGlobalOverlay() {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        // The tee is the only reason a bare spawn would need a per-session
        // file, so a non-desk bare spawn must still take the shared path.
        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: UUID().uuidString)
        #expect(path == ClaudeHookOverlay.overlayPath)
    }

    @Test func fragmentSuppliedStatusLineBecomesTheDelegateRatherThanBeingClobbered() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let operatorCommand = "~/bin/my-statusline.sh --fancy"
        let fragment = #"{"statusLine":{"type":"command","command":"\#(operatorCommand)"}}"#

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: key,
            extraSettingsJSON: fragment,
            watchDeskRole: .readOnlyCoordinator
        )

        let entry = try #require(try statusLine(inOverlayAt: path))
        let command = try #require(entry["command"] as? String)
        // The tee wins the slot — and carries the operator's command as its
        // delegate, so nothing they configured stops being displayed.
        #expect(command.contains(StatuslineTee.scriptPath))
        #expect(command.contains(operatorCommand))
    }

    @Test func aFragmentStatusLineOnANonDeskSpawnIsLeftExactlyAsGiven() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let operatorCommand = "~/bin/my-statusline.sh"
        let fragment = #"{"statusLine":{"type":"command","command":"\#(operatorCommand)"}}"#

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: UUID().uuidString, extraSettingsJSON: fragment)

        let entry = try #require(try statusLine(inOverlayAt: path))
        #expect(entry["command"] as? String == operatorCommand)
    }

    // MARK: - A desk spawn carrying the session mod's `usage`

    private func sessionMod(_ features: [SessionModFeature]) -> SessionModSpawnContext {
        SessionModSpawnContext(features: features, incarnationID: UUID(), environment: [:])
    }

    private func seedCapture(sessionKey: String) throws -> String {
        let capturePath = StatuslineTee.capturePath(sessionKey: sessionKey)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: capturePath).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data(#"{"context_window":{"context_window_size":200000}}"#.utf8)
            .write(to: URL(fileURLWithPath: capturePath))
        return capturePath
    }

    /// The decision keys on the features the spawn was given, so a spawn whose
    /// `prepare` returned nil — every feature off, an unsafe session ID, a
    /// spawn record that could not be written — has no `usage` and gets the
    /// tee.
    @Test func theTeeDecisionKeysOnTheSpawnsOwnFeatures() {
        #expect(ClaudeHookOverlay.installsStatuslineTee(carrying: nil))
        #expect(ClaudeHookOverlay.installsStatuslineTee(carrying: sessionMod([.composerDraft])))
        #expect(!ClaudeHookOverlay.installsStatuslineTee(carrying: sessionMod([.usage])))
        #expect(!ClaudeHookOverlay.installsStatuslineTee(
            carrying: sessionMod([.composerDraft, .usage])))
    }

    @Test func aDeskSpawnCarryingUsageKeepsThePersonsOwnStatusLine() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let operatorCommand = "~/bin/my-statusline.sh"
        let fragment = #"{"statusLine":{"type":"command","command":"\#(operatorCommand)"}}"#

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil,
            sessionKey: UUID().uuidString,
            extraSettingsJSON: fragment,
            watchDeskRole: .readOnlyCoordinator,
            statuslineTee: false)

        // The fragment's statusline stands exactly as given — no tee wraps it.
        let entry = try #require(try statusLine(inOverlayAt: path))
        #expect(entry["command"] as? String == operatorCommand)
    }

    @Test func aDeskSpawnCarryingUsageWithNothingElseHasNoStatusLineKey() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString

        let path = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: key,
            watchDeskRole: .readOnlyCoordinator, statuslineTee: false)

        // Still a per-session file, so a replacement spawn's command can name
        // this path before its features are known…
        #expect(path == ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key))
        // …whose body is the one any session without fragments gets.
        let written = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(written == (try ClaudeHookOverlay.generateBody()))
        #expect(try statusLine(inOverlayAt: path) == nil)
    }

    @Test func aDeskSpawnCarryingUsageDeletesTheCaptureFromAPreviousLife() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)

        _ = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: nil, sessionKey: key,
            watchDeskRole: .readOnlyCoordinator, statuslineTee: false)

        #expect(!FileManager.default.fileExists(atPath: capturePath))
    }

    /// `statuslineTee` only ever withholds a tee a desk role would install, so
    /// a non-desk overlay is the same bytes whichever way it is passed.
    @Test func statuslineTeeHasNoEffectOnANonDeskSpawn() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let models = ["claude-haiku-4-5-20251001"]
        let key = UUID().uuidString

        let withTee = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: models, sessionKey: key, statuslineTee: true)
        let teeBytes = try Data(contentsOf: URL(fileURLWithPath: withTee))
        let withoutTee = ClaudeHookOverlay.resolveOverlayPath(
            fallbackModels: models, sessionKey: key, statuslineTee: false)
        let noTeeBytes = try Data(contentsOf: URL(fileURLWithPath: withoutTee))

        #expect(withTee == withoutTee)
        #expect(teeBytes == noTeeBytes)
        #expect(teeBytes == (try ClaudeHookOverlay.generateBody(fallbackModels: models)))
        #expect(try statusLine(inOverlayAt: withTee) == nil)
    }

    // MARK: - A replacement spawn's overlay is written at launch

    private func replacementOverlay(
        sessionKey: String, role: WatchDeskRole?, fallbackModels: [String]? = nil,
        repoSettingsJSON: String? = nil
    ) -> ReplacementSpawnOverlay {
        ReplacementSpawnOverlay.plan(
            fallbackModels: fallbackModels,
            sessionKey: sessionKey,
            repoSettingsJSON: repoSettingsJSON,
            watchDeskRole: role,
            worktreePath: nil,
            profileConfigDir: nil,
            promptAnswerHooks: false)
    }

    /// Writes `bytes` where the session's per-session overlay lives, standing
    /// in for the overlay a running process was launched with.
    private func seedOverlay(sessionKey: String, _ bytes: Data) throws -> String {
        let path = ClaudeHookOverlay.perSessionOverlayPath(sessionKey: sessionKey)
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: path).deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try bytes.write(to: URL(fileURLWithPath: path))
        return path
    }

    private static let runningOverlay = Data(#"{"previous":"life"}"#.utf8)
    private static let command = "claude --resume s"

    private func commandNaming(_ path: String) -> String {
        "\(Self.command) --settings \(SystemPromptBuilder.shellEscape(path))"
    }

    /// Planning is what a spawn that never launches does — a wake that adopts
    /// a holder still running, a swap that fails before its replacement
    /// starts — so it must leave the running process's overlay and capture as
    /// they are.
    @Test func planningWritesNothingAndDeletesNothing() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)
        let overlayPath = try seedOverlay(sessionKey: key, Self.runningOverlay)

        let overlay = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)

        #expect(overlay.path == overlayPath)
        #expect(overlay.isPerSession)
        #expect(try Data(contentsOf: URL(fileURLWithPath: overlayPath)) == Self.runningOverlay)
        #expect(FileManager.default.fileExists(atPath: capturePath))
    }

    /// The command is composed before `settle` writes the file, so the
    /// builder must be told the planned path will exist — otherwise a first
    /// launch would drop `--settings`, and with it every TBD hook.
    @Test func theCommandNamesThePlannedPathBeforeItExists() {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let overlay = replacementOverlay(sessionKey: UUID().uuidString, role: .readOnlyCoordinator)
        #expect(!FileManager.default.fileExists(atPath: overlay.path))

        let spawn = ClaudeSpawnCommandBuilder.build(
            resumeID: "s", freshSessionID: nil, appendSystemPrompt: nil, initialPrompt: nil,
            profileSecret: nil, cmd: nil, shellFallback: "",
            settingsOverlayPath: overlay.path, fileExists: overlay.commandFileExists)

        #expect(spawn.command.contains(" --settings \(SystemPromptBuilder.shellEscape(overlay.path))"))
        // Anything else is still asked of the disk.
        #expect(!overlay.commandFileExists("/nonexistent/\(UUID().uuidString)"))
    }

    /// The spawn has no `usage` — `prepare` returned nil — so the desk gets
    /// the tee, written at launch on the file its command already names.
    @Test func settlingADeskLaunchedWithoutUsageInstallsTheTee() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)
        let command = commandNaming(overlay.path)

        #expect(overlay.settle(carrying: nil, command: command) == command)

        let entry = try #require(try statusLine(inOverlayAt: overlay.path),
                                 "settling a usage-less spawn left the desk without its tee")
        let teeCommand = try #require(entry["command"] as? String)
        #expect(teeCommand.contains(StatuslineTee.scriptPath))
        #expect(teeCommand.contains(StatuslineTee.capturePath(sessionKey: key)))
    }

    @Test func settlingADeskLaunchedWithUsageDropsTheTeeAndTheCapture() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)
        _ = try seedOverlay(sessionKey: key, Self.runningOverlay)
        let overlay = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)
        let command = commandNaming(overlay.path)

        #expect(overlay.settle(carrying: sessionMod([.usage]), command: command) == command)

        #expect(try Data(contentsOf: URL(fileURLWithPath: overlay.path))
                == (try ClaudeHookOverlay.generateBody()))
        #expect(!FileManager.default.fileExists(atPath: capturePath))
    }

    /// A tee desk's relaunch still drops the previous process's capture: its
    /// window may differ (a swap to a smaller profile), and the new tee
    /// republishes its own when it fires.
    @Test func settlingADeskLaunchedWithTheTeeDeletesTheOldCapture() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)
        let overlay = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)

        _ = overlay.settle(carrying: sessionMod([.composerDraft]), command: Self.command)

        #expect(try statusLine(inOverlayAt: overlay.path) != nil)
        #expect(!FileManager.default.fileExists(atPath: capturePath),
                "a tee desk's relaunch kept an earlier process's capture")
    }

    @Test func settlingANonDeskOverlayNeverInstallsATee() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key, role: nil)
        #expect(!overlay.isPerSession)
        #expect(overlay.path == ClaudeHookOverlay.overlayPath)

        #expect(overlay.settle(carrying: nil, command: Self.command) == Self.command)

        // No per-session file appeared: a non-desk never gets a tee, whatever
        // its session mod turned out to be.
        #expect(!FileManager.default.fileExists(
            atPath: ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key)))
    }

    /// A non-desk with fallback models gets a per-session file too, and it is
    /// written at launch as well, not when planned.
    @Test func aNonDeskPerSessionOverlayIsAlsoWrittenOnlyAtLaunch() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let models = ["claude-haiku-4-5-20251001"]
        let overlay = replacementOverlay(sessionKey: key, role: nil, fallbackModels: models)
        #expect(overlay.isPerSession)
        #expect(!FileManager.default.fileExists(atPath: overlay.path))

        _ = overlay.settle(carrying: nil, command: commandNaming(overlay.path))

        #expect(try Data(contentsOf: URL(fileURLWithPath: overlay.path))
                == (try ClaudeHookOverlay.generateBody(fallbackModels: models)))
    }

    /// The model proxy decides before the launch whether the overlay will set
    /// `ANTHROPIC_BASE_URL`, so the answer comes from the planned body — not
    /// from a file that does not exist yet, or that holds another process's.
    @Test func theRoutingQuestionIsAnsweredFromThePlanNotTheFile() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let setsURL = #"{"env":{"ANTHROPIC_BASE_URL":"https://proxy.acme.test"}}"#
        _ = try seedOverlay(sessionKey: key, Data(setsURL.utf8))

        let plain = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)
        #expect(!plain.setsEnv("ANTHROPIC_BASE_URL"),
                "the routing question read the running process's overlay")

        let other = UUID().uuidString
        let routed = replacementOverlay(
            sessionKey: other, role: nil, repoSettingsJSON: setsURL)
        #expect(routed.setsEnv("ANTHROPIC_BASE_URL"))
        #expect(!FileManager.default.fileExists(atPath: routed.path),
                "answering the routing question wrote the overlay")
    }

    /// When the per-session write fails at launch, `resolveOverlayPath` falls
    /// back to the global overlay, and the command must follow it rather than
    /// name a file that is missing or still holds an earlier process's overlay.
    @Test func aFailedWriteAtLaunchRepointsTheCommandAwayFromThePlannedFile() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)
        // A directory where the file belongs: the atomic write cannot replace it.
        try FileManager.default.createDirectory(
            atPath: overlay.path, withIntermediateDirectories: true)
        let planned = " --settings \(SystemPromptBuilder.shellEscape(overlay.path))"

        let launched = overlay.settle(carrying: nil, command: commandNaming(overlay.path))

        #expect(!launched.contains(planned), "the command still names the file that was not written")
        #expect(launched.hasPrefix(Self.command))
        if FileManager.default.fileExists(atPath: ClaudeHookOverlay.overlayPath) {
            #expect(launched.contains(
                " --settings \(SystemPromptBuilder.shellEscape(ClaudeHookOverlay.overlayPath))"))
        } else {
            #expect(!launched.contains("--settings"))
        }
    }

    /// A desk that planned a tee but launches on the global overlay runs
    /// without one, so the capture an earlier process published must not
    /// survive to be read as this process's window — the removal must not
    /// depend on the write succeeding.
    @Test func aFailedWriteAtLaunchDropsTheCaptureOfADeskThatPlannedATee() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)
        let overlay = replacementOverlay(sessionKey: key, role: .readOnlyCoordinator)
        try FileManager.default.createDirectory(
            atPath: overlay.path, withIntermediateDirectories: true)

        _ = overlay.settle(carrying: nil, command: commandNaming(overlay.path))

        #expect(!FileManager.default.fileExists(atPath: capturePath),
                "a launch without a tee kept an earlier process's capture")
    }

    @Test func repointingFollowsTheBuildersRuleForAMissingFile() {
        let from = "/runtime/claude-overlay-session-x.json"
        let to = "/runtime/claude-overlay.json"
        let command = "claude --settings \(SystemPromptBuilder.shellEscape(from)) --name n"

        #expect(ReplacementSpawnOverlay.repointSettings(
            in: command, from: from, to: to, fileExists: { _ in true })
            == "claude --settings \(SystemPromptBuilder.shellEscape(to)) --name n")
        #expect(ReplacementSpawnOverlay.repointSettings(
            in: command, from: from, to: to, fileExists: { _ in false })
            == "claude --name n")
    }
}
}
