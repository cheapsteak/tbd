import Testing
import Foundation
@testable import TBDDaemonLib
@testable import TBDShared

@Test func writesFallbackFileAtTargetPath() throws {
    let tempRoot = NSTemporaryDirectory() + "tbd-skill-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tempRoot) }

    let writer = SkillFileWriter(applicationSupportRoot: tempRoot)
    try writer.writeFallback()

    let target = tempRoot + "/TBD/skill/SKILL.md"
    #expect(FileManager.default.fileExists(atPath: target))

    let written = try String(contentsOfFile: target, encoding: .utf8)
    #expect(written == TBDSkillContent.body)
}

@Test func overwritesExistingFile() throws {
    let tempRoot = NSTemporaryDirectory() + "tbd-skill-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tempRoot) }

    let dir = tempRoot + "/TBD/skill"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try "stale".write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)

    let writer = SkillFileWriter(applicationSupportRoot: tempRoot)
    try writer.writeFallback()

    let written = try String(contentsOfFile: dir + "/SKILL.md", encoding: .utf8)
    #expect(written == TBDSkillContent.body)
}

@Test func fallbackPathMatchesExpectedShape() {
    let writer = SkillFileWriter(applicationSupportRoot: "/var/test")
    #expect(writer.fallbackPath() == "/var/test/TBD/skill/SKILL.md")
}
