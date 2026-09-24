import AppKit
import SwiftUI
import TBDShared
import UserNotifications
import os

private let logger = Logger(subsystem: "com.tbd.app", category: "NotificationSoundPlayer")

@MainActor
final class NotificationSoundPlayer {
    @AppStorage("enableNotificationSounds") private var enabled: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""
    @AppStorage("errorNotificationSoundName") private var errorSoundName: String = "Sosumi"
    @AppStorage("errorNotificationSoundCustomPath") private var errorCustomPath: String = ""

    /// The sound the notification center should play for a notification of
    /// this type, or nil when sounds are off. Notification sounds are never
    /// played directly: the center plays them, so Focus and Do Not Disturb
    /// silence them exactly as they suppress the banner. Only the settings
    /// "Test" buttons below play through `NSSound`, because there the user is
    /// asking to hear the sound.
    func notificationSound(for type: NotificationType) -> UNNotificationSound? {
        let config = Self.resolveSoundConfig(
            for: type,
            defaultName: soundName, defaultCustomPath: customPath,
            errorName: errorSoundName, errorCustomPath: errorCustomPath
        )
        switch Self.notificationSoundSource(enabled: enabled, name: config.name, customPath: config.customPath) {
        case .none:
            return nil
        case .named(let name):
            return UNNotificationSound(named: UNNotificationSoundName(name))
        case .custom(let path):
            guard let staged = Self.stageCustomSound(atPath: path) else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(staged))
        case .systemDefault:
            return .default
        }
    }

    enum NotificationSoundSource: Equatable {
        /// Sounds are turned off.
        case none
        /// A sound the system finds by name (the picker lists
        /// /System/Library/Sounds).
        case named(String)
        /// A user-picked file in a format the notification center can play.
        case custom(path: String)
        /// A user-picked file the notification center cannot play (MP3, M4A):
        /// the system default sound stands in.
        case systemDefault
    }

    /// Formats `UNNotificationSound` accepts; MP3 and M4A are not among them.
    nonisolated static let notificationCenterSoundExtensions: Set<String> = ["aiff", "aif", "wav", "caf"]

    /// Pure: which sound source a notification gets from the settings.
    nonisolated static func notificationSoundSource(
        enabled: Bool, name: String, customPath: String
    ) -> NotificationSoundSource {
        guard enabled else { return .none }
        guard !customPath.isEmpty else { return .named(name) }
        let ext = (customPath as NSString).pathExtension.lowercased()
        guard notificationCenterSoundExtensions.contains(ext) else { return .systemDefault }
        return .custom(path: customPath)
    }

    /// The notification center only plays files it can find by name, and an
    /// app outside the sandbox finds them in ~/Library/Sounds. Copy the picked
    /// file there under a TBD-prefixed name (refreshing it when the source is
    /// newer) and return that name, or nil when the copy fails.
    private static func stageCustomSound(atPath path: String) -> String? {
        let fm = FileManager.default
        let source = URL(fileURLWithPath: path)
        let stagedName = stagedSoundFileName(forSourcePath: path)
        let soundsDir = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds", isDirectory: true)
        let destination = soundsDir.appendingPathComponent(stagedName)
        do {
            let sourceDate = try source.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if fm.fileExists(atPath: destination.path) {
                let destDate = try destination.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
                if let sourceDate, let destDate, destDate >= sourceDate { return stagedName }
                try fm.removeItem(at: destination)
            }
            try fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: destination)
            return stagedName
        } catch {
            logger.error("Could not stage custom notification sound: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Pure: the ~/Library/Sounds file name a custom sound is staged under.
    nonisolated static func stagedSoundFileName(forSourcePath path: String) -> String {
        "TBD-" + (path as NSString).lastPathComponent
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
