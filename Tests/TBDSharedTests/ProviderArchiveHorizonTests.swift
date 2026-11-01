import Foundation
import Testing
@testable import TBDShared

@Suite("describe.archive_horizon_seconds")
struct ProviderArchiveHorizonTests {
    private func decode(_ value: String?) throws -> ProviderDescribe {
        let field = value.map { #","archive_horizon_seconds":\#($0)"# } ?? ""
        let json = #"{"contract_versions":[1],"name":"acme","provider_version":"9","capabilities":["send"]\#(field)}"#
        return try JSONDecoder().decode(ProviderDescribe.self, from: Data(json.utf8))
    }

    @Test("an absent field decodes to nil")
    func absent() throws {
        #expect(try decode(nil).archiveHorizonSeconds == nil)
    }

    @Test("values at or above one day decode as given")
    func valid() throws {
        #expect(try decode("86400").archiveHorizonSeconds == 86_400)
        #expect(try decode("172800").archiveHorizonSeconds == 172_800)
    }

    @Test("a whole-valued float is read as its integer")
    func wholeFloat() throws {
        #expect(try decode("172800.0").archiveHorizonSeconds == 172_800)
    }

    @Test("anything but an integer of at least 86400 reads as absent",
          arguments: ["null", #""172800""#, "true", "false", "172800.5", "-172800", "0", "1", "86399",
                      "[]", "{}", "1e400"])
    func hostile(_ value: String) throws {
        #expect(try decode(value).archiveHorizonSeconds == nil)
    }

    @Test("a malformed horizon costs only the horizon, never the describe")
    func describeSurvives() throws {
        let d = try decode(#""soon""#)
        #expect(d.name == "acme")
        #expect(d.providerVersion == "9")
        #expect(d.capabilities == ["send"])
    }

    @Test("the memberwise init defaults the horizon to nil")
    func memberwiseDefault() {
        #expect(ProviderDescribe(name: "acme").archiveHorizonSeconds == nil)
        #expect(ProviderDescribe(name: "acme", archiveHorizonSeconds: 90_000).archiveHorizonSeconds == 90_000)
    }
}
