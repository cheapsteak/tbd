import Foundation
import Testing
import TBDShared

@Suite("NightwatchMode Codable Tests")
struct NightwatchModeTests {
    @Test("Config decodes nightwatch_mode from JSON")
    func decodeNightwatchMode() throws {
        let json = """
        {
            "nightwatchMode": "nightwatch"
        }
        """
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "TestError", code: -1, userInfo: nil)
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        #expect(config.nightwatchMode == .nightwatch)
    }

    @Test("Config decodes missing nightwatch_mode as .off (backward compat)")
    func decodeMissingNightwatchMode() throws {
        // Old JSON row with no nightwatch_mode key should default to .off
        let json = """
        {
            "defaultProfileID": null,
            "primaryAgentPreference": "claude"
        }
        """
        guard let data = json.data(using: .utf8) else {
            throw NSError(domain: "TestError", code: -1, userInfo: nil)
        }
        let config = try JSONDecoder().decode(Config.self, from: data)
        #expect(config.nightwatchMode == .off)
    }

    @Test("All NightwatchMode cases encode/decode correctly")
    func allModesRoundTrip() throws {
        for mode in NightwatchMode.allCases {
            let config = Config(nightwatchMode: mode)
            let encoded = try JSONEncoder().encode(config)
            let decoded = try JSONDecoder().decode(Config.self, from: encoded)
            #expect(decoded.nightwatchMode == mode)
        }
    }

    @Test("NightwatchMode init(rawValue:) works for all cases")
    func initFromRawValue() {
        #expect(NightwatchMode(rawValue: "off") == .off)
        #expect(NightwatchMode(rawValue: "daywatch") == .daywatch)
        #expect(NightwatchMode(rawValue: "nightwatch") == .nightwatch)
        #expect(NightwatchMode(rawValue: "invalid") == nil)
    }
}
