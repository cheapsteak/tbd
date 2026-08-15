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
}
}
