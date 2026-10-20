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
        #expect(ClaudeHookOverlay.installsStatuslineTee(features: []))
        #expect(!ClaudeHookOverlay.installsStatuslineTee(features: [.usage]))
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

        // Still a per-session file, so a replacement spawn can rewrite the
        // path its command already names once its features are known…
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

    // MARK: - A replacement spawn's overlay settles on what `prepare` returned

    private func replacementOverlay(
        sessionKey: String, role: WatchDeskRole?, planned: [SessionModFeature]
    ) -> ReplacementSpawnOverlay {
        ReplacementSpawnOverlay.resolve(
            fallbackModels: nil,
            sessionKey: sessionKey,
            repoSettingsJSON: nil,
            watchDeskRole: role,
            worktreePath: nil,
            profileConfigDir: nil,
            promptAnswerHooks: false,
            plannedFeatures: planned)
    }

    /// Planned `usage`, but the spawn record could not be written: the spawn
    /// has no `usage`, so the desk must get its tee back — on the very file
    /// its command already names.
    @Test func aDeskPlannedWithUsageThatLaunchesWithoutItGetsTheTee() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString

        let overlay = replacementOverlay(
            sessionKey: key, role: .readOnlyCoordinator, planned: [.usage])
        #expect(!overlay.installsTee)
        #expect(try statusLine(inOverlayAt: overlay.path) == nil)

        overlay.settle(carrying: nil)

        let entry = try #require(try statusLine(inOverlayAt: overlay.path),
                                 "settling a usage-less spawn left the desk without its tee")
        let command = try #require(entry["command"] as? String)
        #expect(command.contains(StatuslineTee.scriptPath))
        #expect(command.contains(StatuslineTee.capturePath(sessionKey: key)))
    }

    @Test func aDeskPlannedWithoutUsageThatLaunchesWithItDropsTheTee() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)

        let overlay = replacementOverlay(
            sessionKey: key, role: .readOnlyCoordinator, planned: [])
        #expect(overlay.installsTee)
        #expect(try statusLine(inOverlayAt: overlay.path) != nil)
        #expect(FileManager.default.fileExists(atPath: capturePath))

        overlay.settle(carrying: sessionMod([.usage]))

        #expect(try statusLine(inOverlayAt: overlay.path) == nil)
        #expect(!FileManager.default.fileExists(atPath: capturePath))
    }

    @Test func aSettleThatAgreesWithThePlanLeavesTheOverlayAlone() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let capturePath = try seedCapture(sessionKey: key)
        let overlay = replacementOverlay(
            sessionKey: key, role: .readOnlyCoordinator, planned: [])
        let before = try Data(contentsOf: URL(fileURLWithPath: overlay.path))

        overlay.settle(carrying: sessionMod([.composerDraft]))

        #expect(try Data(contentsOf: URL(fileURLWithPath: overlay.path)) == before)
        #expect(FileManager.default.fileExists(atPath: capturePath))
    }

    @Test func settlingANonDeskOverlayNeverInstallsATee() throws {
        let scratch = Scratch()
        defer { scratch.cleanUp() }
        let key = UUID().uuidString
        let overlay = replacementOverlay(sessionKey: key, role: nil, planned: [.usage])
        #expect(!overlay.installsTee)
        #expect(overlay.path == ClaudeHookOverlay.overlayPath)

        overlay.settle(carrying: nil)

        // No per-session file appeared: a non-desk never gets a tee, whatever
        // its session mod turned out to be.
        #expect(!FileManager.default.fileExists(
            atPath: ClaudeHookOverlay.perSessionOverlayPath(sessionKey: key)))
    }
}
}
