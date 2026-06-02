import Foundation
import Testing
@testable import TBDApp
import TBDShared

@Suite("NotificationSoundPlayer.resolveSoundConfig")
struct NotificationSoundPlayerTests {

    @Test func errorTypeResolvesErrorSound() {
        let r = NotificationSoundPlayer.resolveSoundConfig(
            for: .error,
            defaultName: "Blow", defaultCustomPath: "",
            errorName: "Sosumi", errorCustomPath: ""
        )
        #expect(r.name == "Sosumi")
        #expect(r.customPath == "")
    }

    @Test func nonErrorTypeResolvesDefaultSound() {
        let r = NotificationSoundPlayer.resolveSoundConfig(
            for: .responseComplete,
            defaultName: "Blow", defaultCustomPath: "",
            errorName: "Sosumi", errorCustomPath: ""
        )
        #expect(r.name == "Blow")
    }

    @Test func errorCustomPathIsCarried() {
        let r = NotificationSoundPlayer.resolveSoundConfig(
            for: .error,
            defaultName: "Blow", defaultCustomPath: "",
            errorName: "Sosumi", errorCustomPath: "/tmp/alarm.aiff"
        )
        #expect(r.customPath == "/tmp/alarm.aiff")
    }
}
