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

@Suite("NotificationSoundPlayer.notificationSoundSource")
struct NotificationSoundSourceTests {

    @Test func soundsOffAttachesNoSound() {
        let r = NotificationSoundPlayer.notificationSoundSource(enabled: false, name: "Blow", customPath: "/tmp/a.aiff")
        #expect(r == .none)
    }

    @Test func systemSoundIsAttachedByName() {
        let r = NotificationSoundPlayer.notificationSoundSource(enabled: true, name: "Blow", customPath: "")
        #expect(r == .named("Blow"))
    }

    @Test func playableCustomFileIsStaged() {
        for path in ["/tmp/a.aiff", "/tmp/a.AIF", "/tmp/a.wav", "/tmp/a.caf"] {
            #expect(NotificationSoundPlayer.notificationSoundSource(enabled: true, name: "Blow", customPath: path)
                == .custom(path: path))
        }
    }

    @Test func unplayableCustomFileFallsBackToSystemDefault() {
        for path in ["/tmp/a.mp3", "/tmp/a.m4a"] {
            #expect(NotificationSoundPlayer.notificationSoundSource(enabled: true, name: "Blow", customPath: path)
                == .systemDefault)
        }
    }

    @Test func stagedNameIsPrefixedBasename() {
        #expect(NotificationSoundPlayer.stagedSoundFileName(forSourcePath: "/Users/acme/alarm.aiff") == "TBD-alarm.aiff")
    }
}
