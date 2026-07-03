import Testing
import Foundation
@testable import TBDShared

@Suite("MockMode")
struct MockModeTests {
    @Test("mock disabled when TBD_MOCK is absent")
    func disabledWhenAbsent() {
        #expect(MockMode.fromEnvironment([:]) == nil)
        #expect(MockMode.isActive(in: [:]) == false)
    }

    @Test("mock disabled when fixture path missing")
    func disabledWithoutFixture() {
        #expect(MockMode.fromEnvironment(["TBD_MOCK": "1"]) == nil)
    }

    @Test("mock enabled for truthy flag + fixture path")
    func enabledWhenSet() {
        let env = ["TBD_MOCK": "1", "TBD_MOCK_FIXTURE": "/tmp/s.json"]
        #expect(MockMode.fromEnvironment(env) == .enabled(fixturePath: "/tmp/s.json"))
        #expect(MockMode.isActive(in: env) == true)
    }

    @Test("mock flag accepts \"true\" and is case-insensitive")
    func acceptsTrue() {
        let env = ["TBD_MOCK": "TRUE", "TBD_MOCK_FIXTURE": "/tmp/s.json"]
        #expect(MockMode.fromEnvironment(env) == .enabled(fixturePath: "/tmp/s.json"))
    }

    @Test("mock disabled for empty or falsey flag")
    func disabledForFalsey() {
        #expect(MockMode.fromEnvironment(["TBD_MOCK": "0", "TBD_MOCK_FIXTURE": "/x"]) == nil)
        #expect(MockMode.fromEnvironment(["TBD_MOCK": "", "TBD_MOCK_FIXTURE": "/x"]) == nil)
    }

    @Test("scenario decodes from JSON with omitted optional fields")
    func scenarioDecodes() throws {
        let json = """
        {"repos":[{"path":"/tmp/acme","displayName":"acme","worktrees":[
          {"name":"main","branch":"main","status":"main"},
          {"name":"feat","branch":"tbd/feat","prStatus":{"number":7,"url":"https://x/7","state":"mergeable"},
           "terminals":[{"kind":"claude","activityState":"working","transcriptFixture":"long-session.jsonl"}]}
        ]}]}
        """
        let scenario = try JSONDecoder().decode(MockScenario.self, from: Data(json.utf8))
        #expect(scenario.repos.count == 1)
        #expect(scenario.repos[0].defaultBranch == nil)   // optional, not provided
        #expect(scenario.repos[0].worktrees[1].prStatus?.number == 7)
        #expect(scenario.repos[0].worktrees[1].terminals?.first?.transcriptFixture == "long-session.jsonl")
    }
}
