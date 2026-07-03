import Testing
import Foundation
import TBDShared
@testable import TBDApp

@Suite("Mock UserDefaults selection")
struct MockUserDefaultsTests {
    @Test("uses standard defaults when mock env absent")
    @MainActor
    func standardWhenAbsent() {
        #expect(TBDAppMain.resolveUserDefaults(env: [:]) === UserDefaults.standard)
    }

    @Test("uses an isolated suite when mock env present")
    @MainActor
    func isolatedWhenMock() {
        let env = ["TBD_MOCK": "1", "TBD_MOCK_FIXTURE": "/tmp/s.json"]
        let defaults = TBDAppMain.resolveUserDefaults(env: env)
        #expect(defaults !== UserDefaults.standard)
        // The mock suite name never collides with the real TBDApp.plist domain.
        #expect(MockMode.appUserDefaultsSuiteName == "com.tbd.app.mock")
    }
}
