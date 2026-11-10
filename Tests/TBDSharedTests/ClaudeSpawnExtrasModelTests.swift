import Foundation
import Testing
@testable import TBDShared

/// The Claude model a tab was started with rides in its stored spawn extras,
/// so every later start can pass it again. These pin the JSON shape and the
/// blank-means-nothing rule.
@Suite struct ClaudeSpawnExtrasModelTests {

    @Test func modelRoundTripsThroughJSON() throws {
        let extras = ClaudeSpawnExtras(model: "opus")
        let data = try JSONEncoder().encode(extras)

        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["model"] as? String == "opus")
        // A nil field leaves its key out.
        #expect(object["pluginDirs"] == nil)
        #expect(object["claudeSettingsOverlay"] == nil)

        let decoded = try JSONDecoder().decode(ClaudeSpawnExtras.self, from: data)
        #expect(decoded == extras)
    }

    /// Every row written before the model joined the object.
    @Test func rowWithoutModelKeyDecodesNil() throws {
        let data = Data(#"{"pluginDirs":["/a"]}"#.utf8)
        let decoded = try JSONDecoder().decode(ClaudeSpawnExtras.self, from: data)
        #expect(decoded.model == nil)
        #expect(decoded.pluginDirs == ["/a"])
        #expect(decoded == ClaudeSpawnExtras(pluginDirs: ["/a"]))
    }

    @Test func nonEmptyKeepsModelAlone() {
        let kept = ClaudeSpawnExtras(model: "opus").nonEmpty
        #expect(kept?.model == "opus")
        #expect(kept?.pluginDirs == nil)
        #expect(kept?.claudeSettingsOverlay == nil)
    }

    /// A non-blank model is kept as given, not trimmed.
    @Test func nonEmptyKeepsModelVerbatim() {
        #expect(ClaudeSpawnExtras(model: " claude-opus-5 ").nonEmpty?.model == " claude-opus-5 ")
    }

    /// A blank model from the app or a script must never become
    /// `ANTHROPIC_MODEL=  `.
    @Test func nonEmptyDropsBlankModel() {
        #expect(ClaudeSpawnExtras(model: "  ").nonEmpty == nil)
        #expect(ClaudeSpawnExtras(model: "").nonEmpty == nil)
        #expect(ClaudeSpawnExtras(model: "\n\t").nonEmpty == nil)
    }

    /// A blank model beside other values is dropped, and the rest kept.
    @Test func nonEmptyDropsBlankModelBesideOtherValues() {
        let extras = ClaudeSpawnExtras(pluginDirs: ["/a"], model: " ").nonEmpty
        #expect(extras == ClaudeSpawnExtras(pluginDirs: ["/a"]))
    }
}
