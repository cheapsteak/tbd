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

    @Test func stagedNameIsFixedPerRole() {
        #expect(NotificationSoundPlayer.stagedSoundFileName(role: .standard, sourcePath: "/Users/acme/alarm.AIFF")
            == "TBD-notification.aiff")
        #expect(NotificationSoundPlayer.stagedSoundFileName(role: .error, sourcePath: "/Users/acme/alarm.wav")
            == "TBD-error-notification.wav")
    }
}

@Suite("NotificationSoundPlayer.stageCustomSound")
struct StageCustomSoundTests {

    private func makeDirs() throws -> (source: URL, sounds: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("tbd-sound-staging-\(UUID().uuidString)", isDirectory: true)
        let source = root.appendingPathComponent("source", isDirectory: true)
        let sounds = root.appendingPathComponent("Sounds", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        return (source, sounds)
    }

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func contents(_ url: URL) throws -> String {
        String(bytes: try Data(contentsOf: url), encoding: .utf8) ?? ""
    }

    @Test func copiesIntoAMissingSoundsDirectory() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let file = dirs.source.appendingPathComponent("alarm.aiff")
        try write("one", to: file)

        let name = NotificationSoundPlayer.stageCustomSound(atPath: file.path, role: .standard, in: dirs.sounds)

        #expect(name == "TBD-notification.aiff")
        #expect(try contents(dirs.sounds.appendingPathComponent("TBD-notification.aiff")) == "one")
    }

    @Test func sameBasenameForBothRolesDoesNotCollide() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let a = dirs.source.appendingPathComponent("a", isDirectory: true)
        let b = dirs.source.appendingPathComponent("b", isDirectory: true)
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        try write("standard", to: a.appendingPathComponent("alarm.aiff"))
        try write("error", to: b.appendingPathComponent("alarm.aiff"))

        NotificationSoundPlayer.stageCustomSound(atPath: a.appendingPathComponent("alarm.aiff").path, role: .standard, in: dirs.sounds)
        NotificationSoundPlayer.stageCustomSound(atPath: b.appendingPathComponent("alarm.aiff").path, role: .error, in: dirs.sounds)

        #expect(try contents(dirs.sounds.appendingPathComponent("TBD-notification.aiff")) == "standard")
        #expect(try contents(dirs.sounds.appendingPathComponent("TBD-error-notification.aiff")) == "error")
    }

    @Test func changedSourceReplacesTheStagedCopy() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let first = dirs.source.appendingPathComponent("first.wav")
        let second = dirs.source.appendingPathComponent("second.wav")
        try write("first", to: first)
        try write("second", to: second)

        NotificationSoundPlayer.stageCustomSound(atPath: first.path, role: .standard, in: dirs.sounds)
        NotificationSoundPlayer.stageCustomSound(atPath: second.path, role: .standard, in: dirs.sounds)

        #expect(try contents(dirs.sounds.appendingPathComponent("TBD-notification.wav")) == "second")
    }

    @Test func switchingFormatRemovesTheOldStagedFile() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let aiff = dirs.source.appendingPathComponent("x.aiff")
        let wav = dirs.source.appendingPathComponent("x.wav")
        try write("aiff", to: aiff)
        try write("wav", to: wav)

        NotificationSoundPlayer.stageCustomSound(atPath: aiff.path, role: .standard, in: dirs.sounds)
        NotificationSoundPlayer.stageCustomSound(atPath: wav.path, role: .standard, in: dirs.sounds)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dirs.sounds.appendingPathComponent("TBD-notification.aiff").path))
        #expect(fm.fileExists(atPath: dirs.sounds.appendingPathComponent("TBD-notification.wav").path))
    }

    @Test func missingSourceReturnsNil() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let missing = dirs.source.appendingPathComponent("gone.aiff")

        #expect(NotificationSoundPlayer.stageCustomSound(atPath: missing.path, role: .standard, in: dirs.sounds) == nil)
    }

    @Test func failedReplacementKeepsThePreviousStagedFile() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let good = dirs.source.appendingPathComponent("good.aiff")
        try write("good", to: good)
        NotificationSoundPlayer.stageCustomSound(atPath: good.path, role: .standard, in: dirs.sounds)

        // The copy step fails; the last good copy is kept and still played.
        let missing = dirs.source.appendingPathComponent("gone.aiff")
        #expect(NotificationSoundPlayer.stageCustomSound(atPath: missing.path, role: .standard, in: dirs.sounds)
            == "TBD-notification.aiff")

        #expect(try contents(dirs.sounds.appendingPathComponent("TBD-notification.aiff")) == "good")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dirs.sounds.path)
        #expect(leftovers == ["TBD-notification.aiff"])
    }

    @Test func systemSoundNameStagesFromSystemSounds() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        let path = NotificationSoundPlayer.systemSoundPath(named: "Blow")
        #expect(path == "/System/Library/Sounds/Blow.aiff")
        // Every macOS install ships Blow.aiff; skip the copy check if a
        // stripped-down runner does not.
        guard FileManager.default.fileExists(atPath: path) else { return }

        let name = NotificationSoundPlayer.stageCustomSound(atPath: path, role: .error, in: dirs.sounds)

        #expect(name == "TBD-error-notification.aiff")
        #expect(FileManager.default.contentsEqual(
            atPath: path, andPath: dirs.sounds.appendingPathComponent("TBD-error-notification.aiff").path))
    }

    @Test func removeStagedSoundsLeavesOtherRolesAndUserFiles() throws {
        let dirs = try makeDirs()
        defer { try? FileManager.default.removeItem(at: dirs.source.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: dirs.sounds, withIntermediateDirectories: true)
        for name in ["TBD-notification.aiff", "TBD-error-notification.aiff", "Mine.aiff"] {
            try write(name, to: dirs.sounds.appendingPathComponent(name))
        }

        NotificationSoundPlayer.removeStagedSounds(role: .standard, keeping: nil, in: dirs.sounds)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: dirs.sounds.appendingPathComponent("TBD-notification.aiff").path))
        #expect(fm.fileExists(atPath: dirs.sounds.appendingPathComponent("TBD-error-notification.aiff").path))
        #expect(fm.fileExists(atPath: dirs.sounds.appendingPathComponent("Mine.aiff").path))
    }
}
