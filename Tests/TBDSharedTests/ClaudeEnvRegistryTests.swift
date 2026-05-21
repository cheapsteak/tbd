import Testing
import Foundation
@testable import TBDShared

@Suite("ClaudeEnvRegistry")
struct ClaudeEnvRegistryTests {
    @Test("ClaudeEnvValue round-trips all three cases")
    func valueCodableRoundTrip() throws {
        let values: [ClaudeEnvValue] = [.bool(true), .int(7), .string("x")]
        for v in values {
            let data = try JSONEncoder().encode(v)
            let back = try JSONDecoder().decode(ClaudeEnvValue.self, from: data)
            #expect(back == v)
        }
    }

    @Test("overrides map round-trips")
    func mapCodableRoundTrip() throws {
        let map: [String: ClaudeEnvValue] = ["fullscreenRendering": .bool(false)]
        let data = try JSONEncoder().encode(map)
        let back = try JSONDecoder().decode([String: ClaudeEnvValue].self, from: data)
        #expect(back == map)
    }

    @Test("registry contains fullscreenRendering, default on")
    func registryHasFullscreen() throws {
        let setting = try #require(ClaudeEnvRegistry.setting(id: "fullscreenRendering"))
        #expect(setting.envVar == "CLAUDE_CODE_NO_FLICKER")
        #expect(setting.defaultValue == .bool(true))
    }

    @Test("fullscreen emits CLAUDE_CODE_NO_FLICKER=1 when on, nothing when off")
    func fullscreenEmit() throws {
        let setting = try #require(ClaudeEnvRegistry.setting(id: "fullscreenRendering"))
        #expect(setting.emit(.bool(true)) == "1")
        #expect(setting.emit(.bool(false)) == nil)
    }

    @Test("type-mismatched value falls back to the kind default")
    func emitTypeMismatchFallsBack() throws {
        let setting = try #require(ClaudeEnvRegistry.setting(id: "fullscreenRendering"))
        #expect(setting.emit(.string("garbage")) == "1")
    }

    @Test("decoding an unknown kind throws")
    func decodeUnknownKindThrows() {
        let data = Data(#"{"kind":"date","value":1}"#.utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ClaudeEnvValue.self, from: data)
        }
    }
}
