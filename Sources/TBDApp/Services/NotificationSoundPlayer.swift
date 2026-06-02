import AppKit
import SwiftUI
import TBDShared

@MainActor
final class NotificationSoundPlayer {
    @AppStorage("enableNotificationSounds") private var enabled: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""
    @AppStorage("errorNotificationSoundName") private var errorSoundName: String = "Sosumi"
    @AppStorage("errorNotificationSoundCustomPath") private var errorCustomPath: String = ""

    func playIfEnabled(for type: NotificationType) {
        guard enabled else { return }
        let config = Self.resolveSoundConfig(
            for: type,
            defaultName: soundName, defaultCustomPath: customPath,
            errorName: errorSoundName, errorCustomPath: errorCustomPath
        )
        Self.makeSound(name: config.name, customPath: config.customPath)?.play()
    }

    func playTest() {
        Self.makeSound(name: soundName, customPath: customPath)?.play()
    }

    func playTestError() {
        Self.makeSound(name: errorSoundName, customPath: errorCustomPath)?.play()
    }

    /// Pure: pick which (name, customPath) pair to use for a notification
    /// type. `.error` uses the error sound; everything else uses the default.
    nonisolated static func resolveSoundConfig(
        for type: NotificationType,
        defaultName: String, defaultCustomPath: String,
        errorName: String, errorCustomPath: String
    ) -> (name: String, customPath: String) {
        if type == .error {
            return (errorName, errorCustomPath)
        }
        return (defaultName, defaultCustomPath)
    }

    private static func makeSound(name: String, customPath: String) -> NSSound? {
        if !customPath.isEmpty {
            return NSSound(contentsOf: URL(fileURLWithPath: customPath), byReference: true)
        }
        return NSSound(named: NSSound.Name(name))
    }

    static func systemSoundNames() -> [String] {
        let soundsDir = "/System/Library/Sounds"
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: soundsDir) else {
            return []
        }
        return files
            .filter { $0.hasSuffix(".aiff") }
            .map { ($0 as NSString).deletingPathExtension }
            .sorted()
    }
}
