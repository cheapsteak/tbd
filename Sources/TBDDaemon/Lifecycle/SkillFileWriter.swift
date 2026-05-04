import Foundation
import TBDShared
import os

/// Writes the canonical TBD skill body to the failsafe path under
/// Application Support. Called once at daemon startup. Failures are
/// logged but never thrown to the caller — the legacy injection still
/// works without this file.
struct SkillFileWriter {
    private static let logger = Logger(subsystem: "com.tbd.daemon", category: "skill")

    let applicationSupportRoot: String

    init(applicationSupportRoot: String? = nil) {
        if let explicit = applicationSupportRoot {
            self.applicationSupportRoot = explicit
        } else {
            // ~/Library/Application Support
            let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            self.applicationSupportRoot = urls.first?.path
                ?? (FileManager.default.homeDirectoryForCurrentUser.path + "/Library/Application Support")
        }
    }

    /// Absolute path the daemon writes to, e.g.
    /// `/Users/chang/Library/Application Support/TBD/skill/SKILL.md`.
    func fallbackPath() -> String {
        applicationSupportRoot + "/TBD/skill/SKILL.md"
    }

    /// Write the canonical body, creating parent directories as needed.
    func writeFallback() throws {
        let path = fallbackPath()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try TBDSkillContent.body.write(toFile: path, atomically: true, encoding: .utf8)
        Self.logger.info("Wrote fallback skill file to \(path, privacy: .public)")
    }
}
