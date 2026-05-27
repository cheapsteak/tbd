import Foundation
import Testing
import TBDShared

@Suite("Appearance RPC Handlers")
struct AppearanceHandlerTests {
    @Test("AppearanceUpdateColorFgBgParams encodes and decodes correctly")
    func testParamsRoundTrip() throws {
        let params = AppearanceUpdateColorFgBgParams(value: "0;15")
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(params)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(AppearanceUpdateColorFgBgParams.self, from: encoded)

        #expect(decoded.value == "0;15")
    }

    @Test("AppearanceUpdateColorFgBgParams accepts dark and light values")
    func testParamsValues() throws {
        let darkValue = AppearanceUpdateColorFgBgParams(value: "15;0")
        let lightValue = AppearanceUpdateColorFgBgParams(value: "0;15")

        let encoder = JSONEncoder()
        let darkEncoded = try encoder.encode(darkValue)
        let lightEncoded = try encoder.encode(lightValue)

        let decoder = JSONDecoder()
        let darkDecoded = try decoder.decode(AppearanceUpdateColorFgBgParams.self, from: darkEncoded)
        let lightDecoded = try decoder.decode(AppearanceUpdateColorFgBgParams.self, from: lightEncoded)

        #expect(darkDecoded.value == "15;0")
        #expect(lightDecoded.value == "0;15")
    }
}
