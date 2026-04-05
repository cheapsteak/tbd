import AppKit
import SwiftUI

@MainActor
final class NotificationSoundPlayer {
    @AppStorage("enableNotificationSounds") private var enabled: Bool = true
    @AppStorage("notificationSoundName") private var soundName: String = "Blow"
    @AppStorage("notificationSoundCustomPath") private var customPath: String = ""

    func playIfEnabled() {
        guard enabled else { return }
        resolveSound()?.play()
    }

    func playTest() {
        resolveSound()?.play()
    }

    private func resolveSound() -> NSSound? {
        if !customPath.isEmpty {
            return NSSound(contentsOf: URL(fileURLWithPath: customPath), byReference: true)
        }
        return NSSound(named: NSSound.Name(soundName))
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
