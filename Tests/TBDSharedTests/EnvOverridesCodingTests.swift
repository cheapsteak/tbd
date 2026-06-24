import Testing
@testable import TBDShared

@Suite struct EnvOverridesCodingTests {
    @Test func roundTrips() throws {
        let json = EnvOverridesCoding.encode(["A": "1", "B": "two"])
        #expect(EnvOverridesCoding.decode(json) == ["A": "1", "B": "two"])
    }
    @Test func nilAndEmptyEncodeToNil() {
        #expect(EnvOverridesCoding.encode(nil) == nil)
        #expect(EnvOverridesCoding.encode([:]) == nil)
    }
    @Test func corruptDecodesToEmpty() {
        #expect(EnvOverridesCoding.decode("not json") == [:])
        #expect(EnvOverridesCoding.decode(nil) == [:])
    }
}
