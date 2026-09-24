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
        let role: StagedSoundRole = type == .error ? .error : .standard
        let soundsDir = Self.userSoundsDirectory
        switch Self.notificationSoundSource(enabled: enabled, name: config.name, customPath: config.customPath) {
        case .none:
            return nil
        case .named(let name):
            // `UNNotificationSound(named:)` is only documented to search the
            // app bundle and Library/Sounds, not /System/Library/Sounds, so a
            // system sound is staged exactly like a custom one.
            let path = Self.systemSoundPath(named: name)
            guard let staged = Self.stageCustomSound(atPath: path, role: role, in: soundsDir) else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(staged))
        case .custom(let path):
            guard let staged = Self.stageCustomSound(atPath: path, role: role, in: soundsDir) else { return .default }
            return UNNotificationSound(named: UNNotificationSoundName(staged))
        case .systemDefault:
            Self.removeStagedSounds(role: role, keeping: nil, in: soundsDir)
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

    /// Which setting a staged custom sound belongs to. Each role owns exactly
    /// one staged file, so two picked files that share a name never collide.
    enum StagedSoundRole: String, CaseIterable {
        case standard = "TBD-notification"
        case error = "TBD-error-notification"
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
    /// app outside the sandbox finds them in ~/Library/Sounds.
    nonisolated static var userSoundsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Sounds", isDirectory: true)
    }

    /// Pure: where the picker's system sound names live on disk.
    nonisolated static func systemSoundPath(named name: String) -> String {
        "/System/Library/Sounds/\(name).aiff"
    }

    /// Pure: the file name a role's custom sound is staged under. The source
    /// extension is kept because the system uses it to decode the file.
    nonisolated static func stagedSoundFileName(role: StagedSoundRole, sourcePath: String) -> String {
        role.rawValue + "." + (sourcePath as NSString).pathExtension.lowercased()
    }

    /// Copy the sound file into `soundsDir` under the role's fixed name,
    /// replacing it whenever its contents differ from the source, and return
    /// that name, or nil when the copy fails. The new copy is written to a
    /// temporary name and swapped in, so a failed copy leaves the previous
    /// staged file in place. The role's staged files in other formats are
    /// removed, so each role leaves at most one file behind; this function is
    /// the reconciler for those files and runs on every post.
    @discardableResult
    nonisolated static func stageCustomSound(atPath path: String, role: StagedSoundRole, in soundsDir: URL) -> String? {
        let fm = FileManager.default
        let stagedName = stagedSoundFileName(role: role, sourcePath: path)
        let destination = soundsDir.appendingPathComponent(stagedName)
        do {
            if fm.fileExists(atPath: destination.path),
               fm.contentsEqual(atPath: path, andPath: destination.path) {
                removeStagedSounds(role: role, keeping: stagedName, in: soundsDir)
                return stagedName
            }
            try fm.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            // A dot-prefixed temporary name never matches a picker entry.
            let temporary = soundsDir.appendingPathComponent(".\(stagedName).\(UUID().uuidString).tmp")
            do {
                try fm.copyItem(at: URL(fileURLWithPath: path), to: temporary)
                if fm.fileExists(atPath: destination.path) {
                    _ = try fm.replaceItemAt(destination, withItemAt: temporary)
                } else {
                    try fm.moveItem(at: temporary, to: destination)
                }
            } catch {
                try? fm.removeItem(at: temporary)
                throw error
            }
            removeStagedSounds(role: role, keeping: stagedName, in: soundsDir)
            return stagedName
        } catch {
            logger.error("Could not stage custom notification sound: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Delete the role's staged files other than `keeping` (all of them when
    /// nil). Only exact `<role>.<playable extension>` names are touched.
    nonisolated static func removeStagedSounds(role: StagedSoundRole, keeping: String?, in soundsDir: URL) {
        let fm = FileManager.default
        for ext in notificationCenterSoundExtensions {
            let name = role.rawValue + "." + ext
            guard name != keeping else { continue }
            let url = soundsDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                try? fm.removeItem(at: url)
            }
        }
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
